set -euo pipefail
locker="$home/.config/vgs/plugins/acme.locker"
mkdir -p "$locker"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.locker/." "$locker/"
expect "rescan after adding the lock fixture answers ok" ok ipc shell rescanPlugins
expect_poll "the lock fixture is discovered" True plugin_known acme.locker
expect "enabling a second lock plugin is allowed" ok ipc shell setPluginEnabled acme.locker true
expect_poll "the lock stays with its first holder" '["acme.probe"]' lent holders.lock
expect "the second lock plugin is not built while the lock is held" False record_exists acme.locker

expect "the fixture holds an idle watch before its disable" ok probe idle-watch 600
expect "disabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe false
expect_poll "the second lock plugin builds once the holder is disabled" True record_exists acme.locker
expect_poll "the lock moved to the second plugin" '["acme.locker"]' lent holders.lock
expect "disabling the second lock plugin is allowed" ok ipc shell setPluginEnabled acme.locker false
expect_widgets "the fixture widget left the bar" '["acme.tick"]'
got=""
for _ in $(seq 1 25); do if got="$(service_built)" && [[ $got == False ]]; then break; fi; sleep 0.2; done
if [[ $got == False ]]; then ok "the service host destroyed the disabled service"; else fail "service still built: $got"; fi
fixture_holds() { ipc shell lent | py_reply 'import json,sys; print(sorted(k for k,v in json.load(sys.stdin)["holders"].items() if "acme.probe" in v))'; }
expect_poll "disable released every capability hold" '[]' fixture_holds
expect "disable released the fixture's shortcut" '[]' fixture_shortcuts
expect "disable released the IPC target" '[]' lent ipcTargets
expect "disable released the notification subscriber" '[]' lent subscribers
expect "disable destroyed the notification server" false lent notificationServer
expect "disable destroyed the polkit agent" false lent polkitAgent
expect "disable released every idle watch" '[]' lent idle
expect "disable released the tui capability" '["vgs.themes"]' lent holders.tui
expect_poll "the compositor dropped the fixture's shortcut" 0 hypr_shortcuts
expect "qs lists no IPC target for the disabled fixture" 0 ipc_targets
expect "disabling the bare fixture is allowed" ok ipc shell setPluginEnabled acme.bare false

# Both backgrounds become eligible in one configuration update, before the
# registry's deferred lending snapshot sees the first holder.
python3 - "$repo/scripts/smoke/fixtures/plugins/acme.contention" "$home/.config/vgs/plugins" <<'PY'
import json, pathlib, shutil, sys
for suffix in ("a", "b"):
    plugin_id = "acme.contend-" + suffix
    target = pathlib.Path(sys.argv[2]) / plugin_id
    shutil.copytree(sys.argv[1], target)
    manifest = target / "manifest.json"
    data = json.loads(manifest.read_text())
    data["id"] = plugin_id
    manifest.write_text(json.dumps(data))
PY
expect "rescan discovers the contending backgrounds" ok ipc shell rescanPlugins
expect_poll "both contending backgrounds are known" True plugin_known acme.contend-b
expected_errors+=('plugins: acme\.contend-[ab] refused: capability=lock held-by=acme\.contend-[ab]')
python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
data = json.load(open(p))
data.setdefault("plugins", []).extend({"id": "acme.contend-" + suffix} for suffix in ("a", "b"))
json.dump(data, open(p + ".tmp", "w"))
os.replace(p + ".tmp", p)
PY
expect_log "a live hold refuses the other background before lending settles" 1 'plugins: acme\.contend-[ab] refused: capability=lock held-by=acme\.contend-[ab]'
holder="$(lent holders.lock | py_reply 'import json,sys; print(json.load(sys.stdin)[0])')"
case "$holder" in
  acme.contend-a) contender=acme.contend-b ;;
  acme.contend-b) contender=acme.contend-a ;;
  *) fail "unexpected contention holder: $holder"; exit 1 ;;
esac
expect "the refused background has no instance" False record_exists "$contender"
expect "the first background releases the exclusive capability" ok ipc shell setPluginEnabled "$holder" false
expect_poll "the refused background builds after the holder leaves" True record_exists "$contender"
expect "the remaining background is disabled" ok ipc shell setPluginEnabled "$contender" false
expect_poll "contention cleanup releases the lock" null lent holders.lock
