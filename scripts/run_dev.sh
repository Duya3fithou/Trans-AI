#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_PYTHON="$ROOT_DIR/worker/.venv/bin/python"
export TT_WORKER_SCRIPT_PATH="$ROOT_DIR/worker/src/worker_main.py"
export TT_FAKE_DOWNLOAD="${TT_FAKE_DOWNLOAD:-1}"
export TT_PIPELINE_MODE="${TT_PIPELINE_MODE:-mock}"

if [[ -x "$VENV_PYTHON" ]]; then
  export TT_PYTHON_PATH="$VENV_PYTHON"
fi

cd "$ROOT_DIR"
swift run TranscribeTranslateApp
