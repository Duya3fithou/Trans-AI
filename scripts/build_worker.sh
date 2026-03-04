#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="$ROOT_DIR/worker/.venv"
REQUESTED_PYTHON="${TT_PYTHON_BUILD_PATH:-}"

pick_python() {
  local candidates=()

  if [[ -n "$REQUESTED_PYTHON" ]]; then
    candidates+=("$REQUESTED_PYTHON")
  fi

  candidates+=(
    "/opt/homebrew/bin/python3.12"
    "/opt/homebrew/bin/python3.11"
    "/usr/local/bin/python3.12"
    "/usr/local/bin/python3.11"
    "python3.12"
    "python3.11"
    "python3"
  )

  for candidate in "${candidates[@]}"; do
    if ! command -v "$candidate" >/dev/null 2>&1; then
      continue
    fi

    local resolved
    resolved="$(command -v "$candidate")"
    local minor
    minor="$("$resolved" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    if [[ "$minor" == "3.10" || "$minor" == "3.11" || "$minor" == "3.12" ]]; then
      echo "$resolved"
      return 0
    fi
  done

  return 1
}

if ! PYTHON_BIN="$(pick_python)"; then
  echo "No compatible Python found for torch. Install Python 3.11 or 3.12." >&2
  echo "Tip: set TT_PYTHON_BUILD_PATH=/path/to/python3.12 and rerun." >&2
  exit 1
fi

echo "Using Python: $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"
PYTHON_ARCH="$("$PYTHON_BIN" -c 'import platform; print(platform.machine())')"
if [[ "$(uname -m)" == "arm64" && "$PYTHON_ARCH" != "arm64" ]]; then
  echo "Warning: selected Python is $PYTHON_ARCH on an arm64 Mac. This will run under Rosetta and be slower." >&2
  echo "Recommendation: install an arm64 Python (usually /opt/homebrew/bin/python3.12)." >&2
fi

"$PYTHON_BIN" -m venv --clear "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install -r "$ROOT_DIR/worker/requirements.txt"

echo "Worker virtualenv ready at $VENV_DIR"
echo "Run the app with this env by default via scripts/run_dev.sh"
