# The lock, vgs.lock: a first-party service on the core's `lock`
# capability. The harness starts it disabled; this row enables it and locks
# the nested session through each entry point: its IPC function, `vgsh
# lock`, SUPER+L on the nested seat, its idle watch and its before-sleep
# hook. Each lock is read back from the compositor, a monitor naming LOCK
# among the reasons it cannot go solitary in `hyprctl -j monitors`, and
# from the core's lending record. Disabling the plugin while locked keeps
# the session locked, and the rebuilt plugin hands its lock screen over
# again. The shell killed by its pid while locked leaves the session
# locked, and the next shell's lock plugin reads the stranded lock and takes
# it over through the layer's `misc.allow_session_lock_restore`.
#
# No row types a password: PAM would check it against the real account,
# whose pam_faillock counts each failure. The sandbox's own probe releases
# the core's lock with no password, test code that never ships
# (docs/architecture/lock-polkit.md § Validation), and the plugin's status
# shows it never started a PAM conversation.
#
# The before-sleep hook runs under stand-ins in the shell's stand-in
# directory: a systemd-inhibit that runs its command with no inhibitor and
# logs the command's lines, a busctl that answers logind's 5 s default and a
# dbus-monitor that announces one PrepareForSleep once the row creates its
# trigger file. The sandbox's system bus holds no logind.
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
session_lock() { hypr -j monitors | python3 -c 'import json,sys; print("locked" if any("LOCK" in (m.get("solitaryBlockedBy") or []) for m in json.load(sys.stdin)) else "unlocked")'; }
# The core's lock as [requested, secure, content].
core_requested() { ipc shell lent | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["lock"]["requested"]))'; }
core_lock() { ipc shell lent | python3 -c 'import json,sys; l=json.load(sys.stdin)["lock"]; print(json.dumps([l["requested"], l["secure"], l["content"]]))'; }
lock_status() { ipc vgs.lock invoke status '' | py_reply 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d[k] for k in sys.argv[1:]]))' "$@"; }
sleep_status() { ipc smoke statusValues vgs.lock | py_reply 'import json,sys; v=json.load(sys.stdin).get("sleep"); print(v["tone"] if v else "unpublished")'; }
lock_binds() { hypr -j binds | python3 -c 'import json,sys; print(json.dumps(sorted([b["modmask"], b["key"], b["description"]] for b in json.load(sys.stdin) if b["description"].startswith("vgs.lock"))))'; }
lock_lent() { ipc shell lent | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([[s for s in d["shortcuts"] if s.startswith("vgs.lock")], [t for t in d["ipcTargets"] if t == "vgs.lock"], [[w["id"], w["timeout"]] for w in d["idle"] if w["id"] == "vgs.lock"]]))'; }
restore_option() { hypr -j getoption misc:allow_session_lock_restore | python3 -c 'import json,sys; v=json.load(sys.stdin); print(json.dumps({k: v[k] for k in v if k not in ("option", "set")}))'; }
alive() { if [[ $1 =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; then echo alive; else echo gone; fi; }
# Release the core's lock with the probe and read the session unlocked.
release() { # LABEL
  expect "$1: the probe releases the lock" ok ipc smoke sessionUnlock
  expect_poll "$1: the session is unlocked" unlocked session_lock
  expect_poll "$1: the core holds no lock" false core_requested
}
# Set vgs.lock's idleLockSeconds in shell.json, or drop it for null.
set_idle() {
  python3 - "$lock_user_config" "$1" <<'PY'
import json, os, sys
path, value = sys.argv[1], json.loads(sys.argv[2])
config = json.load(open(path))
rows = config.setdefault("plugins", [])
row = next((r for r in rows if r.get("id") == "vgs.lock"), None)
if row is None:
    row = {"id": "vgs.lock"}
    rows.append(row)
if value is None:
    row.pop("idleLockSeconds", None)
else:
    row["idleLockSeconds"] = value
with open(path + ".tmp", "w") as out:
    json.dump(config, out)
os.replace(path + ".tmp", path)
PY
}
restore_lock_hypr_lua() { { printf '%s\n' "pcall(dofile, \"$home/.local/state/vgs/hypr/vgs.lua\")"; cat -- "$sandbox/hyprland-harness.lua"; } >"$lock_hypr_lua.next" && mv -T -- "$lock_hypr_lua.next" "$lock_hypr_lua"; }
# Kill the shell by its pid while locked, check the session stays locked,
# and start the next shell. The killed shell's log is checked first: the
# rows after this one read the next shell's.
kill_and_restart() { # LABEL LOG
  local killed="$shell_qs_pid"
  check_unexpected_log "$1: the shell's log before the kill" "$instance_log"
  kill -KILL "$killed" || fail "$1: SIGKILL to the shell pid $killed failed"
  expect_poll "$1: the killed shell is gone" gone alive "$killed"
  stop_shell || :
  expect "$1: the session stays locked after the shell died" locked session_lock
  start_shell "$repo" "$2"
}

# The before-sleep stand-ins, ahead of the host's commands on the shell's PATH.
cat >"$shim/systemd-inhibit" <<SH
#!/usr/bin/env bash
set -o pipefail
while [[ \${1:-} == --* ]]; do shift; done
"\$@" | tee -a $(printf %q "$sleep_log")
SH
printf '#!/bin/sh\necho "t 5000000"\n' >"$shim/busctl"
cat >"$shim/dbus-monitor" <<SH
#!/usr/bin/env bash
until [[ -e $(printf %q "$sleep_trigger") ]]; do sleep 0.1; done
rm -f -- $(printf %q "$sleep_trigger")
echo '   boolean true'
exec sleep 600
SH
chmod 755 "$shim/systemd-inhibit" "$shim/busctl" "$shim/dbus-monitor"
rm -f -- "${sleep_log:?}" "${sleep_trigger:?}"

expect "the session is unlocked before the row" unlocked session_lock
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

# The idle watch: two seconds with no input lock the session. The setting
# goes back before any key, which would start the next idle period.
set_idle 2
expect_poll "the idle watch follows the setting" '[["vgs.lock:lock"], ["vgs.lock"], [["vgs.lock", 2]]]' lock_lent
expect_poll "two seconds without input locked the session" locked session_lock
set_idle null
expect_poll "the idle watch is back at its default" '[["vgs.lock:lock"], ["vgs.lock"], [["vgs.lock", 300]]]' lock_lent
release "the idle lock"

# Disabling the plugin while locked keeps the session locked; the rebuilt
# plugin hands its lock screen over again.
expect "the IPC lock answers ok before the disable" ok ipc vgs.lock invoke lock ''
expect_poll "the session is locked before the disable" '[true, true, true]' core_lock
expect "disabling the lock plugin while locked is allowed" ok ipc shell setPluginEnabled vgs.lock false
expect_poll "the disabled plugin's lock screen is gone and the lock stays" '[true, true, false]' core_lock
expect "the session stays locked with the plugin disabled" locked session_lock
expect "enabling the lock plugin again is allowed" ok ipc shell setPluginEnabled vgs.lock true
expect_poll "the rebuilt plugin hands its lock screen over again" '[true, true, true]' core_lock
release "the lock across a disable"

# Control: a copy that never locks a stranded session. After the kill and
# the restart the session is still locked, and the core holds no lock.
control_dir="$home/.config/vgs/plugins/vgs.lock"
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
expected_errors+=('plugins: .*vgs\.lock')
expect "rescan over the control copy answers ok" ok ipc shell rescanPlugins
lock_dir_of() { ipc shell listPlugins | python3 -c 'import json,sys; print([p["dir"] for p in json.load(sys.stdin)["plugins"] if p["id"] == "vgs.lock"][0])'; }
expect_poll "the control copy is the plugin the shell runs" "$control_dir" lock_dir_of
expect "the control's IPC lock answers ok" ok ipc vgs.lock invoke lock ''
expect_poll "the control's session is locked" '[true, true, true]' core_lock
kill_and_restart "the control" "$sandbox/lock-control-qs.log"
expect_poll "the control's restarted lock read the stranded lock" '[false, true]' lock_status locked strandedDone
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
kill_and_restart "the kill" "$sandbox/after-lock-qs.log"
expect_poll "the restarted shell took the stranded lock over" '[true, true, true]' core_lock
expect "the session is still locked" locked session_lock
release "the taken-over lock"

expect "no PAM conversation ran and no attempt failed" '[false, 0]' lock_status checking failures
expect "disabling the lock plugin is allowed" ok ipc shell setPluginEnabled vgs.lock false
expect_poll "disable released the lock's shortcut, IPC target and idle watch" '[[], [], []]' lock_lent
expect_poll "the nested instance drops the lock's bind" '[]' lock_binds
rm -f -- "$shim/systemd-inhibit" "$shim/busctl" "$shim/dbus-monitor"
expect "hyprland.lua is as the first run left it" same bash -c 'cmp -s <(sed 1d "$1") "$2" && echo same || echo differs' _ "$lock_hypr_lua" "$sandbox/hyprland-harness.lua"
if [[ $probe_enabled == True ]]; then
  expect "re-enabling the capability fixture is allowed" ok ipc shell setPluginEnabled acme.probe true
fi
