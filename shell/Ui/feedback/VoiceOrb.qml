import QtQuick
import QtQuick.Window
import qs.Commons

// A passive voice-level ring. D060 keeps actions outside this decoration.
// Item.visible includes hidden ancestors; Window covers an unmapped host.
Item {
    id: root

    property string tone: "accent"
    property real level: 0
    property real secondaryLevel: 0
    property bool active: false

    implicitWidth: Theme.voiceOrb.size
    implicitHeight: Theme.voiceOrb.size
    Accessible.ignored: true

    function toneColor(name) {
        const found = Theme.voiceOrb.tone[name];
        if (found !== undefined) return found;
        console.error('VoiceOrb: no tone named "' + name + '"; drawing accent');
        return Theme.voiceOrb.tone.accent;
    }

    function bounded(value) {
        return Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0;
    }

    QtObject {
        id: state
        property real phase: 0
        property real primary: 0
        property real secondary: 0

        function smooth(current, target, seconds) {
            const duration = target > current ? Theme.voiceOrb.attack : Theme.voiceOrb.release;
            return duration > 0 ? current + (target - current) * (1 - Math.exp(-seconds * 1000 / duration)) : target;
        }
    }

    ShaderEffect {
        id: shader
        anchors.fill: parent
        property color ink: root.toneColor(root.tone)
        property vector2d dimensions: Qt.vector2d(width, height)
        property real phase: state.phase
        property real amplitude: driver.running ? state.primary : root.bounded(root.level)
        property real secondaryAmplitude: driver.running ? state.secondary : root.bounded(root.secondaryLevel)
        property vector4d lines: Qt.vector4d(Theme.voiceOrb.radius, Theme.voiceOrb.gap, Theme.voiceOrb.stroke, Theme.voiceOrb.arcStroke)
        property vector4d waves: Qt.vector4d(Theme.voiceOrb.amplitude, Theme.voiceOrb.waveCount, Theme.voiceOrb.arcSpan, Theme.voiceOrb.arcOpacity)
        fragmentShader: Qt.resolvedUrl("shaders/voiceorb.frag.qsb")
    }

    FrameAnimation {
        id: driver
        running: root.visible && root.active && Theme.motion.scale > 0 && Theme.voiceOrb.period > 0
                 && root.Window.window !== null && root.Window.window.visible
                 && root.Window.window.visibility !== Window.Minimized
        onRunningChanged: if (running) {
            state.primary = root.bounded(root.level);
            state.secondary = root.bounded(root.secondaryLevel);
        }
        onTriggered: {
            state.phase = (state.phase + frameTime * 1000 * 2 * Math.PI / Theme.voiceOrb.period) % (2 * Math.PI);
            state.primary = state.smooth(state.primary, root.bounded(root.level), frameTime);
            state.secondary = state.smooth(state.secondary, root.bounded(root.secondaryLevel), frameTime);
        }
    }
}
