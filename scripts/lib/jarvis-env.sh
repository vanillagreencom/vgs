#!/usr/bin/env bash
# Test-only owner of a Jarvis world. Source and call jarvis_env_run, or run:
#   scripts/lib/jarvis-env.sh STANDINS -- COMMAND [ARG...]
# STANDINS holds executable regular files, not links or host-tool overrides.
# COMMAND and every descendant share one private user/network/PID namespace.
# The PID namespace ends surviving children when COMMAND ends.
# Exit 77 means a host dependency or namespaces are unavailable, not a pass.
# Other command statuses pass through unchanged; invalid arguments exit 2.
# JARVIS_TEST_ROOT and JARVIS_TEST_TMUX_SOCKET name this invocation's scratch
# world. No caller environment entries pass through. Fixture parameters are
# command arguments or scratch files, never inherited environment variables.

_jarvis_env_error() {
  printf 'jarvis-env: %s\n' "$*" >&2
}

# The allow-list is deliberately disjoint from desktop, audio, account,
# browser and installer commands. PATH resolves those only as stand-ins.
_jarvis_env_tools=(bash sh env node python3 cat mkdir rm cp mv ln chmod sleep
  readlink dirname basename stat grep sed awk sort cut wc true false timeout gdbus)

# jarvis_env_run STANDINS -- COMMAND [ARG...]: preserve the sourced caller's
# traps, options, directories and environment in a subshell.
jarvis_env_run() ( _jarvis_env_run "$@"; )

# The CLI calls the owner directly, so its returned PID owns cancellation.
_jarvis_env_run() {
  set -euo pipefail
  export LC_ALL=C
  if [[ $# -lt 3 || $2 != -- || -z $3 ]]; then
    _jarvis_env_error 'refused=arguments'; return 2
  fi
  local standins self root tool real entry name owner="" status=0
  standins="$(cd -- "$1" && pwd -P)" || { _jarvis_env_error "standins=unreadable path=$1"; return 1; }
  shift 2
  self="$(readlink -f -- "${BASH_SOURCE[0]}")" || return 1
  # A short system temporary path fits Unix socket addresses and contains
  # no caller-supplied XML characters in the private bus configuration.
  unset TMPDIR
  root="$(mktemp -d)" || { _jarvis_env_error 'scratch=mktemp-failed'; return 1; }
  [[ -d $root && ! -L $root ]] || { _jarvis_env_error "scratch=not-a-directory value=[$root]"; return 1; }
  root="$(cd -- "$root" && pwd -P)" || { _jarvis_env_error 'scratch=resolve-failed'; return 1; }
  _jarvis_env_cleanup() {
    local result=$?
    if [[ -n $owner ]]; then
      # unshare --fork ignores TERM and INT while waiting. KILL ends that
      # supervisor; --kill-child then ends its PID namespace and descendants.
      if kill -0 "$owner" 2>/dev/null; then kill -KILL "$owner" || result=1; fi
      wait "$owner" 2>/dev/null || :
    fi
    rm -rf -- "${root:?}" || { _jarvis_env_error "cleanup=failed path=$root"; exit 1; }
    exit "$result"
  }
  trap _jarvis_env_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  umask 077
  mkdir -p "$root"/{standins,tools,bootstrap,home,config,data,state,cache,run,tmp} || exit 1
  for tool in "${_jarvis_env_tools[@]}" unshare ip dbus-daemon tmux; do
    # A fixed search path avoids a login-shell function or version-manager
    # shim that opens the developer's configuration before the test starts.
    real="$(PATH=/usr/bin:/usr/sbin:/bin:/sbin type -P -- "$tool")" ||
      { _jarvis_env_error "status=not-measured missing=$tool"; exit 77; }
    case "$tool" in
      unshare|ip|dbus-daemon|tmux) ln -s -- "$real" "$root/bootstrap/$tool" || exit 1 ;;
      *) ln -s -- "$real" "$root/tools/$tool" || exit 1 ;;
    esac
  done
  shopt -s nullglob dotglob
  for entry in "$standins"/*; do
    name="${entry##*/}"
    if [[ ! -f $entry || ! -x $entry || -L $entry ]]; then
      _jarvis_env_error "standin=not-executable-file name=$name"; exit 1
    fi
    if [[ -e $root/tools/$name || -e $root/bootstrap/$name ]]; then
      _jarvis_env_error "standin=host-tool-collision name=$name"; exit 1
    fi
    cp -- "$entry" "$root/standins/$name" || exit 1
  done
  # Force the socket and an empty config even when the caller uses tmux
  # directly. getopts follows tmux 3.7c tmux.c::main's global syntax, including
  # clusters and c/T values. Unknown global syntax fails closed.
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail' \
    'while getopts ":2c:CDdf:hlL:NqS:T:uUvV" option; do' \
    '  case "$option" in' \
    '    S|L|f|\?|:) echo "jarvis-env: tmux=override-refused" >&2; exit 2 ;;' \
    '    *) ;;' \
    '  esac' \
    'done' \
    'exec "$JARVIS_TEST_ROOT/bootstrap/tmux" -f /dev/null -S "$JARVIS_TEST_TMUX_SOCKET" "$@"' \
    >"$root/tools/tmux" || exit 1
  chmod 700 "$root/tools/tmux" || exit 1
  local clean_env=(/usr/bin/env -i
    PATH="$root/standins:$root/tools" HOME="$root/home"
    XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data"
    XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache"
    XDG_RUNTIME_DIR="$root/run" TMPDIR="$root/tmp"
    TMUX_TMPDIR="$root/run" JARVIS_TEST_TMUX_SOCKET="$root/run/tmux.sock"
    PIPEWIRE_RUNTIME_DIR="$root/run" PIPEWIRE_REMOTE=jarvis-test-no-pipewire
    PULSE_RUNTIME_PATH="$root/run" PULSE_SERVER="unix:$root/run/no-pulse"
    LC_ALL=C LANG=C TZ=UTC VGS_TEST_RUN=1
    JARVIS_TEST_ROOT="$root")
  if ! "${clean_env[@]}" "$root/bootstrap/unshare" -rn --pid --fork --mount-proc --kill-child -- \
    "$root/tools/true" 2>"$root/namespace.log"; then
    _jarvis_env_error 'status=not-measured reason=namespaces-unavailable'
    cat -- "$root/namespace.log" >&2 || exit 1
    exit 77
  fi
  "${clean_env[@]}" "$root/bootstrap/unshare" -rn --pid --fork --mount-proc --kill-child -- \
    "$root/tools/bash" --noprofile --norc "$self" --inside "$root" "$@" &
  owner=$!
  wait "$owner" || status=$?
  owner=""
  # Namespace creation can fail between the probe and the real start.
  if [[ ! -f $root/started ]]; then
    _jarvis_env_error 'status=not-measured reason=namespace-start-failed'
    exit 77
  fi
  # Exit while the owner's local resource bindings still exist for its trap.
  exit "$status"
}

