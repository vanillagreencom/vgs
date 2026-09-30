# The gallery: the first-party window that draws every component. Summoned
# over IPC it maps one Hyprland window, holds every section and component
# it claims, shows the hand over an enabled control and the arrow over a
# disabled one, shows a toast through its capability, and takes them all
# down when hidden. Summoned again, it is read as every application window
# is (app_window_rows, scripts/smoke/app-window.sh), ending closed by Escape.
set -euo pipefail
expect "the gallery summons over IPC" ok ipc shell summon window vgs.gallery '{}'
expect_poll "the gallery maps one window" 1 window_count Gallery
expect "the gallery maps no layer surface" 0 layer_count vgs:panel
# Every component the module's qmldir lists is drawn, read back by type
# name; the headings have a size, so they show.
expect_poll "the gallery draws every component of the module" '[]' ipc smoke galleryMissing window vgs.gallery
render expect_poll "the gallery's headings are drawn with a size" 13 ipc smoke galleryHeadings window vgs.gallery
geometry expect "every example stays inside the gallery" '[]' ipc smoke galleryOverflow window vgs.gallery
# No block of the gallery draws over another: the title and each section's
# heading, in the order the body lays them out, each start at or below the
# end of the one before, within one pixel. The control moves the third
# heading onto the second in a copy of the same reading, which the check
# refuses. `[]` is the pass.
gallery_sections=(Surfaces Typography Buttons Choices Inputs Feedback Dialogs Cards Carousel "Titles and scrolling" Lists "List motion")
gallery_stack() {
  local boxes=() title name
  title="$(ipc smoke shownWindowGeometry window vgs.gallery Label Gallery)" || return
  for name in "${gallery_sections[@]}"; do boxes+=("$(ipc smoke shownWindowGeometry window vgs.gallery SectionHeader "$name")"); done
  python3 - "${1:-}" "$title" "${boxes[@]}" <<'PY'
import json, sys
plant, raw = sys.argv[1] == "overlap", sys.argv[2:]
bad = [r for r in raw if not r.startswith("[")]
if bad:
    print(json.dumps(["unread=%s" % bad])); sys.exit()
boxes = [json.loads(r) for r in raw]
if plant: boxes[3] = [boxes[3][0], boxes[2][1] + 4] + boxes[3][2:]
out = []
for n in range(1, len(boxes)):
    prev, cur = boxes[n - 1], boxes[n]
    if cur[1] < prev[1] + prev[3] - 1: out.append("block%d.top=%.2f prev.bottom=%.2f" % (n, cur[1], prev[1] + prev[3]))
print(json.dumps(out))
PY
}
gallery_stack_planted() { gallery_stack overlap | python3 -c 'import json,sys; print(len(json.load(sys.stdin)) > 0)'; }
geometry expect_poll "no block of the gallery draws over another" '[]' gallery_stack
expect "control: a heading moved onto the one before is refused" True gallery_stack_planted
# The cursor over the controls, with the Buttons section scrolled to the
# top: the hand over an enabled button, switch and checkbox, and the arrow
# over each disabled one, which Qt skips when it picks the cursor.
gallery_box() { ipc smoke shownWindowGeometry window vgs.gallery "$1" "$2"; }
# A section's distance below the first one, read at the top, is the
# scroll that brings it to the top: the title sits in the fixed header.
gallery_offset() { python3 -c 'import json,sys; print(int(json.loads(sys.argv[1])[1] - json.loads(sys.argv[2])[1]))' "$(gallery_box SectionHeader "$1")" "$(gallery_box SectionHeader Surfaces)"; }
# Property readback is separate from the engine's compiled shader status.
orb_examples_ok() { ipc smoke galleryOrbs window vgs.gallery '' | py_reply 'import json,sys
rows=json.load(sys.stdin)
print(len(rows)==9 and {r["tone"] for r in rows[:6]}=={"accent","info","success","warning","danger","muted"} and all(r["width"]>0 and r["height"]>0 for r in rows) and all(r["active"] for r in rows[:6]) and not rows[6]["active"] and rows[7]["level"]==1 and rows[7]["secondaryLevel"]==1 and 0<rows[8]["level"]<1)'; }
orb_pixels() {
  local rows window sample geometry colour socket count
  rows="$(ipc smoke galleryOrbs window vgs.gallery "$1")" || return 1
  window="$(surface_box window:Gallery)" || return 1
  if [[ $window != \[* ]]; then printf '%s\n' "$window"; return; fi
  sample="$(py_reply 'import json,sys
rows=json.load(sys.stdin); window=json.loads(sys.argv[1]); index=int(sys.argv[2])
if not isinstance(rows,list) or index>=len(rows): print("absent"); sys.exit()
orb=rows[index]
if not orb["visible"] or not orb["windowVisible"] or not orb["url"].endswith("/voiceorb.frag.qsb"):
    print("not-drawn"); sys.exit()
x,y,w,h=orb["box"]
print("%d,%d %dx%d|%s" % (round(window[0]+x),round(window[1]+y),round(w),round(h),orb["ink"][1:7]))' "$window" "$2" <<<"$rows")" || return 1
  if [[ $sample != *'|'* ]]; then printf '%s\n' "$sample"; return; fi
  IFS='|' read -r geometry colour <<<"$sample"
  socket="$(shot_socket "$rt_dir" "$nested_socket" "$host_socket")" || return 1
  count="$(shot_grim "$socket" "$rt_dir" -g "$geometry" -t ppm - | python3 -c 'import sys
data=sys.stdin.buffer.read().split(b"\n",3)
if len(data)!=4 or data[0]!=b"P6" or data[2]!=b"255": print("unreadable"); sys.exit(1)
w,h=map(int,data[1].split()); pixels=data[3]
if len(pixels)!=w*h*3: print("unreadable"); sys.exit(1)
colour=bytes.fromhex(sys.argv[1])
print(sum(pixels[i:i+3]==colour for i in range(0,len(pixels),3)))' "$colour")" || return 1
  printf '%s\n' "$count"
}
orb_drawn() {
  local count
  count="$(orb_pixels "$1" "$2")" || return 1
  if [[ ! $count =~ ^[0-9]+$ ]]; then printf '%s\n' "$count"; return; fi
  [[ $count -gt 0 ]] && echo True || echo False
}
gallery_orb_offset() { ipc smoke galleryOrbs window vgs.gallery '' | py_reply 'import json,sys
orbs=json.load(sys.stdin)
index=int(sys.argv[1])
print("absent" if index>=len(orbs) or orbs[index]["scrollOffset"] is None else orbs[index]["scrollOffset"])' "$1"; }
gallery_draw_orbs() {
  local label="$1" count index position offset failed_before
  count="$(ipc smoke galleryOrbs window vgs.gallery '' | py_reply 'import json,sys; print(len(json.load(sys.stdin)))')" || return 1
  if [[ $count != 9 ]]; then fail "$label: orb inventory=$count want=9"; return 1; fi
  # Qt's shared shader-info cache leaves some managers Uncompiled even
  # after drawing. Read real pixels in each example's own box instead.
  for ((index=0; index<count; index++)); do
    if ! position="$(ipc smoke scrollTo window vgs.gallery 0)" || [[ $position != \[* ]] ||
       ! offset="$(gallery_orb_offset "$index")" || [[ ! $offset =~ ^-?[0-9]+$ ]] ||
       ! position="$(ipc smoke scrollTo window vgs.gallery "$offset")" || [[ $position != \[* ]]; then
      fail "$label: orb=$index did not scroll into view"; return 1
    fi
    printf '  orb-scroll index=%s requested=%s actual=%s\n' "$index" "$offset" "$position"
    failed_before="$failures"
    render expect_poll "$label: orb=$index draws its tone" True orb_drawn '' "$index"
    if [[ $failures -gt $failed_before ]]; then
      ipc smoke galleryOrbs window vgs.gallery '' || return 1
    fi
  done
}
expect_poll "the gallery builds the VoiceOrb tones and level states" True orb_examples_ok
gallery_draw_orbs "the Gallery VoiceOrb shader"
# The same control must draw before its shader is hidden. Its blue tone
# occupies a blank fourth slot beside the final three accent examples.
python3 - "$repo/shell/Ui/feedback/VoiceOrb.qml" "$repo/shell/plugins/vgs.gallery/VoiceOrbControl.qml" "$repo/shell/Ui/feedback/shaders/voiceorb.frag.qsb" <<'PY'
from pathlib import Path
import json, sys
source, destination, pack = map(Path, sys.argv[1:])
text = source.read_text()
for needle, replacement in [
    ("    Accessible.ignored: true\n", "    Accessible.ignored: true\n    function hideShader() { shader.visible = false; }\n"),
    ('Qt.resolvedUrl("shaders/voiceorb.frag.qsb")', 'Qt.resolvedUrl(' + json.dumps(str(pack)) + ')'),
]:
    assert text.count(needle) == 1, needle
    changed = text.replace(needle, replacement)
    assert changed != text
    text = changed
destination.write_text(text)
PY
control_gap="$(ipc smoke themeValue space.sm)" || exit 1
control_position="$(ipc smoke galleryOrbs window vgs.gallery '' | py_reply 'import json,sys
orb=json.load(sys.stdin)[-1]; x,y,w,h=orb["box"]
print(json.dumps({"x":x+w+json.loads(sys.argv[1]),"y":y,"tone":"info"}))' "$control_gap")" || exit 1
expect "the orb drawing control builds" ok ipc smoke popupLoad orb-control "$repo/shell/plugins/vgs.gallery/VoiceOrbControl.qml" window vgs.gallery "$control_position"
render expect_poll "the normal orb control draws before the defect" True orb_drawn orb-control 0
expect "the control hides only its shader" ok ipc smoke popupCall orb-control hideShader
render expect_poll "the pixel reader rejects the hidden shader control" False orb_drawn orb-control 0
expect "the orb control is released" ok ipc smoke popupDrop orb-control
if [[ $(ipc smoke scrollTo window vgs.gallery 0) == \[* ]] && offset="$(gallery_offset Buttons)" && [[ $(ipc smoke scrollTo window vgs.gallery "$offset") == \[* ]]; then
  expect_cursor "an enabled button shows the hand" pointer window:Gallery "$(gallery_box Button Small)"
  expect_cursor "a disabled button shows the arrow" default window:Gallery "$(gallery_box Button Disabled)"
  if offset="$(gallery_offset Choices)" && [[ $(ipc smoke scrollTo window vgs.gallery "$offset") == \[* ]]; then
  expect_cursor "an enabled switch shows the hand" pointer window:Gallery "$(gallery_box Switch Off)"
  expect_cursor "a disabled switch shows the arrow" default window:Gallery "$(gallery_box Switch Disabled)"
  expect_cursor "an enabled checkbox shows the hand" pointer window:Gallery "$(gallery_box Checkbox Unchecked)"
  expect_cursor "a disabled checkbox shows the arrow" default window:Gallery "$(gallery_box Checkbox Disabled)"
  else
    fail "the gallery did not scroll its Choices section to the top"
  fi
  rest_pointer || fail "moving the pointer off the gallery failed"
else
  fail "the gallery did not scroll its Buttons section to the top"
fi
expect "the gallery shows a toast through its capability" ok ipc smoke invokeInstance window vgs.gallery toast ''
expect_poll "the gallery's toast is in the record under its plugin" '["Saved"]' toast_titles visible
expect "hiding the gallery is allowed" ok ipc shell hide window vgs.gallery
expect_poll "the gallery's window is gone" 0 window_count Gallery
expect_poll "hiding the gallery released its toast" '[]' toast_titles visible
expect "the gallery summons again for the window rows" ok ipc shell summon window vgs.gallery '{}'
app_window_rows Gallery vgs.gallery
