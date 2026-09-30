#!/usr/bin/env bash
# Controls for `vgsh lock`, bin/vgsh-lock: the call it makes on vgs.lock's
# IPC target of the shell the instance lock names, its answer taken from
# qs's last stdout line, and each refusal. A stub qs, first on the suite's
# PATH, records its argv and answers from STUB_REPLY and STUB_STATUS after
# STUB_NOISE; the instance lock names this suite's own pid, a live process
# that is no shell. Expected values are the ones each row planted.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

cat >"$tmp/qs" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${STUB_ARGS:?}"
[[ -z ${STUB_NOISE:-} ]] || printf '%s\n' "$STUB_NOISE"
printf '%s\n' "${STUB_REPLY:-ok}"
exit "${STUB_STATUS:-0}"
SH
chmod 755 "$tmp/qs"

rt="$tmp/rt-lock"
mkdir -p "$rt"
printf '%s\n' "$$" >"$rt/vgsh.lock"
cfg="$tmp/cfg-lock"

# lock_row NAME WANT_EXIT WANT_STDOUT WANT_STDERR [NAME=VALUE...]
lock_row() {
  local name="$1" want_exit="$2" want_out="$3" want_err="$4"
  shift 4
  inst_env=("$@")
  inst "$name" "$cfg" "${RT:-$rt}" "$want_exit" "$want_out" "$want_err" lock
  inst_env=()
}

rm -f -- "${tmp:?}/args"
lock_row "the plugin's ok is the answer" 0 ok ""
check "the call reaches vgs.lock's lock function in the shell the instance lock names" test "$(<"$tmp/args")" == "ipc --pid $$ call vgs.lock invoke lock "
lock_row "qs's log lines ahead of the reply are skipped" 0 ok "" STUB_NOISE="INFO: log line"
lock_row "a plugin refusal is the command's" 1 "" "vgsh: refused: lock=not-ready" STUB_REPLY="refused: lock=not-ready"
lock_row "a core refusal keeps its key" 1 "" "vgsh: refused: lock-content=not-a-component" STUB_REPLY="refused: lock-content=not-a-component"
lock_row "a lock function not registered yet is no answer" 1 "" "vgsh: refused: lock=no-answer pid=$$" STUB_REPLY="unknown: lock"
lock_row "a failed qs call is no answer" 1 "" "vgsh: refused: lock=no-answer pid=$$" STUB_STATUS=1
RT="$tmp/rt-none" lock_row "no shell is exit 69" 69 "" "vgsh: refused: shell=not-running lock=$tmp/rt-none/vgsh.lock"
inst "an argument is a bad invocation" "$cfg" "$rt" 2 "" "vgsh: refused: argument=--now" lock --now

# Must-fail controls, one per rule, each on a copy of bin/: the copy's row
# fails the expectation the real script meets.
control() { # NAME NEEDLE REPLACEMENT
  local tree_copy="$tmp/control-$1"
  mkdir -p "$tree_copy"
  cp -R -- "$repo/bin" "$tree_copy/"
  copy_with "$1" "$repo/bin/vgsh-lock" "$2" "$3"
  cp -- "$copy" "$tree_copy/bin/vgsh-lock"
  control_bin="$tree_copy/bin/vgsh"
}
# control_row NAME WANT_EXIT WANT_STDERR_FIRST [NAME=VALUE...]: passes when
# the copy misses the exit or the first stderr line.
control_row() {
  local name="$1" want_exit="$2" want_err="$3" status=0 err=""
  shift 3
  "${base_env[@]}" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="$rt" STUB_ARGS="$tmp/args" "$@" "$control_bin" lock </dev/null >/dev/null 2>"$tmp/control.err" || status=$?
  [[ -s $tmp/control.err ]] && IFS= read -r err <"$tmp/control.err"
  if [[ $status != "$want_exit" || $err != "$want_err" ]]; then ok "control: $name"; else fail "control: $name passed the row"; fi
}
control reply-ignored 'case "$reply" in' 'case ok in'
control_row "a copy that ignores the plugin's answer" 1 "vgsh: refused: lock=not-ready" STUB_REPLY="refused: lock=not-ready"
control no-answer-unkeyed '  refuse 1 "lock=no-answer pid=$pid" "vgs.lock is disabled' '  : "lock=no-answer pid=$pid" "vgs.lock is disabled'
control_row "a copy that reads a failed call as an empty answer" 1 "vgsh: refused: lock=no-answer pid=$$" STUB_STATUS=1
control whole-output 'reply="${out##*$'"'"'\n'"'"'}"' 'reply="$out"'
control_row "a copy that reads qs's log as the answer" 0 "" STUB_NOISE="INFO: log line"

rows_done test-vgsh-lock
