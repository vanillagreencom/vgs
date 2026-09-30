# The Hyprland layer, shell/Core/HyprlandLayer.qml: the Lua file the shell
# writes from the theme's border colours, the floating TUIs' window rules
# and every enabled plugin's `hyprland` manifest data, the line `vgsh hypr
# wire` keeps first in hyprland.lua, and the `hyprctl reload` after each
# write. The harness's hyprland.lua existed when the shell first started,
# so the first write wired it. Every row reads the nested instance back
# through hyprctl. The launcher's and the notifications' own rows ran
# before this one, so it enables both, types their keys on the nested
# seat, and leaves both disabled, shell.json as it found it and
# hyprland.lua as the first run left it. The window rules are read back on
# windows the harness's toplevel helper maps, each stopped by the pid the
# row started.
#
# Hyprland v0.56.2 reads no layer rule back
# (docs/architecture/runtime-hyprland.md), so the rows hold the layer rules
# through the written file and an empty configerrors, where Hyprland lists a
# field it refuses.
set -euo pipefail
hypr_lua="$home/.config/hypr/hyprland.lua"
hypr_layer="$home/.local/state/vgs/hypr/vgs.lua"
user_config="$home/.config/vgs/shell.json"
wire_line="pcall(dofile, \"$hypr_layer\")"
vgsh_run() { "${shell_env[@]}" "$repo/bin/vgsh" "$@"; }
# A theme apply's verdict and package, `ok theme=<name>`, whatever it
# changed.
applied() { local out; out="$(vgsh_run theme apply "$1")" || return; printf '%s\n' "${out##*$'\n'}" | cut -d' ' -f1-2; }
# The binds whose description names a vgs shortcut, as [modmask, key,
# dispatcher, description]: a Lua bind's dispatcher is `__lua`, so the
# description is what names its shortcut.
vgs_binds() { hypr -j binds | python3 -c 'import json,sys; print(json.dumps(sorted([b["modmask"], b["key"], b["dispatcher"], b["description"]] for b in json.load(sys.stdin) if b["description"].startswith("vgs."))))'; }
config_errors() { hypr -j configerrors | python3 -c 'import json,sys; print(json.dumps([e for e in json.load(sys.stdin) if e]))'; }
# A border option as the nested instance holds it, and what Hyprland prints
# for a one-colour border of `#rrggbbaa` TOKEN_VALUE: hex aarrggbb with no
# leading zeros, then the angle.
hypr_gradient() { hypr -j getoption "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["gradient"])'; }
gradient_of() { python3 -c 'import sys; h = sys.argv[1][1:]; print(format(int(h[6:8] + h[:6], 16), "x") + " 0deg")' "$1"; }
hypr_option() { hypr -j getoption "$1" | python3 -c 'import json,sys; v=json.load(sys.stdin); print(v.get("int", v.get("float", v.get("str", v.get("set", v)))))'; }
animation_leaf() { hypr -j animations | python3 -c '
import json, sys
data = json.load(sys.stdin)
rows = data[0] if data and isinstance(data[0], list) else data
row = next((r for r in rows if r.get("name") == sys.argv[1]), None)
if row is None:
    print("absent")
else:
    print(json.dumps({"bezier": row.get("bezier", ""), "enabled": row.get("enabled"), "overridden": row.get("overridden"), "speed": round(float(row.get("speed", 0)), 2), "style": row.get("style", "")}, sort_keys=True))
' "$1"; }
animation_curve() { hypr -j animations | python3 -c '
import json, sys
def rows(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from rows(value)
    elif isinstance(node, list):
        for value in node:
            yield from rows(value)
data = json.load(sys.stdin)
print("yes" if any(r.get("name") == sys.argv[1] for r in rows(data)) else "no")
' "$1"; }
layer_has() { if grep -qxF -- "$1" "$hypr_layer"; then echo yes; else echo no; fi; }
layer_matches() { if grep -Eq -- "$1" "$hypr_layer"; then echo yes; else echo no; fi; }
section_of() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print("-- " + m["id"] + " " + m["version"] + ": binds and layer rules from its manifest")' "$repo/shell/plugins/$1/manifest.json"; }
# How many plugin sections the layer holds. grep -c exits 1 on a count of
# 0, which is an answer, and 2 on a file it cannot read, which is not.
section_count() { local status=0; grep -c -- ': binds and layer rules from its manifest$' "$hypr_layer" || status=$?; [[ $status -le 1 ]]; }
# Put hyprland.lua back as the shell's first run left it: the loading line,
# then the harness's own text.
restore_hypr_lua() { { printf '%s\n' "$wire_line"; cat -- "$sandbox/hyprland-harness.lua"; } >"$hypr_lua.next" && mv -T -- "$hypr_lua.next" "$hypr_lua"; }
# The toplevel helper, for the floating TUIs' window rules. open_tui APP_ID
# starts it on the nested socket, leaves its pid in tui_pid and returns once
# it prints that its first buffer is committed. close_tui LABEL stops that
# pid alone and passes LABEL when the helper exits 0 on the signal.
tui_pid=""
open_tui() {
  local log="$sandbox/toplevel-$1.log"
  spawn "$log" "${shell_env[@]}" "$sandbox/toplevel" "$1"
  tui_pid="$spawn_pid"
  for _ in $(seq 1 25); do
    grep -qxF -- "mapped $1" "$log" && return 0
    kill -0 -- "$tui_pid" 2>/dev/null || break
    sleep 0.2
  done
  cat -- "$log" >&2
  return 1
}
close_tui() {
  local status=0
  kill -TERM -- "$tui_pid" 2>/dev/null || true
  for _ in $(seq 1 25); do kill -0 -- "$tui_pid" 2>/dev/null || break; sleep 0.2; done
  if kill -0 -- "$tui_pid" 2>/dev/null; then kill -KILL -- "$tui_pid" 2>/dev/null || true; fi
  wait "$tui_pid" || status=$?
  if [[ $status -eq 0 ]]; then ok "$1"; else fail "$1: exit=$status"; fi
}
# The nested instance's client of pid PID as `<class> floating=<bool>`, its
# size as `<w>x<h>`, or clients=<n> when that pid has not one client.
tui_client() { hypr -j clients | python3 -c '
import json, sys
cs = [c for c in json.load(sys.stdin) if c["pid"] == int(sys.argv[2])]
if len(cs) != 1: print("clients=%d" % len(cs))
elif sys.argv[1] == "floating": print("%s floating=%s" % (cs[0]["class"], str(cs[0]["floating"]).lower()))
else: print("%dx%d" % tuple(cs[0]["size"]))' "$1" "$2"; }
tui_floating() { tui_client floating "$1"; }
tui_size() { tui_client size "$1"; }
# `centred` when the centre of the client of pid PID lies within 1 px of
# the centre of its monitor's work area, else both centres. Hyprland
# v0.56.2 centres a floating window on that work area: the monitor's
# logical box less its reserved space, [left, top, right, bottom], and less
# general:float_gaps, CSS order (docs/architecture/runtime-hyprland.md).
# hyprctl prints the window's place in whole pixels, hence the 1 px.
tui_centred() {
  local clients monitors gaps
  clients="$(hypr -j clients)" && monitors="$(hypr -j monitors)" && gaps="$(hypr -j getoption general:float_gaps)" || return 1
  python3 -c '
import json, sys
clients, monitors, gaps, pid = (json.loads(a) for a in sys.argv[1:])
cs = [c for c in clients if c["pid"] == pid]
if len(cs) != 1: print("clients=%d" % len(cs)); sys.exit()
c = cs[0]
m = next(m for m in monitors if m["id"] == c["monitor"])
top, right, bottom, left = (int(v) for v in gaps["css"].split())
rl, rt, rr, rb = m["reserved"]
area_x = (m["x"] + rl + left + m["x"] + m["width"] / m["scale"] - rr - right) / 2
area_y = (m["y"] + rt + top + m["y"] + m["height"] / m["scale"] - rb - bottom) / 2
at_x, at_y = c["at"][0] + c["size"][0] / 2, c["at"][1] + c["size"][1] / 2
print("centred" if abs(at_x - area_x) <= 1 and abs(at_y - area_y) <= 1 else "centre=%g,%g work-area-centre=%g,%g" % (at_x, at_y, area_x, area_y))' "$clients" "$monitors" "$gaps" "$1"
}
# listPlugins' Hyprland problems, sorted.
hypr_problems() { ipc shell listPlugins | python3 -c 'import json,sys; print(json.dumps(sorted(e["error"] for e in json.load(sys.stdin)["errors"] if e["error"].startswith("hyprland: "))))'; }
theme_switches() { ipc shell listShellConfig | python3 -c 'import json,sys; row=next((r for r in json.load(sys.stdin).get("plugins", []) if r.get("id") == "vgs.themes"), {}); print(json.dumps({k: row.get(k) for k in ("setWindowBorders", "setCornerRadius", "setWindowAnimations")}, sort_keys=True))'; }
inbox_mode() { ipc smoke readInstance service vgs.notifications panelMode; }
press_super() { type_keys -M logo -k "$1" -m logo; }
# Give plugins rows the `keys` JSON maps: { id: keys }, replaced whole.
set_keys() {
  python3 - "$user_config" "$1" <<'PY'
import json, os, sys
path, want = sys.argv[1], json.loads(sys.argv[2])
config = json.load(open(path))
rows = config.setdefault("plugins", [])
for plugin_id, keys in want.items():
    row = next((r for r in rows if r.get("id") == plugin_id), None)
    if row is None:
        row = {"id": plugin_id}
        rows.append(row)
    row["keys"] = keys
with open(path + ".next", "w") as f:
    json.dump(config, f, indent=2)
os.replace(path + ".next", path)
PY
}
set_theme_switches() {
  python3 - "$user_config" "$1" "$2" "$3" <<'PY'
import json, os, sys
path = sys.argv[1]
values = {
    "setWindowBorders": sys.argv[2] == "true",
    "setCornerRadius": sys.argv[3] == "true",
    "setWindowAnimations": sys.argv[4] == "true",
}
config = json.load(open(path))
rows = config.setdefault("plugins", [])
row = next((r for r in rows if r.get("id") == "vgs.themes"), None)
if row is None:
    row = {"id": "vgs.themes"}
    rows.append(row)
row.update(values)
with open(path + ".next", "w") as f:
    json.dump(config, f, indent=2)
os.replace(path + ".next", path)
PY
}
both_binds='[[64, "N", "__lua", "vgs.notifications:inbox"], [64, "SPACE", "__lua", "vgs.launcher:toggle"]]'
rebound='[[72, "SPACE", "__lua", "vgs.launcher:toggle"]]'

# The first run.
expect "the first run wired the loading line first in the sandbox's hyprland.lua" "$wire_line" head -n 1 -- "$hypr_lua"
expect "the first run changed nothing else in hyprland.lua" same bash -c 'tail -n +2 -- "$1" | cmp -s - "$2" && echo same' _ "$hypr_lua" "$sandbox/hyprland-harness.lua"
expect "the layer's header names the command that writes it again" yes bash -c 'grep -qF -- "\`vgsh hypr render\`" "$1" && echo yes' _ "$hypr_layer"
expect "no plugin declaring Hyprland data is enabled, so no section is written" 0 section_count
expect_poll "the nested instance holds no vgs bind" '[]' vgs_binds
expect "the nested configuration, the floating TUIs' window rules included, holds no error" '[]' config_errors

border_before="$(hypr_option general:border_size)" || fail "the nested border_size is readable"
radius_before="$(hypr_option decoration:rounding)" || fail "the nested rounding is readable"
cp -- "$user_config" "$sandbox/shell-before-appearance.json"
expect "enabling the themes plugin for the appearance switch rows is allowed" ok ipc shell setPluginEnabled vgs.themes true
probe_theme="$home/.config/vgs/themes/hyprland-probe"
mkdir -p "$probe_theme"
cat >"$probe_theme/theme.json" <<'JSON'
{
  "schemaVersion": 1,
  "name": "hyprland-probe",
  "tokens": {
    "hyprland": {
      "border": { "size": 4 },
      "window": { "radius": 8 },
      "motion": { "preset": "snappy" }
    }
  }
}
JSON
set_theme_switches false false false
expect "the shell reloads the probe theme switches off for the baseline" ok ipc shell reloadConfig
expect_poll "the effective config has the probe theme switches off for the baseline" '{"setCornerRadius": false, "setWindowAnimations": false, "setWindowBorders": false}' theme_switches
expect_poll "with switches off the layer writes no border size" no layer_matches '^[[:space:]]*border_size ='
expect_poll "with switches off the layer writes no window rounding" no layer_matches '^[[:space:]]*rounding ='
border_before="$(hypr_option general:border_size)" || fail "the nested border_size baseline is readable"
radius_before="$(hypr_option decoration:rounding)" || fail "the nested rounding baseline is readable"
expect "the switch-off border baseline is Hyprland's default" 1 printf '%s\n' "$border_before"
expect "the switch-off radius baseline is Hyprland's default" 0 printf '%s\n' "$radius_before"
motion_before="$(animation_leaf windows)" || fail "the nested windows animation baseline is readable"
expect "the switch-off motion baseline has no VGS curve" no animation_curve vgsSnappy
expect "the switch-off appearance baseline holds no configuration error" '[]' config_errors
set_theme_switches true true false
expect "the shell reloads the probe border and radius switches on" ok ipc shell reloadConfig
expect_poll "the effective config has the probe border and radius switches on" '{"setCornerRadius": true, "setWindowAnimations": false, "setWindowBorders": true}' theme_switches
expect "the Hyprland probe package applies" "ok theme=hyprland-probe" applied hyprland-probe
expect_poll "the theme border size reaches Hyprland" 4 hypr_option general:border_size
expect_poll "the theme corner radius reaches Hyprland" 8 hypr_option decoration:rounding
expect "the theme border and radius hold no configuration error" '[]' config_errors
set_theme_switches false false false
expect "the shell reloads the probe theme switches off" ok ipc shell reloadConfig
expect_poll "the effective config has the probe theme switches off" '{"setCornerRadius": false, "setWindowAnimations": false, "setWindowBorders": false}' theme_switches
# Control run on 2026-09-29: a source_tree copy of the shell whose
# HyprlandLayer.js forced borders and radius enabled after these switches
# failed the two restore rows below, reading 4 and 8 instead of 1 and 0.
expect_poll "turning the border switch off removes the border size line" no layer_matches '^[[:space:]]*border_size ='
expect_poll "turning the radius switch off removes the window rounding line" no layer_matches '^[[:space:]]*rounding ='
expect_poll "turning the border switch off leaves Hyprland's own border size" "$border_before" hypr_option general:border_size
expect_poll "turning the radius switch off leaves Hyprland's own rounding" "$radius_before" hypr_option decoration:rounding
expect "the switched-off theme appearance holds no configuration error" '[]' config_errors
set_theme_switches false false true
expect "the shell reloads the probe motion switch on" ok ipc shell reloadConfig
expect_poll "the effective config has the probe motion switch on" '{"setCornerRadius": false, "setWindowAnimations": true, "setWindowBorders": false}' theme_switches
expect_poll "turning the motion switch on writes the VGS snappy curve" yes animation_curve vgsSnappy
expect_poll "turning the motion switch on writes the windows preset" '{"bezier": "vgsSnappy", "enabled": true, "overridden": true, "speed": 1.8, "style": ""}' animation_leaf windows
expect "the motion preset holds no configuration error" '[]' config_errors
expect "vgs applies under the motion switch for the smooth preset" "ok theme=vgs" applied vgs
expect_poll "the default smooth preset writes its curve" yes animation_curve vgsEaseOutQuint
expect_poll "the default smooth preset writes the windows leaf" '{"bezier": "vgsEaseOutQuint", "enabled": true, "overridden": true, "speed": 3.79, "style": ""}' animation_leaf windows
expect "the smooth preset holds no configuration error" '[]' config_errors
set_theme_switches false false false
expect "the shell reloads the probe motion switch off" ok ipc shell reloadConfig
expect_poll "turning the motion switch off removes the windows animation line" no layer_matches '^hl\.animation\(\{ leaf = "windows"'
expect_poll "turning the motion switch off restores the windows animation leaf" "$motion_before" animation_leaf windows
cp -- "$sandbox/shell-before-appearance.json" "$user_config.next" && mv -T -- "$user_config.next" "$user_config"
expect "the shell reloads the restored theme settings" ok ipc shell reloadConfig
expect "vgs applies after the Hyprland appearance probe" "ok theme=vgs" applied vgs
rm -rf -- "$probe_theme"

# The floating TUIs' window rules: a window of each class floats, at its
# class's size, centred on the work area.
for tui in "org.vgs.tui 875x600" "org.vgs.tui.wide 1200x720" "org.vgs.tui.tall 875x900"; do
  read -r tui_class tui_want <<<"$tui"
  if open_tui "$tui_class"; then
    expect_poll "a $tui_class window floats" "$tui_class floating=true" tui_floating "$tui_pid"
    geometry expect_poll "a $tui_class window is $tui_want" "$tui_want" tui_size "$tui_pid"
    geometry expect_poll "a $tui_class window is centred on the work area" centred tui_centred "$tui_pid"
    close_tui "the $tui_class helper exits 0 on SIGTERM"
    expect_poll "the $tui_class window is gone" clients=0 tui_floating "$tui_pid"
  else
    fail "the toplevel helper maps a $tui_class window"
  fi
done
# A rule disabled by name after the line stops floating its class alone.
printf '%s\n' 'hl.window_rule({ name = "vgs:tui", enabled = false })' >>"$hypr_lua"
expect "the nested instance reloads with vgs:tui disabled" ok hypr reload config-only
expect "disabling a window rule by name holds no configuration error" '[]' config_errors
for tui in "org.vgs.tui false" "org.vgs.tui.wide true"; do
  read -r tui_class tui_want <<<"$tui"
  if open_tui "$tui_class"; then
    expect_poll "with vgs:tui disabled a $tui_class window has floating=$tui_want" "$tui_class floating=$tui_want" tui_floating "$tui_pid"
    close_tui "the $tui_class helper exits 0 on SIGTERM with vgs:tui disabled"
  else
    fail "the toplevel helper maps a $tui_class window with vgs:tui disabled"
  fi
done
restore_hypr_lua || fail "hyprland.lua is put back after the floating TUI rows"
expect "the nested instance reloads the first run's hyprland.lua after the floating TUI rows" ok hypr reload config-only
expect "the vgs package applies for the Hyprland rows" "ok theme=vgs" applied vgs
if vgs_accent="$(resolved_token vgs palette.accent)"; then
  expect_poll "the nested active border takes the vgs accent" "$(gradient_of "$vgs_accent")" hypr_gradient general:col.active_border
else
  fail "the judge resolves palette.accent for the vgs package"
fi

# Enabled plugins' sections. shell.json is kept first, so the row can put
# it back with both plugins disabled.
cp -- "$user_config" "$sandbox/shell-before-hyprland.json"
expect "enabling the launcher for the Hyprland rows is allowed" ok ipc shell setPluginEnabled vgs.launcher true
expect "enabling the notifications for the Hyprland rows is allowed" ok ipc shell setPluginEnabled vgs.notifications true
expect_poll "both plugins' binds reach the nested instance" "$both_binds" vgs_binds
expect "the launcher's section names its id and version" yes layer_has "$(section_of vgs.launcher)"
expect "the notifications' section names its id and version" yes layer_has "$(section_of vgs.notifications)"
expect "the launcher's blur rule is written" yes layer_has 'hl.layer_rule({ name = "vgs.launcher:overlay", match = { namespace = "^vgs:overlay$" }, blur = true, ignore_alpha = 0.6 })'
expect "the notifications' blur rule is written" yes layer_has 'hl.layer_rule({ name = "vgs.notifications:layer", match = { namespace = "^vgs:layer$" }, blur = true, ignore_alpha = 0.6 })'
expect "the configuration with both sections holds no error" '[]' config_errors
expect "no plugin reports a Hyprland problem" '[]' hypr_problems

# Each bind reaches its plugin. wtype types on a virtual keyboard with
# keycodes of its own, which a bind resolves only by keysym, so the sandbox
# user's settings after the line turn that on
# (docs/architecture/runtime-hyprland.md).
printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = true } })' >>"$hypr_lua"
expect "the nested instance reloads with binds resolved by keysym" ok hypr reload config-only
expect "no launcher surface shows before SUPER+SPACE" 0 layer_count vgs:overlay
press_super space || fail "typing SUPER+SPACE failed"
expect_poll "SUPER+SPACE opens the launcher" 1 layer_count vgs:overlay
press_super space || fail "typing SUPER+SPACE again failed"
expect_poll "SUPER+SPACE closes the launcher again" 0 layer_count vgs:overlay
expect "the inbox is closed before SUPER+N" '""' inbox_mode
press_super n || fail "typing SUPER+N failed"
expect_poll "SUPER+N opens the inbox" '"inbox"' inbox_mode
press_super n || fail "typing SUPER+N again failed"
expect_poll "SUPER+N closes the inbox again" '""' inbox_mode

# A rebind, an unbind and a name no bind declares, in shell.json.
set_keys '{"vgs.launcher": {"toggle": "super+alt+space", "nope": "SUPER+F9"}, "vgs.notifications": {"inbox": null}}'
expect_poll "a shell.json rebind and unbind reach the nested instance" "$rebound" vgs_binds
expect "the unbound shortcut is a comment in the layer" yes layer_has "-- unbound vgs.notifications:inbox: shell.json sets its key to null"
expect "listPlugins reports the key name no bind declares" '["hyprland: shell.json keys.nope names no bind of vgs.launcher"]' hypr_problems

# One key for two plugins: the first by id keeps it.
set_keys '{"vgs.launcher": {"toggle": "SUPER+ALT+SPACE"}, "vgs.notifications": {"inbox": "ALT+SUPER+SPACE"}}'
expect_poll "listPlugins reports the key the later plugin lost" '["hyprland: SUPER+ALT+SPACE for vgs.notifications:inbox skipped: already bound by vgs.launcher"]' hypr_problems
expect "the lost bind is a skipped comment in the layer" yes layer_has "-- skipped SUPER+ALT+SPACE: already bound by vgs.launcher"
expect_poll "the nested instance binds the key to the first plugin alone" "$rebound" vgs_binds

# A disabled plugin's section leaves the layer.
expect "disabling the notifications for the Hyprland rows is allowed" ok ipc shell setPluginEnabled vgs.notifications false
expect_poll "a disabled plugin's section leaves the layer" no layer_has "$(section_of vgs.notifications)"
expect "the enabled plugin's section stays" yes layer_has "$(section_of vgs.launcher)"
expect_poll "the disabled plugin's conflict is no longer reported" '[]' hypr_problems

# The border colours follow a theme apply.
if light_accent="$(resolved_token light palette.accent)"; then
  expect "the light package applies" "ok theme=light" applied light
  expect_poll "the nested active border follows the light accent" "$(gradient_of "$light_accent")" hypr_gradient general:col.active_border
  expect "vgs applies again" "ok theme=vgs" applied vgs
  expect_poll "the nested active border follows the vgs accent again" "$(gradient_of "$vgs_accent")" hypr_gradient general:col.active_border
else
  fail "the judge resolves palette.accent for the light package"
fi

# The runner's verbs: render writes a removed layer again, and the line is
# what loads the layer.
rm -- "$hypr_layer"
expect "vgsh hypr render is answered ok" ok vgsh_run hypr render
expect_poll "render writes the removed layer again" yes layer_has "$(section_of vgs.launcher)"
expect "vgsh hypr unwire removes the line" "ok hypr=unwired path=$hypr_lua" vgsh_run hypr unwire
expect "the nested instance reloads without the line" ok hypr reload config-only
expect_poll "without the line the nested instance holds no vgs bind" '[]' vgs_binds
expect "vgsh hypr wire keeps the line again" "ok hypr=wired path=$hypr_lua" vgsh_run hypr wire
expect "the line is first again" "$wire_line" head -n 1 -- "$hypr_lua"
expect "the nested instance reloads with the line" ok hypr reload config-only
expect_poll "with the line the launcher's bind is back" "$rebound" vgs_binds

# Leave the sandbox as the row found it: shell.json as before the row, which
# disables both plugins again, and hyprland.lua as the first run left it.
cp -- "$sandbox/shell-before-hyprland.json" "$user_config.next" && mv -T -- "$user_config.next" "$user_config"
expect_poll "the launcher is disabled again" False plugin_enabled vgs.launcher
expect_poll "the notifications are disabled again" False plugin_enabled vgs.notifications
restore_hypr_lua || fail "hyprland.lua is put back after the Hyprland rows"
expect "the nested instance reloads the first run's hyprland.lua" ok hypr reload config-only
expect_poll "the nested instance holds no vgs bind after the Hyprland rows" '[]' vgs_binds
expect "the configuration after the Hyprland rows holds no error" '[]' config_errors
