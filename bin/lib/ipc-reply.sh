# shellcheck shell=bash
# bin/lib/ipc-reply.sh: classifies the last stdout line from
# `qs ipc call`. Source this file from Bash. Loading it prints nothing,
# starts no process and restores the caller's shell options. The table rests
# on Quickshell 0.3.1 `src/io/ipccomm.cpp` callFunction and
# `src/ipc/ipc.hpp` waitForResponse.
#
#   vgs_ipc_strip_ansi LINE
#     prints LINE with SGR colour escapes removed.
#   vgs_ipc_reply_failure LINE
#     prints a stable reason key and returns 0 when LINE is a Quickshell IPC
#     client failure. It returns 1 for a normal reply and for an empty line.

_vgs_ipc_had_errexit=0
_vgs_ipc_had_nounset=0
_vgs_ipc_had_pipefail=0
[[ $- == *e* ]] && _vgs_ipc_had_errexit=1
[[ $- == *u* ]] && _vgs_ipc_had_nounset=1
[[ -o pipefail ]] && _vgs_ipc_had_pipefail=1
set -euo pipefail

vgs_ipc_strip_ansi() { sed $'s/\x1b\[[0-9;]*m//g' <<<"$1"; }

vgs_ipc_failure_rows=(
  'client-error|contains|ERROR quickshell.ipc'
  'function-not-found|exact|Function not found.'
  'target-not-found|exact|Target not found.'
  'not-ready|exact|Not ready to accept queries yet.'
  'target-required|exact|Target required to send message.'
  'function-required|exact|Function required to send message.'
  'too-many-arguments|prefix|Too many arguments provided'
  'too-few-arguments|prefix|Too few arguments provided'
  'unparseable-argument|prefix|Unable to parse argument'
  'arguments|prefix|Function definition:'
)

vgs_ipc_reply_failure() { # LINE
  local line="$1" stripped row reason kind text
  if ! stripped="$(vgs_ipc_strip_ansi "$line")"; then
    return 1
  fi
  for row in "${vgs_ipc_failure_rows[@]}"; do
    IFS='|' read -r reason kind text <<<"$row"
    case "$kind" in
      contains) [[ $stripped == *"$text"* ]] || continue ;;
      exact) [[ $stripped == "$text" ]] || continue ;;
      prefix) [[ $stripped == "$text"* ]] || continue ;;
      *) continue ;;
    esac
    printf '%s\n' "$reason"
    return 0
  done
  return 1
}

[[ $_vgs_ipc_had_errexit == 1 ]] || set +e
[[ $_vgs_ipc_had_nounset == 1 ]] || set +u
[[ $_vgs_ipc_had_pipefail == 1 ]] || set +o pipefail
unset _vgs_ipc_had_errexit _vgs_ipc_had_nounset _vgs_ipc_had_pipefail
