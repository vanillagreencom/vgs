# The Jarvis bar widget against private scripted Session ports: its
# section, every state read back as drawn, and privacy mute by a click on
# the widget and by the physical Mute key. No audio, account, provider or
# network runs; no PAM, polkit, keyring or TUI is reached. No latency
# ceiling is measured. Widget and state reads poll once per nested IPC
# round trip; fixture callback gates poll at 10 ms.
set -euo pipefail

jarvis_widget_config="$home/.config/vgs/shell.json"
jarvis_widget_lua="$home/.config/hypr/hyprland.lua"
jarvis_widget_dir="$repo/shell/plugins/vgs.jarvis"
jarvis_widget_gates="$sandbox/jarvis-widget-gates"
jarvis_widget_files=(Service.qml Widget.qml WidgetView.js backend/jarvisd.js)
cp -- "$jarvis_widget_config" "$sandbox/jarvis-widget-config-before.json"
cp -- "$jarvis_widget_lua" "$sandbox/jarvis-widget-lua-before"
for jarvis_widget_file in "${jarvis_widget_files[@]}"; do
  cp -- "$jarvis_widget_dir/$jarvis_widget_file" "$sandbox/jarvis-widget-before-${jarvis_widget_file##*/}"
done
jarvis_widget_key="$(bar_key)"
expect "the widget row starts with Jarvis disabled" absent ipc smoke jarvisProcess
expect "a disabled Jarvis draws no widget" absent ipc smoke readInstance "$jarvis_widget_key" vgs.jarvis moduleName
"$node_bin" "$source_repo/scripts/fixtures/jarvis/scripted.js" "$jarvis_widget_dir/backend/jarvisd.js" "$jarvis_widget_gates"
jarvis_gate="$sandbox/jarvis-widget-startup-gate"
jarvis_seen="$sandbox/jarvis-widget-startup-seen"
"$node_bin" "$source_repo/scripts/fixtures/jarvis/prepare.js" --gate-daemon "$jarvis_widget_dir/backend/jarvisd.js" "$jarvis_gate" "$jarvis_seen"
jarvis_rescan

jarvis_widget_gate() { : >"$jarvis_widget_gates/$1"; }
jarvis_widget_section() { ipc shell listShellConfig | py_reply 'import json,sys; l=json.load(sys.stdin)["bar"]["layout"]; print(([s for s in ("left","center","right") if any(e["id"]==sys.argv[1] for e in l.get(s,[]))] + ["none"])[0])' vgs.jarvis; }
jarvis_widget_tones="$(python3 -c 'import json,sys; print(json.dumps(dict(zip(["calm", "neutral", "accent", "info", "danger"], [json.loads(v).lower() for v in sys.argv[1:]]))))' \
  "$(ipc smoke themeValue bar.foreground)" "$(ipc smoke themeValue badge.tone.neutral.foreground)" \
  "$(ipc smoke themeValue badge.tone.accent.foreground)" "$(ipc smoke themeValue badge.tone.info.foreground)" \
  "$(ipc smoke themeValue badge.tone.danger.foreground)")" || fail "the widget tones are unreadable"
