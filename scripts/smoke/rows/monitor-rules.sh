# Monitor rules a plugin writes through the `monitors` capability, judged,
# saved as monitors.json and rendered into the Hyprland layer, read back
# from the nested Hyprland through hyprctl and from the acme.monitors
# fixture's instance. The consent row wired hyprland.lua and the rows since
# left it so. The row runs on the first nested output alone, WAYLAND-1,
# which takes any mode and lists none
# (docs/architecture/runtime-hyprland-monitors.md).
#
# The scale-2 write gives the output double its sized mode at scale 2, as
# rows/hidpi.sh holds it, through the layer's rule alone: no hold file is
# written until the write reads back, since the harness's hyprland.lua runs
# that file after the loading line and its rule would win. A host configure
# moves the output off the written mode (runtime-hyprland-nested.md), so
# the reading applies the layer's rule again through a configuration
# reload, which runs the layer file, up to mode_attempts times, and reads
# again; a reset is never read as the write failing. Once the write reads
# back, hold_mode holds the same mode and scale, so a later reading after a
# reset counts as a mode reset (validation-smoke-faults.md). The user's
# later line moves the output's position alone, which leaves the held mode
# and scale in force. At the end the row puts hyprland.lua and shell.json
# back, removes monitors.json, gives the output its own mode at scale 1
# again and disables the fixture.
#
# No latency is budgeted: each reading polls through expect_poll every
# 0.2 s for up to 5 s.
#
# Control run on 2026-10-01, host cachy, through this row alone after the
# bar and consent rows, on a sandbox source copy of the tree whose
# MonitorLogic.judgeRule accepts fractional logical pixels: the fractional
# write answered `ok` and "a scale that leaves fractional logical pixels
# is refused" failed.
set -euo pipefail
hypr_lua="$home/.config/hypr/hyprland.lua"
hypr_layer="$home/.local/state/vgs/hypr/vgs.lua"
user_config="$home/.config/vgs/shell.json"
monitors_doc="$home/.config/vgs/monitors.json"
fixture_dir="$home/.config/vgs/plugins/acme.monitors"
mkdir -p "$fixture_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.monitors/." "$fixture_dir/"
cp -- "$user_config" "$sandbox/shell-before-monitors.json"
cp -- "$hypr_lua" "$sandbox/hyprland-before-monitors.lua"

