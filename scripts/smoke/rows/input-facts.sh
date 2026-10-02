# Input facts from the actual core capabilities in the nested compositor.
# XKB resolution reads the nested main keyboard under US and German. Target
# observations read application windows, shell panels and passive overlays.
# No key, click, TUI, authentication or network operation is sent. The layer
# controls drop the layer reply and suppress host keyboard-focus records
# only inside a disposable fixture. The same protection assertions must
# fail once. Polls use expect_poll's 200 ms interval;
# no latency or resource budget is measured here.
set -euo pipefail

input_facts_config="$home/.config/vgs/shell.json"
input_facts_lua="$home/.config/hypr/hyprland.lua"
cp -- "$input_facts_config" "$sandbox/input-facts-config-before.json"
cp -- "$input_facts_lua" "$sandbox/input-facts-lua-before"
for input_facts_id in acme.input-facts acme.surfaces acme.layers; do
  mkdir -p "$home/.config/vgs/plugins/$input_facts_id"
  cp -R "$repo/scripts/smoke/fixtures/plugins/$input_facts_id/." "$home/.config/vgs/plugins/$input_facts_id/"
done
mkdir -p "$home/.local/share/applications"
cat >"$home/.local/share/applications/smoke.input-facts.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Nested input facts
Exec=true
StartupWMClass=smoke.input-facts
Categories=Utility;
DESKTOP
expect "the input facts fixtures are discovered" ok ipc shell rescanPlugins
expect_poll "the input facts fixture is known" True plugin_known acme.input-facts
expect "the input facts fixture enables" ok ipc shell setPluginEnabled acme.input-facts true
expect_poll "the input facts service builds" True record_exists acme.input-facts

input_facts_read() { ipc smoke readInstance service acme.input-facts "$1"; }
input_facts_keys() {
  local before
  before="$(input_facts_read keyAnswers)" || return 1
  # Quickshell's CLI parser expands bracketed argv into multiple arguments.
  # JSON whitespace keeps the key list in one string for the fixture.
  expect "the core accepts a layout resolution request" ok ipc acme.input-facts invoke keys " $1"
  expect_poll "the core completes the layout resolution" "$((before + 1))" input_facts_read keyAnswers
}
input_facts_observe() {
  local before
  before="$(input_facts_read observationAnswers)" || return 1
  expect "the core accepts an input observation" ok ipc acme.input-facts invoke "${2:-observe}" "$1"
  expect_poll "the core completes the input observation" "$((before + 1))" input_facts_read observationAnswers
}
input_facts_result() {
  input_facts_read observation | py_reply 'import json,sys
d=json.load(sys.stdin)
print("pending" if d is None else json.dumps(d.get(sys.argv[1]), separators=(",", ":")))' "$1"
}
input_facts_key_codes() {
  input_facts_read keys | py_reply 'import json,sys
d=json.load(sys.stdin)
print(json.dumps([[k["modifiers"],k["keycode"],k["keysym"]] for k in d[sys.argv[1]]], separators=(",", ":")) if d and d.get("ok") else json.dumps(d))' "${1:-keys}"
}
input_facts_main_layout() {
  hypr -j devices | py_reply 'import json,sys
ks=[k for k in json.load(sys.stdin)["keyboards"] if k["main"]]
print(ks[0]["active_keymap"] if len(ks)==1 else "main="+str(len(ks)))'
}
input_facts_target_kind() {
  input_facts_read observation | py_reply 'import json,sys
d=json.load(sys.stdin)
print(d["target"]["kind"] if d and d.get("ok") else json.dumps(d))'
}
input_facts_point() {
  surface_box "$1" | py_reply 'import json,sys
x,y,w,h=json.load(sys.stdin); print(json.dumps({"x":int(x+w/2),"y":int(y+h/2)},separators=(",", ":")))'
}
input_facts_client_point() {
  hypr -j clients | py_reply 'import json,sys
c=next(c for c in json.load(sys.stdin) if c["address"]==sys.argv[1]); x,y=c["at"]; w,h=c["size"]
print(json.dumps({"x":int(x+w/2),"y":int(y+h/2)},separators=(",", ":")))' "$1"
}
input_facts_keyboard_protected() {
  expect "an interactive VGS layer protects keyboard input over an external active window" \
    '{"kind":"vgs","id":"keyboard"}' input_facts_result target
}

printf '%s\n' 'hl.config({ input = { kb_layout = "us,de", kb_variant = "", kb_options = "" } })' >>"$input_facts_lua"
expect "the nested keyboard uses the fixture layouts" ok hypr reload config-only
expect "the nested keyboard switches to US" ok hypr switchxkblayout all 0
expect_poll "the main keyboard reports US" 'English (US)' input_facts_main_layout
input_facts_keys '["SUPER+Y","SUPER+code:29","SUPER+RETURN","SUPER+code:36"]'
expect "US symbols and physical aliases have the same native key identity" \
  '[[["SUPER"],29,"y"],[["SUPER"],29,"y"],[["SUPER"],36,"Return"],[["SUPER"],36,"Return"]]' input_facts_key_codes
