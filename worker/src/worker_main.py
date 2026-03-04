from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict

from model_downloader import ModelDownloader
from pipeline import ProcessingPipeline
from protocol import PipeClosedError, emit_event


def log(message: str) -> None:
    log_dir = Path.cwd() / "worker" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    with (log_dir / "worker.log").open("a", encoding="utf-8") as handle:
        handle.write(message + "\n")


def handle_command(
    command: Dict[str, Any],
    downloader: ModelDownloader,
    pipeline: ProcessingPipeline,
) -> bool:
    command_type = command.get("type")

    if command_type == "downloadModels":
        pipeline.set_model_root(command["modelRoot"])
        downloader.download_all(command["modelRoot"])
        return True

    if command_type == "warmup":
        message = pipeline.warmup(command.get("targetLanguage", "vie_Latn"))
        emit_event("status", message=message)
        return True

    if command_type == "processAudio":
        result = pipeline.process_audio_chunk(
            pcm_base64=command["audioBase64"],
            sample_rate=int(command.get("sampleRate", 16000)),
            channels=int(command.get("channels", 1)),
        )
        if result.partial is not None:
            emit_event(
                "partialSegment",
                partial={
                    "partial_id": result.partial.partial_id,
                    "start_seconds": result.partial.start_seconds,
                    "end_seconds": result.partial.end_seconds,
                    "source_text": result.partial.source_text,
                },
            )
        if result.segment is not None:
            emit_event(
                "segment",
                segment={
                    "segment_id": result.segment.segment_id,
                    "start_seconds": result.segment.start_seconds,
                    "end_seconds": result.segment.end_seconds,
                    "source_text": result.segment.source_text,
                    "translated_text": result.segment.translated_text,
                },
            )
        return True

    if command_type == "stop":
        emit_event("status", message="Worker stopping")
        return False

    emit_event("error", message=f"Unknown command: {command_type}")
    return True


def main() -> int:
    downloader = ModelDownloader(log=log)
    pipeline = ProcessingPipeline()

    try:
        emit_event("status", message="Worker booted")
    except PipeClosedError:
        return 0
    log("Worker started")

    for line in sys.stdin:
        payload = line.strip()
        if not payload:
            continue
        try:
            command = json.loads(payload)
        except json.JSONDecodeError as exc:
            emit_event("error", message=f"Invalid JSON: {exc}")
            continue

        try:
            should_continue = handle_command(command, downloader, pipeline)
        except PipeClosedError:
            break
        except Exception as exc:  # pragma: no cover - top-level protection
            log(f"Command failure: {exc}")
            try:
                emit_event("error", message=f"Command failure: {exc}")
            except PipeClosedError:
                break
            should_continue = True

        if not should_continue:
            break

    log("Worker exited")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
