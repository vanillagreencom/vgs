# Shared session observation beside the exclusive lock holder. All reads use
# IPC round-trip polling; this row sets no latency budget.
# scripts/test-session-lock.sh holds the owner's must-fail controls.
set -euo pipefail
session_dir="$home/.config/vgs/plugins/acme.session"
mkdir -p "$session_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.session/." "$session_dir/"
expect "rescan discovers the session reader" ok ipc shell rescanPlugins
expect_poll "the session reader is known" True plugin_known acme.session
expect "enable the session reader beside a lock holder" ok ipc shell setPluginEnabled acme.session true
expect_poll "the session reader builds without lock authority" True record_exists acme.session
session_read() { ipc smoke readInstance service acme.session "$1"; }
expect "the reader receives only its declared capabilities" '"ipc,manifest,session,settings"' session_read shellKeys
expect "the lock remains exclusive to its holder" '["acme.probe"]' lent holders.lock
expect "the reader holds session independently" '["acme.session"]' lent holders.session
expect "the reader initially sees an unlocked session" false session_read locked
expect "the unlocked session provider resists writes and authority injection" true ipc acme.session invoke read-only ""
expect "the holder locks for the reader" ok probe lock
expect_poll "the reader binding changes to locked" true session_read locked
expect_poll "the compositor confirms the observed lock" true read_service lockSecure
expect "the locked session provider resists writes" true ipc acme.session invoke read-only ""
expect "unload the holder while its session is locked" ok ipc shell setPluginEnabled acme.probe false
expect_poll "the unloaded holder releases lock authority" null lent holders.lock
expect "the reader stays locked after the holder leaves" true session_read locked
expect "holder unload preserves the lock request" true lent lock.requested
expect "holder unload drops only the lock content" false lent lock.content
expect "restore the holder without replacing the reader" ok ipc shell setPluginEnabled acme.probe true
expect_poll "the restored holder supplies content again" true lent lock.content
expect "the holder unlocks for the reader" ok probe unlock
expect_poll "the reader binding changes back to unlocked" false session_read locked
expect "the same reader observed both transitions" 2 session_read changes
expect "disable releases the session reader" ok ipc shell setPluginEnabled acme.session false
expect_poll "the session hold is gone" null lent holders.session
expect "the lock holder remains built after the reader leaves" True record_exists acme.probe
