#!/usr/bin/env bash
# Controls for bin/lib/ipc-reply.sh. The table pins the Quickshell 0.3.1
# client failure lines that `bin/vgsh` and the smoke harness share.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")" || { echo "test-ipc-reply: self=resolve-failed" >&2; exit 1; }
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)" || { echo "test-ipc-reply: repo=resolve-failed" >&2; exit 1; }
scratch_parent="$repo/tmp"
mkdir -p "$scratch_parent"
tmp="$scratch_parent/test-ipc-reply.$$"
if ! mkdir -- "$tmp"; then
  echo "test-ipc-reply: scratch=exists path=$tmp" >&2
  exit 1
fi
[[ -d $tmp && ! -L $tmp ]] || { echo "test-ipc-reply: scratch=not-a-directory path=$tmp" >&2; exit 1; }
tmp="$(cd -- "$tmp" && pwd -P)" || { echo "test-ipc-reply: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${tmp:?}"' EXIT

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

ansi_error="$(printf '\033[31m ERROR\033[97m quickshell.ipc\033[0m: Error occurred while waiting for response.')" || { echo "test-ipc-reply: ansi-error=build-failed" >&2; exit 1; }
cases=(
  "ANSI ERROR line|$ansi_error|client-error"
  "plain ERROR line|ERROR quickshell.ipc: Error occurred while waiting for response.|client-error"
  "function not found|Function not found.|function-not-found"
  "target not found|Target not found.|target-not-found"
  "not ready|Not ready to accept queries yet.|not-ready"
  "target required|Target required to send message.|target-required"
  "function required|Function required to send message.|function-required"
  "too many arguments|Too many arguments provided, expected 2.|too-many-arguments"
  "too few arguments|Too few arguments provided, expected 2.|too-few-arguments"
  "unparseable argument|Unable to parse argument 2 as int.|unparseable-argument"
  "function definition|Function definition: shell.ping()|arguments"
  "ok reply|ok|-"
  "json reply|{\"a\":1}|-"
  "paged reply|paged=7|-"
  "info log|INFO quickshell.ipc: connected|-"
  "empty line||-"
)

run_cases() { # LIB QUIET
  local lib="$1" quiet="${2:-}" before="$failures" name line want got status
  case_fail() { if [[ -n $quiet ]]; then failures=$((failures + 1)); else fail "$1"; fi; }
  # shellcheck source=../bin/lib/ipc-reply.sh
  source "$lib"
  for row in "${cases[@]}"; do
    IFS='|' read -r name line want <<<"$row"
    status=0
    got="$(vgs_ipc_reply_failure "$line")" || status=$?
    if [[ $want == - ]]; then
      if [[ $status -eq 1 && -z $got ]]; then [[ -n $quiet ]] || ok "$name"; else case_fail "$name: got=[$got] status=$status want=not-failure"; fi
    else
      if [[ $status -eq 0 && $got == "$want" ]]; then [[ -n $quiet ]] || ok "$name"; else case_fail "$name: got=[$got] status=$status want=$want"; fi
    fi
  done
  [[ $failures == "$before" ]]
}

copy_with() { # NAME NEEDLE REPLACEMENT
  local target="$tmp/$1.sh" count
  if ! count="$(grep -cF -- "$2" "$repo/bin/lib/ipc-reply.sh")"; then
    count=0
  fi
  [[ $count == 1 ]] || { echo "test-ipc-reply: control=$1 needle-count=$count" >&2; exit 1; }
  NEEDLE="$2" REPLACEMENT="$3" python3 - "$repo/bin/lib/ipc-reply.sh" "$target" <<'PY'
import os
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
changed = source.replace(os.environ["NEEDLE"], os.environ["REPLACEMENT"], 1)
pathlib.Path(sys.argv[2]).write_text(changed)
PY
  if cmp -s -- "$repo/bin/lib/ipc-reply.sh" "$target"; then
    echo "test-ipc-reply: control=$1 unchanged" >&2
    exit 1
  fi
  copy="$target"
}

run_cases "$repo/bin/lib/ipc-reply.sh"

control_fails() { # NAME NEEDLE REPLACEMENT
  local name="$1"
  copy_with "$@"
  local before="$failures"
  run_cases "$copy" quiet || true
  if [[ $failures -gt $before ]]; then
    ok "control: $name turns the table red"
    failures="$before"
  else
    fail "control: $name still passes"
  fi
}

control_fails "ERROR line rule" 'client-error|contains|ERROR quickshell.ipc' 'client-error|never|ERROR quickshell.ipc'
control_fails "exact message table" 'function-not-found|exact|Function not found.' 'function-not-found|never|Function not found.'

if [[ $failures -gt 0 ]]; then echo "test-ipc-reply: failed=$failures"; exit 1; fi
echo "test-ipc-reply: ok"
