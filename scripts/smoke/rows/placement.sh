# Show in bar: setPluginPlaced takes a widget off the bar and puts it back
# in its default section and never writes disabledPlugins. Over the installed
# fixture acme.probe, a service plus a bar widget that rows/plugins.sh
# enabled and placed, each call is read back from the bar's build records,
# the user shell.json, listPlugins and the service's build record:
# unplacing keeps the plugin enabled and its service built, and neither
# call changes disabledPlugins. The three refusals leave the file as it
# was. The Settings page's Show in bar switch is clicked twice and read
# back the same way, and the page of acme.tick, a widget-only fixture,
# draws no such switch. The row restores the user file byte for byte, so the
# rows after it find the fixture placed as before, and leaves Settings
# disabled.
set -euo pipefail
placement_file="$home/.config/vgs/shell.json"
placement_saved="$sandbox/shell-before-placement.json"
cp -- "$placement_file" "$placement_saved"
# [enabled, placed] of plugin ID in listPlugins.
placement_listed() { ipc shell listPlugins | py_reply 'import json,sys; r=[p for p in json.load(sys.stdin)["plugins"] if p["id"] == sys.argv[1]]; print(json.dumps([r[0]["enabled"], r[0]["placed"]]) if r else "absent")' "$1"; }
# Whether each bar draws the fixture's widget, as the set of answers over
# every bar: [true] in every bar, [false] in none.
placement_in_bars() { bar_widget_ids | py_reply 'import json,sys; print(json.dumps(sorted(set("acme.probe" in ids for ids in json.load(sys.stdin)))))'; }
placement_service() { ipc shell built | py_reply 'import json,sys; print(any(r["id"] == "acme.probe" and r["kind"] == "service" for r in json.load(sys.stdin).get("service", [])))'; }
# The sections of the user file's layout that hold a fixture entry, one per
# entry, and the user file's disabledPlugins.
placement_sections() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); l=d.get("bar", {}).get("layout", {}); print(json.dumps([s for s in ("left", "center", "right") for e in l.get(s, []) if e["id"] == "acme.probe"]))' "$placement_file"; }
placement_disabled() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("disabledPlugins")))' "$placement_file"; }
# The fixture's `placed` on the manager row the Settings window draws.
placement_page() { ipc smoke readInstance window vgs.settings plugins | py_reply 'import json,sys; print(json.dumps([p["placed"] for p in json.load(sys.stdin) if p["id"] == "acme.probe"][0]))'; }
placement_unchanged() { if cmp -s -- "$placement_file" "$placement_saved"; then echo unchanged; else echo changed; fi; }
# placement_reads LABEL PLACED SECTIONS: the reads after a placement edit.
placement_reads() {
  expect_poll "the bar's build records follow $1" "[$2]" placement_in_bars
  expect_poll "the user file's layout follows $1" "$3" placement_sections
  expect_poll "listPlugins reads the fixture enabled and its placement after $1" "[true, $2]" placement_listed acme.probe
  expect "the fixture's service is still built after $1" True placement_service
  expect "disabledPlugins is unchanged by $1" "$placement_disabled_before" placement_disabled
}

expect "the fixture starts enabled and placed" '[true, true]' placement_listed acme.probe
expect "Settings starts disabled" False plugin_enabled vgs.settings
placement_disabled_before="$(placement_disabled)" || fail "the user file's disabledPlugins is unreadable"

expect "an id no plugin has is unknown" "unknown: acme.nowhere" ipc shell setPluginPlaced acme.nowhere true
expect "a plugin without a bar widget is refused" "refused: placed=acme.bare reason=no-bar-widget" ipc shell setPluginPlaced acme.bare true
expect "a disabled plugin's widget is refused" "refused: placed=vgs.settings reason=disabled" ipc shell setPluginPlaced vgs.settings true
expect "the refusals leave the user file as it was" unchanged placement_unchanged

expect "unplacing the fixture is allowed" ok ipc shell setPluginPlaced acme.probe false
placement_reads "the unplace" false '[]'
expect "placing the fixture is allowed" ok ipc shell setPluginPlaced acme.probe true
placement_reads "the place" true '["right"]'
expect "unplacing the fixture again is allowed" ok ipc shell setPluginPlaced acme.probe false
placement_reads "the second unplace" false '[]'

# The drawn switch: real clicks on the page's Show in bar Switch.
settings_page_open acme.probe
expect_poll "the page reads the fixture unplaced" false placement_page
settings_press --type Switch "" Field "Show in bar" || fail "the click on the Show in bar switch failed"
expect_poll "the switch places the widget in the user file" '["right"]' placement_sections
expect_poll "the switch puts the widget in every bar" '[true]' placement_in_bars
expect_poll "listPlugins reads the fixture enabled and placed after the switch" '[true, true]' placement_listed acme.probe
expect_poll "the page reads the fixture placed" true placement_page
settings_press --type Switch "" Field "Show in bar" || fail "the second click on the Show in bar switch failed"
expect_poll "the switch takes the widget out of the user file" '[]' placement_sections
expect_poll "the switch takes the widget off every bar" '[false]' placement_in_bars
expect_poll "listPlugins reads the fixture enabled and unplaced after the switch" '[true, false]' placement_listed acme.probe
expect "the fixture's service is still built after the switch" True placement_service
# A widget-only plugin's Enabled switch is its placement: the same lookup
# that found the probe's switch finds none on acme.tick's page.
expect "Settings is summoned on acme.tick's page" ok ipc shell summon window vgs.settings '{"plugin":"acme.tick"}'
expect_poll "the Settings window shows acme.tick's page" '"acme.tick"' ipc smoke readInstance window vgs.settings page
expect_poll "a widget-only plugin's page draws no Show in bar" absent ipc smoke scopedWindowGeometry window vgs.settings Field "Show in bar" Switch ""
settings_page_close acme.probe

cp -- "$placement_saved" "$placement_file.tmp" && mv -T -- "$placement_file.tmp" "$placement_file"
expect_poll "the restored user file places the fixture again" '[true, true]' placement_listed acme.probe
expect_poll "the restored fixture widget is in every bar" '[true]' placement_in_bars
