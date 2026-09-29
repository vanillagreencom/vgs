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
render expect_poll "the gallery's headings are drawn with a size" 11 ipc smoke galleryHeadings window vgs.gallery
geometry expect "every example stays inside the gallery" '[]' ipc smoke galleryOverflow window vgs.gallery
# The cursor over the controls, with the Buttons section scrolled to the
# top: the hand over an enabled button, switch and checkbox, and the arrow
# over each disabled one, which Qt skips when it picks the cursor.
gallery_box() { ipc smoke shownWindowGeometry window vgs.gallery "$1" "$2"; }
gallery_offset() { python3 -c 'import json,sys; print(int(json.loads(sys.argv[1])[1] - json.loads(sys.argv[2])[1]))' "$(gallery_box SectionHeader Buttons)" "$(gallery_box Label Gallery)"; }
if [[ $(ipc smoke scrollTo window vgs.gallery 0) == \[* ]] && offset="$(gallery_offset)" && [[ $(ipc smoke scrollTo window vgs.gallery "$offset") == \[* ]]; then
  expect_cursor "an enabled button shows the hand" pointer window:Gallery "$(gallery_box Button Small)"
  expect_cursor "a disabled button shows the arrow" default window:Gallery "$(gallery_box Button Disabled)"
  expect_cursor "an enabled switch shows the hand" pointer window:Gallery "$(gallery_box Switch Off)"
  expect_cursor "a disabled switch shows the arrow" default window:Gallery "$(gallery_box Switch Disabled)"
  expect_cursor "an enabled checkbox shows the hand" pointer window:Gallery "$(gallery_box Checkbox Unchecked)"
  expect_cursor "a disabled checkbox shows the arrow" default window:Gallery "$(gallery_box Checkbox Disabled)"
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
