from __future__ import annotations

import base64
import itertools
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from protocol import emit_event

DEFAULT_BUNDLE_ID = "com.example.TranscribeTranslateApp"
DEFAULT_MODEL_ROOT = (
    Path.home()
    / "Library"
    / "Application Support"
    / DEFAULT_BUNDLE_ID
    / "models"
)

WHISPER_TO_NLLB = {
    "ar": "arb_Arab",
    "de": "deu_Latn",
    "en": "eng_Latn",
    "es": "spa_Latn",
    "fr": "fra_Latn",
    "hi": "hin_Deva",
    "id": "ind_Latn",
    "it": "ita_Latn",
    "ja": "jpn_Jpan",
    "ko": "kor_Hang",
    "nl": "nld_Latn",
    "pl": "pol_Latn",
    "pt": "por_Latn",
    "ru": "rus_Cyrl",
    "th": "tha_Thai",
    "tr": "tur_Latn",
    "uk": "ukr_Cyrl",
    "vi": "vie_Latn",
    "zh": "zho_Hans",
}


@dataclass
class SegmentResult:
    segment_id: str
    start_seconds: float
    end_seconds: float
    source_text: str
    translated_text: str


@dataclass
class PartialResult:
    partial_id: str
    start_seconds: float
    end_seconds: float
    source_text: str


@dataclass
class ProcessingResult:
    partial: Optional[PartialResult] = None
    segment: Optional[SegmentResult] = None


