# Input options a plugin's settings set, rendered into the Hyprland layer
# only when set, and the `hyprland` capability, read back from the nested
# Hyprland through hyprctl and from the acme.hyprland fixture's instance.
# The consent row wired hyprland.lua and the hyprland row left it so; this
# row appends the user's own lines after the loading line, then puts
# hyprland.lua and shell.json back and disables the fixture again. No
# latency is budgeted: each reading polls through expect_poll every 0.2 s
# for up to 5 s.
#
# Control run on 2026-09-30, host cachy, through this row alone after the
# bar and consent rows: a source_tree copy of the shell whose
# PluginLogic.hyprlandSection lists every declared option at its effective
# setting, so the layer writes the manifest's defaults for unset options,
# failed "an unset option keeps Hyprland's default", reading [false, true]:
# Hyprland reported natural_scroll as set by the configuration. The layer
# text rows failed with it.
set -euo pipefail
hypr_lua="$home/.config/hypr/hyprland.lua"
hypr_layer="$home/.local/state/vgs/hypr/vgs.lua"
user_config="$home/.config/vgs/shell.json"
fixture_dir="$home/.config/vgs/plugins/acme.hyprland"
mkdir -p "$fixture_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.hyprland/." "$fixture_dir/"
cp -- "$user_config" "$sandbox/shell-before-options.json"
cp -- "$hypr_lua" "$sandbox/hyprland-before-options.lua"

read_options() { ipc smoke readInstance service acme.hyprland "$1"; }
# An option as the nested instance holds it: [value, whether a configuration
# line set it]. FIELD is the reply's value field: bool, int, float or str.
option_value() { hypr -j getoption "$1" | py_reply 'import json,sys; v=json.load(sys.stdin); print(json.dumps([v.get(sys.argv[1]), v["set"]]))' "$2"; }
# Each keymap a keyboard of the nested instance is on, once, sorted.
keymaps() { hypr -j devices | py_reply 'import json,sys; print(json.dumps(sorted({k["active_keymap"] for k in json.load(sys.stdin)["keyboards"]})))'; }
foreign_has() { read_options foreignBinds | py_reply 'import json,sys; print(sys.argv[1] in json.load(sys.stdin))' "$1"; }
reads_active() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["hyprland"]["active"]))'; }
layer_has() { if grep -qxF -- "$1" "$hypr_layer"; then echo yes; else echo no; fi; }
layer_mentions() { if grep -qF -- "$1" "$hypr_layer"; then echo yes; else echo no; fi; }
config_errors() { hypr -j configerrors | py_reply 'import json,sys; print(json.dumps([e for e in json.load(sys.stdin) if e]))'; }
switch_layout() { ipc acme.hyprland invoke switch "$1"; }
# Merge JSON object WANT into the fixture's plugins row in shell.json.
set_options() {
  python3 - "$user_config" "$1" <<'PY'
import json, os, sys
path, want = sys.argv[1], json.loads(sys.argv[2])
config = json.load(open(path))
rows = config.setdefault("plugins", [])
row = next((r for r in rows if r.get("id") == "acme.hyprland"), None)
if row is None:
    row = {"id": "acme.hyprland"}
    rows.append(row)
row.update(want)
with open(path + ".next", "w") as f:
    json.dump(config, f, indent=2)
os.replace(path + ".next", path)
PY
}

expect "rescan discovers the options fixture" ok ipc shell rescanPlugins
expect_poll "the options fixture is known" True plugin_known acme.hyprland
expect "enabling the options fixture is allowed" ok ipc shell setPluginEnabled acme.hyprland true
expect_poll "the options fixture builds" True record_exists acme.hyprland
expect_poll "the fixture reads back the exact hyprland members it was given" '"devices,foreignBinds,overridden,switchKeyboardLayout"' read_options members
expect_poll "the core reads Hyprland while a plugin holds hyprland" true reads_active
expect_poll "with no option set the layer writes no options section" no layer_mentions "acme.hyprland 0.1.0: input options its settings set"
expect_poll "the fixture's bind is written" yes layer_has 'hl.bind("SUPER + F7", hl.dsp.global("acme.hyprland:ping"), { description = "acme.hyprland:ping" })'

