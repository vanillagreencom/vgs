# Application windows: the Settings window, vgs.settings' `window` kind,
# is a Hyprland window. app_window_rows (scripts/smoke/app-window.sh) reads
# it as every application window is read: one client of the shell's class
# titled Settings, floating, centred and focused, its border in the active
# and inactive colours, moved and focused by dispatches, and closed by an
# Escape it has the keyboard for, which the list page leaves to the window
# host, and by none it does not. The rows here add what Settings alone
# shows: the float comes from the Hyprland layer's `vgs:window` rule, which
# disabled tiles a new window; float toggles tile and float it while the
# helper keeps the keyboard, so a focus dispatch alone returns it; typed
# keys reach its search field and not the helper, then the helper and not
# the field; and a close through Hyprland closes it. The themes panel, a
# panel the host draws as a layer surface, is the control of the class,
# the border and the move: it is no client, its edge draws no border and a
# dispatch aimed at it moves nothing. The row enables the Settings plugin
# and leaves it disabled, hyprland.lua as it found it and no window open.
set -euo pipefail
windows_lua="$home/.config/hypr/hyprland.lua"
cp -- "$windows_lua" "$sandbox/hyprland-before-windows.lua"
restore_windows_lua() { cp -- "$sandbox/hyprland-before-windows.lua" "$windows_lua.next" && mv -T -- "$windows_lua.next" "$windows_lua"; }
# The titles of the shell process's clients, sorted.
shell_clients() { hypr -j clients | py_reply 'import json,sys; print(json.dumps(sorted(c["title"] for c in json.load(sys.stdin) if c["pid"] == int(sys.argv[1]))))' "$shell_qs_pid"; }
settings_search() { ipc smoke readDescendant window vgs.settings TextField text; }

expect "enabling the Settings plugin for the window rows is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect_poll "the Settings service is built for the window rows" True record_exists vgs.settings
expect "the IPC opens the Settings window" ok ipc shell summon window vgs.settings '{}'
app_window_rows Settings vgs.settings

# The float comes from the layer's rule: disabled by name after the line,
# the rule floats nothing and a new Settings window tiles.
printf '%s\n' 'hl.window_rule({ name = "vgs:window", enabled = false })' >>"$windows_lua"
expect "the nested instance reloads with vgs:window disabled" ok hypr reload config-only
expect "the IPC opens the Settings window with the rule disabled" ok ipc shell summon window vgs.settings '{}'
expect_poll "with vgs:window disabled the Settings window tiles" '[false]' window_of Settings floating
expect "hiding the tiled Settings window is allowed" ok ipc shell hide window vgs.settings
expect_poll "the tiled Settings window is gone" 0 window_count Settings
restore_windows_lua || fail "hyprland.lua is put back after the rule control"
expect "the nested instance reloads hyprland.lua after the rule control" ok hypr reload config-only

