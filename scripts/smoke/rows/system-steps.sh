# System steps, D081, over the sandbox's device fakes
# (docs/architecture/validation-smoke-devices.md). bin/vgsh-system pins its
# PATH to the system directories and derives every path from its
# `prefix=` line, so before the fixture is enabled devices_system_tree
# rewrites the sandbox copy's line to the fakes' tree. That tree's sys and
# dev are links to the fakes' sysfs and device trees, whose HID fake plants
# a Pro Display XDR as hidraw0 beside two Studio Displays; the row closes
# hidraw0 to the user and gives its mode back at the end. Its udevadm,
# systemctl and gum are links to
# the fakes' stand-ins, answering from device_reply; for the trigger
# the row stands over the udevadm stand-in with a script that opens the
# node while the VGS rule exists and then runs the stand-in, which
# records the call. The rest of the tree is not a device: the records,
# the rules directory, a boot id, coreutils, the bash the stand-ins start
# under, since the step resolves every command in this tree alone, a stat
# that reports the user's own files as root's as they read under the
# stand-in sudo's unshare -r, and as sudo a copy of the harness's sudo
# sentinel, which logs to the one authentication log and runs nothing. No probe or command
# reaches the host's /dev, /sys, systemctl, tailscale or sudo.
#
# The fixture acme.system declares the apple-displays step and publishes
# its state as status. Rows: the core probes once the fixture holds
# `system` and lends the declared step alone; the step reads needed and
# offers Allow; Allow, through the manager's act, hands the stand-in
# terminal `vgsh system apply apple-displays` as the core TUI core/system;
# while that run is held, the row runs the same command on a terminal
# over a sudo stand-in it stands over the tree's sentinel with
# sentinel_stand_over, puts the sentinel back with sentinel_restore, and
# reads the state still needed, since the core probes on its own only when
# a run ends; the run's end then flips the state to ready, the action is no
# longer offered and the manager refuses it. With the node closed again,
# the step reads ready until a plugin scan ends, then needed. The refusals
# are the row's controls: a disabled fixture's act and a ready step's act
# are refused and start no terminal, and the readings before the run's end
# and before the scan show each flip is that re-probe's. The fixture's own
# Allow then goes through `status.act`, scoped to the calling plugin: the
# same step opens core/system, and an act on the status fixture's `token`
# reads undeclared and starts no terminal, its control.
# rows/auth-sentinel.sh, the last row, reads the log empty. Every reading
# is expect_poll's: 25 reads 0.2 s apart.
set -euo pipefail
devices_ready system-steps || return 0
if ! command -v unshare >/dev/null 2>&1 || ! unshare -r true 2>/dev/null; then
  not_measured system-steps missing=user-namespaces
  return 0
fi
command -v script >/dev/null 2>&1 || { fail "system steps: script(1) is missing"; return 0; }
system_root="$devices_system_root"
system_bin="$system_root/usr/bin"
system_hidraw="$devices_dev_root/hidraw0"
system_rule="$system_root/etc/udev/rules.d/60-vgs-apple-displays.rules"
system_calls="$sandbox/system-sudo.calls"
system_question="Run these commands as root?"
expect "the sandbox copy's system steps resolve in the fakes' tree" prefixed devices_system_tree
system_hidraw_mode="$(stat -c %a -- "$system_hidraw")" || { fail "system steps: the HID fake planted no hidraw0"; return 0; }
chmod 0000 "$system_hidraw"
printf '#!/bin/sh\nout="$(%q "$@")" || exit $?\nprintf "%%s\\n" "$out" | sed "s/^%s /0 /"\n' "$(command -v stat)" "$(id -u)" >"$system_bin/stat"
chmod 755 "$system_bin/stat"
cp -- "$shim/sudo" "$system_bin/sudo"
for unit in bluetooth.service tailscaled.service; do
  device_reply systemctl 3 "" is-active --quiet "$unit"
  device_reply systemctl 0 not-found show --property=LoadState --value "$unit"
done
device_reply gum 0 "" confirm -- "$system_question"
device_reply udevadm 0 "" control --reload
device_reply udevadm 0 "" trigger --subsystem-match=hidraw --action=change --settle
sentinel_of() { if grep -q -F -- "$auth_log" "$1"; then echo sentinel; else echo replaced; fi; }
expect "the tree's sudo is the harness's sentinel" sentinel sentinel_of "$system_bin/sudo"

system_dir="$home/.config/vgs/plugins/acme.system"
mkdir -p "$system_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.system/." "$system_dir/"
system_core() { ipc shell lent | py_reply 'import json,sys; s=json.load(sys.stdin)["system"]["steps"]["apple-displays"]; print(s["state"] + " " + s["reason"])'; }
system_holders() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["holders"].get("system", [])))'; }
system_lent() { ipc smoke readInstance service acme.system systemState | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))'; }
system_status() { ipc smoke readInstance service acme.system statusValues 2>/dev/null | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }

expect "rescan after adding the system fixture answers ok" ok ipc shell rescanPlugins
expect_poll "the system fixture is discovered" True plugin_known acme.system
expect "enabling the system fixture is allowed" ok ipc shell setPluginEnabled acme.system true
expect_poll "the system fixture's service is built" True record_exists acme.system
expect_poll "the fixture holds the system capability" '["acme.system"]' system_holders
expect_poll "the core probes the tree once a plugin holds system" "needed hidraw-denied" system_core
expect_poll "the capability lends the declared step alone" '{"apple-displays": {"reason": "hidraw-denied", "state": "needed"}}' system_lent

