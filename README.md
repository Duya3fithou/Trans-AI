# TranscribeTranslateApp MVP Skeleton

macOS-only MVP skeleton for Apple Silicon (`arm64`) using:

- SwiftUI desktop app
- mock-first audio pipeline (replace with `ScreenCaptureKit`)
- Python worker sidecar via JSONL over `stdin`/`stdout`
- first-run model downloader flow
- transcript export to Markdown

This repository is intentionally set up so you can run the UI immediately in a mock mode, then replace the placeholders with real `faster-whisper` + `NLLB` inference.

## What works now

- SwiftUI window with controls for model download, start/stop session, export transcript
- Python worker process management from Swift
- JSON command/event protocol
- simulated model download into `~/Library/Application Support/com.example.TranscribeTranslateApp/models`
- simulated transcript + translation segments so the full UX path is testable

## What is stubbed

- Real `ScreenCaptureKit` system audio + microphone capture
- Real `faster-whisper` transcription
- Real `NLLB-200 distilled 600M` translation
- Bundling the worker into a signed `.app`

## Run the MVP

1. Confirm Xcode command line tools are installed.
2. From the repo root, run:

```bash
./scripts/run_dev.sh
```

This launches the SwiftUI app with the worker script path preconfigured.

## Suggested next implementation steps

1. Replace `AudioCaptureCoordinator` mock chunks with `ScreenCaptureKit` PCM output.
2. Replace `ProcessingPipeline` mock logic with real `faster-whisper` + `NLLB` inference.
3. Package the Python worker as an `arm64` executable and embed it into the `.app` bundle.
4. Add signing, hardened runtime, and notarization.

## Model storage

By default, the app requests models under:

- `~/Library/Application Support/com.example.TranscribeTranslateApp/models`

The current worker writes placeholder manifests there. In the real version, download actual model artifacts into the same location and keep a `.ready` marker per model.
