# The outputs a plugin reads through the `monitors` capability: Hyprland's
# own list, read by the core while a plugin holds the capability and read
# again after each `configreloaded`, compared with what the nested Hyprland
# answers hyprctl. The capability hands a plugin `outputs` and nothing
# else, and the shell writes no monitor rule: the row reads the Hyprland
# layer for an `hl.monitor` call and finds none
# (docs/architecture/hyprland-monitors.md). The row runs on the first nested
# output alone, WAYLAND-1, which takes any mode and lists none
# (docs/architecture/runtime-hyprland-monitors.md).
#
# The change the fixture must follow is the harness's own: hold_mode gives
# the output double its sized mode at scale 2, as rows/hidpi.sh holds it,
# through `hyprctl eval`. The configuration reload after it runs the hold
# file, so the held mode stands, and posts `configreloaded`, the event the
# core reads the outputs again on. The readings under the
# hold count as a mode reset when the host moved the output off it
# (validation-smoke-faults.md). At the end the row gives the output its own
# mode at scale 1 again, puts shell.json back and disables the fixture.
#
# No latency is budgeted: each reading polls through expect_poll every
# 0.2 s for up to 5 s.
#
# Control run on 2026-10-02, host cachy, through this row alone after the
# bar and consent rows, on a source copy of the tree whose MonitorState.qml
# reads the outputs on no `configreloaded`: "the fixture's outputs follow
# the reload to the held mode and scale" failed.
set -euo pipefail
hypr_layer="$home/.local/state/vgs/hypr/vgs.lua"
user_config="$home/.config/vgs/shell.json"
fixture_dir="$home/.config/vgs/plugins/acme.monitors"
mkdir -p "$fixture_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.monitors/." "$fixture_dir/"
cp -- "$user_config" "$sandbox/shell-before-monitors.json"

read_monitors() { ipc smoke readInstance service acme.monitors "$1"; }
reads_active() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["monitors"]["active"]))'; }
# How many lines of the Hyprland layer hold an `hl.monitor` call, or
# `layer=unread` for a layer that is not there to read.
layer_monitor_calls() {
  [[ -r $hypr_layer ]] || { echo layer=unread; return; }
  grep -c -E -- 'hl\.monitor[[:space:]]*\(' "$hypr_layer" || true
}
# The output NAME as the fixture's `outputs` holds it, `WxH scale=S`.
output_read() { read_monitors outputs | py_reply 'import json,sys; m=[o for o in json.load(sys.stdin) if o["name"]==sys.argv[1]]; print("%dx%d scale=%g" % (m[0]["width"], m[0]["height"], m[0]["scale"])) if len(m)==1 else print("outputs=%d" % len(m))' "$1"; }
# The names Hyprland lists, and the names and identifiers the fixture's
# `outputs` hold, each as a JSON list in Hyprland's order.
listed_names() { hypr -j monitors all | py_reply 'import json,sys; print(json.dumps([o["name"] for o in json.load(sys.stdin)]))'; }
read_names() { read_monitors outputs | py_reply 'import json,sys; print(json.dumps([o["name"] for o in json.load(sys.stdin)]))'; }
read_identifiers() { read_monitors outputs | py_reply 'import json,sys; print(json.dumps([o["identifier"] for o in json.load(sys.stdin)]))'; }

expect "rescan discovers the monitors fixture" ok ipc shell rescanPlugins
expect_poll "the monitors fixture is known" True plugin_known acme.monitors
expect "enabling the monitors fixture is allowed" ok ipc shell setPluginEnabled acme.monitors true
expect_poll "the monitors fixture builds" True record_exists acme.monitors
expect_poll "the fixture reads back the exact monitors members it was given" '"outputs"' read_monitors members
expect_poll "the core reads the outputs while a plugin holds monitors" true reads_active

if ! outputs_names="$(listed_names)" || ! outputs_first="$(first_name)" || ! outputs_base="$(unscaled_mode_of "$outputs_first")" || ! outputs_double="$(hidpi_mode_of "$outputs_first")"; then
  fail "the monitor outputs row reads no sized mode at scale 1 on the first monitor ${outputs_first:-unread}"
else
  expect_poll "the fixture's outputs name every output Hyprland lists, in its order" "$outputs_names" read_names
  # The nested outputs carry no serial, so each is named by its connector.
  expect "an output with no serial is identified by its connector" "$outputs_names" read_identifiers
  expect_poll "the fixture's outputs list $outputs_first at its own mode" "$outputs_base scale=1" output_read "$outputs_first"

  hold_mode "the nested compositor holds $outputs_first at double its mode and scale 2" "$outputs_first" "$outputs_double" 2
  if [[ ${#mode_hold[@]} -gt 0 ]]; then
    expect "the nested instance reloads its configuration under the hold" ok hypr reload config-only
    expect_poll "the fixture's outputs follow the reload to the held mode and scale" "$outputs_double scale=2" output_read "$outputs_first"
  fi
  release_mode "the nested compositor gives $outputs_first its own mode at scale 1 again" "$outputs_first" "$outputs_base"
  expect "the nested instance reloads its configuration without the hold" ok hypr reload config-only
  expect_poll "the fixture's outputs follow the reload back to the output's own mode" "$outputs_base scale=1" output_read "$outputs_first"
fi
expect "the Hyprland layer holds no hl.monitor call" 0 layer_monitor_calls

cp -- "$sandbox/shell-before-monitors.json" "$user_config.next" && mv -T -- "$user_config.next" "$user_config"
expect "disabling the monitors fixture is allowed" ok ipc shell setPluginEnabled acme.monitors false
expect_poll "the monitors fixture is disabled" False plugin_enabled acme.monitors
expect_poll "the core stops reading the outputs once no plugin holds monitors" false reads_active
