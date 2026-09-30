//@ pragma Env QS_NO_RELOAD_POPUP=1
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// One layer, no shell or plugin services. The off scene keeps the same
// animation and background; only the shader stops drawing.
ShellRoot {
    id: root
    property int frames: 0
    property real previous: 0
    property var presentation: []
    readonly property string mode: Quickshell.env("VGS_SHADER_MODE")
    readonly property bool complete: frames >= 730

    PanelWindow {
        id: layer
        screen: Quickshell.screens[0]
        implicitWidth: Theme.voiceOrb.size
        implicitHeight: Theme.voiceOrb.size
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "vgs:shader-measure"
        // Both scenes submit a draw, including the off baseline.
        Rectangle { anchors.fill: parent; color: Theme.color.background }
        VoiceOrb {
            id: orb
            anchors.fill: parent
            active: !root.complete
            level: 0.8
            secondaryLevel: 0.5
            Component.onCompleted: {
                const shader = children.find(child => child instanceof ShaderEffect);
                if (root.mode === "off") shader.visible = false;
                if (root.mode === "costly") shader.fragmentShader = Qt.resolvedUrl("costly.frag.qsb");
            }
        }
        Connections {
            target: orb.Window.window
            function onFrameSwapped() {
                const now = Date.now();
                if (root.previous > 0 && !root.complete)
                    root.presentation.push(now - root.previous);
                root.previous = now;
                root.frames++;
            }
        }
    }
    IpcHandler {
        target: "shader"
        function result(): string {
            return JSON.stringify({
                complete: root.complete, frames: root.frames,
                window: String(orb.Window.window),
                scale: orb.Window.window === null ? 0 : orb.Window.window.devicePixelRatio,
                presentation: root.presentation
            });
        }
    }
}
