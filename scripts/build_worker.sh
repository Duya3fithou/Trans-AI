#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="$ROOT_DIR/worker/.venv"

python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install -r "$ROOT_DIR/worker/requirements.txt"

echo "Worker virtualenv ready at $VENV_DIR"
echo "Next: wire real faster-whisper/NLLB logic in worker/src/pipeline.py"
