# The theme browser, vgs.themes' overlay and service: SUPER+T on the
# nested seat opens it, and every row reads what it holds back through the
# probe: the view's cards and state through readDescendant, the images the
# cards draw through images, and the texts of its badges and its Dialog
# through itemTexts. The rows page, filter, install and apply a catalog
# entry, and answer the wallpaper offer both ways. The sandbox copy's
# catalog pins nord's wallpapers to an archive this row builds, served from
# a file:// base, which the runner takes under the sandbox's test-run
# marker. A stand-in holds the download behind a gate after two progress
# lines, polled every 50 ms for at most 30 s, so the Dialog's progress and
# the held close read back before the real download runs. The wallpaper
# view's rows, SUPER+W, follow the theme view's: they flip its source and
# scope, set an image for one screen and for every screen on a second
# headless output and read each screen's drawn image back, and run the
# update card against a second archive the catalog pins anew. A copy of
# WallpaperView.qml that sets every image as the current one is their
# control. rows/themes.sh defines the helpers used here and leaves the
# plugin disabled, and rows/theme-browse.sh leaves vgs applied, no current
# wallpaper and nord not installed; this file enables the plugin and
# leaves all four so.
set -euo pipefail
view_value() { ipc smoke readDescendant overlay vgs.themes ThemeView "$1"; }
view_names() { view_value shownCards | py_reply 'import json,sys; print(json.dumps([c["name"] for c in json.load(sys.stdin)]))'; }
view_selected_name() { view_value selectedName | tr -d '"'; }
view_count() { view_value shownCards | py_reply 'import json,sys; print(len(json.load(sys.stdin)))'; }
has_card() { view_value shownCards | py_reply 'import json,sys; print(sys.argv[1] in [c["name"] for c in json.load(sys.stdin)])' "$1"; }
# The shown card at INDEX, or the last for -1.
card_at() { view_value shownCards | py_reply 'import json,sys; print(json.load(sys.stdin)[int(sys.argv[1])]["name"])' "$1"; }
job_step() { view_value job | py_reply 'import json,sys; j=json.load(sys.stdin); print("none" if j is None else j["step"] + " " + j["name"])'; }
selected_installed() { view_value selected | py_reply 'import json,sys; print(json.load(sys.stdin)["installed"])'; }
selected_preview() { view_value selected | py_reply 'import json,sys; print(json.load(sys.stdin).get("previewImage"))'; }
offer_name() { view_value offer | py_reply 'import json,sys; o=json.load(sys.stdin); print("none" if o is None else o["name"])'; }
badges() { ipc smoke itemTexts overlay vgs.themes Badge | py_reply 'import json,sys; print(json.dumps(sorted(t[0] for t in json.load(sys.stdin) if t)))'; }
dialog_has() { ipc smoke itemTexts overlay vgs.themes Dialog | py_reply 'import json,sys; print(any(sys.argv[1] in t for t in json.load(sys.stdin)))' "$1"; }
# The status of the card image drawing PATH, `none` when no card draws it.
card_image() { ipc smoke images overlay vgs.themes | py_reply 'import json,sys; r=[i[1] for i in json.load(sys.stdin) if i[0]==sys.argv[1]]; print(r[0] if r else "none")' "$1"; }
# Whether a palette card names LABEL: a card with no image draws its
# label, and one whose image shows draws none.
palette_card() { ipc smoke itemTexts overlay vgs.themes ThemeCard | py_reply 'import json,sys; print(any(sys.argv[1] in t for t in json.load(sys.stdin)))' "$1"; }
theme_card_has_colour() { ipc smoke itemColours overlay vgs.themes ThemeCard Rectangle | py_reply 'import json,sys; print(any(sys.argv[1] in row for row in json.load(sys.stdin)))' "$1"; }
has_badge() { ipc smoke itemTexts overlay vgs.themes Badge | py_reply 'import json,sys,re; print(any(re.fullmatch(sys.argv[1], x) for t in json.load(sys.stdin) for x in t))' "$1"; }
lent_themes() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(sorted(s for s in json.load(sys.stdin)["shortcuts"] if s.startswith("vgs.themes"))))'; }
# The binds of shortcut NAME, `themes` by default, as [modmask, key].
themes_bind() { hypr -j binds | py_reply 'import json,sys; print(json.dumps([[b["modmask"], b["key"]] for b in json.load(sys.stdin) if b["description"] == "vgs.themes:" + sys.argv[1] and b.get("submap", "") in ("", "default")]))' "${1:-themes}"; }
catalog_imagery() { "${shell_env[@]}" "$repo/bin/vgsh" theme catalog --json | py_reply 'import json,sys; print([e["imageryInstalled"] for e in json.load(sys.stdin)["entries"] if e["name"]==sys.argv[1]][0])' "$1"; }
# Whether the first ready image drawing PATH asks to decode at its drawn size
# times the CardCarousel's screen scale.
card_source_size_matches() { # PATH
  local dpr
  dpr="$(ipc smoke readDescendant overlay vgs.themes CardCarousel devicePixelRatio)" || return 1
  ipc smoke images overlay vgs.themes | py_reply 'import json,sys; path, dpr = sys.argv[1], float(sys.argv[2]); rows=[i for i in json.load(sys.stdin) if i[0] == path and i[1] == "ready"]; print(bool(rows and rows[0][4] == [round(rows[0][2][0] * dpr), round(rows[0][2][1] * dpr)]))' "$1" "$dpr"
}
# SUPER+T typed on the nested seat.
press_themes() { type_keys -M logo -k t -m logo; }
browser_focused() { expect_poll "${1:-the browser holds the keyboard}" true ipc smoke activeFocusIn overlay vgs.themes; }
all_theme_cards_have_palette() {
  local shown
  shown="$(view_value shownCards)" || return
  ipc smoke paletteStrips overlay vgs.themes | py_reply 'import json, sys
strips = json.load(sys.stdin)
shown = json.loads(sys.argv[1])
shown_ok = {card["name"] for card in shown if card.get("state") != "refused"}
visible_cards = {name for name, card_visible, strip_visible, count in strips if card_visible and name in shown_ok}
visible_strips = [(name, count) for name, card_visible, strip_visible, count in strips if strip_visible and name in shown_ok]
strips_by_name = {name for name, card_visible, strip_visible, count in strips if strip_visible}
print(len(visible_strips) >= 3 and all(count > 0 for name, count in visible_strips) and visible_cards <= strips_by_name)' "$shown"
}
palette_control_card() {
  local shown
  shown="$(view_value shownCards)" || return
  ipc smoke paletteStrips overlay vgs.themes | py_reply 'import json, sys
strips = json.load(sys.stdin)
shown = json.loads(sys.argv[1])
shown_ok = {card["name"] for card in shown if card.get("state") != "refused"}
for name, card_visible, strip_visible, count in strips:
    if name in shown_ok and card_visible and strip_visible and count > 0:
        print(name)
        sys.exit()
sys.exit(1)' "$shown"
}

