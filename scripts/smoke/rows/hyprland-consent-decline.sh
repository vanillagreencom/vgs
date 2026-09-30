# Not now records a marker for this Hyprland session. A restart in the same
# compositor session does not ask again, and a control copy that ignores
# the marker does ask.
set -euo pipefail

hypr_lua="$home/.config/hypr/hyprland.lua"
hypr_layer="$home/.local/state/vgs/hypr/vgs.lua"
marker="$rt_dir/vgs/hypr/consent-declined"
wire_line="pcall(dofile, \"$hypr_layer\")"
vgsh_run() { "${shell_env[@]}" "$repo/bin/vgsh" "$@"; }
wire_count() { grep -cxF -- "$wire_line" "$hypr_lua" || true; }
tail_matches_harness() { tail -n +2 -- "$hypr_lua" | cmp -s - "$sandbox/hyprland-harness.lua" && echo same || echo differs; }
marker_content() { cat -- "$marker" 2>/dev/null || true; }
prepare_unwired_start() { vgsh_run hypr unwire >/dev/null; }

prepare_unwired_start
if stop_shell && start_shell "$repo" "$sandbox/hypr-consent-decline.log"; then
  ok "the real shell restarts for the consent decline row"
fi
expect_poll "the restarted shell asks before wiring an unchanged layer" '{"title": "Let VGS manage its Hyprland settings?", "command": "vgsh hypr wire", "failure": ""}' hypr_consent_record
type_keys -k Escape || fail "sending Escape to the Hyprland consent notice failed"
expect_poll "Not now reaches the declined consent state" declined hypr_consent_phase
expect_poll "Not now closes the Hyprland consent notice" null hypr_consent_record
expect_poll "Not now leaves hyprland.lua unwired" 0 wire_count
expect_poll "Not now writes this Hyprland session's marker" "$signature" marker_content
expect "a forced render after Not now is accepted" ok vgsh_run hypr render
expect_poll "the forced render leaves hyprland.lua unwired" 0 wire_count
expect "a rescan after Not now is accepted" ok ipc shell rescanPlugins
expect_poll "the rescan after Not now keeps the declined consent state" declined hypr_consent_phase
expect "the rescan after Not now raises no consent notice" null hypr_consent_record

if stop_shell && start_shell "$repo" "$sandbox/hypr-consent-decline-restart.log"; then
  ok "the real shell restarts with the decline marker"
fi
expect_poll "the restart with the marker scans plugins" true ipc shell guarded
expect_poll "the restart with the marker reaches the declined consent state" declined hypr_consent_phase
expect "the restart with the marker raises no consent notice" null hypr_consent_record
expect "the restart with the marker leaves hyprland.lua unwired" 0 wire_count

mutant="$sandbox/hypr-consent-mutant"
mkdir -p -- "$mutant"
cp -R -- "$repo/shell" "$mutant/shell"
cp -R -- "$repo/bin" "$mutant/bin"
for dir in config themes; do ln -s -- "$repo/$dir" "$mutant/$dir"; done
for file in VERSION LICENSE README.md; do cp -- "$repo/$file" "$mutant/$file"; done
layer_qml="$mutant/shell/Core/HyprlandLayer.qml"
if python3 - "$layer_qml" <<'PY'
import sys
path = sys.argv[1]
old = '            root.feed({ type: "declineChecked", declined: failure === "" && text === root.hyprlandSignature, failure: failure });\n'
text = open(path).read()
if text.count(old) != 1:
    sys.exit("marker check occurs %d times" % text.count(old))
open(path, "w").write(text.replace(old, '            root.feed({ type: "declineChecked", declined: false, failure: failure });\n'))
PY
then ok "the decline control copy ignores the marker by reporting it absent"; else fail "the decline control copy could not change the marker check"; fi

if stop_shell && start_shell "$mutant" "$sandbox/hypr-consent-mutant.log"; then
  ok "the decline control copy starts"
fi
expect_poll "control: ignoring the marker reaches the asking consent state" asking hypr_consent_phase
expect_poll "control: ignoring the marker asks again after restart" '{"title": "Let VGS manage its Hyprland settings?", "command": "vgsh hypr wire", "failure": ""}' hypr_consent_record

printf '%s\n' "other-session" >"$marker"
if stop_shell && start_shell "$repo" "$sandbox/hypr-consent-other-session.log"; then
  ok "the real shell restarts with another session's marker"
fi
expect_poll "a marker from another Hyprland session is ignored" asking hypr_consent_phase
expect_poll "a marker from another Hyprland session asks again" '{"title": "Let VGS manage its Hyprland settings?", "command": "vgsh hypr wire", "failure": ""}' hypr_consent_record

rm -f -- "$marker"
if stop_shell && start_shell "$repo" "$sandbox/hypr-consent-final.log"; then
  ok "the real shell restarts after the decline control"
fi
expect_poll "the real shell asks again after the marker is removed" '{"title": "Let VGS manage its Hyprland settings?", "command": "vgsh hypr wire", "failure": ""}' hypr_consent_record
type_keys -k Return || fail "sending Return to the final Hyprland consent notice failed"
expect_poll "the final Connect reaches the wired consent state" wired hypr_consent_phase
expect_poll "the final Connect closes the Hyprland consent notice" null hypr_consent_record
expect_poll "the final Connect adds the loading line exactly once" 1 wire_count
expect_poll "the final Connect keeps the loading line first" "$wire_line" head -n 1 -- "$hypr_lua"
expect_poll "the final Connect changes no other hyprland.lua byte" same tail_matches_harness
