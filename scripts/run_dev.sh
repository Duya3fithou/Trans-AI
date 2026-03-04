#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export TT_WORKER_SCRIPT_PATH="$ROOT_DIR/worker/src/worker_main.py"
export TT_FAKE_DOWNLOAD="1"
export TT_PIPELINE_MODE="mock"

cd "$ROOT_DIR"
swift run TranscribeTranslateApp