# The fixture archive and nord's pin to it, in the sandbox copy's catalog.
index="$repo/themes/catalog/index.json"
cp -p -- "$index" "$sandbox/catalog-index.json"
assets="$sandbox/theme-assets"
mkdir -p -- "$assets/themes-v1"
python3 - "$repo/themes/catalog/nord/preview.png" <<'PY'
import base64, sys
open(sys.argv[1], "wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
PY
python3 - "$assets/themes-v1/vgs-theme-nord-smoke.tar.gz" "$repo/themes/catalog/thumbnails/nord.jpg" "$index" <<'PY'
import hashlib, io, json, os, sys, tarfile
out, image, index = sys.argv[1:]
with tarfile.open(out, "w:gz") as tar:
    for name in ("backgrounds/a.jpg", "backgrounds/b.jpg"):
        tar.add(image, arcname=name)
data = open(out, "rb").read()
doc = json.load(open(index))
nord = [e for e in doc["entries"] if e["name"] == "nord"][0]
nord["imagery"] = dict(nord["imagery"], archive=os.path.basename(out), size=len(data), sha256=hashlib.sha256(data).hexdigest())
with open(index + ".next", "w") as f:
    json.dump(doc, f)
os.replace(index + ".next", index)
PY
wallpaper_gate="$sandbox/theme-wallpaper-gate"
# The first apply of akane answers busy, as a runner holding the theme lock
# does; the file records that it did.
akane_refused="$sandbox/theme-akane-refused"
cp -p -- "$repo/bin/vgsh" "$repo/bin/vgsh.real"
stand_in_vgsh "export VGS_THEME_ASSET_BASE=$(printf %q "file://$assets")
if [[ \${2:-} == apply && \${4:-} == akane && ! -e $(printf %q "$akane_refused") ]]; then
  touch -- $(printf %q "$akane_refused")
  printf '%s\n' '{\"state\":\"failed\",\"shell\":\"failed\",\"targets\":[],\"theme\":\"akane\",\"reason\":\"busy\"}'
  exit 75
fi
if [[ \${2:-} == wallpapers ]]; then
  printf '%s\n' '{\"state\":\"downloading\",\"bytes\":0,\"total\":4000000}' '{\"state\":\"downloading\",\"bytes\":2000000,\"total\":4000000}'
  for _ in \$(seq 1 600); do [[ -e $(printf %q "$wallpaper_gate") ]] && break; sleep 0.05; done
fi"

# The service registers the shortcut and the layer binds SUPER+T.
expect "enabling vgs.themes for the browser rows is allowed" ok ipc shell setPluginEnabled vgs.themes true
expect_poll "the themes service registered its shortcuts" '["vgs.themes:themes", "vgs.themes:wallpapers"]' lent_themes
expect_poll "the nested instance binds SUPER+T to the theme browser" '[[64, "T"]]' themes_bind
expect_poll "the nested instance binds SUPER+W to the wallpaper browser" '[[64, "W"]]' themes_bind wallpapers
themes_global() { hypr globalshortcuts | python3 -c 'import sys; print(sum(1 for line in sys.stdin if "vgs.themes:themes" in line))'; }
expect_poll "the compositor lists the themes shortcut" 1 themes_global
# wtype types on a virtual keyboard with keycodes of its own, which a bind
# resolves only by keysym, so the sandbox user's settings turn that on
# for these rows, as rows/hyprland.sh does for its own (docs/architecture/
# runtime-hyprland.md), and the file is put back after them.
hypr_lua="$home/.config/hypr/hyprland.lua"
cp -p -- "$hypr_lua" "$sandbox/hyprland-before-browser.lua"
{
  printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = true } })'
  printf '%s\n' 'hl.bind("SUPER + A", hl.dsp.focus({ direction = "left" }), { description = "Smoke focus left" })'
  printf '%s\n' 'hl.bind("SUPER + D", hl.dsp.focus({ direction = "right" }), { description = "Smoke focus right" })'
} >>"$hypr_lua"
expect "the nested instance reloads with binds resolved by keysym and smoke focus keys" ok hypr reload config-only
expect "no browser shows before SUPER+T" 0 layer_count vgs:overlay
# SUPER+T opens the theme view on the applied theme.
press_themes || fail "typing SUPER+T failed"
expect_poll "SUPER+T opens the browser" 1 layer_count vgs:overlay
expect "the browser shows the theme view" '"themes"' ipc smoke readInstance overlay vgs.themes view
browser_focused "the open browser holds the keyboard"
expect_poll "the browser read the list, the catalog and the images" true view_value loaded
expect "the browser includes the shipped vgs card" True has_card vgs
expect "the browser includes the catalog nord card" True has_card nord
expect "the applied theme is selected" '"vgs"' view_value selectedName
expect_poll "the applied theme is badged Displayed" '["Displayed"]' badges
expect_poll "every built theme card exposes palette colours" True all_theme_cards_have_palette
type_keys -k Home || fail "sending Home before focus bind failed"
focus_first="$(card_at 0)"
focus_second="$(card_at 1)"
type_keys -M logo -k d -m logo || fail "sending the user's focus-right bind failed"
expect_poll "the user's focus-right bind moves the carousel inside the browser" "$focus_second" view_selected_name
type_keys -M logo -k a -m logo || fail "sending the user's focus-left bind failed"
expect_poll "the user's focus-left bind moves the carousel inside the browser" "$focus_first" view_selected_name
press_themes || fail "closing the browser after the focus bind check failed"
expect_poll "the browser closes after the focus bind check" 0 layer_count vgs:overlay
press_themes || fail "reopening the browser after the focus bind check failed"
expect_poll "the browser reopens after the focus bind check" 1 layer_count vgs:overlay
browser_focused "the reopened browser holds the keyboard after the focus bind check"
expect_poll "the reopened browser read its cards after the focus bind check" true view_value loaded
first_card=akane

