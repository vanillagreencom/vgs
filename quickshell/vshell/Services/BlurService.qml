pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("BlurService")

    property bool backgroundEffectSupported: false
    property bool hyprlandLayerBlurSupported: false
    property string backend: "none"
    property bool _applyPending: false

    readonly property bool compositorSupported: CompositorService.isHyprland
    readonly property bool available: compositorSupported && (backgroundEffectSupported || hyprlandLayerBlurSupported)
    readonly property bool enabled: available && (SettingsData.blurEnabled ?? false)
    readonly property bool backgroundEffectEnabled: enabled && backgroundEffectSupported && !hyprlandLayerBlurSupported

    // Keep the blur* setting keys; they also control non-blurred surface borders.
    readonly property color borderColor: {
        const opacity = SettingsData.blurBorderOpacity ?? 0.35;
        switch (SettingsData.blurBorderColor ?? "outline") {
        case "primary":
            return Theme.withAlpha(Theme.primary, opacity);
        case "secondary":
            return Theme.withAlpha(Theme.secondary, opacity);
        case "surfaceText":
            return Theme.withAlpha(Theme.surfaceText, opacity);
        case "custom":
            return Theme.withAlpha(SettingsData.blurBorderCustomColor ?? "#ffffff", opacity);
        default:
            return Theme.withAlpha(Theme.outline, opacity);
        }
    }
    readonly property int borderWidth: Theme.surfaceBorderWidth

    function hoverColor(baseColor, hoverAlpha) {
        if (!enabled)
            return baseColor;
        return Theme.withAlpha(baseColor, hoverAlpha ?? 0.15);
    }

    function _boolArg(value) {
        return value ? "true" : "false";
    }

    function _surfaceOpacityArg() {
        return String(Math.max(0.08, Math.min(1, Theme.popupSurfaceColor(Theme.surfaceContainer).a)));
    }

    function scheduleHyprlandApply() {
        if (!hyprlandLayerBlurSupported)
            return;
        hyprlandApplyTimer.restart();
    }

    function applyHyprlandLayerBlur() {
        if (!hyprlandLayerBlurSupported)
            return;
        if (hyprlandApply.running) {
            _applyPending = true;
            return;
        }
        hyprlandApply.command = [
            Paths.vshellCli,
            "blur",
            "apply",
            "--enabled",
            _boolArg(enabled),
            "--strength",
            String(Math.max(0, Math.min(1, SettingsData.popupBlurStrength ?? 0.0))),
            "--glass",
            _boolArg(SettingsData.popupGlassEffect ?? false),
            "--opacity",
            _surfaceOpacityArg(),
            "--mode",
            Theme.isLightMode ? "light" : "dark",
            "--json"
        ];
        hyprlandApply.running = true;
    }

    Timer {
        id: hyprlandApplyTimer
        interval: 140
        repeat: false
        onTriggered: root.applyHyprlandLayerBlur()
    }

    Process {
        id: blurProbe
        running: false
        command: [Paths.vshellCli, "blur", "check", "--json"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const payload = JSON.parse(text || "{}");
                    root.backgroundEffectSupported = payload.backgroundEffect === true;
                    root.hyprlandLayerBlurSupported = payload.hyprlandLayerBlur === true;
                    root.backend = payload.backend || "none";
                    if (root.available)
                        log.info("Blur backend available:", root.backend);
                    else
                        log.info("No blur backend available:", payload.reason || "unknown");
                    root.scheduleHyprlandApply();
                } catch (e) {
                    root.backgroundEffectSupported = false;
                    root.hyprlandLayerBlurSupported = false;
                    root.backend = "none";
                    log.warn("blur probe returned invalid JSON:", e);
                }
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0)
                log.warn("blur probe failed with code:", exitCode);
        }
    }

    Process {
        id: hyprlandApply
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                if ((text || "").trim().length === 0)
                    return;
                try {
                    const payload = JSON.parse(text);
                    if (!payload.ok)
                        log.warn("Hyprland blur apply failed:", payload.error || payload.stderr || "unknown");
                } catch (e) {
                    log.warn("Hyprland blur apply returned invalid JSON:", e);
                }
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0)
                log.warn("Hyprland blur apply failed with code:", exitCode);
            if (root._applyPending) {
                root._applyPending = false;
                root.scheduleHyprlandApply();
            }
        }
    }

    Connections {
        target: SettingsData
        function onBlurEnabledChanged() { root.scheduleHyprlandApply(); }
        function onPopupBlurStrengthChanged() { root.scheduleHyprlandApply(); }
        function onPopupGlassEffectChanged() { root.scheduleHyprlandApply(); }
        function onPopupTransparencyChanged() { root.scheduleHyprlandApply(); }
    }

    Connections {
        target: Theme
        function onIsLightModeChanged() { root.scheduleHyprlandApply(); }
    }

    Connections {
        target: CompositorService.isHyprland ? Hyprland : null
        enabled: CompositorService.isHyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded" || event.name === "configreload")
                root.scheduleHyprlandApply();
        }
    }

    Connections {
        target: CompositorService
        function onCompositorDetectedChanged() {
            if (CompositorService.compositorDetected && CompositorService.isHyprland)
                blurProbe.running = true;
        }
    }

    Component.onCompleted: {
        if (CompositorService.compositorDetected && CompositorService.isHyprland)
            blurProbe.running = true;
    }
}
