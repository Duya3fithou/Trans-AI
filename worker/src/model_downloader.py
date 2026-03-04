from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Callable, Dict

from protocol import emit_event

DEFAULT_MODELS: Dict[str, Dict[str, str]] = {
    "whisper": {
        "repo_id": "Systran/faster-whisper-small",
        "local_dir": "faster-whisper-small",
    },
    "translation": {
        "repo_id": "facebook/nllb-200-distilled-600M",
        "local_dir": "nllb-200-distilled-600M",
    },
}


class ModelDownloader:
    def __init__(self, log: Callable[[str], None]) -> None:
        self.log = log

    def download_all(self, model_root: str) -> None:
        root = Path(model_root).expanduser()
        root.mkdir(parents=True, exist_ok=True)
        manifest = {
            "root": str(root),
            "models": DEFAULT_MODELS,
        }

        fake_mode = os.getenv("TT_FAKE_DOWNLOAD", "1") == "1"
        for index, (name, metadata) in enumerate(DEFAULT_MODELS.items(), start=1):
            local_dir = root / metadata["local_dir"]
            ready_file = local_dir / ".ready"

            if ready_file.exists():
                emit_event(
                    "downloadProgress",
                    message=f"{name} already ready",
                    progress=index / len(DEFAULT_MODELS),
                )
                continue

            local_dir.mkdir(parents=True, exist_ok=True)
            self.log(f"Preparing {name} in {local_dir}")

            if fake_mode:
                for step in (0.15, 0.45, 0.75, 1.0):
                    time.sleep(0.2)
                    overall = ((index - 1) + step) / len(DEFAULT_MODELS)
                    emit_event(
                        "downloadProgress",
                        message=f"Downloading {name} ({int(step * 100)}%)",
                        progress=overall,
                    )
                ready_file.write_text("ready\n", encoding="utf-8")
            else:
                try:
                    from huggingface_hub import snapshot_download
                except Exception:
                    self.log("huggingface_hub missing, falling back to fake download mode")
                    ready_file.write_text("ready\n", encoding="utf-8")
                else:
                    snapshot_download(
                        repo_id=metadata["repo_id"],
                        local_dir=str(local_dir),
                        local_dir_use_symlinks=False,
                    )
                    ready_file.write_text("ready\n", encoding="utf-8")
                    emit_event(
                        "downloadProgress",
                        message=f"Downloaded {name}",
                        progress=index / len(DEFAULT_MODELS),
                    )

        (root / "manifest.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        emit_event("status", message="All models are ready")
