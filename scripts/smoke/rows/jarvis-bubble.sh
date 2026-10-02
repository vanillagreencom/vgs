# Runs inside jarvis-keys' private scripted ports and physical keyboard.
# No real audio, provider, authentication or network runs. Presentation
# and state poll once per IPC round trip; no latency budget is claimed.
set -euo pipefail

jarvis_bubble_state() {
  ipc smoke layerWindows vgs.jarvis | py_reply '
import json,sys
rows=json.load(sys.stdin)
shown=[r for r in rows if r["visible"] and r["presented"] and r["width"]>0 and r["height"]>0]
print("presented" if len(shown)==1 else "not-presented")
'
}
jarvis_bubble_widgets() {
  ipc shell built | py_reply '
import json,sys
bars=[r for host,rows in json.load(sys.stdin).items() if host.startswith("bar:") for r in rows]
if not any(r["id"]=="acme.tick" for r in bars):
    sys.exit("jarvis-bubble: bar-reader=missing-tick")
print(sum(r["id"]=="vgs.jarvis" for r in bars))
'
}
jarvis_bubble_hide_bar() {
  local answer
  answer="$(ipc shell setPluginEnabled vgs.bar false)" || return 1
  case "$answer" in
    ok|ok\ hidden=*) echo ok ;;
    *) printf '%s\n' "$answer" ;;
  esac
}
jarvis_bubble_geometry() {
  local box window margin
  box="$(control_box vgs:layer vgs.jarvis Surface level raised)" &&
    window="$(surface_box vgs:layer)" &&
    margin="$(ipc smoke themeValue voiceBubble.margin)" || return 1
  [[ $box == \[* && $window == \[* ]] || { echo absent; return; }
  python3 -c '
import json,sys
b,w=map(json.loads,sys.argv[1:3]); margin=float(sys.argv[3])
ok=(b[2]>0 and b[3]>0 and b[0]>=w[0] and b[1]>=w[1]
    and b[0]+b[2]<=w[0]+w[2] and b[1]+b[3]<=w[1]+w[3]
    and abs((b[0]+b[2]/2)-(w[0]+w[2]/2))<=1
    and abs((w[1]+w[3])-(b[1]+b[3])-margin)<=1)
print("bottom-centre" if ok else "wrong-geometry")
' "$box" "$window" "$margin"
}
jarvis_bubble_pixels() {
  local box colour socket geometry count
  box="$(control_box vgs:layer vgs.jarvis VoiceOrb active true)" &&
    colour="$(ipc smoke themeValue voiceOrb.tone.accent | py_reply 'import json,sys; print(json.load(sys.stdin)[-6:])')" &&
    socket="$(shot_socket "$rt_dir" "$nested_socket" "$host_socket")" || return 1
  [[ $box == \[* ]] || { echo absent; return; }
  geometry="$(python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); print("%d,%d %dx%d"%(x,y,w,h))' "$box")" || return 1
  count="$(shot_grim "$socket" "$rt_dir" -g "$geometry" -t ppm - | python3 -c '
import sys
d=sys.stdin.buffer.read().split(b"\n",3)
if len(d)!=4 or d[0]!=b"P6" or d[2]!=b"255": sys.exit("jarvis-bubble: pixels=unreadable")
w,h=map(int,d[1].split()); pixels=d[3]
if len(pixels)!=w*h*3: sys.exit("jarvis-bubble: pixels=incomplete")
c=bytes.fromhex(sys.argv[1])
print(sum(pixels[i:i+3]==c for i in range(0,len(pixels),3)))
' "$colour")" || return 1
  [[ $count =~ ^[0-9]+$ ]] || return 1
  [[ $count -gt 0 ]] && echo drawn || echo blank
}
# The fixture's assistant caption as the bubble draws it: one visible label
# holding the whole text, longer than the token's three lines, inside one
# clipping window of exactly that height. The label's bottom on the window's
# bottom draws the text's end; its top on the window's top draws its start.
jarvis_bubble_words() {
  local labels windows lines
  labels="$(ipc smoke layerItems vgs.jarvis Label text,visible,lineCount,lineBox)" &&
    windows="$(ipc smoke layerItems vgs.jarvis QQuickItem clip,visible)" &&
    lines="$(ipc smoke themeValue voiceBubble.textLines)" || return 1
  [[ $labels == \[* && $windows == \[* ]] || { printf 'jarvis-bubble: words-reader=unreadable labels=%s windows=%s\n' "$labels" "$windows" >&2; return 1; }
  python3 -c '
import json,sys
labels,windows=map(json.loads,sys.argv[1:3]); lines=int(sys.argv[3]); text=sys.argv[4]
shown=[(s,r,v) for s,r,v in labels if v["visible"] and v["text"]==text]
if not shown: print("absent"); sys.exit()
if len(shown)!=1: print("unbounded"); sys.exit()
screen,(x,y,w,h),label=shown[0]
held=[r for s,r,v in windows if s==screen and v["visible"] and v["clip"] and r[0]==x and r[2]==w]
bounded=(len(held)==1 and label["lineCount"]>lines and abs(held[0][3]-lines*label["lineBox"])<=1
         and abs(h-label["lineCount"]*label["lineBox"])<=1)
if not bounded: print("unbounded"); sys.exit()
top,height=held[0][1],held[0][3]
print("latest-lines" if abs(y+h-top-height)<=1 else "first-lines" if abs(y-top)<=1 else "unbounded")
' "$labels" "$windows" "$lines" "$jarvis_bubble_reply"
}
jarvis_bubble_caption() {
  ipc smoke jarvisProcess | py_reply '
import json,sys
s=json.load(sys.stdin)["status"]; t=s.get("transcript")
print("none" if t is None else "current" if t["gen"]==s["detail"]["state"]["gen"] else "stale")
'
}
# After jarvis_bubble_begin: one thinking turn, with its caption on request.
jarvis_bubble_think() { # [caption]
  jarvis_key_talk_up
  jarvis_key_commit
  [[ ${1-} == caption ]] || return 0
  jarvis_key_gate reply-caption
  expect_poll "the service publishes this conversation's assistant caption" current jarvis_bubble_caption
}
jarvis_bubble_no_capture() {
  expect_poll "an unavailable indicator releases capture" closed jarvis_key_state capture
  expect "the daemon records indicator gone" gone jarvis_key_state indicator
}
jarvis_bubble_focused() {
  local rows focused
  rows="$(ipc smoke layerWindows vgs.jarvis)" &&
    focused="$(ipc smoke readInstance service vgs.jarvis focusedOutput)" || return 1
  py_reply '
import json,sys
rows=json.load(sys.stdin); focused=json.loads(sys.argv[1])
ok=any(r["screen"]==focused for r in rows) and all(
    r["screen"]==focused for r in rows if r["shown"] or r["visible"])
print("focused" if ok else "wrong-output")
' "$focused" <<<"$rows"
}
jarvis_bubble_loss_control() {
  (failures=0 behaviour_failures=0
   jarvis_bubble_no_capture >"$sandbox/jarvis-bubble-loss-control.log"
   echo "$failures")
}
jarvis_bubble_pass() { # X Y
  local down up
  down="$(other_events '^button 272 pressed$')" &&
    up="$(other_events '^button 272 released$')" || return 1
  hover "$(($1 - 1))" "$2" && click "$1" "$2" || return 1
  expect_poll "a decorative point delivers press to the client below" "$((down + 1))" other_events '^button 272 pressed$'
  expect_poll "a decorative point delivers release to the client below" "$((up + 1))" other_events '^button 272 released$'
}
jarvis_bubble_click() { # LABEL
  local point x y
  if ! point="$(point_item vgs:layer vgs.jarvis IconButton label "$1")"; then
    printf 'jarvis-bubble: pointer-not-ready=%s\n' "$1" >&2
    ipc smoke layerItems vgs.jarvis IconButton label,hovered,visible >&2
    ipc smoke layerWindows vgs.jarvis >&2
    return 1
  fi
  read -r x y <<<"$point"
  click "$x" "$y"
}
jarvis_bubble_begin() {
  jarvis_key_talk_down
  expect_poll "capture waits for the bubble then listens" listening jarvis_key_state phase
  expect_poll "the listening bubble has presented on its own host" presented jarvis_bubble_state
}

expect_poll "ready idle maps no bubble" 0 layer_count vgs:layer
expect "the Jarvis widget unplaces without disabling its service" ok ipc shell setPluginPlaced vgs.jarvis false
expect "the build contains no Jarvis bar widget" 0 jarvis_bubble_widgets
if ! open_other "$sandbox/toplevel-jarvis-bubble.log"; then fail "the client below Jarvis maps"; exit 1; fi
expect_poll "the client below Jarvis has keyboard focus" '["smoke.other", "Other window"]' active_window
jarvis_bubble_begin
geometry expect_poll "the bubble clears reserved space and sits at bottom centre" bottom-centre jarvis_bubble_geometry
expect "the bubble takes no keyboard focus" '["smoke.other", "Other window"]' active_window
geometry expect_poll "the orb draws without a Jarvis bar widget" drawn jarvis_bubble_pixels
expect "control: hide only the bubble's shader" ok ipc smoke layerShaderSet vgs.jarvis false
geometry expect_poll "control: the same pixel reader sees the hidden shader" blank jarvis_bubble_pixels
expect "the shader is restored" ok ipc smoke layerShaderSet vgs.jarvis true
geometry expect_poll "the restored orb draws" drawn jarvis_bubble_pixels
expect "the bar disables independently of Jarvis" ok jarvis_bubble_hide_bar
expect_poll "the orb still presents without any bar" presented jarvis_bubble_state
geometry expect_poll "the bubble follows the free area without a bar" bottom-centre jarvis_bubble_geometry
expect "the bar returns without restarting Jarvis" ok ipc shell setPluginEnabled vgs.bar true
expect_poll "the bubble follows the restored reserved space" presented jarvis_bubble_state

read -r orb_x orb_y < <(python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); print(round(x+w/2),round(y+h/2))' "$(control_box vgs:layer vgs.jarvis VoiceOrb active true)")
read -r mute_x mute_y mute_w mute_h < <(python3 -c 'import json,sys; print(*json.loads(sys.argv[1]))' "$(control_box vgs:layer vgs.jarvis IconButton label 'Mute Jarvis')")
read -r stop_x stop_y stop_w stop_h < <(python3 -c 'import json,sys; print(*json.loads(sys.argv[1]))' "$(control_box vgs:layer vgs.jarvis IconButton label 'Stop Jarvis')")
jarvis_bubble_pass "$orb_x" "$orb_y"
jarvis_bubble_pass "$(((mute_x + mute_w + stop_x) / 2))" "$((mute_y + mute_h / 2))"
jarvis_bubble_pass "$((mute_x - 2))" "$mute_y"
expect "decorative clicks cannot mute" off jarvis_key_state mute
expect "decorative clicks keep capture live" open jarvis_key_state capture
jarvis_bubble_click "Stop Jarvis"
jarvis_key_talk_up
jarvis_key_stop_assertion
expect_poll "Stop removes the idle bubble" 0 layer_count vgs:layer
jarvis_bubble_begin
jarvis_bubble_click "Mute Jarvis"
expect_poll "the labelled Mute button turns privacy mute on" on jarvis_key_state mute
expect_poll "the Mute button closes capture before hiding" closed jarvis_key_state capture
jarvis_key_talk_up
jarvis_key_mute
expect_poll "explicit unmute does not restore capture" off jarvis_key_state mute
expect "unmute still leaves no capture" closed jarvis_key_state capture

jarvis_bubble_reply="$(python3 -c 'print(" ".join(["scripted reply"] * 24))')"
jarvis_bubble_begin
jarvis_bubble_think caption
expect_poll "the bubble draws the latest three lines of Jarvis's words" latest-lines jarvis_bubble_words
expect "the worded bubble keeps its presented indicator" presented jarvis_bubble_state
geometry expect_poll "the worded bubble stays at bottom centre" bottom-centre jarvis_bubble_geometry
read -r words_x words_y < <(python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); print(round(x+w/2),round(y+h/2))' "$(control_box vgs:layer vgs.jarvis QQuickItem clip true)")
jarvis_bubble_pass "$words_x" "$words_y"
jarvis_key_stop
jarvis_key_stop_assertion
jarvis_bubble_begin
jarvis_bubble_think
expect "the status still holds the ended conversation's caption" stale jarvis_bubble_caption
expect "a new conversation draws none of the last one's words" absent jarvis_bubble_words
jarvis_key_stop
jarvis_key_stop_assertion

jarvis_bubble_begin
jarvis_bubble_launcher="$(ipc smoke jarvisProcess | jarvis_launcher_pid)" || exit 1
jarvis_bubble_daemon="$(jarvis_descendants "$jarvis_bubble_launcher")" || exit 1
kill -KILL "$jarvis_bubble_daemon"
expect_poll "daemon death immediately removes its listening visual" 0 layer_count vgs:layer
expect "the service recovers through its existing allowance" ready jarvis_wait_ready 1
expect_poll "the recovered daemon has no capture demand" closed jarvis_key_state capture
jarvis_key_talk_up
jarvis_key_stop
jarvis_disable
jarvis_enable

jarvis_bubble_begin
jarvis_bubble_lua="$home/.config/hypr/hyprland.lua"
cp -- "$jarvis_bubble_lua" "$sandbox/jarvis-bubble-focus-before.lua"
jarvis_bubble_first="$(hypr -j monitors | py_reply 'import json,sys; print(next(m["name"] for m in json.load(sys.stdin) if m["focused"]))')"
printf '%s\n' 'hl.config({ input = { follow_mouse = 0 }, cursor = { no_warps = true }, misc = { mouse_move_focuses_monitor = false } })' >>"$jarvis_bubble_lua"
expect "the nested configuration holds monitor focus" ok hypr reload config-only
expect "the nested compositor adds another focus target" ok hypr output create headless SMOKE-JARVIS
expect "the physical-key fixture focuses the other monitor" ok probe dispatch "focusMonitor SMOKE-JARVIS"
expect_poll "the service observes the other focused output" '"SMOKE-JARVIS"' ipc smoke readInstance service vgs.jarvis focusedOutput
expect_poll "only the focused output requests a bubble" focused jarvis_bubble_focused
expect "focus returns to the original monitor" ok probe dispatch "focusMonitor $jarvis_bubble_first"
expect_poll "the service observes restored monitor focus" "\"$jarvis_bubble_first\"" ipc smoke readInstance service vgs.jarvis focusedOutput
expect_poll "the restored focused output owns the visual" focused jarvis_bubble_focused
expect "the nested compositor removes the focus target" ok hypr output remove SMOKE-JARVIS
cp -- "$sandbox/jarvis-bubble-focus-before.lua" "$jarvis_bubble_lua"
expect "the nested pointer configuration is restored" ok hypr reload config-only
jarvis_key_talk_up
jarvis_key_stop
jarvis_key_stop_assertion

jarvis_bubble_begin
expect "losing the mapped host hides the indicator" ok ipc smoke layerWindowSet vgs.jarvis visible false
jarvis_bubble_no_capture
jarvis_key_talk_up
jarvis_key_stop
jarvis_disable
expect_poll "disable destroys the bubble registration" '[]' ipc smoke layerWindows vgs.jarvis
jarvis_enable
jarvis_bubble_begin
expect "a screen loss reaches the content binding" ok ipc smoke layerWindowSet vgs.jarvis screen false
jarvis_bubble_no_capture
expect_poll "no screen maps no bubble surface" 0 layer_count vgs:layer
jarvis_key_talk_up
jarvis_key_stop
jarvis_disable

# Retain the actual host and key. Ignore only mapping/presentation in a
# disposable plugin copy; the same lost-host assertion must turn red. The
# words controls keep the caption on the wire and break one bubble rule each.
jarvis_bubble_file="$repo/shell/plugins/vgs.jarvis/Bubble.qml"
cp -- "$jarvis_bubble_file" "$sandbox/jarvis-bubble-before"
for jarvis_bubble_mutant in geometry focus words lines head generation; do
  python3 - "$jarvis_bubble_file" "$jarvis_bubble_mutant" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); assert not p.is_symlink()
needle,replacement={
    "geometry": ("anchors.bottomMargin: Theme.voiceBubble.margin", "anchors.bottomMargin: Theme.voiceBubble.margin + Theme.voiceBubble.gap"),
    "focus": ("screen.name === service.focusedOutput", "true"),
    "words": ('caption.role === "assistant"', "false"),
    "lines": ("Theme.voiceBubble.textLines * tail.lineBox", "(Theme.voiceBubble.textLines + 1) * tail.lineBox"),
    "head": ("y: parent.height - height", "y: 0"),
    "generation": ("caption.gen === state.gen", "true")
}[sys.argv[2]]
s=p.read_text(); assert s.count(needle)==1
changed=s.replace(needle,replacement); assert changed!=s
p.write_text(changed)
PY
  jarvis_rescan
  jarvis_enable
  jarvis_bubble_begin
  case "$jarvis_bubble_mutant" in
    geometry)
      expect "control: a wrong bottom margin fails the same geometry reader" wrong-geometry jarvis_bubble_geometry
      jarvis_key_talk_up ;;
    focus)
      expect "control: add another output without changing focus" ok hypr output create headless SMOKE-JARVIS
      expect_poll "control: ignoring focus fails the same output reader" wrong-output jarvis_bubble_focused
      expect "control: remove the second output" ok hypr output remove SMOKE-JARVIS
      jarvis_key_talk_up ;;
    words)
      jarvis_bubble_think caption
      expect "control: dropping the consumer fails the same words reader" absent jarvis_bubble_words ;;
    lines)
      jarvis_bubble_think caption
      expect_poll "control: a fourth line fails the same words reader" unbounded jarvis_bubble_words ;;
    head)
      jarvis_bubble_think caption
      expect_poll "control: the first three lines fail the same words reader" first-lines jarvis_bubble_words ;;
    generation)
      jarvis_bubble_think caption
      jarvis_key_stop
      jarvis_key_stop_assertion
      jarvis_bubble_begin
      jarvis_bubble_think
      expect_poll "control: ignoring the conversation fails the same words reader" latest-lines jarvis_bubble_words ;;
  esac
  jarvis_key_stop
  jarvis_disable
  cp -- "$sandbox/jarvis-bubble-before" "$jarvis_bubble_file"
done
python3 - "$jarvis_bubble_file" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); assert not p.is_symlink()
s=p.read_text()
needle='shown && visible && host !== null && host.presented === true'
assert s.count(needle)==1
changed=s.replace(needle, 'shown')
assert changed!=s
p.write_text(changed)
PY
jarvis_rescan
jarvis_enable
jarvis_bubble_begin
expect "control: the same host disappears after acquisition" ok ipc smoke layerWindowSet vgs.jarvis visible false
expect "control: ignoring presentation fails lost-host capture teardown" 2 jarvis_bubble_loss_control
jarvis_key_talk_up
jarvis_key_stop
jarvis_disable
cp -- "$sandbox/jarvis-bubble-before" "$jarvis_bubble_file"
jarvis_rescan
jarvis_enable
jarvis_key_mode hold
close_other "the client below Jarvis exits"
