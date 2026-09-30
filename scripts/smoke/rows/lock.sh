# The lock, vgs.lock: a first-party service on the core's `lock`
# capability. The harness starts it disabled; this row enables it and locks
# the nested session through each entry point: its IPC function, `vgsh
# lock`, SUPER+L on the nested seat, its idle watch and its before-sleep
# hook. Each lock is read back from the compositor, a monitor naming LOCK
# among the reasons it cannot go solitary in `hyprctl -j monitors`, and
# from the core's lending record. The lock screen's geometry holds the
# design standard on every screen (docs/architecture/design-quality.md):
# each part inside its surface, the time and the date at least `stack.row`
# apart, the field and the status line each at least `stack.group` below
# the block above, the field at least `size.control.md` tall and centred;
# its control is a planted reading with the field `stack.group` short.
# While a second lock client, the harness's
# lock-client standing in for another locker, holds the session, the
# plugin's lock takes over under the restore option; the client's unlock
# then unlocks the session, the core ends the plugin's lock, and the plugin
# publishes it and locks again. A sleep whose budget runs out before the
# lock is confirmed is published and shown as a toast once unlocked.
# A hook that cannot start is published as such and taken again once the
# setting turns it back on. Disabling the plugin while locked keeps
# the session locked, and the rebuilt plugin hands its lock screen over
# again. The shell killed by its pid while locked leaves the session
# locked, the runner starts the next shell (D069), and that shell's lock
# plugin reads the stranded lock and takes it over through the layer's
# `misc.allow_session_lock_restore`. A sampler reads the session lock from
# the compositor every 100 ms from before the kill until the new shell's
# lock is confirmed and must find it locked each time; its control runs it
# across the second lock client's unlock, which unlocks the session. An
# unlock shorter than one 100 ms sample, between two readings, is not
# read. The runner's relaunch line for each kill names session=locked,
# the runner's own reading of the same lock. The time from the kill to the
# confirmed lock with the lock screen is printed as latency_lock_back_ms
# and held under lock_back_budget_ms, below.
#
# No row types a password: PAM would check it against the real account,
# whose pam_faillock counts each failure. The sandbox's own probe releases
# the core's lock with no password, test code that never ships
# (docs/architecture/lock-polkit.md § Validation). The evidence that no
# check ran spans the whole row, every plugin rebuild and both shell
# relaunches: each shell's log, kept before its kill, holds a
# `lock: check=started` line for every check started, and the harness's
# watcher records every authentication helper it sees under the sandbox.
# A control copy of the plugin starts one stand-in check, which runs no
# PAM, before the restarts, and a stand-in named unix_chkpwd, a copy of
# sleep, runs early too: at the row's end the whole-row readings must hold
# exactly those two, so a reading of the last instance or the last shell
# alone would fail.
#
# The before-sleep hook runs under stand-ins in the shell's stand-in
# directory: a systemd-inhibit that runs its command with no inhibitor and
# logs the command's lines, a busctl that answers logind's 5 s default and
# no preparation under way, and a dbus-monitor that prints the bus's
# NameAcquired at once and announces one PrepareForSleep once the row
# creates its trigger file. The sandbox's system bus holds no logind.
#
# The control installs a copy of the plugin, in the user directory whose id
# wins, that never locks a stranded session: after a kill and a restart the
# session is still locked while the core holds no lock, so the takeover
# reading is not vacuous. `lock` is exclusive, so the row disables the
# capability rows' fixture, acme.probe, when an earlier row left it
# enabled. The row ends with the plugin disabled, the fixture as it found
# it, the stand-ins gone and hyprland.lua as the first run left it.
set -euo pipefail
lock_user_config="$home/.config/vgs/shell.json"
lock_hypr_lua="$home/.config/hypr/hyprland.lua"
sleep_log="$sandbox/sleep-watch.log"
sleep_trigger="$sandbox/prepare-sleep"
# `locked` while any nested monitor names LOCK among the reasons it cannot
# go solitary, which Hyprland keeps while an ext-session-lock holds, its
# client dead or not; `unlocked` otherwise.
session_lock() { hypr -j monitors | py_reply 'import json,sys; print("locked" if any("LOCK" in (m.get("solitaryBlockedBy") or []) for m in json.load(sys.stdin)) else "unlocked")'; }
# The core's lock as [requested, secure, content].
core_requested() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["lock"]["requested"]))'; }
core_lock() { ipc shell lent | py_reply 'import json,sys; l=json.load(sys.stdin)["lock"]; print(json.dumps([l["requested"], l["secure"], l["content"]]))'; }
lock_status() { ipc vgs.lock invoke status '' | py_reply 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d[k] for k in sys.argv[1:]]))' "$@"; }
sleep_status() { ipc smoke statusValues vgs.lock | py_reply 'import json,sys; v=json.load(sys.stdin).get("sleep"); print(v["tone"] if v else "unpublished")'; }
# A published status value of vgs.lock as [tone, text], or null.
status_value() { ipc smoke statusValues vgs.lock | py_reply 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print(json.dumps(v if v is None else [v["tone"], v["text"]]))' "$1"; }
lock_toasts() { ipc shell lent | py_reply 'import json,sys; print(json.dumps([[t["title"], t["tone"]] for t in json.load(sys.stdin)["toasts"]["visible"] if t["plugin"] == "vgs.lock"]))'; }
# `vgsh lock`'s first line and its exit status.
vgsh_lock() { local out status=0; out="$("${shell_env[@]}" "$repo/bin/vgsh" lock 2>&1)" || status=$?; printf '%s exit=%s\n' "$(head -n 1 <<<"$out")" "$status"; }
client_said() { if grep -q -x -- "$2" "$1" 2>/dev/null; then echo "$2"; else echo waiting; fi; }
# The lock's binds in the default map; the overlay capture submap repeats
# every plugin bind (hyprland.md).
lock_binds() { hypr -j binds | py_reply 'import json,sys; print(json.dumps(sorted([b["modmask"], b["key"], b["description"]] for b in json.load(sys.stdin) if b["description"].startswith("vgs.lock") and b.get("submap", "") in ("", "default"))))'; }
lock_lent() { ipc shell lent | py_reply 'import json,sys; d=json.load(sys.stdin); print(json.dumps([[s for s in d["shortcuts"] if s.startswith("vgs.lock")], [t for t in d["ipcTargets"] if t == "vgs.lock"], [[w["id"], w["timeout"]] for w in d["idle"] if w["id"] == "vgs.lock"]]))'; }
restore_option() { hypr -j getoption misc:allow_session_lock_restore | py_reply 'import json,sys; v=json.load(sys.stdin); print(json.dumps({k: v[k] for k in v if k not in ("option", "set")}))'; }
# The `lock: check=started` lines in every shell log of the row: the kept
# logs of the killed shells and the running shell's.
kept_logs=()
check_starts() { cat -- "${kept_logs[@]}" "$instance_log" | grep -c -F 'lock: check=started' || :; }
no_checks() { expect "$1: no PAM check started and no attempt failed" '[false, 0, 0]' lock_status checking checks failures; }
# The lock screens vgs.lock reports, as the probe reads them.
lock_screens() { ipc smoke lockScreens vgs.lock; }
# Read a lockScreens reply on stdin against the standard: `ok`, or the
# first rule a screen breaks. Arguments: size.control.md, stack.group and
# stack.row.
lock_geometry_check() { py_reply 'import json,sys
screens = json.load(sys.stdin)
control, group, row = (float(v) for v in sys.argv[1:4])
def bad(text):
    print(text)
    sys.exit(0)
if not isinstance(screens, list) or not screens:
    bad("no-screen")
for i, screen in enumerate(screens):
    width, height, parts = screen["width"], screen["height"], screen["parts"]
    for key in ("time", "date", "field", "status"):
        if key not in parts:
            bad("screen%d: no %s" % (i, key))
        x, y, w, h = parts[key]
        if w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > width + 0.5 or y + h > height + 0.5:
            bad("screen%d: %s outside the screen" % (i, key))
    time, date, field, status = (parts[k] for k in ("time", "date", "field", "status"))
    if date[1] < time[1] + time[3] + row - 0.5:
        bad("screen%d: the date is less than stack.row under the time" % i)
    if field[1] < date[1] + date[3] + group - 0.5:
        bad("screen%d: the field is less than stack.group under the date" % i)
    if status[1] < field[1] + field[3] + group - 0.5:
        bad("screen%d: the status line is less than stack.group under the field" % i)
    if field[3] < control - 0.5:
        bad("screen%d: the field is shorter than size.control.md" % i)
    if abs(field[0] + field[2] / 2 - width / 2) > 1:
        bad("screen%d: the field is off centre" % i)
print("ok")' "$@"; }
standard_values() { local key; for key in size.control.md stack.group stack.row; do ipc smoke themeValue "$key" || return; done; }
alive() { if [[ $1 =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; then echo alive; else echo gone; fi; }
# Release the core's lock with the probe and read the session unlocked.
release() { # LABEL
  expect "$1: the probe releases the lock" ok ipc smoke sessionUnlock
  expect_poll "$1: the session is unlocked" unlocked session_lock
  expect_poll "$1: the core holds no lock" false core_requested
}
# Set vgs.lock's setting KEY in shell.json, or drop it for null.
set_setting() { # KEY VALUE
  python3 - "$lock_user_config" "$1" "$2" <<'PY'
import json, os, sys
path, key, value = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
config = json.load(open(path))
rows = config.setdefault("plugins", [])
row = next((r for r in rows if r.get("id") == "vgs.lock"), None)
if row is None:
    row = {"id": "vgs.lock"}
    rows.append(row)
if value is None:
    row.pop(key, None)
else:
    row[key] = value
with open(path + ".tmp", "w") as out:
    json.dump(config, out)
os.replace(path + ".tmp", path)
PY
}
restore_lock_hypr_lua() { { printf '%s\n' "pcall(dofile, \"$home/.local/state/vgs/hypr/vgs.lua\")"; cat -- "$sandbox/hyprland-harness.lua"; } >"$lock_hypr_lua.next" && mv -T -- "$lock_hypr_lua.next" "$lock_hypr_lua"; }
# The session lock sampler: session_lock appended to FILE every 100 ms
# until FILE.stop exists, for 60 s at most, so a row that fails before it
# stops the sampler leaves no reader behind. samples_read FILE:
# `never-unlocked` when every sample, three at least, read locked; else
# the first other reading and the count of samples.
sampler_start() { # FILE
  rm -f -- "$1" "$1.stop"
  (
    for _ in $(seq 1 600); do
      [[ -e $1.stop ]] && break
      session_lock >>"$1" 2>/dev/null || echo unreadable >>"$1"
      sleep 0.1
    done
  ) &
  sampler_pid=$!
}
sampler_stop() { : >"$1.stop"; wait "$sampler_pid" 2>/dev/null || :; } # FILE
samples_read() { # FILE
  local other count
  count="$(wc -l <"$1")" || return
  other="$(grep -v -x -m 1 locked -- "$1" || :)"
  if [[ -n $other ]]; then echo "$other samples=$count"
  elif ((count < 3)); then echo "too-few samples=$count"
  else echo never-unlocked; fi
}
# The ceiling on the time from a SIGKILL to the shell while locked to the
# relaunched shell's confirmed lock with its lock screen, read from the
# core's lending record every 50 ms, so the reading carries at most one
# poll. It holds the runner's first delay, 0.5 s, the new shell's start
# and its stranded-lock reading. Twice the highest of six readings of this
# row on host cachy on 2026-09-30, at load average 5 to 8: 1497 to
# 1606 ms.
lock_back_budget_ms=3212
# Kill the shell by its pid while locked; the runner starts the next shell,
# which the row takes up with harness.sh's adopt_shell, and the sampler
# reads the session lock from before the kill until the caller stops it.
# The killed shell's log is checked and kept first: the rows after this one
# read the next shell's.
# relaunch_lines: the runner's relaunch lines in its log, one per line.
# The relaunch count and the delay depend on how long the shell before ran
# (docs/architecture/runtime.md § Process), so a line is read without
# them.
relaunch_lines() { grep -E '^vgsh: shell=exited .* relaunch=' -- "$shell_log" | sed -E 's/ relaunch=[0-9]+ delay=[0-9.]+//' || :; }
relaunch_count() { relaunch_lines | wc -l; }
last_relaunch() { relaunch_lines | tail -n 1; }
kill_and_relaunch() { # LABEL
  local killed="$shell_qs_pid" kept="$sandbox/lock-shell-${#kept_logs[@]}.log" before
  before="$(relaunch_count)"
  check_unexpected_log "$1: the shell's log before the kill" "$instance_log"
  no_checks "$1: before the kill"
  cp -- "$instance_log" "$kept" || fail "$1: keeping the shell's log failed"
  kept_logs+=("$kept")
  sampler_start "$sandbox/lock-samples"
  sleep 0.2
  killed_ms="$(now_ms)"
  kill -KILL "$killed" || fail "$1: SIGKILL to the shell pid $killed failed"
  expect_poll "$1: the killed shell is gone" gone alive "$killed"
  if adopt_shell "$killed"; then ok "$1: the runner started the next shell"; fi
  expect "$1: the runner logged one relaunch for the kill" $((before + 1)) relaunch_count
  expect "$1: the runner read the session locked before the relaunch" "vgsh: shell=exited status=137 session=locked" last_relaunch
}
# The time from the kill to the core's confirmed lock with the plugin's
# lock screen, polled every 50 ms for up to 20 s; `none` past that.
lock_back_ms() {
  for _ in $(seq 1 400); do
    [[ $(core_lock 2>/dev/null) == '[true, true, true]' ]] && { echo $(( $(now_ms) - killed_ms )); return; }
    sleep 0.05
  done
  echo none
}

# The before-sleep stand-ins, ahead of the host's commands on the shell's PATH.
cat >"$shim/systemd-inhibit" <<SH
#!/usr/bin/env bash
set -o pipefail
while [[ \${1:-} == --* ]]; do shift; done
"\$@" | tee -a $(printf %q "$sleep_log")
SH
printf '#!/bin/sh\ncase "$5" in PreparingForSleep) echo "b false" ;; *) echo "t 5000000" ;; esac\n' >"$shim/busctl"
cat >"$shim/dbus-monitor" <<SH
#!/usr/bin/env bash
echo 'signal sender=org.freedesktop.DBus -> destination=:1.9 serial=2 path=/org/freedesktop/DBus; interface=org.freedesktop.DBus; member=NameAcquired'
until [[ -e $(printf %q "$sleep_trigger") ]]; do sleep 0.1; done
rm -f -- $(printf %q "$sleep_trigger")
echo '   boolean true'
exec sleep 600
SH
chmod 755 "$shim/systemd-inhibit" "$shim/busctl" "$shim/dbus-monitor"
rm -f -- "${sleep_log:?}" "${sleep_trigger:?}"

expect "the session is unlocked before the row" unlocked session_lock
auth_watch_start "$sandbox/lock-auth-helpers.log"
expect "the helper watcher scans the tree that holds the shell" yes in_harness_tree "$shell_qs_pid"
# The watcher's stand-in: a copy of sleep named unix_chkpwd, run by the
# harness, never PAM's.
mkdir -p -- "$sandbox/stand-in"
cp -- "$(command -v sleep)" "$sandbox/stand-in/unix_chkpwd"
sleep 0.2
"$sandbox/stand-in/unix_chkpwd" 0.3 &
standin_pid=$!
wait "$standin_pid" || fail "the stand-in unix_chkpwd failed"
expect_poll "control: the watcher recorded the stand-in unix_chkpwd" "unix_chkpwd $standin_pid" cat -- "$sandbox/lock-auth-helpers.log"
expect "the Hyprland layer lets a new client take over a dead lock" '{"bool": true}' restore_option
expect "the lock plugin starts disabled in the sandbox" False plugin_enabled vgs.lock
probe_enabled="$(plugin_enabled acme.probe)" || probe_enabled=unreadable
case "$probe_enabled" in
  True) expect "disabling the capability fixture, which holds lock, is allowed" ok ipc shell setPluginEnabled acme.probe false ;;
  False|absent) ;;
  *) fail "the capability fixture's enabled state is unreadable: $probe_enabled" ;;
esac
expect "enabling the lock plugin is allowed" ok ipc shell setPluginEnabled vgs.lock true
expect_poll "the lock service registered its shortcut, IPC target and idle watch" '[["vgs.lock:lock"], ["vgs.lock"], [["vgs.lock", 300]]]' lock_lent
expect_poll "the nested instance binds SUPER+L to the lock" '[[64, "L", "vgs.lock:lock"]]' lock_binds
expect_poll "the before-sleep hook holds" ok sleep_status
expect "the hook read logind's delay" "ready budget_ms=4000" head -n 1 -- "$sleep_log"
expect "the lock read no stranded lock at start" '[false, true]' lock_status locked strandedDone

# The IPC lock, and `vgsh lock` while locked.
expect "the IPC lock answers ok" ok ipc vgs.lock invoke lock ''
expect_poll "the compositor reports the session locked" locked session_lock
expect_poll "the core holds the confirmed lock with the plugin's lock screen" '[true, true, true]' core_lock
mapfile -t standard < <(standard_values) || :
if [[ ${#standard[@]} -eq 3 ]]; then
  lock_geometry() { lock_screens | lock_geometry_check "${standard[@]}"; }
  expect_poll "the lock screen holds the design standard's geometry" ok lock_geometry
  planted='[{"width": 1000, "height": 800, "parts": {"time": [400, 300, 200, 40], "date": [400, 344, 200, 24], "field": [400, 370, 200, 32], "status": [400, 414, 200, 20]}}]'
  got="$(lock_geometry_check "${standard[@]}" <<<"$planted")" || got=unreadable
  if [[ $got == ok ]]; then fail "control: a planted field stack.group short of the date passed the geometry reading"; else ok "control: a planted field too close to the date fails the geometry reading ($got)"; fi
else
  fail "the standard's values are unreadable: ${standard[*]}"
fi
expect "vgsh lock while locked answers ok" ok "${shell_env[@]}" "$repo/bin/vgsh" lock
expect "the session stays locked" locked session_lock
release "the IPC lock"

# SUPER+L on the nested seat. wtype's keys resolve a bind by keysym only
# (docs/architecture/runtime-hyprland.md), so the row turns that on.
printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = true } })' >>"$lock_hypr_lua"
expect "the nested instance reloads with binds resolved by keysym" ok hypr reload config-only
type_keys -M logo -k l -m logo || fail "typing SUPER+L failed"
expect_poll "SUPER+L locked the session" locked session_lock
release "the SUPER+L lock"
restore_lock_hypr_lua || fail "hyprland.lua is put back after SUPER+L"
expect "the nested instance reloads the first run's hyprland.lua" ok hypr reload config-only

# The before-sleep hook: logind's PrepareForSleep locks, and the hook lets
# go once the lock is confirmed.
: >"$sleep_trigger"
expect_poll "a sleep locked the session" locked session_lock
expect_poll "the hook let the sleep go once the lock was confirmed" "released reason=secure" bash -c 'grep -x "released reason=secure" -- "$1" || :' _ "$sleep_log"
expect "the hook announced the sleep with its budget" "sleep budget_ms=4000" bash -c 'grep -x "sleep budget_ms=[0-9]*" -- "$1" || :' _ "$sleep_log"
release "the sleep lock"
expect_poll "the hook is taken again after the sleep" 2 bash -c 'grep -c -x "ready budget_ms=4000" -- "$1" || :' _ "$sleep_log"
expect "the last sleep is published as locked" '["ok", "The session was locked before the last suspend"]' status_value lastSleep

# A second lock client, the harness's lock-client, holds the session. It
# runs no authentication and is stopped by its pid. With the VGS layer's
# misc:allow_session_lock_restore on, Hyprland lets the plugin's lock
# replace the client's and tells the client nothing; the client's unlock
# then unlocks the session under the plugin's confirmed lock, and the
# core's reading of Hyprland ends that lock as the compositor's.
expected_errors+=('capabilities: lock=ended-by-compositor')
# Wait up to 12 s for CMD to print WANT, and fail nothing: the expect that
# follows reads it. The core reads Hyprland every 2 s and ends a lock on
# the second unlocked reading.
settle() { # WANT CMD...
  local want="$1"; shift
  for _ in $(seq 1 60); do [[ $("$@" 2>/dev/null) == "$want" ]] && return 0; sleep 0.2; done
}
# spawn truncates the client's log, so each start reads its own lines.
start_lock_client() { # LABEL
  spawn "$sandbox/lock-client.log" "${shell_env[@]}" "$sandbox/lock-client"
  client_pid="$spawn_pid"
  expect_poll "$1: the second lock client holds the session" locked client_said "$sandbox/lock-client.log" locked
  expect "$1: the session is locked by the other client" locked session_lock
}
stop_lock_client() { # LABEL
  kill -TERM "$client_pid" || fail "$1: SIGTERM to the lock client pid $client_pid failed"
  expect_poll "$1: the other client let the session go" unlocked client_said "$sandbox/lock-client.log" unlocked
}
start_lock_client "takeover"
expect "takeover: vgsh lock takes the lock over" "ok exit=0" vgsh_lock
expect_poll "takeover: the core holds the confirmed lock" '[true, true, true]' core_lock
# Control for the sampler: across the other client's unlock it reads the
# session unlocked.
sampler_start "$sandbox/lock-samples-control"
stop_lock_client "takeover"
settle '[false, false, true]' core_lock
sampler_stop "$sandbox/lock-samples-control"
got="$(samples_read "$sandbox/lock-samples-control")" || got=unreadable
if [[ $got == unlocked\ samples=* ]]; then ok "control: the sampler reads the unlock the other client made ($got)"; else fail "control: the sampler across the other client's unlock read $got"; fi
expect "takeover: the core ended the lock the other client's unlock released" '[false, false, true]' core_lock
expect "takeover: the session is unlocked" unlocked session_lock
expect_poll "takeover: the plugin counted the end" '[1, false, false]' lock_status refusals locked secure
expect "takeover: the lock status warns of it" '["warning", "Hyprland refused or ended the last lock: another lock screen may hold the session"]' status_value lock
expect "takeover: vgsh lock locks again" "ok exit=0" vgsh_lock
expect_poll "takeover: the core holds the confirmed lock again" '[true, true, true]' core_lock
expect "takeover: the lock status is ready again" '["ok", "Ready"]' status_value lock
release "the lock after the takeover"

# A sleep whose budget runs out before the lock is confirmed: logind's delay
# reads 1 s, so the hook's budget is 1 ms. The hook lets the sleep go as
# timed out, the plugin publishes it, and the user sees the toast once back
# at the desktop, not over the lock screen.
expected_errors+=('lock: sleep=unlocked reason=timeout')
retake_hook() { # LABEL
  set_setting lockBeforeSleep false
  expect_poll "$1: turning the setting off publishes the hook off" info sleep_status
  set_setting lockBeforeSleep null
  expect_poll "$1: the hook holds again" ok sleep_status
}
printf '#!/bin/sh\ncase "$5" in PreparingForSleep) echo "b false" ;; *) echo "t 1000000" ;; esac\n' >"$shim/busctl"
retake_hook "a 1 s delay"
expect_poll "timeout: the hook read the short delay" "ready budget_ms=1" tail -n 1 -- "$sleep_log"
: >"$sleep_trigger"
expect_poll "timeout: the hook let the sleep go on its budget" "released reason=timeout" bash -c 'grep -x "released reason=timeout" -- "$1" || :' _ "$sleep_log"
expect_poll "timeout: the sleep still locked the session" locked session_lock
expect_poll "timeout: the last sleep is published as unconfirmed" '["danger", "The last suspend went ahead before the lock was confirmed"]' status_value lastSleep
expect "timeout: no toast shows over the lock screen" '[]' lock_toasts
release "the timed-out sleep lock"
expect_poll "timeout: the user is told once back at the desktop" '[["The session was not locked before sleep", "danger"]]' lock_toasts
printf '#!/bin/sh\ncase "$5" in PreparingForSleep) echo "b false" ;; *) echo "t 5000000" ;; esac\n' >"$shim/busctl"
retake_hook "logind's default delay"
expect_poll "the hook read logind's default delay again" "ready budget_ms=4000" tail -n 1 -- "$sleep_log"

# A hook that cannot start, here a systemd-inhibit whose interpreter does
# not exist, is published as such, and turning the setting back on takes it
# again at once.
mv -- "$shim/systemd-inhibit" "$sandbox/systemd-inhibit.good"
set_setting lockBeforeSleep false
expect_poll "turning the setting off publishes the hook off" info sleep_status
printf '#!/nonexistent/interpreter\n' >"$shim/systemd-inhibit"
chmod 755 "$shim/systemd-inhibit"
set_setting lockBeforeSleep null
expect_poll "a hook that cannot start is published as such" '["warning", "Unavailable: the sleep hook could not start; the session is not locked before sleep"]' status_value sleep
mv -- "$sandbox/systemd-inhibit.good" "$shim/systemd-inhibit"
set_setting lockBeforeSleep false
expect_poll "the setting off again" info sleep_status
set_setting lockBeforeSleep null
expect_poll "the hook holds again once it can start" ok sleep_status

# The idle watch: two seconds with no input lock the session. The setting
# goes back before any key, which would start the next idle period.
set_setting idleLockSeconds 2
expect_poll "the idle watch follows the setting" '[["vgs.lock:lock"], ["vgs.lock"], [["vgs.lock", 2]]]' lock_lent
expect_poll "two seconds without input locked the session" locked session_lock
set_setting idleLockSeconds null
expect_poll "the idle watch is back at its default" '[["vgs.lock:lock"], ["vgs.lock"], [["vgs.lock", 300]]]' lock_lent
release "the idle lock"

# Disabling the plugin while locked keeps the session locked; the rebuilt
# plugin hands its lock screen over again.
no_checks "before the disable"
expect "the IPC lock answers ok before the disable" ok ipc vgs.lock invoke lock ''
expect_poll "the session is locked before the disable" '[true, true, true]' core_lock
expect "disabling the lock plugin while locked is allowed" ok ipc shell setPluginEnabled vgs.lock false
expect_poll "the disabled plugin's lock screen is gone and the lock stays" '[true, true, false]' core_lock
expect "the session stays locked with the plugin disabled" locked session_lock
expect "enabling the lock plugin again is allowed" ok ipc shell setPluginEnabled vgs.lock true
expect_poll "the rebuilt plugin hands its lock screen over again" '[true, true, true]' core_lock
release "the lock across a disable"

# Control: a copy whose IPC lock starts one stand-in check, with PAM's
# start taken out so no PAM runs. Its log line is in the first shell's log,
# which the two restarts below leave behind, and the row's last reading
# must still count it.
no_checks "before the stand-in check"
control_dir="$home/.config/vgs/plugins/vgs.lock"
mkdir -p -- "$control_dir"
cp -R -- "$repo/shell/plugins/vgs.lock/." "$control_dir/"
python3 - "$control_dir/Service.qml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
edits = [
    ('shell.ipc.handle("lock", () => root.lock());', 'shell.ipc.handle("lock", () => { const reply = root.lock(); root.submit("stand-in"); return reply; });'),
    ("        if (!pam.start()) fail();", "        fail();"),
]
for needle, replacement in edits:
    assert text.count(needle) == 1, "stand-in control: must match once: " + needle
    text = text.replace(needle, replacement)
open(path, "w").write(text)
PY
expected_errors+=('plugins: .*vgs\.lock')
lock_dir_of() { ipc shell listPlugins | py_reply 'import json,sys; print([p["dir"] for p in json.load(sys.stdin)["plugins"] if p["id"] == "vgs.lock"][0])'; }
expect "rescan over the stand-in copy answers ok" ok ipc shell rescanPlugins
expect_poll "the stand-in copy is the plugin the shell runs" "$control_dir" lock_dir_of
expect "the stand-in copy's IPC lock answers ok" ok ipc vgs.lock invoke lock ''
expect_poll "control: the stand-in copy started one check" '[1, 1]' lock_status checks failures
expect_poll "control: the shell's log holds the stand-in check" 1 check_starts
release "the stand-in check"
rm -r -- "${control_dir:?}"
expect "rescan after removing the stand-in copy answers ok" ok ipc shell rescanPlugins
expect_poll "the shipped plugin runs again after the stand-in" "$repo/shell/plugins/vgs.lock" lock_dir_of
expect_poll "the rebuilt shipped plugin holds its sleep hook again" ok sleep_status

# Control: a copy that never locks a stranded session. After the kill and
# the restart the session is still locked, and the core holds no lock.
mkdir -p -- "$control_dir"
cp -R -- "$repo/shell/plugins/vgs.lock/." "$control_dir/"
python3 - "$control_dir/Service.qml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = '                root.lock();\n            }\n        }\n    }\n\n    Timer {\n        id: strandedRetry'
assert text.count(needle) == 1, "lock control: the stranded lock call must match once"
open(path, "w").write(text.replace(needle, '            }\n        }\n    }\n\n    Timer {\n        id: strandedRetry', 1))
PY
expect "rescan over the control copy answers ok" ok ipc shell rescanPlugins
expect_poll "the control copy is the plugin the shell runs" "$control_dir" lock_dir_of
expect "the control's IPC lock answers ok" ok ipc vgs.lock invoke lock ''
expect_poll "the control's session is locked" '[true, true, true]' core_lock
kill_and_relaunch "the control"
expect_poll "the control's relaunched lock read the stranded lock" '[false, true]' lock_status locked strandedDone
sampler_stop "$sandbox/lock-samples"
expect "the control's session never read unlocked across the kill" never-unlocked samples_read "$sandbox/lock-samples"
got="$(core_lock)" || got=unreadable
if [[ $got == '[false, false, false]' && $(session_lock) == locked ]]; then ok "control: a copy that never takes a stranded lock over leaves the core without it"; else fail "control: the takeover reading got core=$got over a copy that never takes the lock over"; fi
expect "the probe takes the stranded lock over" ok ipc smoke sessionLockBare
expect_poll "the probe's lock is confirmed" '[true, true, false]' core_lock
release "the control"
rm -r -- "$control_dir"
expect "rescan after removing the control copy answers ok" ok ipc shell rescanPlugins
expect_poll "the shipped plugin runs again" "$repo/shell/plugins/vgs.lock" lock_dir_of

# The shell dies while locked: the session stays locked, and the next
# shell's lock plugin takes the stranded lock over with its lock screen.
expect "the IPC lock answers ok before the kill" ok ipc vgs.lock invoke lock ''
expect_poll "the session is locked before the kill" '[true, true, true]' core_lock
kill_and_relaunch "the kill"
lock_back="$(lock_back_ms)"
sampler_stop "$sandbox/lock-samples"
echo "  latency_lock_back_ms=$lock_back budget_ms=$lock_back_budget_ms"
if [[ $lock_back =~ ^[0-9]+$ && $lock_back -le $lock_back_budget_ms ]]; then ok "the relaunched shell took the stranded lock over within its budget"; else fail "lock back after the kill: $lock_back ms, budget $lock_back_budget_ms ms"; fi
echo "  lock samples=$(wc -l <"$sandbox/lock-samples")"
expect "the session never read unlocked from before the kill to the relaunched lock" never-unlocked samples_read "$sandbox/lock-samples"
expect "the session is still locked" locked session_lock
release "the taken-over lock"

no_checks "the row's end"
expect "no authentication helper runs under the shell" none auth_helpers "$shell_qs_pid"
expect "over the whole row, every shell log holds the stand-in check alone" 1 check_starts
kill "$auth_watch_pid" 2>/dev/null || fail "stopping the helper watcher pid $auth_watch_pid failed"
expect "over the whole row, the watcher saw the stand-in unix_chkpwd alone" "unix_chkpwd $standin_pid" cat -- "$sandbox/lock-auth-helpers.log"
expect "disabling the lock plugin is allowed" ok ipc shell setPluginEnabled vgs.lock false
expect_poll "disable released the lock's shortcut, IPC target and idle watch" '[[], [], []]' lock_lent
expect_poll "the nested instance drops the lock's bind" '[]' lock_binds
rm -f -- "$shim/systemd-inhibit" "$shim/busctl" "$shim/dbus-monitor" "$sandbox/stand-in/unix_chkpwd"
expect "hyprland.lua is as the first run left it" same bash -c 'cmp -s <(sed 1d "$1") "$2" && echo same || echo differs' _ "$lock_hypr_lua" "$sandbox/hyprland-harness.lua"
if [[ $probe_enabled == True ]]; then
  expect "re-enabling the capability fixture is allowed" ok ipc shell setPluginEnabled acme.probe true
fi
