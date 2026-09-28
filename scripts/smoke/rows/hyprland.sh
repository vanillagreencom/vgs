# The Hyprland layer, shell/Core/HyprlandLayer.qml: the Lua file the shell
# writes from the theme's border colours and every enabled plugin's
# `hyprland` manifest data, the line `vgsh hypr wire` keeps first in
# hyprland.lua, and the `hyprctl reload` after each write. The harness's
# hyprland.lua existed when the shell first started, so the first write
# wired it. Every row reads the nested instance back through hyprctl. The
# launcher's and the notifications' own rows ran before this one, so it
# enables both, types their keys on the nested seat, and leaves both
# disabled, shell.json as it found it and hyprland.lua as the first run left
# it.
#
# Hyprland v0.56.2 reads no layer rule back (docs/architecture/runtime.md
# § Hyprland), so the rows hold the rules through the written file and an
# empty configerrors, where Hyprland lists a field it refuses.
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
layer_has() { if grep -qxF -- "$1" "$hypr_layer"; then echo yes; else echo no; fi; }
section_of() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print("-- " + m["id"] + " " + m["version"] + ": binds and layer rules from its manifest")' "$repo/shell/plugins/$1/manifest.json"; }
# How many plugin sections the layer holds. grep -c exits 1 on a count of
# 0, which is an answer, and 2 on a file it cannot read, which is not.
section_count() { local status=0; grep -c -- ': binds and layer rules from its manifest$' "$hypr_layer" || status=$?; [[ $status -le 1 ]]; }
# listPlugins' Hyprland problems, sorted.
hypr_problems() { ipc shell listPlugins | python3 -c 'import json,sys; print(json.dumps(sorted(e["error"] for e in json.load(sys.stdin)["errors"] if e["error"].startswith("hyprland: "))))'; }
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
both_binds='[[64, "N", "__lua", "vgs.notifications:inbox"], [64, "SPACE", "__lua", "vgs.launcher:toggle"]]'
rebound='[[72, "SPACE", "__lua", "vgs.launcher:toggle"]]'

# The first run.
expect "the first run wired the loading line first in the sandbox's hyprland.lua" "$wire_line" head -n 1 -- "$hypr_lua"
expect "the first run changed nothing else in hyprland.lua" same bash -c 'tail -n +2 -- "$1" | cmp -s - "$2" && echo same' _ "$hypr_lua" "$sandbox/hyprland-harness.lua"
expect "the layer's header names the command that writes it again" yes bash -c 'grep -qF -- "\`vgsh hypr render\`" "$1" && echo yes' _ "$hypr_layer"
expect "no plugin declaring Hyprland data is enabled, so no section is written" 0 section_count
expect_poll "the nested instance holds no vgs bind" '[]' vgs_binds
expect "the nested configuration holds no error" '[]' config_errors
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
# user's settings after the line turn that on (docs/architecture/runtime.md
# § Hyprland).
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
{ printf '%s\n' "$wire_line"; cat -- "$sandbox/hyprland-harness.lua"; } >"$hypr_lua.next" && mv -T -- "$hypr_lua.next" "$hypr_lua"
expect "the nested instance reloads the first run's hyprland.lua" ok hypr reload config-only
expect_poll "the nested instance holds no vgs bind after the Hyprland rows" '[]' vgs_binds
expect "the configuration after the Hyprland rows holds no error" '[]' config_errors
