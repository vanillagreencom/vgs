#!/usr/bin/env bash
# Controls for bin/lib/ipc-reply.sh, the one judge of Quickshell 0.3.1
# client failure lines that bin/vgsh and the smoke harness share. The
# table pins each failure form's reason key and the replies that are no
# failure. Each rule kind of the judge, `contains`, `exact` and `prefix`,
# has a must-fail control on a copy of the library, and a copy with a row
# of unknown kind pins the judge's internal error.
set -euo pipefail

TMP_ROOT="$(mktemp -d)" || { echo "test-ipc-reply: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-ipc-reply: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "test-ipc-reply: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

repo="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)" || { echo "test-ipc-reply: repo=resolve-failed" >&2; exit 1; }
lib="$repo/bin/lib/ipc-reply.sh"

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

esc=$'\e'
# NAME|LINE|WANT, WANT `-` for a line that is no failure.
cases=(
  "ANSI ERROR line|$esc[31m ERROR$esc[97m quickshell.ipc$esc[0m: Error occurred while waiting for response.|client-error"
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
  "info log line|INFO quickshell.ipc: connected|-"
  "a reply quoting a failure text|said Function not found.|-"
  "empty line||-"
)

# check_cases LIB: run every case against LIB in a subshell and print one
# line per mismatch; exit 1 when any case mismatched, 3 when LIB does not
# load or defines no judge, so a broken mutant never reads as a red table.
check_cases() { # LIB
  (
    # shellcheck source=../bin/lib/ipc-reply.sh
    source "$1" || { echo "load-failed: $1"; exit 3; }
    declare -F vgs_ipc_reply_failure >/dev/null || { echo "no-judge: $1"; exit 3; }
    bad=0
    for row in "${cases[@]}"; do
      name="${row%%|*}"; rest="${row#*|}"; line="${rest%|*}"; want="${rest##*|}"
      status=0
      got="$(vgs_ipc_reply_failure "$line")" || status=$?
      if [[ $want == - ]]; then
        [[ $status -eq 1 && -z $got ]] && continue
      else
        [[ $status -eq 0 && $got == "$want" ]] && continue
      fi
      printf '%s: got=[%s] status=%s want=%s\n' "$name" "$got" "$status" "$want"
      bad=1
    done
    exit "$bad"
  )
}

# mutant NAME NEEDLE REPLACEMENT: a copy of the library with NEEDLE, which
# must occur exactly once, replaced; prints the copy's path.
mutant() { # NAME NEEDLE REPLACEMENT
  local copy="$TMP_ROOT/$1.sh"
  NEEDLE="$2" REPLACEMENT="$3" python3 - "$lib" "$copy" <<'PY'
import os
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = os.environ["NEEDLE"]
count = source.count(needle)
if count != 1:
    raise SystemExit(f"test-ipc-reply: needle-count={count} needle={needle!r}")
changed = source.replace(needle, os.environ["REPLACEMENT"])
if changed == source:
    raise SystemExit("test-ipc-reply: mutant=unchanged")
pathlib.Path(sys.argv[2]).write_text(changed)
PY
  printf '%s\n' "$copy"
}

echo "=== the table ==="
if report="$(check_cases "$lib")"; then
  ok "every failure form has its key and every reply reads as no failure (${#cases[@]} cases)"
else
  fail "the judge disagrees with the table:"
  printf '        %s\n' "$report"
fi

echo "=== must-fail controls ==="
# Each mutant keeps the rule's text and removes the rule's behaviour. A
# control passes only on a table mismatch, exit 1, never on a copy that
# does not load. Fields are tab-separated: the needles hold `|`.
controls=(
  $'contains rule\t      contains) [[ $stripped == *"$text"* ]] || continue ;;\t      contains) continue ;;'
  $'exact rule\t      exact) [[ $stripped == "$text" ]] || continue ;;\t      exact) continue ;;'
  $'prefix rule\t      prefix) [[ $stripped == "$text"* ]] || continue ;;\t      prefix) continue ;;'
)
for row in "${controls[@]}"; do
  IFS=$'\t' read -r name needle replacement <<<"$row" || { fail "control row unreadable: [$row]"; continue; }
  copy="$(mutant "${name// /-}" "$needle" "$replacement")" || { fail "control: $name: the mutant could not be written"; continue; }
  status=0
  report="$(check_cases "$copy")" || status=$?
  if [[ $status -eq 1 ]]; then
    ok "control: a judge without its $name turns the table red"
  else
    fail "control: a judge without its $name: status=$status report=[$report]"
  fi
done

copy="$(mutant unknown-kind "'client-error|contains|ERROR quickshell.ipc'" "'client-error|contain|ERROR quickshell.ipc'")" || { echo "test-ipc-reply: mutant=unknown-kind" >&2; exit 1; }
set +e
out="$(source "$copy"; vgs_ipc_reply_failure ok 2>"$TMP_ROOT/err")"
status=$?
set -e
err="$(cat -- "$TMP_ROOT/err")" || { echo "test-ipc-reply: read=err" >&2; exit 1; }
if [[ $status -eq 2 && -z $out && $err == "ipc-reply: kind=contain row=client-error" ]]; then
  ok "a table row of unknown kind is an internal error, exit 2"
else
  fail "unknown kind: status=$status out=[$out] err=[$err]"
fi

if [[ $failures -gt 0 ]]; then echo "test-ipc-reply: failed=$failures"; exit 1; fi
echo "test-ipc-reply: ok"