# Float toggles, the keyboard and a close through Hyprland, beside the
# toplevel helper. The pointer rests off every window, since under
# Hyprland's default follow_mouse a float toggle that tiles Settings under
# the pointer hands it the keyboard, so only the focus dispatch returns it.
# The shell must read the keyboard leaving Settings before that return:
# Qt's Wayland client can drop a return that lands in one batch with the
# reply to the leave's sync, leaving Settings with the keyboard and no
# focused item (docs/architecture/runtime-qml.md).
expect "the IPC opens the Settings window for the keyboard rows" ok ipc shell summon window vgs.settings '{}'
expect_poll "the Settings window is focused for the keyboard rows" "[\"$shell_class\", \"Settings\"]" active_window
rest_pointer || fail "moving the pointer off the Settings window failed"
if open_other "$sandbox/toplevel-windows.log"; then
  expect_poll "the new window takes the focus" '["smoke.other", "Other window"]' active_window
  expect_poll "the shell reads the Settings window without the keyboard" false ipc smoke activeFocusIn window vgs.settings
  leaves_before="$(other_events '^keyboard leave$')"
  if address="$(window_address Settings)" && [[ $address == 0x* ]]; then
    expect "a float toggle aimed at the window answers ok" ok hypr dispatch "hl.dsp.window.float({ action = \"toggle\", window = \"address:$address\" })"
    expect_poll "the float toggle tiles the window" '[false]' window_of Settings floating
    expect "a second float toggle answers ok" ok hypr dispatch "hl.dsp.window.float({ action = \"toggle\", window = \"address:$address\" })"
    expect_poll "the second float toggle floats it again" '[true]' window_of Settings floating
    expect "the other window keeps the keyboard through the float toggles" "$leaves_before" other_events '^keyboard leave$'
    other="$(other_address)"
    expect "a focus dispatch aimed at the Settings window answers ok" ok hypr dispatch "hl.dsp.focus({ window = \"address:$address\" })"
    expect_poll "the focus dispatch focused the Settings window" "[\"$shell_class\", \"Settings\"]" active_window

    # The keyboard goes to the focused window alone. With Settings
    # focused, typed letters reach its search field and the helper gets no
    # key; once the helper is focused, the next letter reaches the helper
    # and the field keeps its text.
    expect_poll "the Settings search field takes the keyboard" true ipc smoke activeFocusIn window vgs.settings
    keys_before="$(other_events '^key ')"
    type_keys zz || fail "typing into the Settings window failed"
    expect_poll "keys typed with Settings focused reach its search field" '"zz"' settings_search
    expect "keys typed with Settings focused never reach the other window" "$keys_before" other_events '^key '
    enters_before="$(other_events '^keyboard enter$')"
    expect "a focus dispatch gives the other window the keyboard" ok hypr dispatch "hl.dsp.focus({ window = \"address:$other\" })"
    expect_poll "the other window reports the keyboard entering it" "$((enters_before + 1))" other_events '^keyboard enter$'
    type_keys q || fail "typing into the other window failed"
    expect_poll "a key typed once the other window is focused reaches it" "$((keys_before + 2))" other_events '^key '
    expect "the Settings search field kept its text" '"zz"' settings_search
    expect "a focus dispatch gives Settings the keyboard back" ok hypr dispatch "hl.dsp.focus({ window = \"address:$address\" })"
    expect_poll "Settings is focused again" "[\"$shell_class\", \"Settings\"]" active_window
    type_keys -k BackSpace -k BackSpace || fail "clearing the Settings search failed"
    expect_poll "the Settings search field is empty again" '""' settings_search

    # A close through Hyprland, as its killactive key sends, closes the
    # window and the host drops the instance.
    expect "a close dispatch aimed at the window answers ok" ok hypr dispatch "hl.dsp.window.close({ window = \"address:$address\" })"
    expect_poll "the close dispatch closed the Settings window" 0 window_count Settings
    expect_poll "the host dropped the closed window's instance" absent ipc smoke readInstance window vgs.settings page
  else
    fail "the Settings window's address is unreadable: ${address:-}"
  fi
  close_other "the other window's helper exits 0 on SIGTERM"
else
  fail "the toplevel helper maps the other window"
fi

# Controls: the themes panel, a layer panel, opens beside a Settings
# window and is no client; under the same border as app_window_rows reads,
# its layer edge draws neither border colour, and a move aimed at its
# plugin's name reaches no window and leaves its layer where it was. The
# panel can hold the keyboard, which a newly mapped window then does not
# take, so it opens after the rows above.
expect "the IPC opens the Settings window beside the layer panel" ok ipc shell summon window vgs.settings '{}'
expect_poll "the Settings window maps beside the layer panel" 1 window_count Settings
expect "the themes panel, a layer panel, opens" ok ipc shell summon panel vgs.themes '{}'
expect_poll "the themes panel maps one layer surface" 1 layer_count vgs:panel
expect "the shell's only client is the Settings window, not the themes panel" '["Settings"]' shell_clients
expect "hiding the Settings window before the layer controls is allowed" ok ipc shell hide window vgs.settings
expect_poll "the Settings window is gone before the layer controls" 0 window_count Settings
window_border_on
panel_edge() {
  local box x y colour
  box="$(one_layer vgs:panel)" && [[ $box == \[* ]] || { echo "$box"; return; }
  read -r x y < <(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); print(b[0] - 2, b[1] + b[3] // 2)' "$box")
  colour="$(pixel "$x" "$y")" || { echo "$colour"; return; }
  no_border_colour "$colour"
}
render expect "the themes panel's layer edge draws no window border" none panel_edge
panel_before="$(layers_of vgs:panel)"
hypr dispatch 'hl.dsp.window.move({ x = 40, y = 30, relative = true, window = "title:^Themes$" })' >/dev/null || true
geometry expect "a move aimed at the themes panel moves no layer" "$panel_before" layers_of vgs:panel
window_border_off
expect "hiding the themes panel after the window rows is allowed" ok ipc shell hide panel vgs.themes
expect_poll "the themes panel's surface is gone after the window rows" 0 layer_count vgs:panel
restore_windows_lua || fail "hyprland.lua is put back after the window rows"
expect "the nested instance reloads hyprland.lua as the row found it" ok hypr reload config-only
expect "disabling the Settings plugin after the window rows is allowed" ok ipc shell setPluginEnabled vgs.settings false