# A catalog card draws its thumbnail and live preview from its own tokens.
type_keys "$first_card" || fail "typing $first_card failed"
expect_poll "the filter selects the catalog card" "\"$first_card\"" view_value selectedName
expect_poll "the catalog card draws its thumbnail" ready card_image "$repo/themes/catalog/thumbnails/$first_card.jpg"
expect "the catalog card decodes at card size times screen scale" True card_source_size_matches "$repo/themes/catalog/thumbnails/$first_card.jpg"
before_accent="$(ipc smoke readDescendant overlay vgs.themes DesktopPreview accentHex)" || before_accent=""
python3 - "$repo/themes/catalog/$first_card/theme.json" "$index" "$first_card" <<'PY'
import json, os, sys
theme_file, index_file, name = sys.argv[1:]
theme = json.load(open(theme_file))
theme.setdefault("tokens", {}).setdefault("palette", {})["accent"] = "#00ff00"
with open(theme_file + ".next", "w") as f:
    json.dump(theme, f)
os.replace(theme_file + ".next", theme_file)
doc = json.load(open(index_file))
for entry in doc["entries"]:
    if entry["name"] == name:
        entry["palette"]["accent"] = "#00ff00ff"
with open(index_file + ".next", "w") as f:
    json.dump(doc, f)
os.replace(index_file + ".next", index_file)
PY
press_themes || fail "closing the browser for the live preview token change failed"
expect_poll "the browser closes before the live preview token check" 0 layer_count vgs:overlay
press_themes || fail "reopening the browser for the live preview token change failed"
expect_poll "the browser reopens after the live preview token change" 1 layer_count vgs:overlay
expect_poll "the browser rereads the changed package tokens" true view_value loaded
type_keys "$first_card" || fail "typing $first_card after the token change failed"
expect_poll "the live preview changes when the package accent changes" '"#00ff00"' ipc smoke readDescendant overlay vgs.themes DesktopPreview accentHex
expect "the live-preview card keeps the palette strip layer" true ipc smoke readDescendant overlay vgs.themes ThemePaletteStrip visible
expect "a catalog card is badged Not installed" True has_badge "Not installed"
expect "a catalog card is badged with its wallpapers' size" True has_badge "Wallpapers [0-9]+ MB"

# Paging: Home, Right, Left and End move the selection.
type_keys -k Escape || fail "clearing the catalog-card filter failed"
expect_poll "the catalog-card filter clears" '""' view_value filterText
first_card="$(card_at 0)"
type_keys -k Home || fail "sending Home failed"
expect_poll "Home selects the first card" "\"$first_card\"" view_value selectedName
type_keys -k Right || fail "sending Right failed"
expect_poll "Right selects the second card" "\"$(card_at 1)\"" view_value selectedName
type_keys -k Left || fail "sending Left failed"
expect_poll "Left selects the first card again" "\"$first_card\"" view_value selectedName
type_keys -k End || fail "sending End failed"
expect_poll "End selects the last card" "\"$(card_at -1)\"" view_value selectedName

# The filter and the scope.
type_keys "nor" || fail "typing the filter failed"
expect_poll "typing reaches the filter" '"nor"' view_value filterText
type_keys -k BackSpace || fail "sending BackSpace failed"
expect_poll "BackSpace erases a character" '"no"' view_value filterText
type_keys "rd" || fail "typing the rest of the filter failed"
expect_poll "the filter leaves nord alone" '["nord"]' view_names
expect "the selection moves to the one match" '"nord"' view_value selectedName
# Control: scripts/test-qml-unit.sh deletes CardCarousel's modelData rebind and tst_carousel.qml fails.
expect "the drawn centre theme card matches the selected name after filtering" '"nord"' ipc smoke currentThemeCardName overlay vgs.themes
expect_poll "nord's package preview wins over its thumbnail and live preview" "$repo/themes/catalog/nord/preview.png" selected_preview
expect_poll "nord's selected card draws preview.png" ready card_image "$repo/themes/catalog/nord/preview.png"
expect "nord's selected card hides the live preview" false ipc smoke readDescendant overlay vgs.themes DesktopPreview visible
click_in vgs:overlay overlay vgs.themes QQuickButton Installed || fail "the click on Installed failed"
expect_poll "Installed hides the catalog's nord" '[]' view_names
browser_focused "the rail takes the keyboard back after the scope click"
click_in vgs:overlay overlay vgs.themes QQuickButton All || fail "the click on All failed"
expect_poll "All shows nord again" '["nord"]' view_names
type_keys -M alt -k i -m alt || fail "sending Alt+I in the theme view failed"
expect_poll "Alt+I switches the theme view to Installed" 1 view_value scopeIndex
expect_poll "Alt+I hides the catalog card under Installed" '[]' view_names
type_keys -M alt -k i -m alt || fail "sending Alt+I in the theme view again failed"
expect_poll "Alt+I switches the theme view back to All" 0 view_value scopeIndex
expect_poll "Alt+I shows the catalog card again" '["nord"]' view_names

# Enter installs nord, applies it, and offers its wallpapers; Not now
# leaves it applied without them.
type_keys -k Return || fail "sending Return failed"
expect_poll "Enter installs and applies nord" nord ipc smoke themeName
expect_poll "the offer follows the apply" nord offer_name
expect "the browser stays open for the offer" 1 layer_count vgs:overlay
expect "nord is installed as a catalog package" True bash -c '[[ -f $1/nord/.vgs-catalog.json ]] && echo True' _ "$installed"
expect "the Dialog names the theme and the archive's size" True dialog_has "Download wallpapers for Nord (1 MB)?"
click_in vgs:overlay overlay vgs.themes Button "Not now" || fail "the click on Not now failed"
expect_poll "Not now withdraws the offer" none offer_name
expect "Not now leaves the browser open" 1 layer_count vgs:overlay
expect "Not now downloads nothing" False catalog_imagery nord
browser_focused "the rail takes the keyboard back after Not now"