expect "the global translation map uses its first US group" \
  '[[["SUPER"],29,"y"],[["SUPER"],29,"y"],[["SUPER"],36,"Return"],[["SUPER"],36,"Return"]]' input_facts_key_codes translation
expect "the nested keyboard switches to German" ok hypr switchxkblayout all 1
expect_poll "the main keyboard reports German" German input_facts_main_layout
input_facts_keys '["SUPER+Y","SUPER+code:29","SUPER+RETURN","SUPER+code:36"]'
expect "German resolves the moved symbol and preserves Return's alias identity" \
  '[[["SUPER"],52,"y"],[["SUPER"],29,"z"],[["SUPER"],36,"Return"],[["SUPER"],36,"Return"]]' input_facts_key_codes
expect "the global translation map keeps group zero while the native keyboard uses German" \
  '[[["SUPER"],29,"y"],[["SUPER"],29,"y"],[["SUPER"],36,"Return"],[["SUPER"],36,"Return"]]' input_facts_key_codes translation

expect "the surfaces fixture enables its background for pointer protection" ok ipc shell setPluginEnabled acme.surfaces true
expect_poll "a VGS background is mapped below the external application" "$monitors" layer_count vgs:background
if open_toplevel "$sandbox/input-facts-known.log" smoke.input-facts "Input facts"; then
  input_facts_known_pid="$toplevel_pid"
  input_facts_known_address="$(toplevel_address "$input_facts_known_pid")" || exit 1
  expect_poll "the recognized external application holds keyboard focus" '["smoke.input-facts", "Input facts"]' active_window
  input_facts_observe null
  expect "the focused external application is classified by its desktop entry" application input_facts_target_kind
  input_facts_app_point="$(input_facts_client_point "$input_facts_known_address")" || exit 1
  input_facts_observe "$input_facts_app_point"
  expect "an application above VGS background remains a pointer target" application input_facts_target_kind

  expect "the passive overlay fixture enables for protection" ok ipc shell setPluginEnabled acme.layers true
  expect_poll "the passive overlay service builds for protection" True record_exists acme.layers
  expect "the passive fixture draws its overlay" ok layered draw
  expect_poll "the passive overlay is mapped for protection" "$monitors" layer_count vgs:layer
  input_facts_observe "$input_facts_app_point"
  expect "the whole passive overlay rectangle protects its pass-through area" vgs input_facts_target_kind

  cat >"$shim/hyprctl.input-no-layers" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ \${1:-} == --batch && \${2:-} == 'j/clients;j/activewindow;j/monitors;j/layers;j/cursorpos' ]]; then
  "$hyprctl_bin" "\$@" | python3 -c 'import json,sys; p=sys.stdin.read().strip().split("\\n\\n\\n"); assert len(p)==5; p[3]="{}"; print("\\n\\n\\n".join(p))'
else
  exec "$hyprctl_bin" "\$@"
fi
EOF
  chmod 755 "$shim/hyprctl.input-no-layers"
  shim_hyprctl input-no-layers
  input_facts_observe "$input_facts_app_point"
  (
    failures=0
    behaviour_failures=0
    expect "the same overlay assertion rejects a transport that dropped layer facts" vgs input_facts_target_kind
    printf 'control-failures=%s\n' "$failures"
  ) >"$sandbox/input-facts-layer-control.log"
  input_facts_control_failures="$(sed -n 's/^control-failures=//p' "$sandbox/input-facts-layer-control.log")" || exit 1
  expect "dropping observed layers makes the protection assertion fail once" 1 printf '%s' "$input_facts_control_failures"
  shim_hyprctl real
  expect "the passive fixture releases its overlay" ok layered undraw
  expect_poll "the released overlay leaves the compositor" 0 layer_count vgs:layer
  expect "the passive overlay fixture disables" ok ipc shell setPluginEnabled acme.layers false

  expect "the panel fixture enables for keyboard protection" ok ipc shell setPluginEnabled acme.surfaces true
  expect "an interactive shell panel opens for keyboard protection" ok ipc shell summon panel acme.surfaces '{}'
  expect_poll "the shell panel holds keyboard focus" true ipc smoke activeFocusIn panel acme.surfaces
  input_facts_observe null
  input_facts_keyboard_protected
  # Instrument only this disposable plugin. The shipping fixture keeps
  # the plugin import boundary, and the core has no test escape switch.
  input_facts_service="$home/.config/vgs/plugins/acme.input-facts/Service.qml"
  cp -- "$input_facts_service" "$sandbox/input-facts-service-before"
  expect "the input observer disables before its control is installed" ok ipc shell setPluginEnabled acme.input-facts false
  python3 - "$input_facts_service" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); assert not p.is_symlink()
