# A plugin whose entry points cannot take what the core assigns is not
# built and keeps nothing it was lent: no hold, no background surface.
set -euo pipefail
broken="$home/.config/vgs/plugins/acme.broken"
mkdir -p "$broken"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.broken/." "$broken/"
expected_errors+=('plugins: acme\.broken (service|background) not built: ')
expect "rescan after adding the broken fixture answers ok" ok ipc shell rescanPlugins
expect_poll "the broken fixture is discovered" True plugin_known acme.broken
expect "enabling the broken fixture is allowed" ok ipc shell setPluginEnabled acme.broken true
expect_log "the core logged both refused builds of the broken fixture" 2 'plugins: acme\.broken (service|background) not built: '
expect "the broken fixture has no build record" False record_exists acme.broken
expect "the broken fixture keeps no capability hold" null lent holders.lock
expect_poll "the background host shows no surface for a failed build" 0 layer_count vgs:background
expect "disabling the broken fixture is allowed" ok ipc shell setPluginEnabled acme.broken false

# A nonvisual root can accept the facade but cannot belong to a host.
printf 'import QtQuick\nQtObject { property var shell: null; property var screen: null }\n' >"$broken/Item.qml"
expect "rescan after changing the broken root answers ok" ok ipc shell rescanPlugins
expect_poll "the new broken revision is scanned" '' scan_error
expect "enabling the nonvisual root is allowed" ok ipc shell setPluginEnabled acme.broken true
expect_log "both nonvisual roots are refused before publication" 2 'plugins: acme\.broken (service|background) not built: entry point must be an Item'
expect "the nonvisual root has no build record" False record_exists acme.broken
expect "the nonvisual root keeps no capability hold" null lent holders.lock
expect_poll "the nonvisual background leaves no surface" 0 layer_count vgs:background
expect "disabling the nonvisual root is allowed" ok ipc shell setPluginEnabled acme.broken false

# A bar widget that cannot take what the core assigns is not built, and the
# section's entries stay aligned with the layout: an edit to the entry after
# it reaches that entry's own widget, never a neighbour's settings.
nowidget="$home/.config/vgs/plugins/acme.nowidget"
mkdir -p "$nowidget"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.nowidget/." "$nowidget/"
expected_errors+=('plugins: acme\.nowidget bar-widget not built: ')
expect "rescan after adding the widget that cannot be built answers ok" ok ipc shell rescanPlugins
expect_poll "the widget that cannot be built is discovered" True plugin_known acme.nowidget
python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["bar"]["layout"]["center"].insert(0, {"id": "acme.nowidget"})
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
expect_log "the core logged the refused widget build on every bar" "$monitors" 'plugins: acme\.nowidget bar-widget not built: '
expect_widgets "the section shows the widget after the one that failed" '["acme.tick"]'
python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
[e for e in d["bar"]["layout"]["center"] if e["id"] == "acme.tick"][0]["format"] = "aligned"
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
expect_poll "an edit after a failed entry reaches its own widget" '"aligned"' read_tick format
python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["bar"]["layout"]["center"] = [e for e in d["bar"]["layout"]["center"] if e["id"] != "acme.nowidget"]
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
expect_widgets "removing the failed entry leaves the widget in place" '["acme.tick"]'
