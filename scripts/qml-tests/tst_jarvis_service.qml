import QtQuick
import QtTest
import Quickshell.Io
import "../../shell/plugins/vgs.jarvis"

// The environment the Jarvis service hands its daemon. The service clears
// the shell's environment, so a variable the desktop tool executors pass to
// their commands reaches the daemon only by name here. The stand-in
// Quickshell.env answers "env:NAME", so each value also names its source.
Item {
    Service { id: service }

    TestCase {
        name: "jarvisService"

        function daemonProcess() {
            const found = ProcessRegistry.processes.filter(process =>
                process.command.length > 1 && String(process.command[1]).endsWith("/backend/jarvisd.js"));
            compare(found.length, 1, "one daemon process");
            return found[0];
        }

        function test_daemon_environment() {
            const process = daemonProcess();
            verify(process.clearEnvironment, "the daemon inherits nothing");
            const expected = { LANG: "C.UTF-8" };
            for (const name of ["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
                "XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
                "YDOTOOL_SOCKET", "CLAUDE_CONFIG_DIR", "CODEX_HOME"])
                expected[name] = "env:" + name;
            const sorted = value => Object.keys(value).sort().map(name => name + "=" + value[name]).join("\n");
            compare(sorted(process.environment), sorted(expected));
        }
    }
}