# Enter again applies nord and offers again; Download runs on the lane,
# shows its progress, holds the browser open, and applies nord again.
type_keys -k Return || fail "sending Return again failed"
expect_poll "applying nord again offers its wallpapers again" nord offer_name
type_keys -k Return || fail "sending Return to the Dialog failed"
expect_poll "Download runs the download" "download nord" job_step
expect_poll "the Dialog shows the download's progress" True dialog_has "Downloading 2 of 4 MB"
type_keys -k Escape || fail "sending Escape during the download failed"
press_themes || fail "typing SUPER+T during the download failed"
expect "Escape and SUPER+T leave the browser open during the download" 1 layer_count vgs:overlay
touch -- "$wallpaper_gate"
expect_poll "the download and the apply after it close the browser" 0 layer_count vgs:overlay
expect "the wallpapers are unpacked into nord" True bash -c '[[ -f $1/nord/backgrounds/a.jpg && -f $1/nord/backgrounds/b.jpg ]] && echo True' _ "$installed"
expect "the catalog records the wallpapers" True catalog_imagery nord
expect_poll "the apply after the download shows nord's first wallpaper" "\"$installed/nord/backgrounds/a.jpg\"" bg_current

# nord's card now draws its first wallpaper; Escape clears the filter,
# then closes.
press_themes || fail "typing SUPER+T to reopen failed"
expect_poll "SUPER+T opens the browser again" 1 layer_count vgs:overlay
browser_focused
expect_poll "the reopened browser selects the applied nord" '"nord"' view_value selectedName
expect_poll "nord's card draws its first wallpaper" ready card_image "$installed/nord/backgrounds/a.jpg"
type_keys "x" || fail "typing x failed"
expect_poll "x filters" '"x"' view_value filterText
type_keys -k Escape || fail "sending Escape failed"
expect_poll "Escape clears the filter" '""' view_value filterText
expect "Escape with a filter keeps the browser open" 1 layer_count vgs:overlay
type_keys -k Escape || fail "sending Escape again failed"
expect_poll "Escape with no filter closes the browser" 0 layer_count vgs:overlay
# SUPER+T closes the view it opened, and a click on the scrim closes it.
press_themes || fail "typing SUPER+T failed"
expect_poll "SUPER+T opens the browser" 1 layer_count vgs:overlay
press_themes || fail "typing SUPER+T again failed"
expect_poll "SUPER+T on the open theme view closes it" 0 layer_count vgs:overlay
expect "a summon over IPC opens the first view" ok ipc shell summon overlay vgs.themes '{}'
expect_poll "the summon maps the browser" 1 layer_count vgs:overlay
expect_poll "the summoned browser read its cards" true view_value loaded
click 4 4
expect_poll "a click on the scrim closes the browser" 0 layer_count vgs:overlay
expected_errors+=('summon host: vgs\.themes open\(\) failed: payload=')
expect "a payload naming no view is refused" "refused: open-failed=vgs.themes" ipc shell summon overlay vgs.themes '{"view":"fonts"}'
expect "a payload with an unknown key is refused" "refused: open-failed=vgs.themes" ipc shell summon overlay vgs.themes '{"view":"themes","source":"all"}'
expect_poll "a refused summon leaves no browser" 0 layer_count vgs:overlay

# An install whose apply fails leaves the theme installed: the cards are
# read again, so Enter retries the apply and not the install.
press_themes || fail "typing SUPER+T for akane failed"
expect_poll "SUPER+T opens the browser for akane" 1 layer_count vgs:overlay
browser_focused
type_keys "akane" || fail "typing akane failed"
expect_poll "the filter selects akane" '"akane"' view_value selectedName
type_keys -k Return || fail "sending Return for akane failed"
expect_poll "the apply after the install fails with the runner's reason" '"Applying Akane failed: busy"' view_value problem
expect "the install before the failed apply landed" True bash -c '[[ -f $1/akane/.vgs-catalog.json ]] && echo True' _ "$installed"
expect_poll "the cards read akane installed after the failed apply" True selected_installed
type_keys -k Return || fail "sending Return to retry akane failed"
expect_poll "Enter retries the apply" akane ipc smoke themeName
expect_poll "the retried apply offers akane's wallpapers" akane offer_name
click_in vgs:overlay overlay vgs.themes Button "Not now" || fail "the click on Not now for akane failed"
expect_poll "Not now withdraws akane's offer" none offer_name
type_keys -k Escape || fail "sending Escape to clear akane's filter failed"
type_keys -k Escape || fail "sending Escape to close after akane failed"
expect_poll "Escape twice closes the browser after akane" 0 layer_count vgs:overlay

# vgs applies from the browser, which closes it, since vgs offers nothing.
press_themes || fail "typing SUPER+T for vgs failed"
expect_poll "SUPER+T opens the browser for vgs" 1 layer_count vgs:overlay
browser_focused
type_keys "vgs" || fail "typing vgs failed"
expect_poll "the filter selects vgs" '"vgs"' view_value selectedName
type_keys -k Return || fail "sending Return for vgs failed"
expect_poll "Enter applies vgs" vgs ipc smoke themeName
expect_poll "an apply that offers nothing closes the browser" 0 layer_count vgs:overlay

