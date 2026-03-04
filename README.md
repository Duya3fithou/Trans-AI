# TranscribeTranslateApp MVP Skeleton

macOS-only MVP skeleton for Apple Silicon (`arm64`) using:

- SwiftUI desktop app
- live audio capture (`ScreenCaptureKit` + microphone fallback)
- Python worker sidecar via JSONL over `stdin`/`stdout`
- first-run model downloader flow
- transcript export to Markdown

This repository is intentionally set up so you can run the UI immediately in a mock mode, then replace the placeholders with real `faster-whisper` + `NLLB` inference.

## What works now

- SwiftUI window with controls for model download, start/stop session, export transcript
- Python worker process management from Swift
- JSON command/event protocol
- simulated model download into `~/Library/Application Support/com.example.TranscribeTranslateApp/models`
- file-level real download progress from Hugging Face (when `TT_FAKE_DOWNLOAD=0`)
- live system audio + microphone capture routed into the worker
- real `faster-whisper + NLLB` pipeline is available when you run with real models
- simulated transcript + translation segments so the full UX path is testable

## What is stubbed

- default dev launch still uses mock inference until you opt into `TT_PIPELINE_MODE=real`
- Bundling the worker into a signed `.app`

## Run the MVP

1. Confirm Xcode command line tools are installed.
2. From the repo root, run:

```bash
./scripts/run_dev.sh
```

This launches the SwiftUI app with the worker script path preconfigured.

## Enable the real AI pipeline

The default dev script still runs in mock mode so the UI stays easy to test.

To run the real worker pipeline:

1. Install the worker dependencies:

```bash
./scripts/build_worker.sh
```

`build_worker.sh` automatically selects a Python compatible with torch (3.10-3.12).
If your default `python3` is too new (for example 3.14), set:

```bash
TT_PYTHON_BUILD_PATH=/usr/local/bin/python3.12 ./scripts/build_worker.sh
```

On Apple Silicon, prefer an arm64 Python (typically `/opt/homebrew/bin/python3.12`) for better performance.

2. Launch the app in real download mode, then click `Download Models` in the UI:

```bash
TT_FAKE_DOWNLOAD=0 ./scripts/run_dev.sh
```

3. In Xcode or Terminal, launch with:

```bash
TT_PIPELINE_MODE=real TT_FAKE_DOWNLOAD=0 ./scripts/run_dev.sh
```

The real pipeline expects:

- `faster-whisper-small` under `~/Library/Application Support/com.example.TranscribeTranslateApp/models`
- `nllb-200-distilled-600M` under the same models directory

By default:

- Whisper runs on CPU with `int8`
- NLLB runs on CPU

Optional overrides:

- `TT_TRANSLATION_DEVICE=mps`
- `TT_WHISPER_DEVICE=cpu`
- `TT_WHISPER_COMPUTE_TYPE=int8`

## Suggested next implementation steps

1. Tune chunk duration / VAD settings for your speaking style and latency target.
2. Package the Python worker as an `arm64` executable and embed it into the `.app` bundle.
3. Add signing, hardened runtime, and notarization.

## Model storage

By default, the app requests models under:

- `~/Library/Application Support/com.example.TranscribeTranslateApp/models`

The current worker writes placeholder manifests there. In the real version, download actual model artifacts into the same location and keep a `.ready` marker per model.