class ProcessingPipeline:
    def __init__(self) -> None:
        self.mode = os.getenv("TT_PIPELINE_MODE", "mock")
        self.segment_counter = itertools.count(1)
        self.elapsed_seconds = 0.0

        self.target_language = "vie_Latn"
        self.source_language = os.getenv("TT_SOURCE_LANGUAGE", "eng_Latn")

        self.model_root = Path(os.getenv("TT_MODEL_ROOT", str(DEFAULT_MODEL_ROOT))).expanduser()
        self.whisper_model_dir = Path(
            os.getenv("TT_WHISPER_MODEL_DIR", str(self.model_root / "faster-whisper-small"))
        ).expanduser()
        self.translation_model_dir = Path(
            os.getenv("TT_TRANSLATION_MODEL_DIR", str(self.model_root / "nllb-200-distilled-600M"))
        ).expanduser()
        self.translation_ct2_model_dir = Path(
            os.getenv(
                "TT_TRANSLATION_CT2_MODEL_DIR",
                str(self.model_root / "nllb-200-distilled-600M-ct2"),
            )
        ).expanduser()

        self.min_window_seconds = max(float(os.getenv("TT_MIN_TRANSCRIBE_SECONDS", "2.2")), 0.8)
        self.max_window_seconds = max(
            float(os.getenv("TT_MAX_TRANSCRIBE_SECONDS", "7.0")),
            self.min_window_seconds,
        )
        self.min_silence_seconds = max(
            float(os.getenv("TT_MIN_SILENCE_SECONDS", "0.35")),
            0.15,
        )
        self.silence_rms_threshold = max(
            float(os.getenv("TT_SILENCE_RMS_THRESHOLD", "220.0")),
            1.0,
        )
        self.partial_min_window_seconds = max(
            float(os.getenv("TT_PARTIAL_MIN_SECONDS", "0.5")),
            0.3,
        )
        self.partial_interval_seconds = max(
            float(os.getenv("TT_PARTIAL_INTERVAL_SECONDS", "0.75")),
            0.3,
        )
        self.partial_max_window_seconds = max(
            float(os.getenv("TT_PARTIAL_MAX_SECONDS", "1.25")),
            self.partial_min_window_seconds,
        )

        self.pending_pcm = bytearray()
        self.pending_seconds = 0.0
        self.pending_start_seconds = 0.0
        self.pending_sample_rate = 16_000
        self.pending_channels = 1
        self.trailing_silence_seconds = 0.0
        self.last_partial_emit_seconds = -1.0
        self.last_partial_text = ""
        self.partial_counter = itertools.count(1)

        self._whisper_model = None
        self._translation_model = None
        self._translation_tokenizer = None
        self._numpy = None
        self._translation_backend = "cpu/int8"

    def set_model_root(self, model_root: str) -> None:
        root = Path(model_root).expanduser()
        if root == self.model_root:
            return

        self.model_root = root
        self.whisper_model_dir = root / "faster-whisper-small"
        self.translation_model_dir = root / "nllb-200-distilled-600M"
        self.translation_ct2_model_dir = root / "nllb-200-distilled-600M-ct2"

        self._whisper_model = None
        self._translation_model = None
        self._translation_tokenizer = None
        self._numpy = None
        self._reset_partial_state()

    def warmup(self, target_language: str) -> str:
        self.target_language = target_language or "vie_Latn"
        self.pending_pcm.clear()
        self.pending_seconds = 0.0
        self.pending_start_seconds = self.elapsed_seconds
        self.pending_sample_rate = 16_000
        self.pending_channels = 1
        self.trailing_silence_seconds = 0.0
        self._reset_partial_state()

        if self.mode == "mock":
            return f"Mock pipeline ready for {self.target_language}"

        self._ensure_real_models_loaded()
        return (
            "Real pipeline ready: faster-whisper + NLLB-CT2 "
            f"(source={self.source_language}, target={self.target_language}, backend={self._translation_backend})"
        )

    def process_audio_chunk(
        self,
        pcm_base64: str,
        sample_rate: int,
        channels: int,
    ) -> ProcessingResult:
        raw = base64.b64decode(pcm_base64.encode("utf-8"))
        bytes_per_second = max(sample_rate, 1) * max(channels, 1) * 2
        chunk_duration = max(len(raw) / bytes_per_second, 0.5)

        if self.mode == "mock":
            return ProcessingResult(segment=self._process_mock_chunk(chunk_duration))

        self._ensure_real_models_loaded()

        if not raw:
            self.elapsed_seconds += chunk_duration
            return ProcessingResult()

        if (sample_rate, channels) != (self.pending_sample_rate, self.pending_channels):
            self.pending_pcm.clear()
            self.pending_seconds = 0.0
            self.pending_sample_rate = sample_rate
            self.pending_channels = channels
            self.trailing_silence_seconds = 0.0
            self._reset_partial_state()

        if not self.pending_pcm:
            self.pending_start_seconds = self.elapsed_seconds

        self.pending_pcm.extend(raw)
        self.pending_seconds += chunk_duration
        self.elapsed_seconds += chunk_duration

        if self._is_chunk_silent(raw):
            self.trailing_silence_seconds += chunk_duration
        else:
            self.trailing_silence_seconds = 0.0

        should_flush_segment = False
        if self.pending_seconds >= self.min_window_seconds:
            if self.trailing_silence_seconds >= self.min_silence_seconds:
                should_flush_segment = True
            elif self.pending_seconds >= self.max_window_seconds:
                should_flush_segment = True

        if not should_flush_segment:
            partial = self._build_partial_result(sample_rate=sample_rate, channels=channels)
            return ProcessingResult(partial=partial)

        window_pcm = bytes(self.pending_pcm)
        window_duration = self.pending_seconds
        window_start = self.pending_start_seconds
        window_end = window_start + window_duration

        self.pending_pcm.clear()
        self.pending_seconds = 0.0
        self.trailing_silence_seconds = 0.0
        self._reset_partial_state()

        source_text = self._transcribe(window_pcm, sample_rate=sample_rate, channels=channels)
        if not source_text:
            return ProcessingResult()

        translated_text = self._translate(source_text)
        index = next(self.segment_counter)

        return ProcessingResult(
            segment=SegmentResult(
                segment_id=f"segment-{index}",
                start_seconds=window_start,
                end_seconds=window_end,
                source_text=source_text,
                translated_text=translated_text,
            )
        )

    def _process_mock_chunk(self, chunk_duration: float) -> SegmentResult:
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

    def _build_partial_result(self, sample_rate: int, channels: int) -> Optional[PartialResult]:
        if self.pending_seconds < self.partial_min_window_seconds:
            return None

        if self.last_partial_emit_seconds >= 0:
            elapsed_since_last_partial = self.elapsed_seconds - self.last_partial_emit_seconds
            if elapsed_since_last_partial < self.partial_interval_seconds:
                return None

        preview_pcm, preview_duration = self._latest_pcm_window(
            pcm_bytes=bytes(self.pending_pcm),
            sample_rate=sample_rate,
            channels=channels,
            max_seconds=self.partial_max_window_seconds,
        )
        if not preview_pcm or preview_duration <= 0:
            return None

        partial_text = self._transcribe(preview_pcm, sample_rate=sample_rate, channels=channels)
        if not partial_text or partial_text == self.last_partial_text:
            return None

        partial_end = self.elapsed_seconds
        partial_start = max(partial_end - preview_duration, self.pending_start_seconds)

        self.last_partial_text = partial_text
        self.last_partial_emit_seconds = self.elapsed_seconds

        return PartialResult(
            partial_id=f"partial-{next(self.partial_counter)}",
            start_seconds=partial_start,
            end_seconds=partial_end,
            source_text=partial_text,
        )

    def _transcribe(self, pcm_bytes: bytes, sample_rate: int, channels: int) -> str:
        whisper_language = os.getenv("TT_WHISPER_LANGUAGE")
        vad_filter = os.getenv("TT_WHISPER_VAD", "1") == "1"
        beam_size = int(os.getenv("TT_WHISPER_BEAM_SIZE", "1"))
        audio = self._pcm16_bytes_to_float32(
            pcm_bytes=pcm_bytes,
            sample_rate=sample_rate,
            channels=channels,
        )
        if audio.size == 0:
            return ""

        segments, info = self._whisper_model.transcribe(
            audio,
            task="transcribe",
            language=whisper_language,
            beam_size=beam_size,
            best_of=1,
            condition_on_previous_text=False,
            vad_filter=vad_filter,
            word_timestamps=False,
            temperature=0.0,
        )
        text = " ".join(segment.text.strip() for segment in segments if segment.text.strip())

        mapped_source = self._map_whisper_language(getattr(info, "language", None))
        if mapped_source:
            self.source_language = mapped_source

        return text.strip()

    def _translate(self, source_text: str) -> str:
        target_language = self.target_language or "vie_Latn"
        source_language = self.source_language or "eng_Latn"

        if target_language == source_language:
            return source_text

        tokenizer = self._translation_tokenizer
        model = self._translation_model

        if not self._supports_nllb_language(target_language):
            raise RuntimeError(
                f"Unsupported target language for NLLB: {target_language}. "
                "Use codes like vie_Latn, eng_Latn, jpn_Jpan."
            )

        if not self._supports_nllb_language(source_language):
            source_language = "eng_Latn"

        tokenizer.src_lang = source_language
        encoded = tokenizer(
            source_text,
            truncation=True,
            max_length=512,
        )
        input_ids = encoded.get("input_ids", [])
        if not input_ids:
            return source_text

        source_tokens = tokenizer.convert_ids_to_tokens(input_ids)
        if not source_tokens:
            return source_text

        results = model.translate_batch(
            [source_tokens],
            target_prefix=[[target_language]],
            beam_size=max(int(os.getenv("TT_TRANSLATION_BEAM_SIZE", "1")), 1),
            max_decoding_length=max(int(os.getenv("TT_MAX_TRANSLATION_TOKENS", "96")), 16),
        )
        if not results or not results[0].hypotheses:
            return source_text

        output_tokens = list(results[0].hypotheses[0])
        if output_tokens and output_tokens[0] == target_language:
            output_tokens = output_tokens[1:]

        special_tokens = set(tokenizer.all_special_tokens)
        output_tokens = [token for token in output_tokens if token not in special_tokens]
        if not output_tokens:
            return source_text

        text = tokenizer.convert_tokens_to_string(output_tokens).strip()
        return text if text else source_text

    def _ensure_real_models_loaded(self) -> None:
        if (
            self._whisper_model is not None
            and self._translation_model is not None
            and self._translation_tokenizer is not None
            and self._numpy is not None
        ):
            return

        self._assert_local_models_exist()

        try:
            from faster_whisper import WhisperModel
            import ctranslate2
            import numpy
        except Exception as exc:  # pragma: no cover - import error surface to UI
            raise RuntimeError(
                "faster-whisper/ctranslate2/numpy are missing. Run: pip install -r worker/requirements.txt"
            ) from exc

        try:
            from transformers import AutoTokenizer
        except Exception as exc:  # pragma: no cover - import error surface to UI
            raise RuntimeError(
                "transformers is missing. Run: pip install -r worker/requirements.txt"
            ) from exc

        whisper_device = os.getenv("TT_WHISPER_DEVICE", "cpu")
        whisper_compute_type = os.getenv("TT_WHISPER_COMPUTE_TYPE", "int8")

        self._whisper_model = WhisperModel(
            str(self.whisper_model_dir),
            device=whisper_device,
            compute_type=whisper_compute_type,
        )

        self._translation_tokenizer = AutoTokenizer.from_pretrained(
            str(self.translation_model_dir),
            local_files_only=True,
            use_fast=False,
        )
        self._ensure_ct2_translation_model(ctranslate2)

        requested_translation_device = os.getenv("TT_TRANSLATION_DEVICE", "cpu").lower()
        translation_device = requested_translation_device if requested_translation_device in {"cpu", "auto"} else "cpu"
        translation_compute_type = os.getenv("TT_TRANSLATION_COMPUTE_TYPE", "int8")

        self._translation_model = ctranslate2.Translator(
            str(self.translation_ct2_model_dir),
            device=translation_device,
            compute_type=translation_compute_type,
        )
        self._translation_backend = f"{translation_device}/{translation_compute_type}"
        self._numpy = numpy

    def _assert_local_models_exist(self) -> None:
        whisper_required = self.whisper_model_dir / "model.bin"
        translation_config = self.translation_model_dir / "config.json"
        translation_entries = list(self.translation_model_dir.iterdir()) if self.translation_model_dir.exists() else []

        translation_has_tokenizer = any(
            (self.translation_model_dir / candidate).exists()
            for candidate in ("sentencepiece.bpe.model", "spiece.model", "tokenizer.json")
        )
        translation_has_weights = (self.translation_model_dir / "pytorch_model.bin").exists() or (
            self.translation_model_dir / "model.safetensors"
        ).exists() or any(
            path.name.startswith("pytorch_model-") and path.suffix == ".bin" for path in translation_entries
        ) or any(
            path.name.startswith("model-") and path.suffix == ".safetensors" for path in translation_entries
        )

        if (
            not whisper_required.exists()
            or not translation_config.exists()
            or not translation_has_tokenizer
            or not translation_has_weights
        ):
            raise RuntimeError(
                "Model files are missing. Download models first with TT_FAKE_DOWNLOAD=0. "
                f"Expected: {whisper_required} and NLLB files in {self.translation_model_dir}."
            )

    def _map_whisper_language(self, whisper_language: Optional[str]) -> Optional[str]:
        if not whisper_language:
            return None
        return WHISPER_TO_NLLB.get(whisper_language.lower())

    def _ensure_ct2_translation_model(self, ctranslate2) -> None:
        model_file = self.translation_ct2_model_dir / "model.bin"
        if model_file.exists():
            return

        quantization = os.getenv(
            "TT_TRANSLATION_CT2_QUANTIZATION",
            os.getenv("TT_TRANSLATION_COMPUTE_TYPE", "int8"),
        )
        copy_files = [
            filename
            for filename in (
                "tokenizer.json",
                "tokenizer_config.json",
                "special_tokens_map.json",
                "sentencepiece.bpe.model",
                "spiece.model",
                "generation_config.json",
            )
            if (self.translation_model_dir / filename).exists()
        ]

        emit_event(
            "status",
            message="Optimizing translation model for realtime use (one-time setup)...",
        )
        self.translation_ct2_model_dir.parent.mkdir(parents=True, exist_ok=True)
        converter = ctranslate2.converters.TransformersConverter(
            str(self.translation_model_dir),
            copy_files=copy_files or None,
        )
        converter.convert(
            str(self.translation_ct2_model_dir),
            quantization=quantization,
            force=True,
        )
        emit_event("status", message="Realtime translation model is ready")

    def _supports_nllb_language(self, language_code: str) -> bool:
        token_id = self._translation_tokenizer.convert_tokens_to_ids(language_code)
        return token_id is not None and token_id != self._translation_tokenizer.unk_token_id

    def _is_chunk_silent(self, pcm_bytes: bytes) -> bool:
        numpy = self._numpy
        if numpy is None or not pcm_bytes:
            return False

        samples = numpy.frombuffer(pcm_bytes, dtype=numpy.int16)
        if samples.size == 0:
            return True

        rms = float(numpy.sqrt(numpy.mean(numpy.square(samples.astype(numpy.float32)))))
        return rms <= self.silence_rms_threshold

    def _reset_partial_state(self) -> None:
        self.last_partial_emit_seconds = -1.0
        self.last_partial_text = ""

    def _latest_pcm_window(
        self,
        pcm_bytes: bytes,
        sample_rate: int,
        channels: int,
        max_seconds: float,
    ) -> tuple[bytes, float]:
        bytes_per_second = max(sample_rate, 1) * max(channels, 1) * 2
        max_bytes = int(bytes_per_second * max_seconds)
        if max_bytes <= 0:
            return b"", 0.0

        if len(pcm_bytes) <= max_bytes:
            return pcm_bytes, len(pcm_bytes) / bytes_per_second if bytes_per_second else 0.0

        return pcm_bytes[-max_bytes:], max_bytes / bytes_per_second

    def _pcm16_bytes_to_float32(self, pcm_bytes: bytes, sample_rate: int, channels: int):
        numpy = self._numpy

        samples = numpy.frombuffer(pcm_bytes, dtype=numpy.int16)
        channel_count = max(channels, 1)
        if channel_count > 1 and samples.size >= channel_count:
            frame_count = samples.size // channel_count
            samples = samples[: frame_count * channel_count].reshape(frame_count, channel_count)
            samples = samples.mean(axis=1)

        audio = samples.astype(numpy.float32) / 32768.0
        if sample_rate == 16_000 or audio.size == 0:
            return audio

        target_size = max(int(round((audio.size / max(sample_rate, 1)) * 16_000)), 1)
        source_positions = numpy.linspace(0.0, 1.0, num=audio.size, endpoint=False)
        target_positions = numpy.linspace(0.0, 1.0, num=target_size, endpoint=False)
        return numpy.interp(target_positions, source_positions, audio).astype(numpy.float32)
