import QtQuick
import QtQuick.Effects
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: aboutTab

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property bool isHyprland: CompositorService.isHyprland
    property bool isNiri: CompositorService.isNiri
    property bool isSway: CompositorService.isSway
    property bool isScroll: CompositorService.isScroll
    property bool isMiracle: CompositorService.isMiracle
    property bool isMango: CompositorService.isMango
    property bool isLabwc: CompositorService.isLabwc

    property string compositorName: {
        if (isHyprland)
            return "hyprland";
        if (isSway)
            return "sway";
        if (isScroll)
            return "scroll";
        if (isMiracle)
            return "miracle";
        if (isMango)
            return "mangowc";
        if (isLabwc)
            return "labwc";
        return "niri";
    }

    property string compositorLogo: {
        if (isHyprland)
            return "/assets/hyprland.svg";
        if (isSway)
            return "/assets/sway.svg";
        if (isScroll)
            return "/assets/sway.svg";
        if (isMiracle)
            return "/assets/miraclewm.svg";
        if (isMango)
            return "/assets/mango.png";
        if (isLabwc)
            return "/assets/labwc.png";
        return "/assets/niri.svg";
    }








    readonly property var expectedBackendCapabilities: ["core", "loginctl", "dbus", "freedesktop", "mime", "network", "bluetooth", "clipboard", "gamma", "location", "wallpaper", "brightness", "wlroutput", "cups", "tailscale", "sysupdate", "evdev"]
    readonly property var degradedBackendCapabilities: expectedBackendCapabilities.filter(cap => !VGSBackendService.capabilities.includes(cap))

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn
            topPadding: Theme.spacingXS

            width: Math.min(550, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL


            StyledRect {
                width: parent.width
                height: asciiSection.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                border.color: Theme.outlineHeavy
                border.width: 0

                Column {
                    id: asciiSection

                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: parent.width < 350 ? Theme.spacingM : Theme.spacingL

                        property bool compactLogo: parent.width < 400
                        property bool hideLogo: parent.width < 280

                        Image {
                            id: logoImage

                            visible: !parent.hideLogo
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.compactLogo ? 80 : 120
                            height: width
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            mipmap: true
                            asynchronous: true
                            source: "file://" + Theme.shellDir + "/assets/vgslogo.svg"
                            layer.enabled: true
                            layer.smooth: true
                            layer.mipmap: true
                            layer.effect: MultiEffect {
                                saturation: 0
                                colorization: 1
                                colorizationColor: Theme.primary
                            }
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "VGS"
                            font.pixelSize: parent.compactLogo ? 32 : 48
                            font.weight: Font.Bold
                            font.family: interFont.name
                            color: Theme.surfaceText
                            antialiasing: true

                            FontLoader {
                                id: interFont
                                source: Qt.resolvedUrl("../../assets/fonts/inter/InterVariable.ttf")
                            }
                        }
                    }

                    StyledText {
                        text: {
                            if (!ShellVersionService.shellVersion && !VGSBackendService.cliVersion)
                                return "vgs";

                            let version = ShellVersionService.shellVersion || "";
                            let cliVersion = VGSBackendService.cliVersion || "";

                            // Debian/Ubuntu/OpenSUSE git format: 1.0.3+git2264.c5c5ce84
                            let match = version.match(/^([\d.]+)\+git(\d+)\./);
                            if (match) {
                                return `vgs (git) v${match[1]}-${match[2]}`;
                            }

                            // Fedora COPR git format: 0.0.git.2267.d430cae9
                            match = version.match(/^[\d.]+\.git\.(\d+)\./);
                            if (match) {
                                function extractBaseVersion(value) {
                                    if (!value)
                                        return "";
                                    let baseMatch = value.match(/(\d+\.\d+\.\d+)/);
                                    if (baseMatch)
                                        return baseMatch[1];
                                    baseMatch = value.match(/(\d+\.\d+)/);
                                    if (baseMatch)
                                        return baseMatch[1];
                                    return "";
                                }

                                let baseVersion = extractBaseVersion(cliVersion);
                                if (!baseVersion)
                                    baseVersion = extractBaseVersion(ShellVersionService.semverVersion);
                                if (baseVersion) {
                                    return `vgs (git) v${baseVersion}-${match[1]}`;
                                }
                                return `vgs (git) v${match[1]}`;
                            }

                            // Stable release format: 1.0.3
                            match = version.match(/^([\d.]+)$/);
                            if (match) {
                                return `vgs v${match[1]}`;
                            }

                            if (!version && cliVersion) {
                                match = cliVersion.match(/^([\d.]+)\+git(\d+)\./);
                                if (match) {
                                    return `vgs (git) v${match[1]}-${match[2]}`;
                                }
                                match = cliVersion.match(/^([\d.]+)$/);
                                if (match) {
                                    return `vgs v${match[1]}`;
                                }
                                return `vgs ${cliVersion}`;
                            }

                            return `vgs ${version}`;
                        }
                        font.pixelSize: Theme.fontSizeXLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        horizontalAlignment: Text.AlignHCenter
                        width: parent.width
                    }

                    StyledText {
                        visible: ShellVersionService.shellCodename.length > 0
                        text: `"${ShellVersionService.shellCodename}"`
                        font.pixelSize: Theme.fontSizeMedium
                        font.italic: true
                        color: Theme.surfaceVariantText
                        horizontalAlignment: Text.AlignHCenter
                        width: parent.width
                    }

                    Row {
                        id: resourceButtonsRow
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Theme.spacingS

                        property bool compactMode: parent.width < 450

                        VgsButton {
                            id: githubButton
                            text: resourceButtonsRow.compactMode ? "" : I18n.tr("GitHub")
                            iconName: "code"
                            iconSize: 18
                            backgroundColor: Theme.surfaceTextHover
                            textColor: Theme.surfaceText
                            onClicked: Qt.openUrlExternally("https://github.com/vanillagreencom/vgs")
                            onHoveredChanged: {
                                if (hovered)
                                    resourceTooltip.show("github.com/vanillagreencom/vgs", githubButton, 0, 0, "bottom");
                                else
                                    resourceTooltip.hide();
                            }
                        }
                    }

                    VgsInlineTooltip {
                        id: resourceTooltip
                    }

                }
            }

            SettingsCard {
                width: parent.width
                iconName: "info"
                title: I18n.tr("Project")

                StyledText {
                    text: I18n.tr('VanillaGreen Shell (VGS) is a fast, deeply customizable desktop shell for <a href="https://hypr.land" style="text-decoration:none; color:%1;">Hyprland</a> and <a href="https://github.com/YaLTeR/niri" style="text-decoration:none; color:%1;">Niri</a>.<br /><br/>It is built with <a href="https://quickshell.org" style="text-decoration:none; color:%1;">Quickshell</a>, a Qt6 framework for building desktop shells, and <a href="https://go.dev" style="text-decoration:none; color:%1;">Go</a>, a statically typed, compiled programming language.<br /><br />VGS builds on the work of <a href="https://github.com/AvengeMedia/DankMaterialShell" style="text-decoration:none; color:%1;">DankMaterialShell</a>, which it was originally forked from.').arg(Theme.primary)
                    textFormat: Text.RichText
                    font.pixelSize: Theme.fontSizeMedium
                    linkColor: Theme.primary
                    onLinkActivated: url => Qt.openUrlExternally(url)
                    color: Theme.surfaceVariantText
                    width: parent.width
                    wrapMode: Text.WordWrap

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                        acceptedButtons: Qt.NoButton
                        propagateComposedEvents: true
                    }
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "dns"
                title: I18n.tr("Backend")

                Row {
                    anchors.left: parent.left
                    spacing: Theme.spacingL

                    Column {
                        spacing: Theme.spacingXXS

                        StyledText {
                            text: I18n.tr("Version")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            horizontalAlignment: Text.AlignLeft
                        }

                        StyledText {
                            text: VGSBackendService.cliVersion || "—"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            horizontalAlignment: Text.AlignLeft
                        }
                    }

                    Rectangle {
                        width: 1
                        height: 32
                        color: Theme.outlineVariant
                    }

                    Column {
                        spacing: Theme.spacingXXS

                        StyledText {
                            text: I18n.tr("API")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            horizontalAlignment: Text.AlignLeft
                        }

                        StyledText {
                            text: `v${VGSBackendService.apiVersion}`
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            horizontalAlignment: Text.AlignLeft
                        }
                    }

                    Rectangle {
                        width: 1
                        height: 32
                        color: Theme.outlineVariant
                    }

                    Column {
                        spacing: Theme.spacingXXS

                        StyledText {
                            text: I18n.tr("Status")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            horizontalAlignment: Text.AlignLeft
                        }

                        Row {
                            spacing: Theme.spacingXS

                            Rectangle {
                                width: 8
                                height: 8
                                radius: 4
                                color: VGSBackendService.isConnected ? Theme.success : Theme.error
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: VGSBackendService.isConnected ? I18n.tr("Connected") : I18n.tr("Unavailable")
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                horizontalAlignment: Text.AlignLeft
                            }
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXXS

                    StyledText {
                        text: I18n.tr("Socket")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        width: parent.width
                        horizontalAlignment: Text.AlignLeft
                    }

                    StyledText {
                        text: VGSBackendService.socketPath.length > 0 ? VGSBackendService.socketPath : I18n.tr("Not exported")
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: "monospace"
                        color: Theme.surfaceText
                        width: parent.width
                        wrapMode: Text.WrapAnywhere
                        horizontalAlignment: Text.AlignLeft
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXXS
                    visible: VGSBackendService.lastError.length > 0

                    StyledText {
                        text: I18n.tr("Last Error")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        width: parent.width
                        horizontalAlignment: Text.AlignLeft
                    }

                    StyledText {
                        text: VGSBackendService.lastError
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        width: parent.width
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignLeft
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXXS

                    StyledText {
                        text: I18n.tr("Build Log")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        width: parent.width
                        horizontalAlignment: Text.AlignLeft
                    }

                    StyledText {
                        text: VGSBackendService.backendBuildLogPath
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: "monospace"
                        color: Theme.surfaceText
                        width: parent.width
                        wrapMode: Text.WrapAnywhere
                        horizontalAlignment: Text.AlignLeft
                    }
                }

                Row {
                    anchors.left: parent.left
                    spacing: Theme.spacingL
                    visible: VGSBackendService.isConnected

                    Column {
                        spacing: Theme.spacingXXS

                        StyledText {
                            text: I18n.tr("VGS Protocol")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            horizontalAlignment: Text.AlignLeft
                        }

                        StyledText {
                            text: `v${VGSBackendService.vgsApiVersion}`
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            horizontalAlignment: Text.AlignLeft
                        }
                    }

                    Rectangle {
                        width: 1
                        height: 32
                        color: Theme.outlineVariant
                    }

                    Column {
                        spacing: Theme.spacingXXS

                        StyledText {
                            text: I18n.tr("Methods")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            horizontalAlignment: Text.AlignLeft
                        }

                        StyledText {
                            text: VGSBackendService.methods.length.toString()
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            horizontalAlignment: Text.AlignLeft
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: VGSBackendService.isConnected && aboutTab.degradedBackendCapabilities.length > 0

                    StyledText {
                        text: I18n.tr("Unavailable Capabilities")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        width: parent.width
                        horizontalAlignment: Text.AlignLeft
                    }

                    Flow {
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: aboutTab.degradedBackendCapabilities

                            Rectangle {
                                width: missingCapText.implicitWidth + Theme.spacingL
                                height: 26
                                radius: 13
                                color: Theme.withAlpha(Theme.warning, 0.14)

                                StyledText {
                                    id: missingCapText
                                    anchors.centerIn: parent
                                    text: modelData
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.warning
                                }
                            }
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: VGSBackendService.capabilities.length > 0

                    StyledText {
                        text: I18n.tr("Capabilities")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        width: parent.width
                        horizontalAlignment: Text.AlignLeft
                    }

                    Flow {
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: VGSBackendService.capabilities

                            Rectangle {
                                width: capText.implicitWidth + Theme.spacingL
                                height: 26
                                radius: 13
                                color: Theme.primaryHover

                                StyledText {
                                    id: capText
                                    anchors.centerIn: parent
                                    text: modelData
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.primary
                                }
                            }
                        }
                    }
                }
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: I18n.tr('<a href="https://github.com/vanillagreencom/vgs/blob/main/LICENSE" style="text-decoration:none; color:%1;">MIT License</a>').arg(Theme.surfaceVariantText)
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
                textFormat: Text.RichText
                wrapMode: Text.NoWrap
                onLinkActivated: url => Qt.openUrlExternally(url)

                MouseArea {
                    anchors.fill: parent
                    cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                    acceptedButtons: Qt.NoButton
                    propagateComposedEvents: true
                }
            }
        }
    }


}