# ---- the wallpaper view -----------------------------------------------------
# nord, applied with its two downloaded images, and a second headless
# output. The browser opens on the focused output; the rows read which one
# from the view and name the other.
wall_value() { ipc smoke readDescendant overlay vgs.themes WallpaperView "$1"; }
wall_keys() { wall_value cards | py_reply 'import json,sys; print(json.dumps([c["key"] for c in json.load(sys.stdin)]))'; }
wall_selected() { wall_value selected | py_reply 'import json,sys; s=json.load(sys.stdin); print("none" if s is None else s["key"])'; }
# Whether the cards hold every KEY.
wall_has() { wall_value cards | py_reply 'import json,sys; keys=[c["key"] for c in json.load(sys.stdin)]; print(all(k in keys for k in sys.argv[1:]))' "$@"; }
wall_job() { wall_value job | py_reply 'import json,sys; j=json.load(sys.stdin); print("none" if j is None else j["step"])'; }
press_wallpapers() { type_keys -M logo -k w -m logo; }
nord_a="$installed/nord/backgrounds/a.jpg"; nord_b="$installed/nord/backgrounds/b.jpg"; nord_c="$installed/nord/backgrounds/c.jpg"
wall_output=SMOKE-WALL
# Whether the first segmented control, the source control in the wallpaper
# view and the scope control in the theme view, holds the keyboard.
segment_focused() { ipc smoke readDescendant overlay vgs.themes SegmentedControl activeFocus; }
thumbs="$repo/themes/catalog/thumbnails"
# The width over the height of the file IMAGE, a JPEG, and of the ready card
# image drawing PATH, `none` while none is ready, each to one decimal place.
# A card decodes to cover its box, so its image keeps the file's ratio.
file_ratio() {
  python3 - "$1" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read(); i = 2
while i < len(d):
    m, l = d[i + 1], struct.unpack(">H", d[i + 2:i + 4])[0]
    if m in (0xC0, 0xC1, 0xC2):
        h, w = struct.unpack(">HH", d[i + 5:i + 9]); print("%.1f" % (w / h)); break
    i += 2 + l
PY
}
card_ratio() { ipc smoke images overlay vgs.themes | py_reply 'import json,sys; r=[i[3] for i in json.load(sys.stdin) if i[0]==sys.argv[1] and i[1]=="ready"]; print("%.1f" % (r[0][0] / r[0][1]) if r else "none")' "$1"; }
# pin_nord ARCHIVE B_IMAGE: an archive holding b.jpg from B_IMAGE and a.jpg
# and c.jpg from nord's thumbnail, pinned for nord in the sandbox copy's
# catalog, which the update card then offers.
pin_nord() {
  python3 - "$assets/themes-v1/$1" "$2" "$thumbs/nord.jpg" "$index" <<'PY'
import hashlib, json, os, sys, tarfile
out, second, image, index = sys.argv[1:]
with tarfile.open(out, "w:gz") as tar:
    tar.add(image, arcname="backgrounds/a.jpg")
    tar.add(second, arcname="backgrounds/b.jpg")
    tar.add(image, arcname="backgrounds/c.jpg")
data = open(out, "rb").read()
doc = json.load(open(index))
nord = [e for e in doc["entries"] if e["name"] == "nord"][0]
nord["imagery"] = dict(nord["imagery"], archive=os.path.basename(out), size=len(data), sha256=hashlib.sha256(data).hexdigest())
with open(index + ".next", "w") as f:
    json.dump(doc, f)
os.replace(index + ".next", index)
PY
}
# plugin_control FILE LABEL OLD NEW: rescan vgs.themes with the OLD text of
# its FILE, which must occur once, replaced by NEW; plugin_restore FILE
# LABEL rescans it with the file put back. Each waits for the scan to
# publish a new revision of the plugin and for the follow after it.
themes_revision() { ipc shell listPlugins | py_reply 'import json,sys; print([p["revision"] for p in json.load(sys.stdin)["plugins"] if p["id"]=="vgs.themes"][0])'; }
themes_revised() { [[ $(themes_revision) != "$1" ]] && echo revised || echo same; }
themes_rescan() { # LABEL
  local before
  before="$(themes_revision)" || { fail "the revision before $1 is unreadable"; return; }
  expect "a rescan builds $1" ok ipc shell rescanPlugins
  expect_poll "the rescan publishes $1" revised themes_revised "$before"
  expect "the follow after the rescan for $1 ends" idle theme_idle
}
plugin_control() {
  local file="$repo/shell/plugins/vgs.themes/$1"
  cp -p -- "$file" "$sandbox/$1.real"
  python3 - "$sandbox/$1.real" "$file.tmp" "$3" "$4" <<'PY' || { fail "the $2 control's text occurs once in $1"; return; }
import pathlib, sys
src, dst, old, new = sys.argv[1:]
text = pathlib.Path(src).read_text()
assert text.count(old) == 1, "control text must match once: " + old
pathlib.Path(dst).write_text(text.replace(old, new))
PY
  mv -T -- "$file.tmp" "$file"
  themes_rescan "the $2 control"
}
plugin_restore() {
  local file="$repo/shell/plugins/vgs.themes/$1"
  cp -- "$sandbox/$1.real" "$file.tmp" && mv -T -- "$file.tmp" "$file"
  themes_rescan "the view the $2 control replaced"
}

# Controls for the preview guarantees above.
plugin_control ThemeCard.qml "preview sourceSize" "decodeSize: root.decodeSize" "decodeSize: Qt.size(1, 1)"
press_themes || fail "typing SUPER+T for the preview sourceSize control failed"
expect_poll "the sourceSize control opens the theme browser" 1 layer_count vgs:overlay
expect_poll "the sourceSize control read its cards" true view_value loaded
type_keys -k Home || fail "sending Home for the sourceSize control failed"
expect_poll "control: the live preview no longer decodes at card size times scale" False card_source_size_matches "$repo/themes/catalog/thumbnails/$first_card.jpg"
type_keys -k Escape || fail "closing the sourceSize control browser failed"
expect_poll "the sourceSize control browser closes" 0 layer_count vgs:overlay
plugin_restore ThemeCard.qml "preview sourceSize"

plugin_control ThemeCard.qml "live preview token" "tokens: root.modelData.tokens" "tokens: ({})"
press_themes || fail "typing SUPER+T for the live preview control failed"
expect_poll "the live preview control opens the theme browser" 1 layer_count vgs:overlay
expect_poll "the live preview control read its cards" true view_value loaded
type_keys "$first_card" || fail "typing $first_card for the live preview control failed"
expect "control: the live preview no longer uses the package accent" '"#ff5a36"' ipc smoke readDescendant overlay vgs.themes DesktopPreview accentHex
type_keys -k Escape || fail "clearing the live preview control filter failed"
type_keys -k Escape || fail "closing the live preview control browser failed"
expect_poll "the live preview control browser closes" 0 layer_count vgs:overlay
plugin_restore ThemeCard.qml "live preview token"

