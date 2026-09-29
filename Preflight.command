#!/bin/zsh
cd "$(dirname "$0")"
fail() { echo "\nエラー：実車前チェックを中止しました。上のメッセージを確認してください。"; read -k 1 '?何かキーを押すと閉じます...'; exit 1; }
if command -v python3.12 >/dev/null 2>&1; then PYTHON_BIN=python3.12; elif command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3; else echo 'Python 3.12以上が必要です。'; fail; fi
$PYTHON_BIN - <<'PY' || fail
import sys
if sys.version_info < (3,12): raise SystemExit(f'Python 3.12以上が必要です。現在: {sys.version.split()[0]}')
print('使用するPython:',sys.version.split()[0])
PY
if [[ ! -d .venv ]]; then $PYTHON_BIN -m venv .venv || fail; fi
source .venv/bin/activate || fail
python -m pip install -e '.[dev]' || fail
python -m pytest -q || fail
honda-analyzer-preflight || fail
read -k 1 '?何かキーを押すと閉じます...'