# The widget as drawn: [icon, tone, tooltip], the tone named by the token
# whose colour the icon draws in, or `absent`.
jarvis_widget() {
  local icon colours tip
  icon="$(ipc smoke readDescendant "$jarvis_widget_key" vgs.jarvis Icon name)" \
    && colours="$(ipc smoke itemColours "$jarvis_widget_key" vgs.jarvis Widget Icon)" \
    && tip="$(ipc smoke readDescendant "$jarvis_widget_key" vgs.jarvis Tooltip text)" || return
  python3 - "$icon" "$colours" "$tip" "$jarvis_widget_tones" <<'PY'
import json, sys
icon, colours, tip, tones = sys.argv[1:5]
if "absent" in (icon, colours, tip):
    print("absent"); sys.exit()
colour = json.loads(colours)[0][0]
names = [name for name, value in json.loads(tones).items() if "#" + value[3:9] + value[1:3] == colour]
print(json.dumps([json.loads(icon), names[0] if len(names) == 1 else "colour=" + colour, json.loads(tip)]))
PY
}
jarvis_widget_ready='["mic", "calm", "Jarvis is ready\nClick to mute"]'
jarvis_widget_live='["audio-lines", "accent", "Jarvis is using the microphone\nClick to mute"]'
jarvis_widget_muted='["mic-off", "neutral", "Jarvis is muted\nClick to unmute"]'
jarvis_widget_click() { click_centre "$jarvis_widget_key" vgs.jarvis || fail "the click on the Jarvis widget failed"; }
jarvis_widget_click_mutes() { expect_poll "a click on the widget mutes Jarvis" "$jarvis_widget_muted" jarvis_widget; }
jarvis_widget_click_control() { # LABEL
  (failures=0 behaviour_failures=0
   jarvis_widget_click_mutes >"$sandbox/jarvis-widget-click-$1-control.log"
   echo "$failures")
}
jarvis_widget_closing() { expect_poll "the widget reads live while muting closes capture" "$jarvis_widget_live" jarvis_widget; }
jarvis_widget_closing_control() {
  (failures=0 behaviour_failures=0
   jarvis_widget_closing >"$sandbox/jarvis-widget-closing-control.log"
   echo "$failures")
}
jarvis_widget_closing_control_check() { expect "a view that ignores capture fails the closing assertion" 1 jarvis_widget_closing_control; }
# A toggle conversation, then the physical Mute key while the scripted
# capture holds its close; ASSERTION reads the widget before the close.
jarvis_widget_mute_while_listening() { # ASSERTION
  jarvis_key_mode toggle
  jarvis_key_talk_down
  jarvis_key_talk_up
  expect_poll "a toggle press opens a conversation" listening jarvis_key_state phase
  jarvis_widget_gate hold-close
  jarvis_key_mute
  expect_poll "mute waits for the scripted capture teardown" muting jarvis_key_state mute
  "$1"
  jarvis_widget_gate close
  expect_poll "mute completes once capture closes" on jarvis_key_state mute
  rm -- "$jarvis_widget_gates/hold-close"
  jarvis_widget_click
  expect_poll "a click unmutes after the conversation" off jarvis_key_state mute
  jarvis_key_mode hold
}
# Disable Jarvis, put FILE's copy from before the row back with NEEDLE
# replaced by REPLACEMENT once, and rescan.
jarvis_widget_plant() { # FILE NEEDLE REPLACEMENT
  jarvis_disable
  python3 - "$sandbox/jarvis-widget-before-$1" "$jarvis_widget_dir/$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys
source, target, needle, replacement = sys.argv[1:]
p = Path(target); assert not p.is_symlink()
s = Path(source).read_text()
assert s.count(needle) == 1, needle
changed = s.replace(needle, replacement)
assert changed != s
p.write_text(changed)
PY
  jarvis_rescan
}
jarvis_widget_restore() { # FILE
  jarvis_disable
  cp -- "$sandbox/jarvis-widget-before-$1" "$jarvis_widget_dir/$1"
  jarvis_rescan
}

printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = false } })' >>"$jarvis_widget_lua"
expect "Jarvis keys use the physical evdev map" ok hypr reload config-only
hold_start_keyboard jarvis-widget "$sandbox/keyboard" us ""

rm -f -- "$jarvis_gate" "$jarvis_seen"
expect "the gated widget service enables" ok ipc shell setPluginEnabled vgs.jarvis true
expect_poll "enabling places the widget in the bar's right section" right jarvis_widget_section
expect_poll "the startup daemon consumes hello" seen jarvis_seen_hello
expect_poll "the widget reads off before the first state" '["power-off", "neutral", "Jarvis: Starting\nClick to mute"]' jarvis_widget
: >"$jarvis_gate"
expect "the gated daemon answers hello" ready jarvis_wait_ready
expect_poll "the widget reads ready" "$jarvis_widget_ready" jarvis_widget
jarvis_key_mode hold

jarvis_key_talk_down
expect_poll "talk down opens capture" listening jarvis_key_state phase
expect_poll "the widget reads live while Jarvis listens" "$jarvis_widget_live" jarvis_widget
jarvis_key_talk_up
expect_poll "release commits the scripted utterance" thinking jarvis_key_state phase
expect_poll "the widget reads working while Jarvis thinks" '["loader", "info", "Jarvis is thinking\nClick to mute"]' jarvis_widget
jarvis_widget_gate brain
expect_poll "the scripted brain speaks" speaking jarvis_key_state phase
expect_poll "the widget reads working while Jarvis speaks" '["loader", "info", "Jarvis is speaking\nClick to mute"]' jarvis_widget
jarvis_widget_gate played
expect_poll "scripted playback returns to idle" idle jarvis_key_state phase
expect_poll "the widget reads ready after the answer" "$jarvis_widget_ready" jarvis_widget

