# A plugin whose entry points cannot take what the core assigns is not
# built and keeps nothing it was lent: no hold, no background surface.
set -euo pipefail
broken="$home/.config/vgs/plugins/acme.broken"
mkdir -p "$broken"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.broken/." "$broken/"
expected_errors+=('plugins: acme\.broken (service|background) not built: ')
expect "rescan after adding the broken fixture answers ok" ok ipc shell rescanPlugins
broken_known() { ipc shell listPlugins | python3 -c 'import json,sys; print(any(p["id"]=="acme.broken" for p in json.load(sys.stdin)["plugins"]))'; }
expect_poll "the broken fixture is discovered" True broken_known
expect "enabling the broken fixture is allowed" ok ipc shell setPluginEnabled acme.broken true
broken_built() { ipc shell built | python3 -c 'import json,sys; print(any(r["id"]=="acme.broken" for rows in json.load(sys.stdin).values() for r in rows))'; }
expect_log "the core logged both refused builds of the broken fixture" 2 'plugins: acme\.broken (service|background) not built: '
expect "the broken fixture has no build record" False broken_built
expect "the broken fixture keeps no capability hold" null lent holders.lock
expect_poll "the background host shows no surface for a failed build" 0 layer_count vgs:background
expect "disabling the broken fixture is allowed" ok ipc shell setPluginEnabled acme.broken false

# A bar widget that cannot take what the core assigns is not built, and the
# section's entries stay aligned with the layout: an edit to the entry after
# it reaches that entry's own widget, never a neighbour's settings.
nowidget="$home/.config/vgs/plugins/acme.nowidget"
mkdir -p "$nowidget"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.nowidget/." "$nowidget/"
expected_errors+=('plugins: acme\.nowidget bar-widget not built: ')
expect "rescan after adding the widget that cannot be built answers ok" ok ipc shell rescanPlugins
nowidget_known() { ipc shell listPlugins | python3 -c 'import json,sys; print(any(p["id"]=="acme.nowidget" for p in json.load(sys.stdin)["plugins"]))'; }
expect_poll "the widget that cannot be built is discovered" True nowidget_known
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