terminal_stand_in
terminal_ready "system steps"
settings_page_open acme.system
expect_poll "a needed step offers Allow" '[["apple", "Allow", true]]' offered_actions acme.system
hold_runs
forget_record
expect "Allow, through the manager's act, answers ok" ok settings_act acme.system apple
expect_poll "Allow hands the terminal vgsh system apply with its step" \
  "$(core_words core/system "System setup" org.vgs.tui system apply apple-displays)" recorded

# The command the TUI runs, on a terminal, over the row's sudo stand-in.
# The stand-ins' records are the run's, so the row reads its own calls
# from the counts before its apply.
system_calls_since() { device_calls "$1" | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)[int(sys.argv[1]):]))' "$2"; }
system_call_count() { device_calls "$1" | py_reply 'import json,sys; print(len(json.load(sys.stdin)))'; }
system_gum_before="$(system_call_count gum)" || { fail "system steps: the gum stand-in's calls are unreadable"; return 0; }
system_udevadm_before="$(system_call_count udevadm)" || { fail "system steps: the udevadm stand-in's calls are unreadable"; return 0; }
: >"$system_calls"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%q\ncase "$1" in -k|-n) exit 0 ;; esac\n[ "$1" = -- ] && shift\nexec %q -r "$@"\n' \
  "$system_calls" "$(command -v unshare)" | sentinel_stand_over "$system_bin/sudo"
expect "the tree's sudo is the row's stand-in" replaced sentinel_of "$system_bin/sudo"
printf '#!/bin/sh\nif [ "$1" = trigger ] && [ -e %q ]; then chmod 0600 %q; fi\nexec %q "$@"\n' \
  "$system_rule" "$system_hidraw" "$(sentinel_saved "$shim/udevadm")" | sentinel_stand_over "$shim/udevadm"
system_apply() {
  local status=0
  "${sandbox_env[@]}" "${shell_start_words[@]}" SHELL="$BASH" script -qec "$(printf '%q ' "$repo/bin/vgsh" system apply apple-displays)" /dev/null \
    </dev/null >"$sandbox/system-apply.out" 2>&1 || status=$?
  tr -d '\r' <"$sandbox/system-apply.out" | tail -n 1
  return "$status"
}
expect "the step's command applies it" "ok system=apple-displays state=ready" system_apply
expect "the stand-in ran the rule's install as root" 1 grep -c -F -- "-- $system_bin/install -m 0644 -o root -g root -T -- $repo/config/system/udev/60-vgs-apple-displays.rules $system_rule" "$system_calls"
sentinel_restore "$system_bin/sudo"
sentinel_restore "$shim/udevadm"
expect "the tree's sudo is the sentinel again" sentinel sentinel_of "$system_bin/sudo"
expect "the step asked its one question through the gum stand-in" "[[\"confirm\", \"--\", \"$system_question\"]]" system_calls_since gum "$system_gum_before"
expect "the udevadm stand-in reloaded the rules, then triggered hidraw" \
  '[["control", "--reload"], ["trigger", "--subsystem-match=hidraw", "--action=change", "--settle"]]' system_calls_since udevadm "$system_udevadm_before"
expect "the core reads the step needed until the run ends" "needed hidraw-denied" system_core
release_runs
expect_run_end "the core/system run ends" core/system
expect_poll "the run's end probes again and the step reads ready" "ready granted" system_core
expect_poll "the fixture publishes the ready step" '{"apple": {"tone": "ok", "text": "ready granted", "action": false}}' system_status
expect_poll "a ready step offers no Allow" '[["apple", "Allow", false]]' offered_actions acme.system
expected_errors+=('settings: acme\.system/apple refused: action=apple reason=(not-offered|disabled)')
forget_record
expect "the manager refuses Allow once the step is ready" "refused: action=apple reason=not-offered" settings_act acme.system apple
expect "the refused ready act started no terminal" absent recorded
chmod 0000 "$system_hidraw"
expect "the core reads the step ready until a scan ends" "ready granted" system_core
expect "a rescan with the node closed again answers ok" ok ipc shell rescanPlugins
expect_poll "a plugin scan's end probes again and the step reads needed" "needed hidraw-denied" system_core
# The plugin's own Allow, as a section's pane presses it: `status.act`
# judges the key against the calling plugin's manifest alone, so the
# status fixture's `token`, an action of another plugin, is undeclared.
system_act() { ipc smoke invokeInstance service acme.system statusAct "$1"; }
forget_record
expect "the fixture's act on another plugin's key is refused" "refused: action=token reason=undeclared" system_act token
expect "the refused act on another plugin's key started no terminal" absent recorded
expect_poll "the needed step offers the fixture's own Allow again" '{"apple": {"tone": "warning", "text": "needed hidraw-denied", "action": true}}' system_status
hold_runs
expect "the fixture's own Allow, through status.act, answers ok" ok system_act apple
expect_poll "status.act hands the terminal vgsh system apply with its step" \
  "$(core_words core/system "System setup" org.vgs.tui system apply apple-displays)" recorded
release_runs
expect_run_end "the status.act core/system run ends" core/system
forget_record
expect "disabling the system fixture is allowed" ok ipc shell setPluginEnabled acme.system false
expect_poll "no plugin holds system once the fixture is disabled" '[]' system_holders
expect "the manager refuses Allow while the fixture is disabled" "refused: action=apple reason=disabled" settings_act acme.system apple
expect "the refused disabled act started no terminal" absent recorded
settings_page_close acme.system
chmod "$system_hidraw_mode" "$system_hidraw"
device_reply_clear systemctl
device_reply_clear gum
device_reply_clear udevadm
