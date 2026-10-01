import QtQuick
import QtTest
import Quickshell.Io
import qs.Core

// HyprlandState's binds read, which the key capture's hint reads: a failed
// read names its failure and empties the keys, a later read clears it, and
// turning the reads off forgets both. The Process stand-in answers each
// `hyprctl -j binds` by hand.
Item {
    id: root
    HyprlandState { id: state }

    TestCase {
        name: "hyprland-state-binds"

        function binds() {
            return ProcessRegistry.processes.find(process => process.running && process.command.join(" ") === "hyprctl -j binds");
        }

        // expected-log: hyprland: binds=failed -- the failed read this case answers
        // expected-log: hyprland: refused: binds=unparsed -- the reply that is no JSON this case answers
        function test_a_failed_binds_read_is_named() {
            state.active = true;
            let read = binds();
            verify(read !== undefined, "the binds read starts");
            read.finish(1, 0, "", "no socket");
            compare(state.foreignKeys, null);
            verify(state.bindsFailure.indexOf("binds=failed") === 0, state.bindsFailure);
            state.readBinds();
            read = binds();
            read.finish(0, 0, JSON.stringify([{ submap: "", modmask: 64, key: "K", keycode: 0, description: "", dispatcher: "exec" }]), "");
            compare(state.bindsFailure, "");
            compare(JSON.stringify(state.foreignKeys), '["SUPER+K"]');
            state.readBinds();
            binds().finish(0, 0, "not json", "");
            verify(state.bindsFailure.indexOf("refused: binds=unparsed") === 0, state.bindsFailure);
            state.active = false;
            compare(state.bindsFailure, "");
            compare(state.foreignKeys, null);
        }
    }
}