read_monitors() { ipc smoke readInstance service acme.monitors "$1"; }
write_rules() { ipc acme.monitors invoke write "{\"rules\": $1}"; }
reads_active() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["monitors"]["active"]))'; }
write_phase() { read_monitors writeState | py_reply 'import json,sys; print(json.load(sys.stdin)["phase"])'; }
layer_has() { if grep -qxF -- "$1" "$hypr_layer"; then echo yes; else echo no; fi; }
layer_mentions() { if grep -qF -- "$1" "$hypr_layer"; then echo yes; else echo no; fi; }
doc_exists() { if [[ -e $monitors_doc ]]; then echo yes; else echo no; fi; }
config_errors() { hypr -j configerrors | py_reply 'import json,sys; print(json.dumps([e for e in json.load(sys.stdin) if e]))'; }
hypr_problems() { ipc shell listPlugins | py_reply 'import json,sys; print(json.dumps(sorted(e["error"] for e in json.load(sys.stdin)["errors"] if e["error"].startswith("hyprland: monitors: "))))'; }
# The output NAME as the fixture's `outputs` holds it, `WxH scale=S`.
output_read() { read_monitors outputs | py_reply 'import json,sys; m=[o for o in json.load(sys.stdin) if o["name"]==sys.argv[1]]; print("%dx%d scale=%g" % (m[0]["width"], m[0]["height"], m[0]["scale"])) if len(m)==1 else print("outputs=%d" % len(m))' "$1"; }
# Whether Hyprland lists output NAME disabled.
output_disabled() { hypr -j monitors all | py_reply 'import json,sys; m=[o for o in json.load(sys.stdin) if o["name"]==sys.argv[1]]; print(json.dumps(m[0]["disabled"]) if len(m)==1 else "outputs=%d" % len(m))' "$1"; }
# Where the Monitors section sits: `placed` when its header follows the
# session lock's restore and comes before every plugin section, and at
# least one plugin section is written; else what was found.
section_place() {
  python3 - "$hypr_layer" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
header = "-- Monitors: the output rules monitors.json sets."
lock = "-- Session lock: a restarted shell takes over a lock whose client died."
plugins = [i for i, line in enumerate(lines) if re.match(r"^-- \S+ \S+: (binds and layer rules from its manifest|input options its settings set)$", line)]
if header not in lines or lock not in lines:
    print("header=%s lock=%s" % (header in lines, lock in lines))
elif not plugins:
    print("plugin-sections=0")
else:
    at = lines.index(header)
    print("placed" if lines.index(lock) < at < plugins[0] else "header=%d lock=%d first-plugin=%d" % (at, lines.index(lock), plugins[0]))
PY
}
# layer_mode_reads NAME MODE SCALE: output NAME reads MODE at SCALE under
# the layer's rule. A reading of another mode applies the rule again
# through a configuration reload, which runs the layer file, up to
# mode_attempts times. Prints `held` or the last reading.
layer_mode_reads() {
  local output="$1" want="$2 scale=$3" got="" attempt reply
  for ((attempt = 1; attempt <= mode_attempts; attempt++)); do
    for _ in $(seq 1 25); do
      got="$(mode_scale_of "$output")" || got=unreadable
      if [[ $got == "$want" ]]; then echo held; return 0; fi
      sleep 0.2
    done
    reply="$(hypr reload config-only)" || reply="status=$?"
    if [[ $reply != ok ]]; then echo "reload=[$reply]"; return 0; fi
  done
  echo "attempts=$mode_attempts got=[$got]"
}

expect "rescan discovers the monitors fixture" ok ipc shell rescanPlugins
expect_poll "the monitors fixture is known" True plugin_known acme.monitors
expect "enabling the monitors fixture is allowed" ok ipc shell setPluginEnabled acme.monitors true
expect_poll "the monitors fixture builds" True record_exists acme.monitors
expect_poll "the fixture reads back the exact monitors members it was given" '"outputs,overridden,saved,write,writeState"' read_monitors members
expect_poll "the core reads the outputs while a plugin holds monitors" true reads_active
expect "with no monitors.json the saved rules are none" '[]' read_monitors saved
expect "with no monitors.json the layer writes no Monitors section" no layer_mentions "-- Monitors"

if ! rules_output="$(first_name)" || ! rules_base="$(unscaled_mode_of "$rules_output")" || ! rules_double="$(hidpi_mode_of "$rules_output")"; then
  fail "the monitor rules row reads no sized mode at scale 1 on the first monitor ${rules_output:-unread}"
