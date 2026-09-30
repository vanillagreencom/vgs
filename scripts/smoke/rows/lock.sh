# The lock, vgs.lock, and `vgsh lock`: the service's IPC and SUPER+L on
# the nested seat run `vgsh lock`, which starts the real hyprlock on the
# theme's lock screen against the nested compositor alone; the compositor
# then reports the session locked. A second `vgsh lock` while locked starts
# nothing. The shell killed by its pid leaves the session locked and
# hyprlock alive, which is the lock's guarantee
# (docs/architecture/lock-polkit.md); SIGUSR1 to hyprlock's pid unlocks.
#
# hyprlock resolves through the shell's stand-in directory, where a wrapper
# records each start's pid, argv and VGS_LOCK_BACKGROUND and execs the real
# binary on a copy of the rendered file with PAM turned off, so the row
# signals only the hyprlock it started and no PAM conversation runs against
# the account: hyprlock starts pam_authenticate as it locks, and a SIGUSR1
# unlock ends that conversation as a failed login, which pam_faillock
# counts (docs/architecture/lock-polkit.md § Validation). The wrapper runs
# nothing but that argv. No row types a password. The sandbox
# copy ships no theme target; the row adds the shipped hyprlock target,
# applies vgs, and takes both back at its end. It restarts the shell after
# the kill, checking the killed shell's log first, since the rows after it
# read the new one, and ends with the plugin disabled and hyprland.lua as
# the first run left it.
#
# The control swaps the wrapper for one that records a pid and never locks:
# the lock reading must stay unlocked over it.
set -euo pipefail
lock_state="$home/.local/state/vgs"
lock_target="$repo/themes/targets/hyprlock"
lock_hypr_lua="$home/.config/hypr/hyprland.lua"
lock_log="$sandbox/hyprlock-starts"
real_hyprlock="$(command -v hyprlock)"
lock_conf="$sandbox/hyprlock-smoke.conf"
# lock_wrapper MODE: `real` execs hyprlock on a copy of the rendered file
# with PAM off, and refuses any other argv; `idle` sleeps in its place.
# Either records the start first.
lock_wrapper() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'log=%q starts=%q conf=%q real=%q mode=%q\n' "$sandbox/hyprlock.log" "$lock_log" "$lock_conf" "$real_hyprlock" "$1"
    cat <<'SH'
