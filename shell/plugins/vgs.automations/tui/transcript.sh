#!/usr/bin/env bash
set -euo pipefail

if [[ ${VGS_TUI_LIB:-} == "" ]]; then
  echo "transcript: VGS_TUI_LIB is not set" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$VGS_TUI_LIB"

path="${1:-}"
if [[ $path != /* || ! -f $path ]]; then
  vgs_tui_warn "Transcript not found: ${path:-missing}"
  vgs_tui_close_prompt 1
  exit 1
fi

vgs_tui_step "Opening transcript"
if [[ -n ${EDITOR:-} ]]; then
  "$EDITOR" "$path"
else
  ${PAGER:-less} "$path"
fi
