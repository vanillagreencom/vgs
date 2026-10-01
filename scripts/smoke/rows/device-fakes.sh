# The sandbox's device fakes (scripts/smoke/devices.sh), the base every
# System row builds on. The row starts them, reads the guard over the
# running shell, then reads each fake through the shell as a section
# reads it: the acme.devices fixture lists the BlueZ mock's adapter and
# device, the NetworkManager mock's Wi-Fi device and the private PipeWire's
# null nodes through Quickshell's singletons, and runs rfkill through the
# shell's own PATH. It reads that neither the sandbox PipeWire nor its
# WirePlumber holds a sound or camera node after WirePlumber has loaded
# its profile, that the rfkill block changed
# the stand-in's state file alone, that a stand-in answers only what a row
# planted, and the HID fake's answers. Its controls: each guard rule
# turns red on a process given the shell's environment words with one
# host value after them, as a harness edit that leaked it would hand the
# shell; devices_ready maps a guard leak to not measured and fails an
# unreadable shell pid; the fd reader finds the /dev/null PipeWire holds;
# a stand-in copy that drops its state write leaves the radio unblocked;
# and a host without python-dbusmock reads not measured through
# devices_ready. The host's radios are read before and after the block,
# never written; no edit here could make that reading differ without a
# hardware write, so it has no control. The row leaves the fakes up,
# clears the reply it plants, and leaves the fixture disabled for the
# System rows.
set -euo pipefail
devices_ready device-fakes || return 0

devices_fixture="$home/.config/vgs/plugins/acme.devices"
mkdir -p "$devices_fixture"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.devices/." "$devices_fixture/"
expect "rescan discovers the device reader" ok ipc shell rescanPlugins
expect_poll "the device reader is known" True plugin_known acme.devices
expect "enabling the device reader is allowed" ok ipc shell setPluginEnabled acme.devices true
expect_poll "the device reader is built" True record_exists acme.devices
devices_read() { ipc smoke readInstance service acme.devices "$1"; }
expect_poll "Quickshell's Bluetooth lists the mock's adapter, powered, with its paired, bonded, connected device" \
  '[{"id":"hci0","name":"VGS Smoke","enabled":true,"state":"Enabled","devices":[{"address":"00:1B:66:AA:BB:01","name":"Smoke Headphones","paired":true,"bonded":true,"connected":true}]}]' devices_read adapters
expect_poll "Quickshell's Networking lists the mock's Wi-Fi device and the network it scans" \
  '[{"name":"wlan0","address":"11:22:33:44:55:66","networks":["VGS Smoke Wi-Fi"]}]' devices_read wifi
expect_poll "Quickshell's Pipewire lists the two null sinks and the filter-chain sink" \
  '["vgs-smoke-equalizer","vgs-smoke-headphones","vgs-smoke-speakers"]' devices_read sinks
expect_poll "Quickshell's Pipewire lists the one source" '["vgs-smoke-microphone"]' devices_read sources
expect_poll "WirePlumber's defaults are the speakers and the source" '["vgs-smoke-speakers","vgs-smoke-microphone"]' devices_read defaults
# The private PipeWire and WirePlumber hold no sound or camera node after
# WirePlumber has loaded its profile and monitors.
for name in pipewire wireplumber; do
  expect "the sandbox $name holds no /dev/snd or /dev/video node" '[]' device_fds "${devices_pid[$name]}" '^/dev/(snd/|video)'
done
expect "control: the fd reader finds the /dev/null the sandbox pipewire holds" '["/dev/null"]' device_fds "${devices_pid[pipewire]}" '^/dev/(snd/|video|null$)'
# A member Quickshell reads that the templates lack would log here.
devices_gaps() { log_lines 'missing from property set|Failed to get (devices|all access points|device type)'; }
expect "Quickshell read every member it needs from the mocks" 0 devices_gaps