printf 'pid=%s argv=%s background=%s\n' "$$" "$*" "${VGS_LOCK_BACKGROUND-unset}" >>"$starts"
exec >>"$log" 2>&1
[[ $mode == real ]] || exec sleep 30
[[ $# -eq 2 && $1 == --config && -f $2 ]] || { echo "hyprlock stand-in: refused: argv=$*"; exit 64; }
{ cat -- "$2" && printf '\nauth {\n    pam {\n        enabled = 0\n    }\n    fingerprint {\n        enabled = 1\n    }\n}\n'; } >"$conf" || exit 65
exec "$real" --config "$conf"
SH
  } >"$shim/hyprlock.next"
  chmod 755 "$shim/hyprlock.next" && mv -T -- "$shim/hyprlock.next" "$shim/hyprlock"
}
# The pid of the Nth start the wrapper recorded, or `none`.
lock_pid() { local line; line="$(sed -n "${1}p" -- "$lock_log" 2>/dev/null)"; [[ $line =~ ^pid=([0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo none; }
lock_starts() { if [[ -f $lock_log ]]; then wc -l <"$lock_log"; else echo 0; fi; }
alive() { if [[ $1 =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; then echo alive; else echo gone; fi; }
# `locked` while any nested monitor names LOCK among the reasons it cannot
# go solitary, which Hyprland keeps while an ext-session-lock holds, its
# client dead or not; `unlocked` otherwise.
session_lock() { hypr -j monitors | python3 -c 'import json,sys; print("locked" if any("LOCK" in (m.get("solitaryBlockedBy") or []) for m in json.load(sys.stdin)) else "unlocked")'; }
lock_lent() { ipc shell lent | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([[s for s in d["shortcuts"] if s.startswith("vgs.lock")], [t for t in d["ipcTargets"] if t == "vgs.lock"]]))'; }
lock_binds() { hypr -j binds | python3 -c 'import json,sys; print(json.dumps(sorted([b["modmask"], b["key"], b["description"]] for b in json.load(sys.stdin) if b["description"].startswith("vgs.lock"))))'; }
# SIGUSR1 to the Nth start's hyprlock, then its exit and the unlock.
unlock_start() { # N LABEL
  local pid
  if ! pid="$(lock_pid "$1")" || [[ $pid == none ]]; then fail "$2: no hyprlock start $1 recorded"; return; fi
  kill -USR1 "$pid" || { fail "$2: SIGUSR1 to pid $pid failed"; return; }
  expect_poll "$2: hyprlock exits" gone alive "$pid"
  expect_poll "$2: the session is unlocked" unlocked session_lock
}
restore_lock_hypr_lua() { { printf '%s\n' "pcall(dofile, \"$home/.local/state/vgs/hypr/vgs.lua\")"; cat -- "$sandbox/hyprland-harness.lua"; } >"$lock_hypr_lua.next" && mv -T -- "$lock_hypr_lua.next" "$lock_hypr_lua"; }
vgsh_lock_run() { "${shell_env[@]}" "$repo/bin/vgsh" "$@"; }

rm -f -- "$lock_log"
lock_wrapper real
expect "the session is unlocked before the row" unlocked session_lock

# The theme's lock screen, from the shipped target.
mkdir -p -- "$lock_target"
cp -- "$source_repo/themes/targets/hyprlock/target.json" "$source_repo/themes/targets/hyprlock/hyprlock.conf" "$lock_target/"
expect "the shell is idle before the apply" idle theme_idle
applied_line() { local out; out="$(vgsh_lock_run theme apply vgs)" || return; printf '%s\n' "${out##*$'\n'}" | cut -d' ' -f1-2; }
expect "vgs applies with the hyprlock target" "ok theme=vgs" applied_line
expect "the apply rendered the lock screen" '$VGS_LOCK_BACKGROUND' bash -c 'sed -n "s/^ *path = //p" "$1"' _ "$lock_state/theme/hyprlock.conf"

expect "the lock plugin starts disabled in the sandbox" False plugin_enabled vgs.lock
expect "enabling the lock plugin is allowed" ok ipc shell setPluginEnabled vgs.lock true
expect_poll "the lock service registered its shortcut and IPC target" '[["vgs.lock:lock"], ["vgs.lock"]]' lock_lent
expect_poll "the nested instance binds SUPER+L to the lock" '[[64, "L", "vgs.lock:lock"]]' lock_binds

# The IPC lock: hyprlock on the theme's lock screen, with its background.
expect "the service's IPC lock answers ok" ok ipc vgs.lock invoke lock ''
expect_poll "the IPC lock started hyprlock" 1 lock_starts
expect "hyprlock ran on the theme's lock screen with its background" \
  "argv=--config $lock_state/theme/hyprlock.conf background=$lock_state/background" bash -c 'sed -n 1p "$1" | cut -d" " -f2-' _ "$lock_log"
expect_poll "the compositor reports the session locked" locked session_lock
expect "the first hyprlock is alive" alive alive "$(lock_pid 1)"
# A hyprlock that asked PAM for a password would count a failed login at
# its SIGUSR1 unlock; SIGKILL ends it before its conversation returns, and
# the row stops there.
if grep -q -e PAMPROMPT -e 'auth:' -- "$sandbox/hyprlock.log"; then
  kill -KILL "$(lock_pid 1)" 2>/dev/null || :
  fail "hyprlock started a PAM conversation; the row stopped it with SIGKILL and ends here"
  return 0
fi

# A second lock while locked starts nothing: the first hyprlock holds the
# guard. The row runs it with the shell's PATH, so any hyprlock it started
# would be the wrapper.
expect "a second vgsh lock while locked answers held" "ok lock=held" "${shell_env[@]}" PATH="$shell_start_path" "$repo/bin/vgsh" lock
expect "the second lock started no hyprlock" 1 lock_starts
expect "the first hyprlock stays alive" alive alive "$(lock_pid 1)"
expect "the session stays locked" locked session_lock
unlock_start 1 "the IPC lock"

# SUPER+L on the nested seat. wtype's keys resolve a bind by keysym only
# (docs/architecture/runtime-hyprland.md), so the row turns that on.
printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = true } })' >>"$lock_hypr_lua"
expect "the nested instance reloads with binds resolved by keysym" ok hypr reload config-only
type_keys -M logo -k l -m logo || fail "typing SUPER+L failed"
expect_poll "SUPER+L started hyprlock" 2 lock_starts
expect_poll "SUPER+L locked the session" locked session_lock

# The shell dies while locked: the lock stays and hyprlock keeps it.
check_unexpected_log "the shell's log before the kill" "$instance_log"
killed_pid="$shell_qs_pid"
kill -KILL "$killed_pid" || fail "SIGKILL to the shell pid $killed_pid failed"
expect_poll "the killed shell is gone" gone alive "$killed_pid"
stop_shell || :
expect "the session stays locked after the shell died" locked session_lock
expect "hyprlock stays alive after the shell died" alive alive "$(lock_pid 2)"
unlock_start 2 "the SUPER+L lock"
restore_lock_hypr_lua || fail "hyprland.lua is put back after the lock rows"
if start_shell "$repo" "$sandbox/after-lock-qs.log"; then
  expect_poll "the restarted shell rebuilt the lock service" '[["vgs.lock:lock"], ["vgs.lock"]]' lock_lent
fi

# Control: a hyprlock that starts and never locks reads unlocked.
lock_wrapper idle
expect "the control's IPC lock answers ok" ok ipc vgs.lock invoke lock ''
expect_poll "the control's stand-in started" 3 lock_starts
control_pid="$(lock_pid 3)" || control_pid=none
got=""
for _ in $(seq 1 10); do got="$(session_lock)" || got=unreadable; [[ $got == unlocked ]] || break; sleep 0.2; done
if [[ $got == unlocked && $(alive "$control_pid") == alive ]]; then ok "control: a live hyprlock stand-in that never locks reads unlocked"; else fail "control: the lock reading got $got over a stand-in that never locks"; fi
[[ $control_pid == none ]] || kill -TERM "$control_pid" 2>/dev/null || :

expect "no hyprlock ran a PAM conversation" 0 bash -c 'grep -c -e PAM -e "auth:" -- "$1" || :' _ "$sandbox/hyprlock.log"
expect "hyprlock read the theme's lock screen with no error" 0 bash -c 'grep -c "^ERR" -- "$1" || :' _ "$sandbox/hyprlock.log"
expect "disabling the lock plugin is allowed" ok ipc shell setPluginEnabled vgs.lock false
expect_poll "disable released the lock's shortcut and IPC target" '[[], []]' lock_lent
expect_poll "the nested instance drops the lock's bind" '[]' lock_binds
rm -f -- "$shim/hyprlock"
rm -r -- "$lock_target"
expect "the shell is idle before the closing apply" idle theme_idle
expect "vgs applies again without the hyprlock target" "ok theme=vgs" applied_line
expect "the closing apply took the lock screen back" absent bash -c '[[ -e $1 ]] && echo present || echo absent' _ "$lock_state/theme/hyprlock.conf"
expect "hyprland.lua is as the first run left it" same bash -c 'cmp -s <(sed 1d "$1") "$2" && echo same || echo differs' _ "$lock_hypr_lua" "$sandbox/hyprland-harness.lua"
