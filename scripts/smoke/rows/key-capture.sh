# Key capture, D086. The Settings window's Keys row takes a key combo by
# its keys. Tab presses on the nested seat reach the Settings shortcut's
# field, which shows its focus ring; Return starts a capture, which puts
# the nested Hyprland in the vgs:passthrough submap; and SUPER+SPACE,
# CTRL+ALT+T and F5, each held by a harness user bind that touches a
# marker, reach the field instead of the bind. Each capture stores the
# string the field's text entry stores when the same keys are typed into
# it, the submap is left once it commits, and the field names the
# Launcher shortcut and the user bind holding SUPER+SPACE. A captured
# SUPER+T names the Themes plugin, whose shortcut asks for the same key,
# and the field's Unbind button, clicked, stores null. The control starts a tree whose key capture owner
# sends no enter: Hyprland stays in its default map, the user bind takes
# SUPER+SPACE, its marker appears and the stored key stays. Every key goes
# to the nested instance alone, through wtype on its seat, and the row
# puts the harness hyprland.lua back at its end.
# No latency is measured; each reading polls every 200 ms for up to 5 s.
set -euo pipefail

kc_hypr_lua="$home/.config/hypr/hyprland.lua"
# The click helper's monitor size, as rows/bar.sh reads it.
read -r mon_w mon_h < <(hypr -j monitors | py_reply 'import json,sys; m=json.load(sys.stdin)[0]; print(m["width"], m["height"])')
kc_marker() { [[ -f $1 ]] && echo 1 || echo 0; }
kc_open() {
  expect "$1: enabling Settings is allowed" ok ipc shell setPluginEnabled vgs.settings true
  expect_poll "$1: the Settings service is built" True record_exists vgs.settings
  expect "$1: Settings is summoned on its own page" ok ipc shell summon window vgs.settings '{"plugin":"vgs.settings"}'
  expect_poll "$1: the Settings window shows its own page" '"vgs.settings"' ipc smoke readInstance window vgs.settings page
  expect_poll "$1: the Settings window has the keyboard" "[\"$shell_class\", \"Settings\"]" active_window
}

# CAPTURE LABEL WANT MARKER WTYPE_ARGS...: a capture of the keys
# WTYPE_ARGS types, started by Return on the focused field.
kc_capture() {
  local label="$1" want="$2" marker="$3"
  shift 3
  rm -f -- "$marker"
  type_keys -k Return || fail "$label: Return on the field failed"
  expect_poll "$label: Return starts a capture" true key_field capturing
  expect_poll "$label: the capture enters the pass-through submap" vgs:passthrough key_submap
  type_keys "$@" || fail "$label: typing the combo failed"
  expect_poll "$label: the captured key is stored" "\"$want\"" settings_key
  expect_poll "$label: the commit leaves the pass-through submap" default key_submap
  expect "$label: the user bind on the same keys did not fire" 0 kc_marker "$marker"
}
# TYPED LABEL TEXT WANT: the same key typed into the field's text entry.
kc_typed() {
  local label="$1"
  key_reset "$label"
  expect "$label: the field's text entry opens" typing ipc smoke invokeInstance window vgs.settings typeKeyField "$key_field_arg"
  type_keys "$2" || fail "$label: typing the text failed"
  type_keys -k Return || fail "$label: Return in the text entry failed"
  expect_poll "$label: the typed key is stored as the captured one" "\"$3\"" settings_key
  expect_poll "$label: the field holds the keyboard again" true key_field focus
}

hypr_lua_save key-capture
{
  printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = true } })'
  printf '%s\n' "hl.bind(\"SUPER + SPACE\", hl.dsp.exec_cmd(\"touch $sandbox/key-capture-space\"), { description = \"Smoke capture space\" })"
  printf '%s\n' "hl.bind(\"CTRL + ALT + T\", hl.dsp.exec_cmd(\"touch $sandbox/key-capture-t\"), { description = \"Smoke capture t\" })"
  printf '%s\n' "hl.bind(\"F5\", hl.dsp.exec_cmd(\"touch $sandbox/key-capture-f5\"), { description = \"Smoke capture f5\" })"
} >>"$kc_hypr_lua"
expect "the nested instance reloads with the key capture harness binds" ok hypr reload config-only
kc_config_errors() { hypr -j configerrors | py_reply 'import json,sys; print(json.dumps([e for e in json.load(sys.stdin) if e]))'; }
expect_poll "the nested instance holds no configuration error" '[]' kc_config_errors