# rfkill through the shell's PATH: the stand-in's state file changes, the
# host's radios do not.
through_shell() { PATH="$shell_start_path" "$@"; }
host_radios() { cat /sys/class/rfkill/rfkill*/soft /sys/class/rfkill/rfkill*/hard 2>/dev/null | tr '\n' ' ' || true; }
radios_before="$(host_radios)"
expect "the fixture's rfkill block starts" started ipc acme.devices invoke rfkill "block bluetooth"
expect_poll "the fixture's rfkill block exits 0" '[["block","bluetooth"],0]' devices_read rfkillRun
expect "the block set the stand-in's Bluetooth radio soft-blocked and left Wi-Fi" \
  '[["bluetooth", "blocked", "unblocked"], ["wlan", "unblocked", "unblocked"]]' rfkill_state
expect "the stand-in recorded the fixture's argv" '[["block", "bluetooth"]]' device_calls rfkill
expect "the host's radios read as before the block" "$radios_before" host_radios
expect "the fixture's rfkill unblock starts" started ipc acme.devices invoke rfkill "unblock all"
expect_poll "the fixture's rfkill unblock exits 0" '[["unblock","all"],0]' devices_read rfkillRun
expect "the unblock cleared both soft blocks" '[["bluetooth", "unblocked", "unblocked"], ["wlan", "unblocked", "unblocked"]]' rfkill_state
expect "rfkill accepts wifi as the wlan alias" "" through_shell rfkill block wifi
expect "the wifi alias soft-blocked wlan only" \
  '[["bluetooth", "unblocked", "unblocked"], ["wlan", "blocked", "unblocked"]]' rfkill_state
expect "rfkill accepts several selectors in one call" "" through_shell rfkill unblock wifi bluetooth
expect "the multi-selector unblock cleared both soft blocks" \
  '[["bluetooth", "unblocked", "unblocked"], ["wlan", "unblocked", "unblocked"]]' rfkill_state
expect "the stand-in recorded each rfkill selector shape" \
  '[["block", "bluetooth"], ["unblock", "all"], ["block", "wifi"], ["unblock", "wifi", "bluetooth"]]' device_calls rfkill
expect "the host's radios still read as before the blocks" "$radios_before" host_radios
rfkill_control="$sandbox/devices-control"
mkdir -p "$rfkill_control"
cp -- "$repo/scripts/smoke/fixtures/devices/rfkill.json" "$rfkill_control/rfkill.json"
if python3 - "$repo/scripts/smoke/fixtures/devices/stand-in.py" "$rfkill_control/stand-in.py" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source).read()
old = "        save_rfkill(state, doc)\n"
assert text.count(old) == 1, "the stand-in's state write must match once"
open(target, "w").write(text.replace(old, "        pass\n"))
PY
then
  python3 "$rfkill_control/stand-in.py" rfkill "$rfkill_control" block bluetooth || fail "control: the copy's block failed"
  expect "control: a stand-in copy that drops its write leaves the radio unblocked" \
    '[["bluetooth", "unblocked", "unblocked"], ["wlan", "unblocked", "unblocked"]]' rfkill_state "$rfkill_control"
else
  fail "control: the stand-in copy could not be made"
fi

# Every other stand-in answers only what a row planted, through the PATH
# every sandbox shell starts with.
answer_of() { local status=0 out; out="$(through_shell "$@" 2>&1)" || status=$?; printf '%s status=%s\n' "$out" "$status"; }
expect "an unplanted systemctl call answers no reply and exits 1" \
  'stand-in: name=systemctl reply=none argv=["is-active", "bluetooth.service"] status=1' answer_of systemctl is-active bluetooth.service
device_reply systemctl 3 inactive is-active bluetooth.service
expect "a planted reply answers its argv" "inactive status=3" answer_of systemctl is-active bluetooth.service
device_reply systemctl 0 active is-active bluetooth.service
expect "a newer planted reply replaces the earlier one" "active status=0" answer_of systemctl is-active bluetooth.service
device_reply_clear systemctl
expect "a cleared planted reply answers no reply again" \
  'stand-in: name=systemctl reply=none argv=["is-active", "bluetooth.service"] status=1' answer_of systemctl is-active bluetooth.service
