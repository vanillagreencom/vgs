import QtQuick
import QtTest
import qs.Core

Item {
    id: root
    Component { id: ownerComponent; SessionLock {} }
    Component {
        id: readerComponent
        QtObject {
            property var session: null
            readonly property bool locked: session !== null && session.locked
        }
    }
    Component { id: contentComponent; Item { property var screen: null } }

    TestCase {
        name: "session-lock"
        property var owner: null
        property var reader: null

        function init() {
            owner = createTemporaryObject(ownerComponent, root);
            reader = createTemporaryObject(readerComponent, root);
            verify(owner !== null && reader !== null);
            reader.session = owner.sessionProvider({});
        }

        function test_live_state_data() {
            return [
                { tag: "unlocked", requested: false, secure: false, locked: false },
                { tag: "request-pending", requested: true, secure: false, locked: true },
                { tag: "confirmed", requested: true, secure: true, locked: true },
                { tag: "release-pending", requested: false, secure: true, locked: true }
            ];
        }

        function test_live_state(data) {
            owner.lockRequested = data.requested;
            owner.lockSecure = data.secure;
            tryCompare(reader, "locked", data.locked, 100);
            // Reuse the same reader after release, not a fresh provider.
            owner.lockRequested = false;
            owner.lockSecure = false;
            tryCompare(reader, "locked", false, 100);
        }

        function test_read_only_data() {
            return [
                { tag: "assign", change: s => { s.locked = true; } },
                { tag: "redefine", change: s => Object.defineProperty(s, "locked", { value: true }) },
                { tag: "delete", change: s => { delete s.locked; } },
                { tag: "add-authority", change: s => { s.unlock = () => "planted"; } }
            ];
        }

        function test_read_only(data) {
            const session = reader.session;
            try { data.change(session); } catch (e) {}
            verify(Object.isFrozen(session));
            compare(Object.keys(session).join(","), "locked");
            compare(session.lock, undefined);
            compare(session.unlock, undefined);
            compare(session.locked, false);
            owner.lockRequested = true;
            tryCompare(reader, "locked", true, 100);
        }

        // expected-log: capabilities: lock=ended-by-compositor; another client may hold the session lock, and this shell's lock is dropped -- the compositor refuses the requested lock
        function test_compositor_end_drops_the_request() {
            const holder = owner.provider({ onDispose: fn => {} });
            compare(holder.lock(contentComponent), "ok");
            owner.lockSecure = true;
            tryCompare(reader, "locked", true);
            owner.compositorEnded();
            compare(owner.lockRequested, false);
            compare(holder.locked, false);
            compare(holder.secure, false);
            compare(holder.compositorEnds, 1);
            tryCompare(reader, "locked", false);
            // The next request locks again.
            compare(holder.lock(contentComponent), "ok");
            compare(holder.locked, true);
        }

        function test_a_released_lock_is_no_compositor_end() {
            const holder = owner.provider({ onDispose: fn => {} });
            compare(holder.lock(contentComponent), "ok");
            compare(holder.unlock(), "ok");
            owner.compositorEnded();
            compare(holder.compositorEnds, 0);
            compare(holder.locked, false);
        }

        function test_holder_unload_keeps_lock() {
            let dispose = null;
            const holder = owner.provider({ onDispose: fn => { dispose = fn; } });
            compare(holder.lock(contentComponent), "ok");
            owner.lockSecure = true;
            tryCompare(reader, "locked", true);
            verify(dispose !== null);
            dispose();
            compare(owner.lockContent, null);
            compare(owner.lockRequested, true);
            compare(holder.locked, true);
            compare(reader.session.locked, true);
            compare(holder.unlock(), "ok");
            compare(reader.session.locked, true);
            owner.lockSecure = false;
            tryCompare(reader, "locked", false);
        }
    }
}