else
  expect_poll "the fixture's outputs list $rules_output at its own mode" "$rules_base scale=1" output_read "$rules_output"
  rules_refresh="$(read_monitors outputs | py_reply 'import json,sys; print("%.3f" % [o for o in json.load(sys.stdin) if o["name"]==sys.argv[1]][0]["refreshRate"])' "$rules_output")" || rules_refresh=unread
  rules_mode="$rules_double@$rules_refresh"
  rule_json() { printf '[{"output": "%s", "mode": "%s", "position": {"x": %s, "y": 0}, "scale": %s}]' "$rules_output" "$rules_mode" "$1" "$2"; }

  expect "a scale that leaves fractional logical pixels is refused" "refused: rule=0 scale=1.3 want=whole-logical-pixels mode=$rules_double" write_rules "$(rule_json 0 1.3)"
  expect "turning off the only output is refused" 'refused: rules=no-output-on want=one-output-on' write_rules "[{\"output\": \"$rules_output\", \"disabled\": true}]"
  expect "the refused writes leave the only output on" false output_disabled "$rules_output"
  expect "the refused writes save no monitors.json" no doc_exists

  expect "a scale-2 write at double the mode is accepted" ok write_rules "$(rule_json 0 2)"
  expect_poll "the write is saved, applied and read back" idle write_phase
  expect "the fixture's outputs read the written mode and scale back" "$rules_double scale=2" output_read "$rules_output"
  expect "hyprctl -j monitors reads the written mode and scale under the layer's rule" held layer_mode_reads "$rules_output" "$rules_double" 2
  expect "the saved rules are the written rule" "[{\"output\":\"$rules_output\",\"mode\":\"$rules_mode\",\"position\":{\"x\":0,\"y\":0},\"scale\":2}]" read_monitors saved
  expect "the layer writes the rule as hl.monitor" yes layer_has "hl.monitor({ output = \"$rules_output\", mode = \"$rules_mode\", position = \"0x0\", scale = 2 })"
  expect "the Monitors section follows the session lock and comes before every plugin section" placed section_place
  expect_poll "no rule is overridden while the user sets none after the line" '[]' read_monitors overridden
  expect "the written rule holds no configuration error" '[]' config_errors

  hold_mode "the nested compositor holds $rules_output at the written mode and scale" "$rules_output" "$rules_double" 2
  # The user's own line after the loading line wins, and the capability
  # says so. It moves the output alone, so the held mode and scale stay.
  printf '%s\n' "hl.monitor({ output = \"$rules_output\", position = \"10x0\" })" >>"$hypr_lua"
  expect "the nested instance reloads with the user's monitor line" ok hypr reload config-only
  expect_poll "a later user line is reported in overridden" "[\"$rules_output\"]" read_monitors overridden
  expect "the user's monitor line holds no configuration error" '[]' config_errors
  cp -- "$sandbox/hyprland-before-monitors.lua" "$hypr_lua.next" && mv -T -- "$hypr_lua.next" "$hypr_lua"
  expect "the nested instance reloads without the user's monitor line" ok hypr reload config-only
  expect_poll "removing the user line clears overridden" '[]' read_monitors overridden

  # A hand edit the judge refuses is not applied and is reported.
  expected_errors+=('monitors: refused: rule=0 disabled=')
  printf '{"version": 1, "rules": [{"output": "%s", "disabled": "yes"}]}\n' "$rules_output" >"$monitors_doc.next" && mv -T -- "$monitors_doc.next" "$monitors_doc"
  expect_poll "a refused monitors.json is reported by listPlugins" "[\"hyprland: monitors: refused: rule=0 disabled=\\\"yes\\\" want=boolean\"]" hypr_problems
  expect_poll "a refused monitors.json writes its comment in the section's place" yes layer_has '-- Monitors: monitors.json is not applied: refused: rule=0 disabled="yes" want=boolean'
  expect "a refused monitors.json holds no saved rules" null read_monitors saved
  expect "a write over a refused monitors.json is refused" "refused: monitors=refused path=$monitors_doc" write_rules "$(rule_json 0 2)"

  # Leave the sandbox as the row found it.
  rm -f -- "$monitors_doc"
  expect_poll "with monitors.json removed the layer writes no Monitors section" no layer_mentions "-- Monitors"
  expect_poll "with monitors.json removed nothing is reported" '[]' hypr_problems
  release_mode "the nested compositor gives $rules_output its own mode at scale 1 again" "$rules_output" "$rules_base"
fi
cp -- "$sandbox/shell-before-monitors.json" "$user_config.next" && mv -T -- "$user_config.next" "$user_config"
expect "disabling the monitors fixture is allowed" ok ipc shell setPluginEnabled acme.monitors false
expect_poll "the monitors fixture is disabled" False plugin_enabled acme.monitors
expect_poll "the core stops reading the outputs once no plugin holds monitors" false reads_active
expect "the configuration after the monitor rules holds no error" '[]' config_errors