expect "the stand-in recorded every reply lookup" \
  '[["is-active", "bluetooth.service"], ["is-active", "bluetooth.service"], ["is-active", "bluetooth.service"], ["is-active", "bluetooth.service"]]' device_calls systemctl
device_transcript '[{"out": "Agent registered\n"}, {"in": "default-agent"}, {"out": "Default agent request successful\n"}]'
transcript_run() { local status=0 out; out="$(printf '%s\n' "$1" | through_shell bluetoothctl 2>&1)" || status=$?; printf '%s status=%s\n' "$(tr '\n' '|' <<<"$out")" "$status"; }
expect "bluetoothctl replays its transcript" "Agent registered|Default agent request successful| status=0" transcript_run default-agent
expect "a session that leaves the transcript ends with 1" 'Agent registered|stand-in: name=bluetoothctl transcript=diverged want="default-agent" got="power on"| status=1' transcript_run "power on"
device_transcript -

# The HID fake answers the brightness helper's feature-report ioctls:
# HIDIOCGFEATURE(7) and HIDIOCSFEATURE(7), report 1 of the planted Pro
# Display XDR, raw 25000 little-endian, then 20000 once set.
hid_get=0xC0074807
hid_set=0xC0074806
expect "the planted XDR answers its brightness report" '{"result": 7, "data": "01a86100000000"}' hid_fake_call hidraw0 "$hid_get" 01000000000000
expect "a set feature report is accepted" '{"result": 7, "data": "01204e00000000"}' hid_fake_call hidraw0 "$hid_set" 01204e00000000
expect "the next read returns the set report" '{"result": 7, "data": "01204e00000000"}' hid_fake_call hidraw0 "$hid_get" 01000000000000
expect "a device the world lacks answers ENOENT" '{"errno": 2}' hid_fake_call hidraw9 "$hid_get" 01000000000000
expect "another ioctl answers ENOTTY" '{"errno": 25}' hid_fake_call hidraw0 0x80084803 0000000000000000
expect "a report the device lacks answers EIO" '{"errno": 5}' hid_fake_call hidraw0 "$hid_get" 02000000000000
expect "the fake planted the XDR's sysfs identity" "HID_ID=0003:000005AC:00009243" grep -x -F -e HID_ID=0003:000005AC:00009243 -- "$devices_sysfs_root/class/hidraw/hidraw0/device/uevent"
expect "the fake planted the device node under VGS_DEV_ROOT" yes bash -c '[[ -f $1 && ! -s $1 ]] && echo yes || echo no' _ "$devices_dev_root/hidraw0"
expect "the fake logged every request" 6 bash -c 'wc -l <"$1"' _ "$devices_hid_log"

