import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Modules.WorkspaceOverlays.OverviewSearch
import qs.Services
import qs.Widgets

Scope {
    id: niriOverviewScope

    property bool searchActive: false
    property string searchActiveScreen: ""
    property bool isClosing: false
    property bool releaseKeyboard: false
    // The overview search yields to the app launcher (vgsMenu plugin) when it opens.
    readonly property bool appMenuOpen: PluginService.appLauncherOpen
    property bool overlayActive: NiriService.inOverview || searchActive

    function showSearch(screenName) {
        isClosing = false;
        releaseKeyboard = false;
        searchActive = true;
        searchActiveScreen = screenName;
    }

    function hideSearch() {
        if (!searchActive)
            return;
        isClosing = true;
    }

    function hideAndReleaseKeyboard() {
        releaseKeyboard = true;
        hideSearch();
    }

    function resetState() {
        searchActive = false;
        searchActiveScreen = "";
        isClosing = false;
        releaseKeyboard = false;
    }

    Connections {
        target: NiriService
        function onInOverviewChanged() {
            if (NiriService.inOverview) {
                resetState();
                return;
            }
            if (!searchActive) {
                resetState();
                return;
            }
            isClosing = true;
        }

        function onCurrentOutputChanged() {
            if (!NiriService.inOverview || !searchActive || searchActiveScreen === "" || searchActiveScreen === NiriService.currentOutput)
                return;
            hideSearch();
        }
    }

    onAppMenuOpenChanged: {
        if (appMenuOpen && searchActive)
            hideSearch();
    }

    onIsClosingChanged: {
        if (!isClosing) {
            closeTimer.stop();
            return;
        }
        closeTimer.restart();
    }

    Timer {
        id: closeTimer
        interval: Theme.expressiveDurations.fast
        onTriggered: niriOverviewScope.resetState()
    }

    Loader {
        id: niriOverlayLoader
        active: overlayActive || isClosing
        asynchronous: false
        sourceComponent: Variants {
            id: overlayVariants
            model: Quickshell.screens

            PanelWindow {
                id: overlayWindow
                required property var modelData

                readonly property real dpr: CompositorService.getScreenScale(screen)
                readonly property bool isActiveScreen: screen.name === NiriService.currentOutput
                readonly property bool shouldShowSearch: niriOverviewScope.searchActive && screen.name === niriOverviewScope.searchActiveScreen && !niriOverviewScope.isClosing
                readonly property bool isSearchScreen: screen.name === niriOverviewScope.searchActiveScreen
                readonly property bool overlayVisible: NiriService.inOverview || niriOverviewScope.isClosing
                property bool hasActivePopout: !!PopoutManager.currentPopoutsByScreen[screen.name]
                property bool hasActiveModal: !!ModalManager.currentModalsByScreen[screen.name]

                Connections {
                    target: PopoutManager
                    function onPopoutChanged() {
                        overlayWindow.hasActivePopout = !!PopoutManager.currentPopoutsByScreen[overlayWindow.screen.name];
                    }
                }

                Connections {
                    target: ModalManager
                    function onModalChanged() {
                        overlayWindow.hasActiveModal = !!ModalManager.currentModalsByScreen[overlayWindow.screen.name];
                    }
                }

                screen: modelData
                visible: overlayVisible
                color: "transparent"

                WlrLayershell.namespace: "vshell:niri-overview-search"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.exclusiveZone: -1
                WlrLayershell.keyboardFocus: {
                    if (PopoutManager.screenshotActive)
                        return WlrKeyboardFocus.None;
                    if (!NiriService.inOverview)
                        return WlrKeyboardFocus.None;
                    if (!isActiveScreen)
                        return WlrKeyboardFocus.None;
                    if (niriOverviewScope.releaseKeyboard)
                        return WlrKeyboardFocus.None;
                    if (hasActivePopout || hasActiveModal)
                        return WlrKeyboardFocus.None;
                    return WlrKeyboardFocus.Exclusive;
                }

                mask: Region {
                    item: overlayVisible && searchContainer.visible ? searchContainer : null
                }

                WindowBlur {
                    targetWindow: overlayWindow
                    // Track the container's scale so blur shrinks with the content
                    // during exit — otherwise blur pops away one frame after content.
                    readonly property real s: Math.min(1, searchContainer.scale)
                    readonly property bool active: overlayWindow.shouldShowSearch && searchContainer.opacity > 0
                    blurX: searchContainer.x + searchContainer.width * (1 - s) * 0.5
                    blurY: searchContainer.y + searchContainer.height * (1 - s) * 0.5
                    blurWidth: active ? searchContainer.width * s : 0
                    blurHeight: active ? searchContainer.height * s : 0
                    blurRadius: Theme.cornerRadius
                }

                onShouldShowSearchChanged: {
                    if (shouldShowSearch) {
                        if (launcherContent?.controller) {
                            launcherContent.controller.searchMode = SessionData.niriOverviewLastMode || "apps";
                            launcherContent.controller.performSearch();
                        }
                        return;
                    }
                    if (!isActiveScreen)
                        return;
                    Qt.callLater(() => keyboardFocusScope.forceActiveFocus());
                }

                anchors {
                    top: true
                    left: true
                    right: true
                    bottom: true
                }

                FocusScope {
                    id: keyboardFocusScope
                    anchors.fill: parent
                    focus: true

                    Keys.onPressed: event => {
                        if (overlayWindow.shouldShowSearch || niriOverviewScope.isClosing)
                            return;
                        if ([Qt.Key_Escape, Qt.Key_Return].includes(event.key)) {
                            NiriService.toggleOverview();
                            event.accepted = true;
                            return;
                        }

                        if (event.key === Qt.Key_Left) {
                            NiriService.moveColumnLeft();
                            event.accepted = true;
                            return;
                        }

                        if (event.key === Qt.Key_Right) {
                            NiriService.moveColumnRight();
                            event.accepted = true;
                            return;
                        }

                        if (event.key === Qt.Key_Up) {
                            NiriService.moveWorkspaceUp();
                            event.accepted = true;
                            return;
                        }

                        if (event.key === Qt.Key_Down) {
                            NiriService.moveWorkspaceDown();
                            event.accepted = true;
                            return;
                        }

                        if (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier) || [Qt.Key_Delete, Qt.Key_Backspace].includes(event.key)) {
                            event.accepted = false;
                            return;
                        }

                        if (event.isAutoRepeat || !event.text)
                            return;
                        if (!launcherContent?.searchField)
                            return;
                        const trimmedText = event.text.trim();
                        launcherContent.searchField.text = trimmedText;
                        launcherContent.controller.setSearchQuery(trimmedText);
                        niriOverviewScope.showSearch(overlayWindow.screen.name);
                        Qt.callLater(() => launcherContent.searchField.forceActiveFocus());
                        event.accepted = true;
                    }
                }

                Item {
                    id: searchContainer

                    readonly property real _centerY: (parent.height - height) / 2

                    x: Theme.snap((parent.width - width) / 2, overlayWindow.dpr)
                    y: Theme.snap(_centerY, overlayWindow.dpr)

                    readonly property int baseWidth: {
                        switch (SettingsData.launcherSize) {
                        case "micro":
                            return 500;
                        case "medium":
                            return 720;
                        case "large":
                            return 860;
                        default:
                            return 620;
                        }
                    }
                    readonly property int baseHeight: {
                        switch (SettingsData.launcherSize) {
                        case "micro":
                            return 480;
                        case "medium":
                            return 720;
                        case "large":
                            return 860;
                        default:
                            return 600;
                        }
                    }
                    width: Math.min(baseWidth, overlayWindow.screen.width - 100)
                    height: Math.min(baseHeight, overlayWindow.screen.height - 100)

                    readonly property bool animatingOut: niriOverviewScope.isClosing && overlayWindow.isSearchScreen

                    scale: overlayWindow.shouldShowSearch ? 1.0 : 0.96
                    opacity: overlayWindow.shouldShowSearch ? 1 : 0
                    visible: overlayWindow.shouldShowSearch || animatingOut
                    enabled: overlayWindow.shouldShowSearch

                    layer.enabled: visible
                    layer.smooth: false
                    layer.textureSize: layer.enabled ? Qt.size(Math.round(width * overlayWindow.dpr), Math.round(height * overlayWindow.dpr)) : Qt.size(0, 0)

                    Behavior on scale {
                        id: scaleAnimation
                        NumberAnimation {
                            duration: Theme.expressiveDurations.fast
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: searchContainer.visible ? Theme.expressiveCurves.expressiveFastSpatial : Theme.expressiveCurves.standardAccel
                            onRunningChanged: {
                                if (running || !searchContainer.animatingOut)
                                    return;
                                niriOverviewScope.resetState();
                            }
                        }
                    }

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.expressiveDurations.fast
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: searchContainer.visible ? Theme.expressiveCurves.expressiveFastSpatial : Theme.expressiveCurves.standardAccel
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
                        radius: Theme.cornerRadius
                        border.color: Theme.outlineMedium
                        border.width: 1
                    }

                    FocusScope {
                        anchors.fill: parent
                        focus: true

                        Keys.onPressed: event => launcherContent.activeContextMenu?.handleKey(event)

                        Keys.onEscapePressed: event => {
                            launcherContent.activeContextMenu?.handleKey(event);
                            if (!event.accepted)
                                launcherContent.parentModal?.hide();
                            event.accepted = true;
                        }

                        OverviewSearchContent {
                            id: launcherContent
                            anchors.fill: parent
                            anchors.margins: 0

                            property var fakeParentModal: QtObject {
                                property bool searchOpen: searchContainer.visible
                                property bool isClosing: niriOverviewScope.isClosing
                                property real alignedX: searchContainer.x
                                property real alignedY: searchContainer.y
                                function hide() {
                                    if (niriOverviewScope.searchActive) {
                                        niriOverviewScope.hideSearch();
                                        return;
                                    }
                                    NiriService.toggleOverview();
                                }
                            }

                            Connections {
                                target: launcherContent.searchField
                                function onTextChanged() {
                                    if (launcherContent.searchField.text.length > 0 || !niriOverviewScope.searchActive)
                                        return;
                                    niriOverviewScope.hideSearch();
                                }
                            }

                            Component.onCompleted: {
                                parentModal = fakeParentModal;
                            }

                            Connections {
                                target: launcherContent.controller
                                function onItemExecuted() {
                                    niriOverviewScope.releaseKeyboard = true;
                                }
                                function onModeChanged(mode) {
                                    if (launcherContent.controller.autoSwitchedToFiles)
                                        return;
                                    SessionData.setNiriOverviewLastMode(mode);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
