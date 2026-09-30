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
# The cursor over the controls, with the Buttons section scrolled to the
# top: the hand over an enabled button, switch and checkbox, and the arrow
# over each disabled one, which Qt skips when it picks the cursor.
gallery_box() { ipc smoke shownWindowGeometry window vgs.gallery "$1" "$2"; }
gallery_offset() { python3 -c 'import json,sys; print(int(json.loads(sys.argv[1])[1] - json.loads(sys.argv[2])[1]))' "$(gallery_box SectionHeader "$1")" "$(gallery_box Label Gallery)"; }
# Property readback is separate from the engine's compiled shader status.
orb_examples_ok() { ipc smoke galleryOrbs window vgs.gallery '' | py_reply 'import json,sys
rows=json.load(sys.stdin)
print(len(rows)==9 and {r["tone"] for r in rows[:6]}=={"accent","info","success","warning","danger","muted"} and all(r["width"]>0 and r["height"]>0 for r in rows) and all(r["active"] for r in rows[:6]) and not rows[6]["active"] and rows[7]["level"]==1 and rows[7]["secondaryLevel"]==1 and 0<rows[8]["level"]<1)'; }
orb_shader_ok() { ipc smoke galleryOrbs window vgs.gallery "$1" | py_reply 'import json,sys
rows=json.load(sys.stdin)
index=int(sys.argv[1])
print("absent" if index<0 or index>=len(rows) else bool(rows[index]["compiled"] and rows[index]["url"].endswith("/voiceorb.frag.qsb")))' "$2"; }
gallery_orb_offset() { ipc smoke descendantGeometry window vgs.gallery | py_reply 'import json,sys
items=json.load(sys.stdin)
orbs=[item for item in items if item["type"]=="VoiceOrb"]
title=next((item for item in items if item["type"]=="Label" and item.get("text")=="Gallery"),None)
index=int(sys.argv[1])
print("absent" if title is None or index>=len(orbs) else round(orbs[index]["box"][1]-title["box"][1]))' "$1"; }
gallery_compile_orbs() {
  local label="$1" count index position offset failed_before
  count="$(ipc smoke galleryOrbs window vgs.gallery '' | py_reply 'import json,sys; print(len(json.load(sys.stdin)))')" || return 1
  if [[ $count != 9 ]]; then fail "$label: orb inventory=$count want=9"; return 1; fi
  # Qt may defer a clipped ShaderEffect's node. Bring each discovered
  # example into the viewport before reading its own compiled status.
  for ((index=0; index<count; index++)); do
    if ! position="$(ipc smoke scrollTo window vgs.gallery 0)" || [[ $position != \[* ]] ||
       ! offset="$(gallery_orb_offset "$index")" || [[ ! $offset =~ ^-?[0-9]+$ ]] ||
       ! position="$(ipc smoke scrollTo window vgs.gallery "$offset")" || [[ $position != \[* ]]; then
      fail "$label: orb=$index did not scroll into view"; return 1
    fi
    failed_before="$failures"
    render expect_poll "$label: orb=$index compiles" True orb_shader_ok '' "$index"
    if [[ $failures -gt $failed_before ]]; then
      ipc smoke galleryOrbs window vgs.gallery '' || return 1
    fi
  done
}
expect_poll "the gallery builds the VoiceOrb tones and level states" True orb_examples_ok
gallery_compile_orbs "the Gallery VoiceOrb shader"
# A hidden shader retains its valid pack URL but never compiles. This
# control tests the compiled-status reader, not frame cost or presentation.
python3 - "$repo/shell/Ui/feedback/VoiceOrb.qml" "$repo/shell/plugins/vgs.gallery/VoiceOrbControl.qml" "$repo/shell/Ui/feedback/shaders/voiceorb.frag.qsb" <<'PY'
from pathlib import Path
import json, sys
source, destination, pack = map(Path, sys.argv[1:])
text = source.read_text()
for needle, replacement in [
    ("        id: shader\n", "        id: shader\n        visible: false\n"),
    ('Qt.resolvedUrl("shaders/voiceorb.frag.qsb")', 'Qt.resolvedUrl(' + json.dumps(str(pack)) + ')'),
]:
    assert text.count(needle) == 1, needle
    changed = text.replace(needle, replacement)
    assert changed != text
    text = changed
destination.write_text(text)
PY
expect "the uncompiled orb control builds" ok ipc smoke popupLoad orb-control "$repo/shell/plugins/vgs.gallery/VoiceOrbControl.qml" window vgs.gallery '{}'
render expect "the shader reader rejects the uncompiled control" False orb_shader_ok orb-control 0
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