plugin_control ThemeCard.qml "preview precedence" "readonly property string cheapImage: packagePreview ? modelData.previewImage : typeof modelData.sharpenedImage === \"string\" && modelData.sharpenedImage !== \"\" ? modelData.sharpenedImage : modelData.image" "readonly property string cheapImage: modelData.image"
press_themes || fail "typing SUPER+T for the preview precedence control failed"
expect_poll "the preview precedence control opens the theme browser" 1 layer_count vgs:overlay
expect_poll "the preview precedence control read its cards" true view_value loaded
type_keys "nord" || fail "typing nord for the preview precedence control failed"
expect_poll "the preview precedence control selects nord" '"nord"' view_value selectedName
expect "control: nord no longer draws preview.png first" none card_image "$repo/themes/catalog/nord/preview.png"
expect "control: nord shows the live preview instead" true ipc smoke readDescendant overlay vgs.themes DesktopPreview visible
type_keys -k Escape || fail "clearing the preview precedence control filter failed"
type_keys -k Escape || fail "closing the preview precedence control browser failed"
expect_poll "the preview precedence control browser closes" 0 layer_count vgs:overlay
plugin_restore ThemeCard.qml "preview precedence"

expect "the follow before the wallpaper rows ends" idle theme_idle
expect "nord applies for the wallpaper rows" "ok theme=nord state=applied shell=applied" vgsh_theme apply nord
expect_poll "the shell follows nord" nord ipc smoke themeName
expect "the nested compositor adds a monitor for the wallpaper rows" ok hypr output create headless "$wall_output"
expect_poll "the wallpaper rows' monitor is listed" True screen_listed "$wall_output"
expect_poll "the wallpaper rows' monitor draws nord's first image" "$nord_a ready" background_image_on "$wall_output"

press_wallpapers || fail "typing SUPER+W failed"
expect_poll "SUPER+W opens the browser" 1 layer_count vgs:overlay
expect "the browser shows the wallpaper view" '"wallpapers"' ipc smoke readInstance overlay vgs.themes view
browser_focused "the wallpaper view holds the keyboard"
expect_poll "the wallpaper view read the images and the catalog" true wall_value loaded
if ! this_screen="$(wall_value screenName | tr -d '"')"; then fail "reading the wallpaper view's screen failed"; this_screen=""; fi
if [[ $this_screen == "$wall_output" ]]; then other_screen="$screen_name"; else other_screen="$wall_output"; fi
expect "the wallpaper view shows on one of the two outputs" True python3 -c 'import sys; print(sys.argv[1] in sys.argv[2:])' "$this_screen" "$screen_name" "$wall_output"
expect "the view starts on the theme source" '"theme"' wall_value source
expect "the theme source lists nord's images and no card" "[\"$nord_a\", \"$nord_b\"]" wall_keys
expect "the view starts on every monitor" '"every"' wall_value scope
expect "two screens show the scope control" true wall_value scoped
expect_poll "the selection starts on the image every screen shows" "$nord_a" wall_selected
expect "the wallpaper card decodes at card size times screen scale" True card_source_size_matches "$nord_a"
expect_poll "the shown image is badged Shown" True has_badge Shown

# The toggles: Alt+S flips the source, Alt+M flips the scope, and
# Tab and Shift+Tab switch the top tabs. None moves the selected card.
type_keys -M alt -k s -m alt || fail "sending Alt+S failed"
expect_poll "Alt+S shows every source" '"all"' wall_value source
expect_poll "every source lists nord's images" True wall_has "$nord_a" "$nord_b"
expect "the all source badges the image's package" True has_badge Nord
type_keys -M alt -k s -m alt || fail "sending Alt+S again failed"
expect_poll "Alt+S shows the theme again" '"theme"' wall_value source
type_keys -k Tab || fail "sending Tab failed"
expect_poll "Tab switches to the theme view" '"themes"' ipc smoke readInstance overlay vgs.themes view
type_keys -M shift -k Tab -m shift || fail "sending Shift+Tab failed"
expect_poll "Shift+Tab switches back to the wallpaper view" '"wallpapers"' ipc smoke readInstance overlay vgs.themes view
type_keys -M alt -k m -m alt || fail "sending Alt+M failed"
expect_poll "Alt+M flips the scope to this monitor" '"this"' wall_value scope
expect_poll "Alt+M moves no card while the scope shows" "$nord_a" wall_selected
type_keys -M alt -k m -m alt || fail "sending Alt+M again failed"
expect_poll "Alt+M flips the scope back" '"every"' wall_value scope
type_keys -M alt -k m -m alt || fail "sending Alt+M for this monitor failed"
expect_poll "Alt+M flips the scope to this monitor again" '"this"' wall_value scope

# This monitor: Enter sets b.jpg on the browser's screen alone and closes.
type_keys -k Right || fail "sending Right failed"
expect_poll "Right selects b.jpg" "$nord_b" wall_selected
type_keys -k Return || fail "sending Return for this monitor failed"
expect_poll "a set for this monitor closes the browser" 0 layer_count vgs:overlay
expect_poll "the browser's screen draws b.jpg" "$nord_b ready" background_image_on "$this_screen"
expect "the other screen keeps nord's first image" "$nord_a ready" background_image_on "$other_screen"
expect "a set for this monitor keeps the current image" "\"$nord_a\"" bg_current

# Each open starts on every monitor; This monitor selects the screen's own
# image, and All monitors sets the current image on every screen, the
# screen's own cleared.
press_wallpapers || fail "typing SUPER+W to reopen failed"
expect_poll "SUPER+W opens the browser again" 1 layer_count vgs:overlay
expect_poll "the reopened view read its lists" true wall_value loaded
expect "the reopened view is on every monitor again" '"every"' wall_value scope
expect_poll "every monitor selects the current image" "$nord_a" wall_selected
type_keys -M alt -k m -m alt || fail "sending Alt+M to this monitor failed"
expect_poll "this monitor selects the screen's own image" "$nord_b" wall_selected
type_keys -M alt -k m -m alt || fail "sending Alt+M to every monitor failed"
expect_poll "every monitor selects the current image again" "$nord_a" wall_selected
type_keys -k Return || fail "sending Return for every monitor failed"
expect_poll "a set for every monitor closes the browser" 0 layer_count vgs:overlay
expect_poll "the browser's screen draws a.jpg again" "$nord_a ready" background_image_on "$this_screen"
expect "the other screen draws a.jpg" "$nord_a ready" background_image_on "$other_screen"
expect "a set for every monitor clears each screen's own image" '{}' bg_screens

