# shellcheck shell=bash
# bin/lib/ipc-reply.sh: classifies the last stdout line from
# `qs ipc call`. Source this file from Bash. Loading it defines one array
# and two functions, prints nothing, starts no process and leaves the
# caller's shell options alone. The table rests on Quickshell 0.3.1
# `src/io/ipccomm.cpp` callFunction and `src/ipc/ipc.hpp` waitForResponse.
#
#   vgs_ipc_strip_into LINE
#     sets vgs_ipc_stripped to LINE with SGR colour escapes removed.
#   vgs_ipc_reply_failure LINE
#     prints a stable reason key and returns 0 when LINE is a Quickshell IPC
#     client failure. It returns 1 for a normal reply and for an empty line.
#     A table row of unknown kind prints `ipc-reply: kind=<kind> row=<reason>`
#     on stderr and returns 2.

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

# Pure Bash, so the strip forks nothing and cannot fail.
vgs_ipc_strip_into() { # LINE
  vgs_ipc_stripped="$1"
  while [[ $vgs_ipc_stripped =~ ^(.*)$'\e'\[[0-9\;]*m(.*)$ ]]; do
    vgs_ipc_stripped="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  done
}

vgs_ipc_reply_failure() { # LINE
  local stripped row reason rest kind text
  vgs_ipc_strip_into "$1"
  stripped="$vgs_ipc_stripped"
  for row in "${vgs_ipc_failure_rows[@]}"; do
    reason="${row%%|*}"
    rest="${row#*|}"
    kind="${rest%%|*}"
    text="${rest#*|}"
    case "$kind" in
      contains) [[ $stripped == *"$text"* ]] || continue ;;
      exact) [[ $stripped == "$text" ]] || continue ;;
      prefix) [[ $stripped == "$text"* ]] || continue ;;
      *)
        printf 'ipc-reply: kind=%s row=%s\n' "$kind" "$reason" >&2
        return 2
        ;;
    esac
    printf '%s\n' "$reason"
    return 0
  done
  return 1
}