# The guard's controls: a process given the shell's own environment words
# with one host value after them, which win, reads as that leak.
ready_probe_control() { # PID
  (
    failures=0
    behaviour_failures=0
    not_measured_rows=()
    shell_qs_pid="$1"
    status=0
    devices_ready probe >"$sandbox/devices-ready-control.log" 2>&1 || status=$?
    printf '%s %s\n' "$status" "$(IFS=,; echo "${not_measured_rows[*]}")"
  )
}
guard_control() { # LABEL WANT ENV_OR_COMMAND...
  local pid label="$1" want="$2"
  shift 2
  spawn "$sandbox/devices-guard.log" "${shell_env[@]}" "${shell_start_words[@]}" "$@" sleep 30
  pid="$spawn_pid"
  for _ in $(seq 1 50); do [[ $(cat -- "/proc/$pid/comm" 2>/dev/null) == sleep ]] && break; sleep 0.05; done
  expect "control: $label" "$want" devices_guard "$pid"
  expect "control: devices_ready maps $label to not measured" "1 probe:$want" ready_probe_control "$pid"
  kill "$pid" 2>/dev/null || true
}
dead_pid_control() {
  local pid status=0 out err="$sandbox/devices-guard-unreadable.err" err_text
  spawn "$sandbox/devices-guard-dead.log" "${shell_env[@]}" "${shell_start_words[@]}" true
  pid="$spawn_pid"
  wait "$pid" 2>/dev/null || true
  out="$(devices_guard "$pid" 2>"$err")" || status=$?
  err_text="$(sed 's/pid=[0-9][0-9]*/pid=<pid>/' "$err")"
  printf 'status=%s stdout=%s stderr=%s\n' "$status" "$out" "$err_text"
}
ready_dead_pid_control() {
  local pid
  spawn "$sandbox/devices-ready-dead.log" "${shell_env[@]}" "${shell_start_words[@]}" true
  pid="$spawn_pid"
  wait "$pid" 2>/dev/null || true
  (
    failures=0
    behaviour_failures=0
    not_measured_rows=()
    shell_qs_pid="$pid"
    status=0
    devices_ready probe >"$sandbox/devices-ready-dead-control.log" 2>&1 || status=$?
    printf 'status=%s failures=%s not_measured=%s\n' "$status" "$failures" "$(IFS=,; echo "${not_measured_rows[*]}")"
  )
}
ready_empty_pid_control() {
  (
    failures=0
    behaviour_failures=0
    not_measured_rows=()
    shell_qs_pid=""
    status=0
    devices_ready probe >"$sandbox/devices-ready-empty-control.log" 2>&1 || status=$?
    printf 'status=%s failures=%s not_measured=%s\n' "$status" "$failures" "$(IFS=,; echo "${not_measured_rows[*]}")"
  )
}
if ! host_rfkill="$(command -v rfkill)"; then
  host_rfkill="$sandbox/host-bin/rfkill"
  mkdir -p -- "${host_rfkill%/*}"
  printf '#!/bin/sh\nexit 0\n' >"$host_rfkill"
  chmod 755 "$host_rfkill"
fi
guard_control "a shell on the host's system bus reads as a leak" \
  "leak=system-bus value=DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket" \
  DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket
guard_control "a shell on the host's PipeWire dir reads as a leak" \
  "leak=pipewire-runtime value=PIPEWIRE_RUNTIME_DIR=$XDG_RUNTIME_DIR" \
  "PIPEWIRE_RUNTIME_DIR=$XDG_RUNTIME_DIR"
guard_control "a shell on the host's /dev reads as a leak" \
  "leak=hardware-root value=VGS_DEV_ROOT=/dev" \
  VGS_DEV_ROOT=/dev
guard_control "a shell without the HID fake socket reads as a leak" \
  "leak=hardware-root value=VGS_HID_FAKE=unset" \
  env -u VGS_HID_FAKE
guard_control "a shell whose PATH finds the host's rfkill first reads as a leak" \
  "leak=path-shim value=rfkill=$host_rfkill" \
  "PATH=${host_rfkill%/*}:$shell_start_path"
expect "control: devices_guard fails an exited shell pid" \
  "status=1 stdout= stderr=devices_guard: environ=unreadable pid=<pid>" dead_pid_control
expect "control: devices_ready fails an exited shell pid" \
  "status=1 failures=1 not_measured=" ready_dead_pid_control
expect "control: devices_ready fails an empty shell pid" \
  "status=1 failures=1 not_measured=" ready_empty_pid_control
dbusmock_hidden="$sandbox/dbusmock-hidden"
mkdir -p -- "$dbusmock_hidden/dbusmock"
printf 'raise ImportError("hidden by the device-fakes control")\n' >"$dbusmock_hidden/dbusmock/__init__.py"
missing_control() {
  (
    devices_state=down
    failures=0
    behaviour_failures=0
    not_measured_rows=()
    status=0
    PYTHONPATH="$dbusmock_hidden" devices_ready probe >"$sandbox/devices-ready-missing-control.log" 2>&1 || status=$?
    printf '%s %s\n' "$status" "$(IFS=,; echo "${not_measured_rows[*]}")"
  )
}
expect "control: a host without python-dbusmock reads not measured" "1 probe:missing=python-dbusmock" missing_control

expect "disabling the device reader is allowed" ok ipc shell setPluginEnabled acme.devices false
expect_poll "the device reader is gone" False record_exists acme.devices
