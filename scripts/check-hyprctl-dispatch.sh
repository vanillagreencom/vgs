#!/usr/bin/env bash
# Refuse a `hyprctl dispatch` in a bin/ shell script other than bin/vshell-hyprctl-dispatch.
# That program checks the reply of every dispatch, so a call routed around it can lose a
# refused dispatch with no diagnostic. A shell script is a bin/ file whose shebang names
# bash or sh; the Python helper modules are outside this rule. Whole-line comments are skipped.
# Usage: scripts/check-hyprctl-dispatch.sh [ROOT], where ROOT defaults to this checkout.
#
# Output protocol: one `hyprctl-dispatch-unchecked bin/<name>:<line>` line on stderr per
# finding, then exit 1; `check-hyprctl-dispatch: ok (<N> shell scripts)` and exit 0 when
# none; exit 2 when bin/ cannot be listed or holds no shell script to scan.
set -euo pipefail

root="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
owner="vshell-hyprctl-dispatch"
# hyprctl, then its flags or batch quoting within the same command, then the dispatch word.
pattern='(^|[^[:alnum:]_-])hyprctl[[:space:]][^|;&]*dispatch([^[:alnum:]_]|$)'

listing="$(mktemp)"
trap 'rm -f -- "${listing:?}"' EXIT
if ! find "$root/bin" -maxdepth 1 -type f -print0 >"$listing"; then
  printf 'hyprctl-dispatch-listing-failed %s/bin\n' "$root" >&2
  exit 2
fi

scanned=0
status=0
while IFS= read -r -d '' file; do
  shebang=""
  IFS= read -r shebang <"$file" || true
  case "$shebang" in
    '#!'*bash* | '#!'*/sh | '#!'*' sh') ;;
    *) continue ;;
  esac
  scanned=$((scanned + 1))
  [[ ${file##*/} == "$owner" ]] && continue
  line_no=0
  while IFS= read -r line || [[ -n $line ]]; do
    line_no=$((line_no + 1))
    [[ $line =~ ^[[:space:]]*# ]] && continue
    if [[ $line =~ $pattern ]]; then
      printf 'hyprctl-dispatch-unchecked bin/%s:%d\n' "${file##*/}" "$line_no" >&2
      status=1
    fi
  done <"$file"
done <"$listing"

if [[ $scanned -eq 0 ]]; then
  printf 'hyprctl-dispatch-no-scripts %s/bin\n' "$root" >&2
  exit 2
fi
if [[ $status -ne 0 ]]; then
  printf 'Route each dispatch through bin/%s.\n' "$owner" >&2
  exit 1
fi
printf 'check-hyprctl-dispatch: ok (%d shell scripts)\n' "$scanned"
