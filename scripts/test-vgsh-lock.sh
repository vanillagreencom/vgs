#!/usr/bin/env bash
# Controls for `vgsh lock`, bin/vgsh-lock: the themed configuration and its
# background variable, the user's own configuration when none is rendered,
# XDG_STATE_HOME, the one-lock guard hyprlock inherits, a held guard, a
# guard that cannot be taken, and the refusals. Every row runs vgsh under a PATH of the
# suite's own directories alone, a stand-in hyprlock that records its argv
# and VGS_LOCK_BACKGROUND and a directory of the few tools vgsh needs, so no
# row can reach the host's hyprlock; base_env also names no Wayland display.
# Expected values are the paths each row planted, never vgsh's own output.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

tools="$tmp/lock-tools"
mkdir -p "$tools"
for tool in bash env readlink dirname cat flock; do
  resolved="$(type -P "$tool")" || { echo "test-vgsh-lock: tool=$tool missing" >&2; exit 1; }
  ln -s -- "$resolved" "$tools/$tool"
done
stub="$tmp/lock-stub"
mkdir -p "$stub"
# The stand-in writes one argv word per line, then `background=<value>` or
# `background=unset`, then `guard=<file>` for the file its descriptor 9
# holds or `guard=none`, to $STUB_ARGS, and exits with $STUB_EXIT.
cat >"$stub/hyprlock" <<'SH'
#!/usr/bin/env bash
{ for word in "$@"; do printf 'arg=%s\n' "$word"; done
  if [[ -v VGS_LOCK_BACKGROUND ]]; then printf 'background=%s\n' "$VGS_LOCK_BACKGROUND"; else echo background=unset; fi
  printf 'guard=%s\n' "$(readlink "/proc/$$/fd/9" 2>/dev/null || echo none)"
} >"$STUB_ARGS"
exit "${STUB_EXIT:-0}"
SH
chmod 755 "$stub/hyprlock"
with_lock="$stub:$tools"
without_lock="$tools"

home="$tmp/home"
default_state="$home/.local/state/vgs"
other_state="$tmp/other-state/vgs"
cfg="$tmp/cfg-lock"
# The stand-in's record as one line, or nothing when it did not run.
recorded() { [[ -f $tmp/args ]] || return 0; local lines; mapfile -t lines <"$tmp/args"; printf '%s' "${lines[*]}"; }
theme_file() { # STATE_DIR
  mkdir -p "$1/theme"
  printf 'general {\n}\n' >"$1/theme/hyprlock.conf"
}

guard="$rt_empty/vgsh-screen-lock.lock"
# lock_row NAME WANT_EXIT WANT_STDOUT WANT_STDERR WANT_RECORD PATH [NAME=VALUE...]
# RT_DIR, when set, is the runtime directory the row hands vgsh.
lock_row() {
  local name="$1" want_exit="$2" want_out="$3" want_err="$4" want_record="$5" path="$6"
  shift 6
  rm -f -- "${tmp:?}/args"
  inst_env=("$@")
  INST_PATH="$path" inst "$name: exit and output" "$cfg" "${RT_DIR:-$rt_empty}" "$want_exit" "$want_out" "$want_err" lock
  inst_env=()
  local got=""
  if got="$(recorded)" && [[ $got == "$want_record" ]]; then ok "$name: hyprlock's argv and background"; else fail "$name: recorded=[$got] want=[$want_record]"; fi
}

rm -rf -- "$default_state" "$other_state"
themed_record="arg=--config arg=$default_state/theme/hyprlock.conf background=$default_state/background guard=$guard"
lock_row "no theme lock screen runs plain hyprlock" 0 "" "" "background=unset guard=$guard" "$with_lock"
theme_file "$default_state"
lock_row "the theme lock screen runs with its background and the guard" 0 "" "" "$themed_record" "$with_lock"
theme_file "$other_state"
lock_row "XDG_STATE_HOME names the state directory" 0 "" "" \
  "arg=--config arg=$other_state/theme/hyprlock.conf background=$other_state/background guard=$guard" "$with_lock" XDG_STATE_HOME="$tmp/other-state"