set_options '{"sensitivity": 0.35, "tapToClick": false, "layouts": "us,de", "repeatRate": 40}'
expect_poll "the set options are one hl.config in the manifest's order" yes layer_has 'hl.config({ input = { sensitivity = 0.35, touchpad = { tap_to_click = false }, kb_layout = "us,de", repeat_rate = 40 } })'
expect_poll "the set sensitivity reads back through getoption" '[0.35, true]' option_value input:sensitivity float
expect_poll "the set tap-to-click reads back through its Lua name" '[false, true]' option_value input:touchpad:tap_to_click bool
expect_poll "the set layouts read back" '["us,de", true]' option_value input:kb_layout str
expect_poll "the set repeat rate reads back" '[40, true]' option_value input:repeat_rate int
expect "an unset option keeps Hyprland's default" '[false, false]' option_value input:natural_scroll bool
expect "the layer writes no unset option" no layer_mentions natural_scroll
expect "an unset touchpad option writes no device" no layer_mentions 'hl.device('
expect "the options hold no configuration error" '[]' config_errors
expect_poll "no option is overridden while the user sets none after the line" '[]' read_options overridden
expect_poll "the layer's own bind is no foreign bind" False foreign_has SUPER+F7

# The user's own lines after the loading line win, and the capability says so.
printf '%s\n' 'hl.config({ input = { sensitivity = -0.5 } })' 'hl.bind("SUPER + F7", hl.dsp.exec_cmd("true"))' >>"$hypr_lua"
expect "the nested instance reloads with the user's lines" ok hypr reload config-only
expect_poll "the user's later sensitivity wins" '[-0.5, true]' option_value input:sensitivity float
expect_poll "a later user line is reported in overridden" '["input.sensitivity"]' read_options overridden
expect_poll "a user bind on the same key shows in foreignBinds" True foreign_has SUPER+F7
expect "the user's lines hold no configuration error" '[]' config_errors

# Two layouts: the switch moves every keyboard, and the devices follow.
expect_poll "the keyboards start on the first layout" '["English (US)"]' keymaps
expect_poll "the fixture reads the first layout" '["English (US)"]' read_options keymaps
expect "switchKeyboardLayout('next') is accepted" ok switch_layout next
expect_poll "the next layout is the active keymap in devices -j" '["German"]' keymaps
expect_poll "the fixture's devices follow the switch" '["German"]' read_options keymaps
expect "switchKeyboardLayout(0) is accepted" ok switch_layout 0
expect_poll "the first layout is active again" '["English (US)"]' keymaps
expected_errors+=('compositor: refused: layout=')
expect "a target that is no layout is refused" 'refused: layout="up" want=next|prev|index' switch_layout up
expect "the switches hold no configuration error" '[]' config_errors

# Leave the sandbox as the row found it.
cp -- "$sandbox/hyprland-before-options.lua" "$hypr_lua.next" && mv -T -- "$hypr_lua.next" "$hypr_lua"
expect "the nested instance reloads without the user's lines" ok hypr reload config-only
cp -- "$sandbox/shell-before-options.json" "$user_config.next" && mv -T -- "$user_config.next" "$user_config"
expect "disabling the options fixture is allowed" ok ipc shell setPluginEnabled acme.hyprland false
expect_poll "the options fixture is disabled" False plugin_enabled acme.hyprland
expect_poll "the disabled fixture's options leave the layer" no layer_mentions "acme.hyprland"
expect_poll "the layer's sensitivity leaves Hyprland" '[0.0, false]' option_value input:sensitivity float
expect_poll "the layouts are Hyprland's own again" '["us", false]' option_value input:kb_layout str
expect_poll "the core stops reading Hyprland once no plugin holds hyprland" false reads_active
expect "the configuration after the options rows holds no error" '[]' config_errors
