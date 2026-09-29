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
# The Settings window lists each failed build among the plugin's errors,
# once per kind however many screens it failed on.
expect "enabling the Settings plugin for the failed builds is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect "the Settings window opens on the broken fixture's page" ok ipc shell summon window vgs.settings '{"plugin":"acme.broken"}'
broken_errors() { settings_rows | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin) if r["id"] == "acme.broken"][0]; print(json.dumps(sorted(e.split(" not built")[0] for e in r["errors"])))'; }
expect_poll "the broken fixture's failed builds are its errors, one per kind" '["build failed: background: background", "build failed: service: service"]' broken_errors
expect "the Settings window closes after the failed builds" ok ipc shell hide window vgs.settings
expect "disabling the Settings plugin after the failed builds is allowed" ok ipc shell setPluginEnabled vgs.settings false
expect_poll "the Settings service released its shortcut and IPC target again" False settings_lent
expect "disabling the broken fixture is allowed" ok ipc shell setPluginEnabled acme.broken false

# A nonvisual root can accept the facade but cannot belong to a host.
printf 'import QtQuick\nQtObject { property var shell: null; property var screen: null }\n' >"$broken/Item.qml"
scans_before_nonvisual="$(scans_done)"
expect "rescan after changing the broken root answers ok" ok ipc shell rescanPlugins
expect_log "the new broken revision is scanned" "$((scans_before_nonvisual + 1))" 'plugins: scan complete '
expect "enabling the nonvisual root is allowed" ok ipc shell setPluginEnabled acme.broken true
expect_log "both nonvisual roots are refused before publication" 2 'plugins: acme\.broken (service|background) not built: entry point must be an Item'
expect "the nonvisual root has no build record" False record_exists acme.broken
expect "the nonvisual root keeps no capability hold" null lent holders.lock
expect_poll "the nonvisual background leaves no surface" 0 layer_count vgs:background
expect "disabling the nonvisual root is allowed" ok ipc shell setPluginEnabled acme.broken false
background_failures() { sed -n 's/.*smoke: backgroundFailures=//p' "$instance_log" | tail -n 1; }
expect_poll "the host remembers the installed broken background" 1 background_failures
printf 'import QtQuick\nItem { property var shell: null; property var screen: null }\n' >"$broken/Item.qml"
expect "rescan after repairing the disabled plugin answers ok" ok ipc shell rescanPlugins
expect_poll "a source repair releases its stale background failure record" 0 background_failures
printf 'import QtQuick\nQtObject { property var shell: null; property var screen: null }\n' >"$broken/Item.qml"
scans_before_removal_control="$(scans_done)"
expect "the removal control's broken source is rescanned" ok ipc shell rescanPlugins
expect_log "the broken source is registered before the removal control" "$((scans_before_removal_control + 1))" 'plugins: scan complete '
expect "the removal control enables the broken plugin" ok ipc shell setPluginEnabled acme.broken true
expect_poll "the removal control reaches a retained failure record" 1 background_failures
failed_output=SMOKE-FAILED
expect "a failed plugin can meet a new monitor" ok hypr output create headless "$failed_output"
expect_poll "the new monitor records its refused background" 1 ipc smoke failedBuilds "background:$failed_output"
expect "the failed background's monitor can be removed" ok hypr output remove "$failed_output"
expect_poll "the removed monitor leaves no background failure record" 0 ipc smoke failedBuilds "background:$failed_output"
expect "monitor removal preserves the screenless service failure" 1 ipc smoke failedBuilds service
expect "monitor removal preserves the remaining background failure" 1 ipc smoke failedBuilds "background:$(bar_key | sed 's/^bar://')"
expect "the removal control disables the broken plugin" ok ipc shell setPluginEnabled acme.broken false
python3 - "$broken" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
expect "rescan after removing the broken plugin answers ok" ok ipc shell rescanPlugins
expect_poll "removing the plugin releases its background failure record" 0 background_failures

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
