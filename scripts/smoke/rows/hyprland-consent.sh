# The first write of the Hyprland layer asks before wiring hyprland.lua.
# This row runs first, while the harness file still lacks the loading line.
set -euo pipefail

hypr_lua="$home/.config/hypr/hyprland.lua"
hypr_layer="$home/.local/state/vgs/hypr/vgs.lua"
wire_line="pcall(dofile, \"$hypr_layer\")"

wire_count() { grep -cxF -- "$wire_line" "$hypr_lua" || true; }
tail_matches_harness() { tail -n +2 -- "$hypr_lua" | cmp -s - "$sandbox/hyprland-harness.lua" && echo same || echo differs; }
config_errors() { hypr -j configerrors | py_reply 'import json,sys; print(json.dumps([e for e in json.load(sys.stdin) if e]))'; }

expect "the harness starts without the VGS loading line" 0 wire_count
expect_poll "the Hyprland consent notice is recorded" '{"title": "Let VGS manage its Hyprland settings?", "command": "vgsh hypr wire", "failure": ""}' hypr_consent_record
expect_poll "the Hyprland consent notice maps" 1 layer_count vgs:notice
expect_poll "the Hyprland consent notice holds the keyboard" true ipc smoke noticeFocused
expect_poll "the Hyprland consent dialog draws Connect, Not now and the closed command disclosure" '{"title":"Let VGS manage its Hyprland settings?","message":"One line at the top of hyprland.lua loads the keys, border colours and blur rules VGS generates. Your own settings after it still win.","rows":[],"command":{"toggle":"Show command","expanded":false,"text":"vgsh hypr wire"},"focused":"Connect","actions":["Connect","Not now"],"busy":false}' ipc smoke noticeDrawn
type_keys -k Return || fail "sending Return to the Hyprland consent notice failed"
expect_poll "Connect reaches the wired consent state" wired hypr_consent_phase
expect_poll "Connect closes the Hyprland consent notice" null hypr_consent_record
expect_poll "Connect adds the loading line exactly once" 1 wire_count
expect_poll "Connect keeps the loading line first" "$wire_line" head -n 1 -- "$hypr_lua"
expect_poll "Connect changes no other hyprland.lua byte" same tail_matches_harness
expect_poll "Hyprland reloads the consent-wired layer without config errors" '[]' config_errors