# Control: a copy of the view that sets every image as the current one
# moves the other screen's image under This monitor.
plugin_control WallpaperView.qml scope "shell.theme.set(card.path, BrowserLogic.setScreen(scope, screenName), result => {" "shell.theme.set(card.path, null, result => {"
press_wallpapers || fail "typing SUPER+W for the scope control failed"
expect_poll "SUPER+W opens the scope control's browser" 1 layer_count vgs:overlay
expect_poll "the scope control's view read its lists" true wall_value loaded
type_keys -M alt -k m -m alt -k Right || fail "sending Alt+M and Right to the scope control failed"
expect_poll "the scope control selects b.jpg for this monitor" "$nord_b" wall_selected
type_keys -k Return || fail "sending Return to the scope control failed"
expect_poll "the scope control's set closes the browser" 0 layer_count vgs:overlay
expect_poll "the scope control moves the other screen's image too" "$nord_b ready" background_image_on "$other_screen"
plugin_restore WallpaperView.qml scope
expect "set --every-screen puts nord's first image back on every screen" "ok background=a.jpg theme=nord path=$nord_a screen=*" vgsh_theme background set "$nord_a" --every-screen

# A click on the segment already chosen hands the keyboard back as a
# change does: Right then steps the rail and leaves the source. In the
# theme view it leaves the scope. Controls: a copy of each view whose
# control keeps the keyboard switches the source or the scope on Right.
press_wallpapers || fail "typing SUPER+W for the segment click failed"
expect_poll "SUPER+W opens the browser for the segment click" 1 layer_count vgs:overlay
expect_poll "the segment-click view selects a.jpg" "$nord_a" wall_selected
click_in vgs:overlay overlay vgs.themes QQuickButton Theme || fail "the click on the chosen Theme segment failed"
expect_poll "the view takes the keyboard back after a click on the chosen source" false segment_focused
type_keys -k Right || fail "sending Right after the segment click failed"
expect_poll "Right after the click steps the rail" "$nord_b" wall_selected
expect "Right after the click leaves the source" '"theme"' wall_value source
type_keys -k Escape || fail "sending Escape after the segment click failed"
expect_poll "Escape closes the browser after the segment click" 0 layer_count vgs:overlay
press_themes || fail "typing SUPER+T for the segment click failed"
expect_poll "SUPER+T opens the theme view for the segment click" 1 layer_count vgs:overlay
expect_poll "the theme view read its cards for the segment click" true view_value loaded
click_in vgs:overlay overlay vgs.themes QQuickButton All || fail "the click on the chosen All segment failed"
expect_poll "the theme view takes the keyboard back after a click on the chosen scope" false segment_focused
type_keys -k Right || fail "sending Right in the theme view failed"
expect "Right after the click leaves the theme view's scope" 0 view_value scopeIndex
type_keys -k Escape || fail "sending Escape to the theme view failed"
expect_poll "Escape closes the theme view after the segment click" 0 layer_count vgs:overlay
plugin_control WallpaperView.qml "wallpaper focus" $'currentIndex: root.sourceIndex\n                    onActiveFocusChanged: if (activeFocus) Qt.callLater(root.takeKeys)' 'currentIndex: root.sourceIndex'
press_wallpapers || fail "typing SUPER+W for the wallpaper focus control failed"
expect_poll "SUPER+W opens the wallpaper focus control's browser" 1 layer_count vgs:overlay
expect_poll "the wallpaper focus control's view read its lists" true wall_value loaded
click_in vgs:overlay overlay vgs.themes QQuickButton Theme || fail "the click on the focus control's Theme segment failed"
type_keys -k Right || fail "sending Right to the wallpaper focus control failed"
expect_poll "the wallpaper focus control's Right switches the source" '"all"' wall_value source
press_wallpapers || fail "typing SUPER+W to close the wallpaper focus control failed"
expect_poll "SUPER+W closes the wallpaper focus control's browser, whose keys the control holds" 0 layer_count vgs:overlay
plugin_restore WallpaperView.qml "wallpaper focus"
plugin_control ThemeView.qml "theme focus" $'\n                onActiveFocusChanged: if (activeFocus) Qt.callLater(root.focusRail)' ''
press_themes || fail "typing SUPER+T for the theme focus control failed"
expect_poll "SUPER+T opens the theme focus control's browser" 1 layer_count vgs:overlay
expect_poll "the theme focus control read its cards" true view_value loaded
click_in vgs:overlay overlay vgs.themes QQuickButton All || fail "the click on the focus control's All segment failed"
type_keys -k Right || fail "sending Right to the theme focus control failed"
expect_poll "the theme focus control's Right switches the scope" 1 view_value scopeIndex
type_keys -k Escape || fail "sending Escape to the theme focus control failed"
expect_poll "Escape closes the theme focus control's browser" 0 layer_count vgs:overlay
plugin_restore ThemeView.qml "theme focus"
plugin_control BrowserLogic.js "theme toggle key" 'if (alt) return key === KEY.I ? "scope" : "";' 'if (alt) return "";'
press_themes || fail "typing SUPER+T for the theme toggle key control failed"
expect_poll "SUPER+T opens the theme toggle key control browser" 1 layer_count vgs:overlay
expect_poll "the theme toggle key control read its cards" true view_value loaded
type_keys -M alt -k i -m alt || fail "sending Alt+I to the theme toggle key control failed"
expect_poll "the theme toggle key control leaves the scope unchanged" 0 view_value scopeIndex
type_keys -k Escape || fail "sending Escape to the theme toggle key control failed"
expect_poll "Escape closes the theme toggle key control browser" 0 layer_count vgs:overlay
plugin_restore BrowserLogic.js "theme toggle key"
press_themes || fail "typing SUPER+T to choose a palette control card failed"
expect_poll "SUPER+T opens the browser to choose a palette control card" 1 layer_count vgs:overlay
expect_poll "the palette control chooser read its cards" true view_value loaded
palette_card_name="$(palette_control_card)" || { fail "the palette control card is readable"; return; }
type_keys -k Escape || fail "sending Escape after choosing a palette control card failed"
expect_poll "Escape closes the palette control chooser" 0 layer_count vgs:overlay
plugin_control ThemeCard.qml palette 'palette: root.colors' "palette: root.modelData.name === \"$palette_card_name\" ? null : root.colors"
press_themes || fail "typing SUPER+T for the palette control failed"
expect_poll "SUPER+T opens the palette control browser" 1 layer_count vgs:overlay
expect_poll "the palette control read its cards" true view_value loaded
expect_poll "the palette control removes one visible card's swatches" False all_theme_cards_have_palette
type_keys -k Escape || fail "sending Escape to the palette control failed"
expect_poll "Escape closes the palette control browser" 0 layer_count vgs:overlay
plugin_restore ThemeCard.qml palette