expect "enabling Launcher, whose shortcut asks for SUPER+SPACE, is allowed" ok ipc shell setPluginEnabled vgs.launcher true
kc_open "key capture"
key_reset "key capture start"
for _ in $(seq 1 60); do
  [[ $(key_field focus) == true ]] && break
  type_keys -k Tab || { fail "key capture: Tab failed"; break; }
done
expect "Tab presses reach the Keys row's field" true key_field focus
expect "the field shows its focus ring for the Tab focus" true key_field visualFocus

kc_capture "SUPER+SPACE" SUPER+SPACE "$sandbox/key-capture-space" -M logo -k space -m logo
expect_poll "the field names the Launcher shortcut and the user bind holding SUPER+SPACE" '"Also used by Launcher (toggle), your other shortcuts."' key_field conflict
kc_typed "SUPER+SPACE typed" "super+space" SUPER+SPACE
kc_capture "CTRL+ALT+T" CTRL+ALT+T "$sandbox/key-capture-t" -M ctrl -M alt -k t -m alt -m ctrl
kc_typed "CTRL+ALT+T typed" "ctrl+alt+t" CTRL+ALT+T
kc_capture "F5" F5 "$sandbox/key-capture-f5" -k F5
kc_typed "F5 typed" "F5" F5

expect "enabling Themes, whose shortcut asks for SUPER+T, is allowed" ok ipc shell setPluginEnabled vgs.themes true
kc_capture "SUPER+T" SUPER+T "$sandbox/key-capture-none" -M logo -k t -m logo
expect_poll "the field names the Themes shortcut asking for SUPER+T" '"Also used by Themes (themes)."' key_field conflict
kc_reveal_unbind() { local at; at="$(ipc smoke revealText window vgs.settings IconButton Unbind)" || return; [[ $at != absent ]] && echo shown || echo absent; }
expect "the Unbind button is scrolled into view" shown kc_reveal_unbind
click_in window:Settings window vgs.settings IconButton Unbind || fail "the click on the field's Unbind button failed"
expect_poll "the Unbind button stores null for the shortcut" null settings_key
key_reset "key capture end"

# The control: no enter request. The user bind takes the keys.
if copy_tree key-capture-no-enter && edit_tree key-capture-no-enter shell/Core/KeyCapture.qml 'const answer = Compositor.passthrough("enter", reply => root.entered(at, reply));' 'const answer = "ok";'; then
  stop_shell
  start_shell "$sandbox/tree-key-capture-no-enter" "$sandbox/key-capture-no-enter.log" || fail "the no-enter control shell starts"
  kc_open "control no-enter"
  expect "control no-enter: the field takes the focus" focused ipc smoke invokeInstance window vgs.settings focusKeyField "$key_field_arg"
  rm -f -- "$sandbox/key-capture-space"
  type_keys -k Return || fail "control no-enter: Return on the field failed"
  expect_poll "control no-enter: Return starts a capture" true key_field capturing
  expect "control no-enter: Hyprland stays in its default map" default key_submap
  type_keys -M logo -k space -m logo || fail "control no-enter: typing SUPER+SPACE failed"
  expect_poll "control no-enter: the user bind takes SUPER+SPACE" 1 kc_marker "$sandbox/key-capture-space"
  expect "control no-enter: the field stores no key" absent settings_key
  type_keys -k Escape || fail "control no-enter: Escape failed"
  expect_poll "control no-enter: Escape ends the capture" false key_field capturing
  stop_shell
  start_shell "$repo" "$sandbox/key-capture-restart.log" || fail "the shell starts again after the key capture control"
fi
hypr_lua_restore key-capture || fail "key capture puts the harness hyprland.lua back"
expect "the nested instance reloads the harness hyprland.lua" ok hypr reload config-only