s=p.read_text()
imports='import QtQuick\n'
assert s.count(imports)==1
changed=s.replace(imports, imports+'import qs.Core as InputFactsCore\n')
marker='readonly property bool hostFocusControl: false'
assert changed.count(marker)==1
changed=changed.replace(marker, 'readonly property bool hostFocusControl: true')
needle='        shell.ipc.handle("observe", text => {'
assert changed.count(needle)==1
handler='''        shell.ipc.handle("observe-without-host-focus", text => {
            const records = InputFactsCore.Compositor.inputSurfaces;
            InputFactsCore.Compositor.inputSurfaces = [];
            root.observation = null;
            root.shell.compositor.observeInput(JSON.parse(text), value => {
                InputFactsCore.Compositor.inputSurfaces = records;
                root.observation = value;
                root.observationAnswers += 1;
            });
            return "ok";
        });
'''
changed=changed.replace(needle, handler+needle)
assert changed!=s
p.write_text(changed)
PY
  expect "the sandbox discovers the instrumented input fixture" ok ipc shell rescanPlugins
  expect "the host-focus control observer enables" ok ipc shell setPluginEnabled acme.input-facts true
  expect_poll "the host-focus control observer builds" True record_exists acme.input-facts
  expect_poll "the observer loads the instrumented source revision" true input_facts_read hostFocusControl
  expect "the same shell panel retains keyboard focus during observer replacement" true ipc smoke activeFocusIn panel acme.surfaces
  input_facts_observe null observe-without-host-focus
  (
    failures=0
    behaviour_failures=0
    input_facts_keyboard_protected
    printf 'control-failures=%s\n' "$failures"
  ) >"$sandbox/input-facts-focus-control.log"
  input_facts_control_failures="$(sed -n 's/^control-failures=//p' "$sandbox/input-facts-focus-control.log")" || exit 1
  expect "omitting host keyboard-focus facts makes the same protection assertion fail once" 1 printf '%s' "$input_facts_control_failures"
  # The callback already restored the real host records. An observation
  # through the normal handler proves restoration before replacing bytes.
  input_facts_observe null
  input_facts_keyboard_protected
  expect "the host-focus control observer disables" ok ipc shell setPluginEnabled acme.input-facts false
  cp -- "$sandbox/input-facts-service-before" "$input_facts_service"
  expect "the sandbox discovers the restored input fixture" ok ipc shell rescanPlugins
  expect "the restored input observer enables" ok ipc shell setPluginEnabled acme.input-facts true
  expect_poll "the restored input observer builds" True record_exists acme.input-facts
  expect_poll "the observer loads the restored source revision" false input_facts_read hostFocusControl
  input_facts_panel_point="$(input_facts_point vgs:panel)" || exit 1
  input_facts_observe "$input_facts_panel_point"
  expect "an interactive VGS layer protects its control rectangle" vgs input_facts_target_kind
  expect "the interactive shell panel closes" ok ipc shell hide panel acme.surfaces
  expect_poll "the interactive shell panel leaves the compositor" 0 layer_count vgs:panel
  close_toplevel "$input_facts_known_pid" "the input facts application exits"
  input_facts_observe "$input_facts_app_point"
  expect "the same point protects the VGS background when no application covers it" vgs input_facts_target_kind
else
  fail "the recognized input facts application maps"
fi
expect "the surfaces fixture releases its background" ok ipc shell setPluginEnabled acme.surfaces false
expect_poll "the fixture background leaves the compositor" 0 layer_count vgs:background

if open_toplevel "$sandbox/input-facts-unknown.log" smoke.input-unknown "Unknown input target"; then
  input_facts_unknown_pid="$toplevel_pid"
  expect_poll "the unknown external window holds keyboard focus" '["smoke.input-unknown", "Unknown input target"]' active_window
  input_facts_observe null
  expect "the core refuses an unknown application instead of assuming text input is safe" '"refused: input=unknown-application"' input_facts_result error
  close_toplevel "$input_facts_unknown_pid" "the unknown input target exits"
else
  fail "the unknown input target maps"
fi

expect "the input facts fixture disables" ok ipc shell setPluginEnabled acme.input-facts false
cp -- "$sandbox/input-facts-config-before.json" "$input_facts_config.next"
mv -T -- "$input_facts_config.next" "$input_facts_config"
cp -- "$sandbox/input-facts-lua-before" "$input_facts_lua.next"
mv -T -- "$input_facts_lua.next" "$input_facts_lua"
expect "the input facts row restores shell configuration" ok ipc shell reloadConfig
expect "the input facts row restores keyboard configuration" ok hypr reload config-only
rm -- "$home/.local/share/applications/smoke.input-facts.desktop"
expect "the input facts row leaves no nested configuration errors" '[]' config_errors
