from __future__ import annotations

import base64
import itertools
import os
from dataclasses import dataclass


@dataclass
class SegmentResult:
    segment_id: str
    start_seconds: float
    end_seconds: float
    source_text: str
    translated_text: str


class ProcessingPipeline:
    def __init__(self) -> None:
        self.mode = os.getenv("TT_PIPELINE_MODE", "mock")
        self.segment_counter = itertools.count(1)
        self.elapsed_seconds = 0.0
        self.target_language = "vie_Latn"

    def warmup(self, target_language: str) -> str:
        self.target_language = target_language or "vie_Latn"
        if self.mode != "mock":
            return (
                "Real mode selected, but pipeline.py still contains placeholder logic. "
                "Implement faster-whisper + NLLB loading here."
            )
        return f"Mock pipeline ready for {self.target_language}"

    def process_audio_chunk(
        self,
        pcm_base64: str,
        sample_rate: int,
        channels: int,
    ) -> SegmentResult:
        raw = base64.b64decode(pcm_base64.encode("utf-8"))
        bytes_per_second = max(sample_rate, 1) * max(channels, 1) * 2
        chunk_duration = max(len(raw) / bytes_per_second, 0.5)

        start = self.elapsed_seconds
        end = start + chunk_duration
        self.elapsed_seconds = end

        index = next(self.segment_counter)
        source_text = f"Mock transcript segment {index} ({chunk_duration:.1f}s audio)"
        translated_text = self._translate_mock(source_text)

        return SegmentResult(
            segment_id=f"segment-{index}",
            start_seconds=start,
            end_seconds=end,
            source_text=source_text,
            translated_text=translated_text,
        )

    def _translate_mock(self, source_text: str) -> str:
        if self.target_language == "vie_Latn":
            return f"Ban dich mau: {source_text}"
        if self.target_language == "eng_Latn":
            return f"Mock translation: {source_text}"
        return f"[{self.target_language}] {source_text}"