# The update card: the catalog pins a newer archive, which replaces b.jpg
# under its name with an image of another shape and adds c.jpg. Enter on
# it runs the update form on the download lane, applies nord again, reads
# the lists again, loads every card's image again and stays open. Each
# card image is read back by the ratio it decodes to. A changed generation
# makes the card image URL change; a copy that drops that stamp keeps Qt's
# old decode for the same path.
plugin_control WallpaperCard.qml identity "Files.stampedUrl(root.modelData.path, root.modelData.generation)" "Files.fileUrl(root.modelData.path)"
pin_nord vgs-theme-nord-smoke2.tar.gz "$thumbs/frankenstein.jpg"
press_wallpapers || fail "typing SUPER+W for the identity control failed"
expect_poll "SUPER+W opens the identity control's browser" 1 layer_count vgs:overlay
expect_poll "the theme source ends with the update card" "[\"$nord_a\", \"$nord_b\", \"update\"]" wall_keys
expect_poll "the identity control draws nord's b.jpg" "$(file_ratio "$thumbs/nord.jpg")" card_ratio "$nord_b"
type_keys -k End || fail "sending End failed"
expect_poll "End selects the update card" update wall_selected
type_keys -k Return || fail "sending Return to the identity control's update card failed"
expect_poll "the identity control's update, apply and lists end" none wall_job
expect "the identity control's update left no problem" '""' wall_value problem
expect_poll "the theme source lists the third image and no card" "[\"$nord_a\", \"$nord_b\", \"$nord_c\"]" wall_keys
expect "the update replaced b.jpg on disk" True bash -c 'cmp -s -- "$1" "$2" && echo True' _ "$thumbs/frankenstein.jpg" "$nord_b"
expect "control: an unstamped image URL keeps drawing the replaced b.jpg's old picture" "$(file_ratio "$thumbs/nord.jpg")" card_ratio "$nord_b"
type_keys -k Escape || fail "sending Escape to the identity control failed"
expect_poll "Escape closes the identity control's browser" 0 layer_count vgs:overlay
plugin_restore WallpaperCard.qml identity
pin_nord vgs-theme-nord-smoke3.tar.gz "$thumbs/biscuit-de-mar.jpg"
press_wallpapers || fail "typing SUPER+W for the update failed"
expect_poll "SUPER+W opens the browser for the update" 1 layer_count vgs:overlay
expect_poll "a new open draws the b.jpg the last update replaced" "$(file_ratio "$thumbs/frankenstein.jpg")" card_ratio "$nord_b"
expect_poll "the theme source ends with the next update card" "[\"$nord_a\", \"$nord_b\", \"$nord_c\", \"update\"]" wall_keys
type_keys -k End || fail "sending End for the update failed"
expect_poll "End selects the next update card" update wall_selected
type_keys -k Return || fail "sending Return to the update card failed"
expect_poll "the update, the apply after it and the lists end" none wall_job
expect "the update left no problem" '""' wall_value problem
expect "the update keeps the browser open" 1 layer_count vgs:overlay
expect_poll "the rail draws the b.jpg the update replaced" "$(file_ratio "$thumbs/biscuit-de-mar.jpg")" card_ratio "$nord_b"
expect "the update unpacks the third image" True bash -c '[[ -f $1 ]] && echo True' _ "$nord_c"
type_keys -k Escape || fail "sending Escape after the update failed"
expect_poll "Escape closes the browser after the update" 0 layer_count vgs:overlay

# One screen: no scope control, Alt+M does nothing and Tab switches tabs.
expect "the nested compositor removes the wallpaper rows' monitor" ok hypr output remove "$wall_output"
expect_poll "the wallpaper rows' monitor is gone" False screen_listed "$wall_output"
press_wallpapers || fail "typing SUPER+W on one screen failed"
expect_poll "SUPER+W opens the browser on one screen" 1 layer_count vgs:overlay
expect_poll "the one-screen view read its lists" true wall_value loaded
expect "one screen shows no scope control" false wall_value scoped
expect_poll "one screen selects the current image" "$nord_a" wall_selected
type_keys -M alt -k m -m alt || fail "sending Alt+M on one screen failed"
expect "Alt+M on one screen leaves every monitor" '"every"' wall_value scope
type_keys -k Tab || fail "sending Tab on one screen failed"
expect_poll "Tab on one screen switches to the theme view" '"themes"' ipc smoke readInstance overlay vgs.themes view
type_keys -M shift -k Tab -m shift || fail "sending Shift+Tab on one screen failed"
expect_poll "Shift+Tab on one screen switches back to the wallpaper view" '"wallpapers"' ipc smoke readInstance overlay vgs.themes view
press_wallpapers || fail "typing SUPER+W to close failed"
expect_poll "SUPER+W on the open wallpaper view closes it" 0 layer_count vgs:overlay
expect "the follow after the wallpaper rows ends" idle theme_idle
expect "vgs applies after the wallpaper rows" "ok theme=vgs state=applied shell=applied" vgsh_theme apply vgs
expect_poll "the shell follows vgs after the wallpaper rows" vgs ipc smoke themeName

expect "disabling vgs.themes after the browser rows is allowed" ok ipc shell setPluginEnabled vgs.themes false
expect_poll "disabling vgs.themes released its shortcut" '[]' lent_themes
expect_poll "disabling vgs.themes unbinds SUPER+T" '[]' themes_bind
expect_poll "disabling vgs.themes unbinds SUPER+W" '[]' themes_bind wallpapers
cp -p -- "$sandbox/hyprland-before-browser.lua" "$hypr_lua.next" && mv -T -- "$hypr_lua.next" "$hypr_lua"
expect "the nested instance reloads the hyprland.lua the browser rows found" ok hypr reload config-only
mv -T -- "$repo/bin/vgsh.real" "$repo/bin/vgsh"
cp -p -- "$sandbox/catalog-index.json" "$index"
rm -r -- "$installed/nord" "$installed/akane" "$assets" "$wallpaper_gate" "$akane_refused"
rm -f -- "$bg_state/backgrounds.json" "$bg_state/background"
