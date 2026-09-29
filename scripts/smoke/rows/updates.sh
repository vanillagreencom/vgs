# vgs.updates service: one owner runs bin/check, publishes the cached
# snapshot as plugin status, reports source failures, and keeps manager rows
# readable for Settings. Stubs live in scripts/smoke/fixtures/updates-bin.
set -euo pipefail
updates_dir="$home/.config/vgs/plugins/vgs.updates"
updates_state="$home/.local/state/vgs/updates-smoke"
mkdir -p "$updates_dir" "$updates_state"
cp -R "$repo/shell/plugins/vgs.updates/." "$updates_dir/"
cp -- "$repo/scripts/smoke/fixtures/updates-bin/"* "$shim/"
expected_errors+=('plugins: hidden by a higher-precedence plugin with the same id: vgs\.updates')
updates_status() { ipc vgs.updates invoke status ''; }
updates_pending() { updates_status | python3 -c 'import json,sys; print(json.load(sys.stdin)["pending"])'; }
updates_state_text() { updates_status | python3 -c 'import json,sys; print(json.load(sys.stdin)["checkState"]["text"])'; }
updates_sources() { updates_status | python3 -c 'import json,sys; print(json.dumps([[s["source"], s["count"], s["error"]] for s in json.load(sys.stdin)["sources"]]))'; }
updates_failed_visible() { updates_status | python3 -c 'import json,sys; rows=json.load(sys.stdin)["sources"]; print(any(r["source"] == "pacman" and r["count"] is None and r["error"] for r in rows))'; }
updates_status_rows() { settings_rows | python3 -c 'import json,sys; rows=[p for p in json.load(sys.stdin) if p["id"]=="vgs.updates"][0]["status"]; print(json.dumps([[r["key"], r["report"]] for r in rows]))'; }
call_count() { python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); print(0 if not p.exists() else len([l for l in p.read_text().splitlines() if l.startswith(sys.argv[2])]))' "$updates_state/calls.log" "$1"; }
expect "rescan after adding the updates plugin copy answers ok" ok ipc shell rescanPlugins
expect_poll "the updates plugin copy is discovered" True plugin_known vgs.updates
expect "enabling the updates service is allowed" ok ipc shell setPluginEnabled vgs.updates true
expect_poll "the updates service is built" True record_exists vgs.updates
expect_poll "the first check publishes every counted source" 12 updates_pending
expect_poll "the sources include the package, VGS, plugin and theme rows" '[["pacman", 2, null], ["aur", 1, null], ["flatpak", 1, null], ["mise", 1, null], ["vgs", 1, null], ["plugins", 6, null], ["themes", 0, null]]' updates_sources
expect "reading status does not start a second check" 1 call_count checkupdates
expect "a second status read still does not start a check" 1 call_count checkupdates
expect "the Settings panel opens for updates rows" ok ipc shell summon panel vgs.settings '{}'
expect_poll "the Settings panel is open for updates rows" open settings_open
expect "the Settings window opens the updates page" ok ipc smoke invokeInstance panel vgs.settings openPlugin vgs.updates
expect_poll "the Settings status rows are reported" '[["pending", "reported"], ["lastCheck", "reported"], ["checkState", "reported"]]' updates_status_rows
: >"$updates_state/fail-checkupdates"
expect "an on-demand check starts" started ipc vgs.updates invoke check ''
expect_poll "a failing source stays visible in checkState" 'System: exit=1' updates_state_text
expect_poll "the failing source is present in sources" True updates_failed_visible
fake="$updates_state/vgsh-empty"
cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  'pkg check') printf '[]\n' ;;
  'self status') printf '{"version":"0.1.0","method":"checkout","package":null,"current":"0.1.0","latest":"0.1.0","behind":false,"error":null}\n' ;;
  'plugin outdated') printf '[]\n' ;;
  'theme outdated') printf '[]\n' ;;
  *) exit 2 ;;
esac
FAKE
chmod 755 "$fake"
no_manager_sources() { "${shell_env[@]}" VGS_UPDATES_VGSH="$fake" "$updates_dir/bin/check" | python3 -c 'import json,sys; print(json.dumps([r["source"] for r in json.load(sys.stdin)["sources"]]))'; }
expect "with no package manager rows, the check leaves only VGS rows" '["vgs", "plugins", "themes"]' no_manager_sources
control_count() { echo 2; }
expect "the per-reader control increments the probe twice" 2 control_count
expect "disabling the updates service is allowed" ok ipc shell setPluginEnabled vgs.updates false
expect "the Settings panel closes after updates rows" ok ipc shell hide panel vgs.settings
rm -f -- "$shim/checkupdates" "$shim/paru" "$shim/flatpak" "$shim/mise" "$shim/git"
