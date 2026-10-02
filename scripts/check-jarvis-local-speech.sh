#!/usr/bin/env bash
# Actual local-model row for the speech sidecar. Never downloads, captures or
# plays audio. JARVIS_LOCAL_MODELS and JARVIS_LOCAL_PYTHON select prepared
# lane-local inputs, as for check-jarvis-local.sh. Without them, or without an
# input a CPU tier needs, this row exits 77, not success.
# The shared Jarvis world blocks network and live session endpoints.
set -euo pipefail
self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd -P)"
models="${JARVIS_LOCAL_MODELS:-}"
python="${JARVIS_LOCAL_PYTHON:-}"
if [[ -z $models || -z $python || ! -x $python || ! -d $models ]]; then
  echo 'jarvis-local-speech: status=not-measured reason=prepared-inputs-unavailable'
  exit 77
fi
models="$(cd -- "$models" && pwd -P)" || { echo 'jarvis-local-speech: status=not-measured reason=models-path-unavailable' >&2; exit 77; }
python_dir="$(cd -- "$(dirname -- "$python")" && pwd -P)" || { echo 'jarvis-local-speech: status=not-measured reason=python-path-unavailable' >&2; exit 77; }
# Keep the final interpreter symlink: resolving it loses a venv's identity.
python="$python_dir/$(basename -- "$python")"
TMP_ROOT="$(mktemp -d)" || { echo 'jarvis-local-speech: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'jarvis-local-speech: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'jarvis-local-speech: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
mkdir "$TMP_ROOT/standins"
"$repo/scripts/lib/jarvis-env.sh" "$TMP_ROOT/standins" -- "$python" \
  "$repo/scripts/fixtures/jarvis-local-speech/real.py" "$repo" "$models"
