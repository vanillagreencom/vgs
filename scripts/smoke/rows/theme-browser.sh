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
# the held close read back before the real download runs. rows/themes.sh
# defines the helpers used here and leaves the plugin disabled, and
# rows/theme-browse.sh leaves vgs applied, no current wallpaper and nord
# not installed; this file enables the plugin and leaves all four so.
set -euo pipefail
view_value() { ipc smoke readDescendant overlay vgs.themes ThemeView "$1"; }
view_names() { view_value shownCards | python3 -c 'import json,sys; print(json.dumps([c["name"] for c in json.load(sys.stdin)]))'; }
view_count() { view_value shownCards | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
has_card() { view_value shownCards | python3 -c 'import json,sys; print(sys.argv[1] in [c["name"] for c in json.load(sys.stdin)])' "$1"; }
# The shown card at INDEX, or the last for -1.
card_at() { view_value shownCards | python3 -c 'import json,sys; print(json.load(sys.stdin)[int(sys.argv[1])]["name"])' "$1"; }
job_step() { view_value job | python3 -c 'import json,sys; j=json.load(sys.stdin); print("none" if j is None else j["step"] + " " + j["name"])'; }
selected_installed() { view_value selected | python3 -c 'import json,sys; print(json.load(sys.stdin)["installed"])'; }
offer_name() { view_value offer | python3 -c 'import json,sys; o=json.load(sys.stdin); print("none" if o is None else o["name"])'; }
badges() { ipc smoke itemTexts overlay vgs.themes Badge | python3 -c 'import json,sys; print(json.dumps(sorted(t[0] for t in json.load(sys.stdin) if t)))'; }
dialog_has() { ipc smoke itemTexts overlay vgs.themes Dialog | python3 -c 'import json,sys; print(any(sys.argv[1] in t for t in json.load(sys.stdin)))' "$1"; }
# The status of the card image drawing PATH, `none` when no card draws it.
card_image() { ipc smoke images overlay vgs.themes | python3 -c 'import json,sys; r=[i[1] for i in json.load(sys.stdin) if i[0]==sys.argv[1]]; print(r[0] if r else "none")' "$1"; }
# Whether a palette card names LABEL: a card with no image draws its
# label, and one whose image shows draws none.
palette_card() { ipc smoke itemTexts overlay vgs.themes ThemeCard | python3 -c 'import json,sys; print(any(sys.argv[1] in t for t in json.load(sys.stdin)))' "$1"; }
has_badge() { ipc smoke itemTexts overlay vgs.themes Badge | python3 -c 'import json,sys,re; print(any(re.fullmatch(sys.argv[1], x) for t in json.load(sys.stdin) for x in t))' "$1"; }
lent_themes() { ipc shell lent | python3 -c 'import json,sys; print(json.dumps([s for s in json.load(sys.stdin)["shortcuts"] if s.startswith("vgs.themes")]))'; }
themes_bind() { hypr -j binds | python3 -c 'import json,sys; print(json.dumps([[b["modmask"], b["key"]] for b in json.load(sys.stdin) if b["description"] == "vgs.themes:themes"]))'; }
catalog_imagery() { "${shell_env[@]}" "$repo/bin/vgsh" theme catalog --json | python3 -c 'import json,sys; print([e["imageryInstalled"] for e in json.load(sys.stdin)["entries"] if e["name"]==sys.argv[1]][0])' "$1"; }
# SUPER+T typed on the nested seat.
press_themes() { type_keys -M logo -k t -m logo; }
browser_focused() { expect_poll "${1:-the browser holds the keyboard}" true ipc smoke activeFocusIn overlay vgs.themes; }

# The fixture archive and nord's pin to it, in the sandbox copy's catalog.
index="$repo/themes/catalog/index.json"
cp -p -- "$index" "$sandbox/catalog-index.json"
assets="$sandbox/theme-assets"
mkdir -p -- "$assets/themes-v1"
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
expect_poll "the themes service registered its shortcut" '["vgs.themes:themes"]' lent_themes
expect_poll "the nested instance binds SUPER+T to the theme browser" '[[64, "T"]]' themes_bind
themes_global() { hypr globalshortcuts | python3 -c 'import sys; print(sum(1 for line in sys.stdin if "vgs.themes:themes" in line))'; }
expect_poll "the compositor lists the themes shortcut" 1 themes_global
# wtype types on a virtual keyboard with keycodes of its own, which a bind
# resolves only by keysym, so the sandbox user's settings turn that on
# for these rows, as rows/hyprland.sh does for its own (docs/architecture/
# runtime.md § Hyprland), and the file is put back after them.
hypr_lua="$home/.config/hypr/hyprland.lua"
cp -p -- "$hypr_lua" "$sandbox/hyprland-before-browser.lua"
printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = true } })' >>"$hypr_lua"
expect "the nested instance reloads with binds resolved by keysym" ok hypr reload config-only
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
expect_poll "vgs, with no image, draws its palette card" True palette_card Vgs
first_card="$(card_at 0)"

# Paging: Home, Right, Left and End move the selection, and a catalog
# card draws its thumbnail.
type_keys -k Home || fail "sending Home failed"
expect_poll "Home selects the first card" "\"$first_card\"" view_value selectedName
expect_poll "the first card draws its catalog thumbnail" ready card_image "$repo/themes/catalog/thumbnails/$first_card.jpg"
expect "a catalog card is badged Not installed" True has_badge "Not installed"
expect "a catalog card is badged with its wallpapers' size" True has_badge "Wallpapers [0-9]+ MB"
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
click_in vgs:overlay overlay vgs.themes QQuickButton Installed || fail "the click on Installed failed"
expect_poll "Installed hides the catalog's nord" '[]' view_names
browser_focused "the rail takes the keyboard back after the scope click"
click_in vgs:overlay overlay vgs.themes QQuickButton All || fail "the click on All failed"
expect_poll "All shows nord again" '["nord"]' view_names

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

expect "disabling vgs.themes after the browser rows is allowed" ok ipc shell setPluginEnabled vgs.themes false
expect_poll "disabling vgs.themes released its shortcut" '[]' lent_themes
expect_poll "disabling vgs.themes unbinds SUPER+T" '[]' themes_bind
cp -p -- "$sandbox/hyprland-before-browser.lua" "$hypr_lua.next" && mv -T -- "$hypr_lua.next" "$hypr_lua"
expect "the nested instance reloads the hyprland.lua the browser rows found" ok hypr reload config-only
mv -T -- "$repo/bin/vgsh.real" "$repo/bin/vgsh"
cp -p -- "$sandbox/catalog-index.json" "$index"
rm -r -- "$installed/nord" "$installed/akane" "$assets" "$wallpaper_gate" "$akane_refused"
rm -f -- "$bg_state/backgrounds.json" "$bg_state/background"