jarvis_widget_click
jarvis_widget_click_mutes
expect "the click reached the service's mute" on jarvis_key_state mute
jarvis_key_mute
expect_poll "the physical Mute key unmutes what the click muted" "$jarvis_widget_ready" jarvis_widget
jarvis_key_mute
expect_poll "the physical Mute key mutes again" "$jarvis_widget_muted" jarvis_widget
jarvis_widget_click
expect_poll "a click on the widget unmutes Jarvis" "$jarvis_widget_ready" jarvis_widget
expect "unmute alone keeps capture closed" closed jarvis_key_state capture
jarvis_widget_mute_while_listening jarvis_widget_closing
expect_poll "the widget reads ready after the toggle case" "$jarvis_widget_ready" jarvis_widget

# Keep the widget's button and its handler. Drop only the click's call.
jarvis_widget_plant Widget.qml 'onClicked: root.toggleMute()' 'onClicked: {}'
jarvis_enable
expect_poll "the click control draws the ready widget" "$jarvis_widget_ready" jarvis_widget
jarvis_widget_click
expect "a widget click that calls nothing fails the click assertion" 1 jarvis_widget_click_control widget
jarvis_widget_restore Widget.qml

# Keep the IPC handler and its reply. Drop only the mute intent it sends.
jarvis_widget_plant Service.qml 'intent("mute"); return "ok";' 'return "ok";'
jarvis_enable
expect_poll "the handler control draws the ready widget" "$jarvis_widget_ready" jarvis_widget
jarvis_widget_click
expect "a handler that sends no intent fails the click assertion" 1 jarvis_widget_click_control handler
jarvis_widget_restore Service.qml

# Judge the microphone by the phase instead of the capture region.
jarvis_widget_plant WidgetView.js 'microphoneOpen(state.capture)) return' '(detail.phase === "listening" || detail.phase === "armed")) return'
jarvis_enable
jarvis_widget_mute_while_listening jarvis_widget_closing_control_check
jarvis_widget_restore WidgetView.js

cp -- "$sandbox/jarvis-widget-before-jarvisd.js" "$jarvis_widget_dir/backend/jarvisd.js"
"$node_bin" "$source_repo/scripts/fixtures/jarvis/prepare.js" --floor-daemon "$jarvis_widget_dir/backend/jarvisd.js"
jarvis_rescan
expect "the permanent-problem widget service enables" ok ipc shell setPluginEnabled vgs.jarvis true
expect_poll "the real service reports its permanent cause" permanent jarvis_permanent
expect_poll "the widget reads the permanent problem" '["circle-alert", "danger", "Problem: jarvis: node=21.0.0 need=22\nClick to mute"]' jarvis_widget
jarvis_widget_refused="$(jarvis_key_refusals 'jarvis: node=21.0.0 need=22')"
jarvis_widget_click
expect_poll "a click in the problem state reports the refusal" "$((jarvis_widget_refused + 1))" jarvis_key_refusals 'jarvis: node=21.0.0 need=22'
expect "the permanent-problem service disables" ok ipc shell setPluginEnabled vgs.jarvis false

hold_stop_keyboard
for jarvis_widget_file in "${jarvis_widget_files[@]}"; do
  cp -- "$sandbox/jarvis-widget-before-${jarvis_widget_file##*/}" "$jarvis_widget_dir/$jarvis_widget_file"
done
rm -- "$jarvis_widget_dir/backend/scripted-fixture.js"
rm -- "$home/.local/state/vgs/jarvis/mute.json"
jarvis_rescan
cp -- "$sandbox/jarvis-widget-config-before.json" "$jarvis_widget_config"
cp -- "$sandbox/jarvis-widget-lua-before" "$jarvis_widget_lua"
expect "restore the Jarvis widget configuration" ok ipc shell reloadConfig
expect "restore the nested keyboard configuration" ok hypr reload config-only
jarvis_enable
expect_poll "the restored stock daemon remains unconfigured" session jarvis_session unconfigured
expect_poll "the widget reads off for the unconfigured daemon" '["power-off", "neutral", "Jarvis is not set up\nClick to mute"]' jarvis_widget
expect "the restored nested keys have no configuration errors" '[]' config_errors
expect "the widget row leaves no Jarvis state file" False \
  python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).exists())' "$home/.local/state/vgs/jarvis/mute.json"
jarvis_disable
expect_poll "disable removes the widget" absent ipc smoke readInstance "$jarvis_widget_key" vgs.jarvis moduleName
