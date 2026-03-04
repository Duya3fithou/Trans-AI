# Architecture

## Runtime shape

1. SwiftUI app owns UI state and local file export.
2. `WorkerBridge` launches a Python worker and speaks JSONL over pipes.
3. `ModelManager` decides where models live on disk.
4. `AudioCaptureCoordinator` produces PCM chunks.
5. Worker emits `segment` events with source text and translated text.

## IPC contract

Commands:

- `downloadModels`
- `warmup`
- `processAudio`
- `stop`

Events:

- `status`
- `downloadProgress`
- `segment`
- `error`

## Packaging direction

Current dev mode launches `python3 worker/src/worker_main.py`.

Production target:

1. Freeze the worker into an `arm64` helper executable.
2. Place it in `.app/Contents/Resources/Worker/`.
3. Launch it via `Process` using the embedded path.
4. Keep model downloads outside the bundle in `Application Support`.