lock_row "hyprlock's exit status is the command's" 3 "" "" "$themed_record" "$with_lock" STUB_EXIT=3
lock_row "no hyprlock on PATH is refused" 1 "" "vgsh: refused: lock=hyprlock-missing" "" "$without_lock"
# A held guard: the lock another vgsh lock's hyprlock holds.
exec 7>>"$guard"
flock -n 7 || { echo "test-vgsh-lock: fixture=guard-hold" >&2; exit 1; }
lock_row "a held guard starts no second hyprlock" 0 "ok lock=held" "" "" "$with_lock"
exec 7>&-
RT_DIR="$tmp/no-runtime-dir" lock_row "a guard that cannot be taken still locks" 0 "" "vgsh: lock-guard=unavailable path=$tmp/no-runtime-dir/vgsh-screen-lock.lock" \
  "arg=--config arg=$default_state/theme/hyprlock.conf background=$default_state/background guard=none" "$with_lock"
rm -f -- "${tmp:?}/args"
INST_PATH="$with_lock" inst "an argument is a bad invocation" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=--now" lock --now
if [[ -e $tmp/args ]]; then fail "a bad invocation ran hyprlock"; else ok "a bad invocation runs no hyprlock"; fi

# Must-fail controls, one per rule, each on a copy of bin/: the copy's
# row fails the expectation the real script meets.
control() { # NAME NEEDLE REPLACEMENT
  local tree_copy="$tmp/control-$1"
  mkdir -p "$tree_copy"
  cp -R -- "$repo/bin" "$tree_copy/"
  copy_with "$1" "$repo/bin/vgsh-lock" "$2" "$3"
  cp -- "$copy" "$tree_copy/bin/vgsh-lock"
  control_bin="$tree_copy/bin/vgsh"
}
# control_row NAME WANT_EXIT WANT_RECORD PATH [NAME=VALUE...]: passes when
# the copy misses WANT_EXIT or WANT_RECORD. RT_DIR as lock_row's.
control_row() {
  local name="$1" want_exit="$2" want_record="$3" path="$4" status=0 got
  shift 4
  rm -f -- "${tmp:?}/args"
  "${base_env[@]}" PATH="$path" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="${RT_DIR:-$rt_empty}" STUB_ARGS="$tmp/args" "$@" "$control_bin" lock </dev/null >/dev/null 2>&1 || status=$?
  got="$(recorded)" || { fail "control: $name: the stand-in's record is unreadable"; return; }
  if [[ $status != "$want_exit" || $got != "$want_record" ]]; then ok "control: $name"; else fail "control: $name passed the row"; fi
}
control no-config 'if [[ -f $config ]]; then' 'if false; then'
control_row "a copy that never reads the theme lock screen" 0 "$themed_record" "$with_lock"
control no-background 'VGS_LOCK_BACKGROUND="$state/background" exec' 'exec'
control_row "a copy that drops the background variable" 0 "$themed_record" "$with_lock"
control no-xdg '${XDG_STATE_HOME:-$HOME/.local/state}/vgs' '$HOME/.local/state/vgs'
control_row "a copy that ignores XDG_STATE_HOME" 0 \
  "arg=--config arg=$other_state/theme/hyprlock.conf background=$other_state/background guard=$guard" "$with_lock" XDG_STATE_HOME="$tmp/other-state"
control no-probe 'hyprlock="$(type -P hyprlock)" ||' 'hyprlock=hyprlock ||'
control_row "a copy that runs hyprlock without looking for it" 1 "" "$without_lock"
control guard-released '  0) ;;' '  0) exec 9>&- ;;'
control_row "a copy that releases the guard before hyprlock" 0 "$themed_record" "$with_lock"
control no-guard 'flock -n -E 75 9 || held=$?' 'true'
exec 7>>"$guard"
flock -n 7 || { echo "test-vgsh-lock: fixture=guard-hold" >&2; exit 1; }
control_row "a copy that ignores a held guard" 0 "" "$with_lock"
exec 7>&-
control guard-refuses '    exec 9>&-' '    refuse 1 "lock-guard=unavailable"'
RT_DIR="$tmp/no-runtime-dir" control_row "a copy that refuses to lock without the guard" 0 \
  "arg=--config arg=$default_state/theme/hyprlock.conf background=$default_state/background guard=none" "$with_lock"

rows_done test-vgsh-lock
