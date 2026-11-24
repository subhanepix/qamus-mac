#!/bin/sh
# Sets up an isolated Python 3.12 virtualenv for Qamus's local CAMeL Tools Arabic parser sidecar.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
PY_BIN=""

for cand in /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12 python3.12 /opt/homebrew/bin/python3.11 python3.11; do
  if command -v "$cand" >/dev/null 2>&1; then
    PY_BIN="$(command -v "$cand")"
    break
  fi
done

if [ -z "$PY_BIN" ]; then
  echo "Python 3.12 not found. Install via: brew install python@3.12" >&2
  exit 1
fi

echo "1/3 Creating virtualenv with $PY_BIN…"
"$PY_BIN" -m venv "$VENV_DIR"

echo "2/3 Installing camel-tools…"
"$VENV_DIR/bin/pip" install --upgrade pip wheel
"$VENV_DIR/bin/pip" install camel-tools

echo "3/3 Downloading CAMeL morphology & BERT disambiguation models…"
"$VENV_DIR/bin/camel_data" -i morphology-db-msa-r13
"$VENV_DIR/bin/camel_data" -i disambig-bert-unfactored-msa

echo ""
echo "✅ CAMeL Tools sidecar ready at $VENV_DIR"
echo "   Test: $VENV_DIR/bin/python $SCRIPT_DIR/server.py"
