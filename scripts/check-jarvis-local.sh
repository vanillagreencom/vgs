#!/usr/bin/env bash
# Actual local-model row. Never downloads, captures or plays audio.
# JARVIS_LOCAL_MODELS and JARVIS_LOCAL_PYTHON explicitly select prepared
# lane-local inputs. Without them this row exits 77, not success.
# The shared Jarvis world blocks network and live session endpoints.
set -euo pipefail
self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd -P)"
models="${JARVIS_LOCAL_MODELS:-}"
python="${JARVIS_LOCAL_PYTHON:-}"
if [[ -z $models || -z $python || ! -x $python ]]; then
  echo 'jarvis-local: status=not-measured reason=prepared-inputs-unavailable'
  exit 77
fi
TMP_ROOT="$(mktemp -d)" || { echo 'jarvis-local: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'jarvis-local: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'jarvis-local: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
mkdir "$TMP_ROOT/standins"
# The inventory comes from the artifact producer, not a second model list.
# A missing exported role must not make the row a smaller passing test.
"$repo/scripts/lib/jarvis-env.sh" "$TMP_ROOT/standins" -- "$python" \
  "$repo/scripts/fixtures/jarvis-local/run.py" "$repo" "$models"
