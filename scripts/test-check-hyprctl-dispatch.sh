#!/usr/bin/env bash
# Run scripts/check-hyprctl-dispatch.sh over one private bin/ fixture per row and assert
# its exit status and first stderr line. Rows cover each spelling of a dispatch the rule
# refuses and each line or file it leaves alone.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
check="$repo_root/scripts/check-hyprctl-dispatch.sh"

fail() {
  printf 'test-check-hyprctl-dispatch: FAIL: %s\n' "$*" >&2
  exit 1
}

tmp="$(mktemp -d)" || fail "could not create a temporary directory"
trap 'rm -rf -- "${tmp:?}"' EXIT

# name ~ file ~ shebang ~ body from line 3, <NL> separating lines ~ expected exit ~ expected first stderr line
# shellcheck disable=SC2016  # the bodies are shell source written verbatim into the fixtures
rows=(
  'routed~vshell-a~#!/bin/bash~"$HYPR_DISPATCH" "hl.dsp.window.center()" || true~0~'
  'discarded~vshell-a~#!/bin/bash~hyprctl dispatch "hl.dsp.window.center()" >/dev/null 2>&1 || true~1~hyprctl-dispatch-unchecked bin/vshell-a:3'
  'instance flag~vshell-a~#!/usr/bin/env bash~  hyprctl -i 0 dispatch "hl.dsp.exit()"~1~hyprctl-dispatch-unchecked bin/vshell-a:3'
  'batch~vshell-a~#!/usr/bin/env bash~hyprctl --batch "dispatch hl.dsp.exit()"~1~hyprctl-dispatch-unchecked bin/vshell-a:3'
  'batch after another command~vshell-a~#!/usr/bin/env bash~hyprctl --batch "keyword a b; dispatch exec foo"~1~hyprctl-dispatch-unchecked bin/vshell-a:3'
  'continued line~vshell-a~#!/usr/bin/env bash~hyprctl \<NL>  dispatch exec foo~1~hyprctl-dispatch-unchecked bin/vshell-a:3'
  'escaped backslash ends the line~vshell-a~#!/usr/bin/env bash~hyprctl clients -j \\<NL>dispatch exec foo~0~'
  'query then separate dispatch word~vshell-a~#!/bin/bash~hyprctl clients -j; echo dispatch~0~'
  'quoted command word~vshell-a~#!/bin/bash~"hyprctl" dispatch "hl.dsp.exit()"~1~hyprctl-dispatch-unchecked bin/vshell-a:3'
  'quoted absolute path~vshell-a~#!/bin/bash~'/usr/bin/hyprctl' dispatch "hl.dsp.exit()"~1~hyprctl-dispatch-unchecked bin/vshell-a:3'
  'command substitution word~vshell-a~#!/bin/bash~"$(command -v hyprctl)" dispatch "hl.dsp.exit()"~1~hyprctl-dispatch-unchecked bin/vshell-a:3'
  'another program whose name ends in hyprctl~vshell-a~#!/bin/bash~myhyprctl dispatch "hl.dsp.exit()"~0~'
  'another program whose name starts with hyprctl~vshell-a~#!/bin/bash~hyprctl-foo dispatch "hl.dsp.exit()"~0~'
  'env option with an operand~vshell-a~#!/usr/bin/env -S -u FOO bash~hyprctl dispatch "hl.dsp.exit()"~1~hyprctl-dispatch-unchecked bin/vshell-a:3'
  'sh with an option~vshell-a~#!/bin/sh -e~hyprctl dispatch "hl.dsp.exit()"~1~hyprctl-dispatch-unchecked bin/vshell-a:3'
  'python shebang~vshell-py~#!/usr/bin/env python3~run("hyprctl dispatch exit")~0~'
  'no shebang~vshell-lib~# sourced, so the caller owns the interpreter~hyprctl dispatch "hl.dsp.exit()"~0~'
  'owner~vshell-hyprctl-dispatch~#!/usr/bin/env bash~  reply="$(hyprctl dispatch "$1" 2>&1)" || status=$?~0~'
  'comment~vshell-a~#!/bin/bash~  # hyprctl dispatch answers ok~0~'
  'query pipeline~vshell-a~#!/bin/bash~hyprctl clients -j | jq -r ".dispatch"~0~'
)

for row in "${rows[@]}"; do
  IFS='~' read -r name file shebang body want_exit want_key <<<"$row"
  fixture="$tmp/$name"
  mkdir -p "$fixture/bin"
  printf '%s\nset -u\n%s\n' "$shebang" "${body//<NL>/$'\n'}" >"$fixture/bin/$file"
  # A shell script beside every row keeps the owner row from being the only file scanned.
  [[ $file == vshell-a ]] || printf '#!/bin/bash\n:\n' >"$fixture/bin/vshell-a"
  got_exit=0
  env -i PATH=/usr/bin:/bin "$check" "$fixture" >/dev/null 2>"$tmp/stderr" || got_exit=$?
  [[ $got_exit == "$want_exit" ]] || fail "$name: exited $got_exit, want $want_exit"
  first_line=""
  IFS= read -r first_line <"$tmp/stderr" || true
  [[ $first_line == "$want_key" ]] || fail "$name: stderr starts '$first_line', want '$want_key'"
done

# A dispatch in a Python module is outside the rule, and bin/ then holds no shell script.
fixture="$tmp/python-only"
mkdir -p "$fixture/bin"
printf '#!/usr/bin/env python3\nrun(["hyprctl", "dispatch", "exit"])\n' >"$fixture/bin/vshell-helper"
got_exit=0
env -i PATH=/usr/bin:/bin "$check" "$fixture" >/dev/null 2>"$tmp/stderr" || got_exit=$?
[[ $got_exit == 2 ]] || fail "python-only: exited $got_exit, want 2"
IFS= read -r first_line <"$tmp/stderr" || true
[[ $first_line == "hyprctl-dispatch-no-scripts $fixture/bin" ]] || fail "python-only: stderr starts '$first_line'"

printf 'test-check-hyprctl-dispatch: ok (%d rows)\n' "$((${#rows[@]} + 1))"
