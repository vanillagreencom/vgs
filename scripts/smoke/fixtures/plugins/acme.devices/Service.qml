import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Services.Pipewire
// The device fakes' consumer for scripts/smoke/rows/device-fakes.sh. It
// reads what Quickshell's Bluetooth, Networking and Pipewire singletons
// see of the sandbox's fakes (scripts/smoke/devices.sh) as plain values a
// row reads back, and runs rfkill through the shell's own PATH. The IPC
// function `rfkill` takes the arguments as one space-separated string and
// answers `started`, or `busy` while a run is live; `rfkillRun` holds the
// last run's [argv, exit code].
Item {
    id: root
    property var shell: null
    property bool registered: false
    property var rfkillRun: null

    readonly property var adapters: Bluetooth.adapters.values.map(a => ({
        id: a.adapterId, name: a.name, enabled: a.enabled, state: BluetoothAdapterState.toString(a.state),
        devices: a.devices.values.map(d => ({ address: d.address, name: d.name, paired: d.paired, bonded: d.bonded, connected: d.connected }))
    }))
    readonly property var wifi: Networking.devices.values.filter(d => d.type === DeviceType.Wifi).map(d => ({
        name: d.name, address: d.address, networks: d.networks.values.map(n => n.name)
    }))
    // An audio node carries `audio`; the driver nodes carry none.
    readonly property var sinks: Pipewire.nodes.values.filter(n => n.audio !== null && n.isSink && !n.isStream).map(n => n.name).sort()
    readonly property var sources: Pipewire.nodes.values.filter(n => n.audio !== null && !n.isSink && !n.isStream).map(n => n.name).sort()
    readonly property var defaults: [Pipewire.defaultAudioSink === null ? null : Pipewire.defaultAudioSink.name,
        Pipewire.defaultAudioSource === null ? null : Pipewire.defaultAudioSource.name]

    // Networking lists a Wi-Fi network only while its device scans, is
    // connected to it or holds its settings
    // (docs/architecture/runtime-devices.md), so each Wi-Fi device scans.
    Instantiator {
        model: Networking.devices
        delegate: QtObject {
            required property var modelData
            Component.onCompleted: if (modelData.type === DeviceType.Wifi) modelData.scannerEnabled = true
        }
    }

    Process {
        id: rfkill
        property var argv: []
        onExited: (code, status) => { root.rfkillRun = [argv.slice(1), code]; }
    }

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("rfkill", arg => {
            if (rfkill.running) return "busy";
            rfkill.argv = ["rfkill"].concat(arg.split(" ").filter(word => word !== ""));
            rfkill.command = rfkill.argv;
            rfkill.running = true;
            return "started";
        });
    }
}
