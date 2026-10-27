#!/usr/bin/env bash
# Assemble Lambda packages under active-active/build/<fn>/ for Terraform to zip.
# Run before plan/apply (run-drill.sh and CI call it too).
set -euo pipefail

AA="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$AA/build"
PY_BIN="$(command -v python || command -v python3)"

rm -rf "$BUILD"
mkdir -p "$BUILD/deps"

# Native python.exe on Windows needs Windows paths, not /c/...
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
"$PY_BIN" -m pip install --quiet --disable-pip-version-check --no-compile \
  --target "$(native "$BUILD/deps")" -r "$(native "$AA/requirements.txt")"

for fn in app migrate analyzer prober; do
  mkdir -p "$BUILD/$fn"
  cp "$AA/src/$fn/"*.py "$BUILD/$fn/"
  if [[ "$fn" != "prober" ]]; then   # prober is stdlib + boto3 only
    cp "$AA/src/common/"*.py "$BUILD/$fn/"
    cp -r "$BUILD/deps/." "$BUILD/$fn/"
  fi
  find "$BUILD/$fn" -name '__pycache__' -type d -prune -exec rm -rf {} +
done
rm -rf "$BUILD/deps"
echo "built: $(ls "$BUILD" | tr '\n' ' ')"
