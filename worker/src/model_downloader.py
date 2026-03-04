from __future__ import annotations

import json
import os
import time
from fnmatch import fnmatch
from pathlib import Path
from typing import Callable, Dict, List

from protocol import emit_event

DEFAULT_MODELS: Dict[str, Dict[str, object]] = {
    "whisper": {
        "repo_id": "Systran/faster-whisper-small",
        "local_dir": "faster-whisper-small",
        "allow_patterns": [
            "config.json",
            "model.bin",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "preprocessor_config.json",
            "vocabulary.*",
            "vocab.*",
            "merges.txt",
        ],
        "required_files": [
            "config.json",
            "model.bin",
        ],
    },
    "translation": {
        "repo_id": "facebook/nllb-200-distilled-600M",
        "local_dir": "nllb-200-distilled-600M",
        "allow_patterns": [
            "config.json",
            "generation_config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "sentencepiece.bpe.model",
            "spiece.model",
            "pytorch_model*.bin*",
            "model*.safetensors*",
        ],
        "required_files": [
            "config.json",
        ],
    },
}


class ModelDownloader:
    def __init__(self, log: Callable[[str], None]) -> None:
        self.log = log

    def download_all(self, model_root: str) -> None:
        root = Path(model_root).expanduser()
        root.mkdir(parents=True, exist_ok=True)

        fake_mode = os.getenv("TT_FAKE_DOWNLOAD", "1") == "1"
        model_count = len(DEFAULT_MODELS)

        manifest: Dict[str, object] = {
            "root": str(root),
            "models": {},
            "fake_mode": fake_mode,
            "timestamp": int(time.time()),
        }

        for index, (name, metadata) in enumerate(DEFAULT_MODELS.items(), start=1):
            local_dir = root / str(metadata["local_dir"])
            local_dir.mkdir(parents=True, exist_ok=True)
            ready_file = local_dir / ".ready"
            model_manifest: Dict[str, object] = {
                "repo_id": metadata["repo_id"],
                "local_dir": str(local_dir),
            }

            required_files = [str(item) for item in metadata.get("required_files", [])]
            if self._is_model_ready(local_dir, required_files):
                emit_event(
                    "downloadProgress",
                    message=f"{name} already ready",
                    progress=index / model_count,
                )
                model_manifest["status"] = "ready"
                manifest["models"][name] = model_manifest
                continue

            self.log(f"Preparing {name} in {local_dir}")
            model_base = (index - 1) / model_count
            model_span = 1 / model_count

            if fake_mode:
                for step in (0.15, 0.45, 0.75, 1.0):
                    time.sleep(0.2)
                    emit_event(
                        "downloadProgress",
                        message=f"Downloading {name} ({int(step * 100)}%)",
                        progress=model_base + (step * model_span),
                    )
                model_manifest["status"] = "fake-downloaded"
            else:
                downloaded_files = self._download_real_model(
                    model_name=name,
                    metadata=metadata,
                    local_dir=local_dir,
                    model_base=model_base,
                    model_span=model_span,
                )
                model_manifest["downloaded_files"] = downloaded_files
                model_manifest["status"] = "downloaded"

            ready_file.write_text("ready\n", encoding="utf-8")
            manifest["models"][name] = model_manifest

        (root / "manifest.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        emit_event("status", message="All models are ready")

    def _download_real_model(
        self,
        model_name: str,
        metadata: Dict[str, object],
        local_dir: Path,
        model_base: float,
        model_span: float,
    ) -> List[str]:
        try:
            from huggingface_hub import HfApi, hf_hub_download
        except Exception as exc:  # pragma: no cover - surfaced to UI
            raise RuntimeError(
                "huggingface_hub is not installed. Run: pip install -r worker/requirements.txt"
            ) from exc

        repo_id = str(metadata["repo_id"])
        api = HfApi()

        allow_patterns = [str(item) for item in metadata.get("allow_patterns", [])]
        files = self._select_repo_files(api=api, repo_id=repo_id, allow_patterns=allow_patterns)
        if model_name == "translation":
            files = self._prefer_single_weight_format(files)

        if not files:
            raise RuntimeError(f"No files selected for model {model_name} ({repo_id})")

        total_files = len(files)
        emit_event(
            "downloadProgress",
            message=f"Downloading {model_name} (0/{total_files} files)",
            progress=model_base,
        )

        for file_index, filename in enumerate(files, start=1):
            hf_hub_download(
                repo_id=repo_id,
                filename=filename,
                repo_type="model",
                local_dir=str(local_dir),
                local_dir_use_symlinks=False,
                force_download=False,
            )

            progress = model_base + ((file_index / total_files) * model_span)
            emit_event(
                "downloadProgress",
                message=f"Downloading {model_name} ({file_index}/{total_files} files)",
                progress=progress,
            )

        return files

    def _select_repo_files(
        self,
        api,
        repo_id: str,
        allow_patterns: List[str],
    ) -> List[str]:
        repo_files = list(api.list_repo_files(repo_id=repo_id, repo_type="model"))
        filtered = [
            filename
            for filename in repo_files
            if not filename.startswith(".") and not filename.endswith(".md")
        ]

        if not allow_patterns:
            return sorted(filtered)

        selected = [
            filename
            for filename in filtered
            if any(fnmatch(filename, pattern) for pattern in allow_patterns)
        ]

        if selected:
            return sorted(selected)

        self.log(
            f"No file matched allow_patterns for {repo_id}. Falling back to filtered repo file list."
        )
        return sorted(filtered)

    def _is_model_ready(self, local_dir: Path, required_files: List[str]) -> bool:
        if not (local_dir / ".ready").exists():
            return False

        for relative_file in required_files:
            if not (local_dir / relative_file).exists():
                return False

        return True

    def _prefer_single_weight_format(self, files: List[str]) -> List[str]:
        has_safetensors = any("safetensors" in filename for filename in files)
        has_pytorch_bin = any(
            filename.startswith("pytorch_model") and ".bin" in filename
            for filename in files
        )

        if not (has_safetensors and has_pytorch_bin):
            return files

        self.log("Both safetensors and pytorch_model bin files detected. Preferring safetensors.")
        return [
            filename
            for filename in files
            if not (filename.startswith("pytorch_model") and ".bin" in filename)
        ]
