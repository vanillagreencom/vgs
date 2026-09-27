# The overlay components, from a fixture bar widget holding a popover, a
# tooltip, a menu and a select, and a fixture panel with a select nested in
# a summoned surface. Each overlay is a Qt window popup: it leaves the bar,
# takes keys through the nested seat, follows its anchor and closes on a
# press outside, on Escape and when its anchor hides. Popup rectangles are
# read through the popup's content item in the bar window's coordinates,
# the same coordinates a click takes, since the bar sits at the origin.
set -euo pipefail
ov="$home/.config/vgs/plugins/acme.overlays"
mkdir -p "$ov"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.overlays/." "$ov/"
expect "rescan after adding the overlay fixture answers ok" ok ipc shell rescanPlugins
expect_poll "the overlay fixture is discovered" True plugin_known acme.overlays
expect_poll "enabling the overlay fixture is allowed" ok ipc shell setPluginEnabled acme.overlays true
ov_key="$(bar_key)"
expect_poll "the overlay widget is built in the bar" True record_exists acme.overlays
ovw() { ipc smoke invokeInstance "$ov_key" acme.overlays "$1" ''; }
ovr() { ipc smoke readInstance "$ov_key" acme.overlays "$1"; }
rect() { python3 -c 'import json,sys; print(*json.loads(sys.argv[1]))' "$1"; }
centre_of() { python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); print(int(x+w/2), int(y+h/2))' "$1"; }
bar_h="$(ovr barSize)"
click_centre "$ov_key" acme.overlays || fail "the click on the overlay widget failed"

# A popover leaves the bar, takes focus and keys, and closes on Escape and
# on a press outside. Its top-left sits at the anchor's bottom-left, the
# theme's gap below.
expect "the widget opens its popover" ok ovw openPopover
expect_poll "the popover is open" true ovr popoverOpen
placed_under() { python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); ax,ay,aw,ah=json.loads(sys.argv[2]); print("placed" if (x, y) == (ax, ay + ah + 4) and h > int(sys.argv[3]) and w == 160 else "popover=%s anchor=%s" % (sys.argv[1], sys.argv[2]))' "$(ovw popoverGeometry)" "$(ovw anchorGeometry)" "$bar_h"; }
render expect_poll "the popover sits under its anchor and is taller than the bar" placed placed_under
expect "the popover's input takes focus" ok ovw focusInput
expect_poll "the input holds active focus" true ovr inputFocus
type_keys ab || fail "typing into the popover failed"
expect_poll "typed keys reach the popover's input" '"ab"' ovr typed
type_keys -k Escape || fail "sending Escape failed"
expect_poll "Escape closes the popover" false ovr popoverOpen
expect "the widget opens its popover again" ok ovw openPopover
expect_poll "the popover is open before the outside press" true ovr popoverOpen
click "$((mon_w / 2))" "$((mon_h / 2))" || fail "the click outside the popover failed"
expect_poll "a press outside closes the popover" false ovr popoverOpen

# The popover follows its anchor and closes when the anchor hides.
expect "the widget opens its popover for the anchor rows" ok ovw openPopover
expect_poll "the popover is open before the anchor moves" true ovr popoverOpen
expect "moving the anchor is allowed" ok ovw moveAnchor
render expect_poll "the popover follows its moved anchor" placed placed_under
expect "hiding the anchor is allowed" ok ovw hideAnchor
expect_poll "hiding the anchor closes its popover" false ovr popoverOpen
expect "showing the anchor again is allowed" ok ovw showAnchor

# A tooltip opens on hover after the delay, closes when the pointer leaves,
# and stays closed while a popover is open.
read -r tx ty < <(centre_of "$(ovw tipTargetGeometry)")
hover "$tx" "$ty" || fail "hovering the tooltip target failed"
expect_poll "hovering the target opens its tooltip" true ovr tooltipOpen
hover "$((mon_w / 2))" "$((mon_h / 2))" || fail "moving the pointer away failed"
expect_poll "leaving the target closes its tooltip" false ovr tooltipOpen
expect "the widget opens its popover beside the tooltip target" ok ovw openPopover
expect_poll "the popover is open under the hover" true ovr popoverOpen
hover "$tx" "$ty" || fail "hovering the target under the popover failed"
sleep 1
expect "a tooltip does not open while a popover is open" false ovr tooltipOpen
type_keys -k Escape || fail "sending Escape failed"
expect_poll "Escape closes the popover under the hover" false ovr popoverOpen
hover "$((mon_w / 2))" "$((mon_h / 2))" || fail "moving the pointer away failed"

# A menu takes the arrow keys and Enter, and Escape closes it.
expect "the widget opens its menu" ok ovw openMenu
expect_poll "the menu is open" true ovr menuOpen
type_keys -k Down -k Down -k Return || fail "sending keys to the menu failed"
expect_poll "the keys trigger the second entry" 1 ovr triggered
expect_poll "a triggered entry closes the menu" false ovr menuOpen
expect "the widget opens its menu again" ok ovw openMenu
expect_poll "the menu is open before Escape" true ovr menuOpen
type_keys -k Escape || fail "sending Escape failed"
expect_poll "Escape closes the menu" false ovr menuOpen

# A select chooses by pointer and by keyboard. The list's rectangle is read
# through the list's own item, in the bar window's coordinates.
expect "the select starts on the first entry" 0 ovr selected
expect "the widget opens its select" ok ovw openSelect
expect_poll "the select list is open" true ovr selectOpen
read -r lx ly lw lh < <(rect "$(ovw selectListGeometry)")
click "$((lx + lw / 2))" "$((ly + lh / 2))" || fail "the click on the middle entry failed"
expect_poll "a click on the middle entry chooses it" 1 ovr selected
expect_poll "a choice closes the list" false ovr selectOpen
expect "the widget opens its select for the keys" ok ovw openSelect
expect_poll "the select list is open for the keys" true ovr selectOpen
type_keys -k Down -k Return || fail "sending keys to the select failed"
expect_poll "the keys choose the next entry" 2 ovr selected
expect_poll "the keyboard choice closes the list" false ovr selectOpen

# A select inside a summoned panel opens its list over the panel's popup
# and the panel stays open through the choice.
expect "the widget summons the fixture panel" ok ovw summonHere
expect_poll "the panel is open" 1 ipc smoke readInstance panel acme.overlays opened
expect "the panel opens its select" ok ipc smoke invokeInstance panel acme.overlays openSelect ''
expect_poll "the nested list is open" true ipc smoke readInstance panel acme.overlays selectOpen
read -r nx ny nw nh < <(rect "$(ipc smoke invokeInstance panel acme.overlays selectListGeometry '')")
click "$((nx + nw / 2))" "$((ny + nh / 2))" || fail "the click on the nested entry failed"
expect_poll "the nested list chooses on click" 1 ipc smoke readInstance panel acme.overlays selected
expect "the panel stays open through the choice" 1 ipc smoke readInstance panel acme.overlays opened
expect "hiding the panel is allowed" ok ipc shell hide panel acme.overlays

# Disabling the plugin with a popover open leaves no record and no error;
# the log row at the end holds the second half.
expect "the widget opens its popover before teardown" ok ovw openPopover
expect_poll "the popover is open before teardown" true ovr popoverOpen
expect "disabling the overlay fixture is allowed" ok ipc shell setPluginEnabled acme.overlays false
expect_poll "the disabled fixture leaves the build records" False record_exists acme.overlays
