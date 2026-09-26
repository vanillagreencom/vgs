set -euo pipefail
locker="$home/.config/vgs/plugins/acme.locker"
mkdir -p "$locker"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.locker/." "$locker/"
expect "rescan after adding the lock fixture answers ok" ok ipc shell rescanPlugins
locker_known() { ipc shell listPlugins | python3 -c 'import json,sys; print(any(p["id"]=="acme.locker" for p in json.load(sys.stdin)["plugins"]))'; }
expect_poll "the lock fixture is discovered" True locker_known
expect "enabling a second lock plugin is allowed" ok ipc shell setPluginEnabled acme.locker true
locker_built() { ipc shell built | python3 -c 'import json,sys; print(any(r["id"]=="acme.locker" for r in json.load(sys.stdin).get("service",[])))'; }
expect_poll "the lock stays with its first holder" '["acme.probe"]' lent holders.lock
expect "the second lock plugin is not built while the lock is held" False locker_built

expect "disabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe false
expect_poll "the second lock plugin builds once the holder is disabled" True locker_built
expect_poll "the lock moved to the second plugin" '["acme.locker"]' lent holders.lock
expect "disabling the second lock plugin is allowed" ok ipc shell setPluginEnabled acme.locker false
expect_widgets "the fixture widget left the bar" '["acme.tick"]'
got=""
for _ in $(seq 1 25); do if got="$(service_built)" && [[ $got == False ]]; then break; fi; sleep 0.2; done
if [[ $got == False ]]; then ok "the service host destroyed the disabled service"; else fail "service still built: $got"; fi
fixture_holds() { ipc shell lent | python3 -c 'import json,sys; print(sorted(k for k,v in json.load(sys.stdin)["holders"].items() if "acme.probe" in v))'; }
expect_poll "disable released every capability hold" '[]' fixture_holds
expect "disable released the shortcut" '[]' lent shortcuts
expect "disable released the IPC target" '[]' lent ipcTargets
expect "disable released the notification subscriber" '[]' lent subscribers
expect "disable destroyed the notification server" false lent notificationServer
expect "disable destroyed the polkit agent" false lent polkitAgent
expect_poll "the compositor dropped the fixture's shortcut" 0 hypr_shortcuts
expect "qs lists no IPC target for the disabled fixture" 0 ipc_targets
expect "disabling the bare fixture is allowed" ok ipc shell setPluginEnabled acme.bare false