# Runs only as the namespace's init process. Bootstrap tools never enter PATH.
_jarvis_env_inside() {
  set -euo pipefail
  local root="$1" bus address
  shift
  : >"$root/started"
  "$root/bootstrap/ip" link set lo up
  for bus in system session; do
    # No includes, servicedir or standard_session_servicedirs: a request on
    # either bus cannot activate a service from the host or a fixture.
    printf '%s\n' '<busconfig>' '<type>session</type>' \
      "<listen>unix:path=$root/run/$bus.bus</listen>" '<auth>EXTERNAL</auth>' \
      '<policy context="default"><allow user="*"/><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy>' \
      '</busconfig>' >"$root/$bus.conf"
    address="$("$root/bootstrap/dbus-daemon" --fork --print-address --config-file="$root/$bus.conf")" || return 1
    [[ $address == "unix:path=$root/run/$bus.bus,"* ]] ||
      { _jarvis_env_error "bus=unexpected-address kind=$bus"; return 1; }
    case "$bus" in
      session) export DBUS_SESSION_BUS_ADDRESS="$address" ;;
      system) export DBUS_SYSTEM_BUS_ADDRESS="$address" ;;
    esac
  done
  cd -- "$HOME"
  # Keep init alive until the command exits. The kernel then ends its buses,
  # private tmux server and all surviving grandchildren, even after a failure.
  "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  if [[ ${1:-} == --inside ]]; then
    shift
    _jarvis_env_inside "$@"
  else
    _jarvis_env_run "$@"
  fi
fi
