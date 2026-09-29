#!/usr/bin/env bash
set -euo pipefail

EXPECTED_SHA256="bae24021b3ca8b1587817821f2db7799ccac3f9dc707aecad962382a30c20d3d"
EXPECTED_VERSION="0.3.4"

usage() {
  echo "Usage: $0 /path/to/honda_ehev_can_uds_analyzer_0.3.4_long_did_recovery.zip [--push]"
}

[[ $# -ge 1 ]] || { usage; exit 2; }
ZIP="$1"
PUSH="${2:-}"

[[ -f "$ZIP" ]] || { echo "ZIP not found: $ZIP" >&2; exit 2; }
git rev-parse --show-toplevel >/dev/null
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

ACTUAL_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA256" ]]; then
  echo "SHA-256 mismatch" >&2
  echo " expected: $EXPECTED_SHA256" >&2
  echo " actual:   $ACTUAL_SHA" >&2
  exit 3
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"

PYP="$(find "$TMP" -maxdepth 3 -type f -name pyproject.toml -print -quit)"
[[ -n "$PYP" ]] || { echo "pyproject.toml not found in ZIP" >&2; exit 4; }
SRC="$(dirname "$PYP")"

grep -q "version = \"$EXPECTED_VERSION\"" "$SRC/pyproject.toml"
test -f "$SRC/src/honda_analyzer/gui/app.py"
test -f "$SRC/tests/test_phase34_long_did_buffer_recovery.py"

mkdir -p src tests docs signals
rsync -a --delete "$SRC/src/" src/
rsync -a --delete "$SRC/tests/" tests/
rsync -a "$SRC/docs/" docs/
if [[ -d "$SRC/signals" ]]; then rsync -a --delete "$SRC/signals/" signals/; fi
cp "$SRC/pyproject.toml" pyproject.toml
cp "$SRC/README.md" README.md
cp "$SRC/Preflight.command" Preflight.command
cp "$SRC/Run Honda Analyzer.command" "Run Honda Analyzer.command"

find src tests -type d -name __pycache__ -prune -exec rm -rf {} +
rm -rf .pytest_cache

rm -rf _import_v034 _bootstrap _bootstrap_v034_fixed
rm -f .github/workflows/materialize-source.yml

python3.12 -m venv .venv-bootstrap
source .venv-bootstrap/bin/activate
python -m pip install --upgrade pip
python -m pip install -e '.[dev]'
python -m pytest -q
python -m compileall -q src

git add -A
git status --short

if git diff --cached --quiet; then
  echo "No source changes to commit."
  exit 0
fi

git commit -m "chore: canonicalize Honda e:HEV Analyzer v0.3.4 source"

if [[ "$PUSH" == "--push" ]]; then
  git push origin HEAD:main
else
  echo "Commit created locally. Re-run with --push or run: git push origin HEAD:main"
fi
