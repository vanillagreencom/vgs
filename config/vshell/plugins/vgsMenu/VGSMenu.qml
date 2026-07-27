pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets
import "./MenuCatalog.js" as MenuCatalog

PluginComponent {
    id: root

    property bool menuOpen: false
    property bool contentVisible: false
    property bool keyboardActive: false
    property string query: ""
    property int selectedCategoryIndex: 0
    property int selectedItemIndex: 0
    property var visibleItems: []
    property var overlayCategories: []
    property var overlayItems: []
    property var webappItems: []

    readonly property var categories: mergeCategories(MenuCatalog.categories, overlayCategories)
    readonly property var allItems: MenuCatalog.items.concat(overlayItems).concat(webappItems)
    readonly property string home: Quickshell.env("HOME")
    readonly property var effectiveScreen: menuWindow.screen
    readonly property real screenWidth: effectiveScreen?.width ?? 1920
    readonly property real screenHeight: effectiveScreen?.height ?? 1080
    readonly property real dpr: effectiveScreen ? CompositorService.getScreenScale(effectiveScreen) : 1
    readonly property int modalWidth: Math.min(860, screenWidth - 120)
    readonly property int modalHeight: Math.min(660, screenHeight - 120)
    readonly property real modalX: Math.max(Theme.spacingL, (screenWidth - modalWidth) / 2)
    readonly property real modalY: Math.max(Theme.spacingL, screenHeight * 0.18)
    readonly property int categoryWidth: 178
    readonly property int rowHeight: 64
    readonly property int openDuration: 80
    readonly property int closeDuration: 60

    function open() {
        const focusedScreen = CompositorService.getFocusedScreen();
        if (focusedScreen && menuWindow.screen !== focusedScreen) {
            menuWindow.screen = focusedScreen;
            clickCatcher.screen = focusedScreen;
        }

        refreshItems();
        menuOpen = true;
        contentVisible = true;
        keyboardActive = true;
        ModalManager.openModal(root);
        Qt.callLater(() => {
            searchInput.forceActiveFocus();
            searchInput.selectAll();
        });
    }

    function close() {
        contentVisible = false;
        keyboardActive = false;
        menuOpen = false;
        ModalManager.closeModal(root);
    }

    function toggle() {
        menuOpen ? close() : open();
    }

    function normalize(value) {
        return String(value || "").toLowerCase();
    }

    function mergeCategories(base, overlay) {
        const out = [];
        const seen = ({});
        const add = function(cat) {
            if (!cat || !cat.id)
                return;
            if (seen[cat.id] !== undefined) {
                out[seen[cat.id]] = cat;
                return;
            }
            seen[cat.id] = out.length;
            out.push(cat);
        };
        for (let i = 0; i < (base || []).length; i++)
            add(base[i]);
        for (let i = 0; i < (overlay || []).length; i++)
            add(overlay[i]);
        return out;
    }

    function parseOverlay(raw) {
        if (!raw || raw.trim().length === 0) {
            overlayCategories = [];
            overlayItems = [];
            return;
        }
        try {
            const data = JSON.parse(raw);
            overlayCategories = data.categories || [];
            overlayItems = data.items || [];
            refreshItems();
        } catch (e) {
            overlayCategories = [];
            overlayItems = [];
            ToastService.showWarning("Menu overlay invalid", e.message || String(e));
        }
    }

    function categoryFor(id) {
        for (let i = 0; i < categories.length; i++) {
            if (categories[i].id === id)
                return categories[i];
        }
        return null;
    }

    function itemMatches(item, q) {
        if (!q)
            return true;
        const category = categoryFor(item.category);
        const haystack = [
            item.title,
            item.subtitle,
            category?.label,
            category?.description,
            (item.keywords || []).join(" ")
        ].join(" ").toLowerCase();
        return haystack.indexOf(q) !== -1;
    }

    function refreshItems() {
        const q = normalize(query.trim());
        const selectedCategory = categories[selectedCategoryIndex]?.id || categories[0]?.id || "";
        const next = [];
        for (let i = 0; i < allItems.length; i++) {
            const item = allItems[i];
            if (!q && item.category !== selectedCategory)
                continue;
            if (q && !itemMatches(item, q))
                continue;
            next.push(item);
        }
        visibleItems = next;
        if (selectedItemIndex >= next.length)
            selectedItemIndex = Math.max(0, next.length - 1);
    }

    function resetResultListPosition() {
        Qt.callLater(() => {
            resultList.contentY = 0;
            if (visibleItems.length > 0)
                resultList.positionViewAtIndex(0, ListView.Beginning);
        });
    }

    function expandArg(arg) {
        return String(arg).replace(/\{home\}/g, home).replace(/\{vshell\}/g, Paths.vshellCli);
    }

    function executeItem(item) {
        if (!item)
            return;
        close();
        Qt.callLater(() => {
            if (item.argv) {
                Quickshell.execDetached(item.argv.map(expandArg));
            } else if (item.shell) {
                Quickshell.execDetached(["sh", "-lc", item.shell]);
            }
        });
        ToastService.showInfo("Launched " + item.title);
    }

    function executeSelected() {
        executeItem(visibleItems[selectedItemIndex]);
    }

    function selectNext() {
        if (visibleItems.length === 0)
            return;
        selectedItemIndex = Math.min(visibleItems.length - 1, selectedItemIndex + 1);
        resultList.positionViewAtIndex(selectedItemIndex, ListView.Contain);
    }

    function selectPrevious() {
        if (visibleItems.length === 0)
            return;
        selectedItemIndex = Math.max(0, selectedItemIndex - 1);
        resultList.positionViewAtIndex(selectedItemIndex, ListView.Contain);
    }

    function handleKey(event) {
        const hasCtrl = event.modifiers & Qt.ControlModifier;
        switch (event.key) {
        case Qt.Key_Escape:
            close();
            event.accepted = true;
            return;
        case Qt.Key_Down:
            selectNext();
            event.accepted = true;
            return;
        case Qt.Key_Up:
            selectPrevious();
            event.accepted = true;
            return;
        case Qt.Key_J:
            if (hasCtrl) {
                selectNext();
                event.accepted = true;
                return;
            }
            break;
        case Qt.Key_K:
            if (hasCtrl) {
                selectPrevious();
                event.accepted = true;
                return;
            }
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            executeSelected();
            event.accepted = true;
            return;
        case Qt.Key_Tab:
            selectedCategoryIndex = (selectedCategoryIndex + 1) % categories.length;
            event.accepted = true;
            return;
        case Qt.Key_Backtab:
            selectedCategoryIndex = (selectedCategoryIndex - 1 + categories.length) % categories.length;
            event.accepted = true;
            return;
        }
        event.accepted = false;
    }

    onQueryChanged: {
        selectedItemIndex = 0;
        refreshItems();
        resetResultListPosition();
    }
    onSelectedCategoryIndexChanged: {
        selectedItemIndex = 0;
        refreshItems();
        resetResultListPosition();
    }

    FileView {
        id: overlayFile
        path: root.home + "/.config/vshell-local/menu.json"
        blockLoading: false
        watchChanges: true
        printErrors: false
        onLoaded: root.parseOverlay(text())
        onFileChanged: overlayFile.reload()
        onLoadFailed: {
            root.overlayCategories = [];
            root.overlayItems = [];
        }
    }

    FileView {
        id: webappsFile
        path: root.home + "/.config/vshell-local/webapps.json"
        blockLoading: false
        watchChanges: true
        printErrors: false
        onLoaded: {
            try {
                const data = JSON.parse(text() || "{}");
                root.webappItems = data.items || [];
                root.refreshItems();
            } catch (e) {
                root.webappItems = [];
            }
        }
        onFileChanged: webappsFile.reload()
        onLoadFailed: root.webappItems = []
    }

    Connections {
        target: ModalManager

        function onCloseAllModalsExcept(excludedModal) {
            if (excludedModal !== root && root.menuOpen)
                root.close();
        }
    }

    Connections {
        target: Quickshell

        function onScreensChanged() {
            if (Quickshell.screens.length === 0)
                return;
            if (!menuWindow.screen) {
                menuWindow.screen = Quickshell.screens[0];
                clickCatcher.screen = Quickshell.screens[0];
            }
        }
    }

    IpcHandler {
        target: "vshell-menu"

        function open(): string {
            root.open();
            return "VSHELL_MENU_OPEN_SUCCESS";
        }

        function close(): string {
            root.close();
            return "VSHELL_MENU_CLOSE_SUCCESS";
        }

        function toggle(): string {
            root.toggle();
            return "VSHELL_MENU_TOGGLE_SUCCESS";
        }
    }

    HyprlandFocusGrab {
        id: focusGrab
        // The catcher is one of ours: leaving it out meant any click that landed
        // on it cleared the grab and closed the menu, even over the menu itself.
        windows: [menuWindow, clickCatcher]
        active: CompositorService.useHyprlandFocusGrab && root.keyboardActive
        onCleared: {
            if (root.menuOpen)
                root.close();
        }
    }

    PanelWindow {
        id: clickCatcher
        visible: root.menuOpen || root.contentVisible
        color: "transparent"
        // Must keep committing, otherwise the input-region mask below never
        // reaches the compositor and the catcher swallows clicks over the menu.
        updatesEnabled: true

        WlrLayershell.namespace: "vshell:vgs-menu:clickcatcher"
        WlrLayershell.layer: LayerShell.fromEnv("VGS_MODAL_LAYER", WlrLayer.Overlay, {
            "allow": ["top", "overlay"],
            "invalidLayer": WlrLayer.Top,
            "label": "vgs menu",
            "error": true
        })
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // Punch the menu's rect out of the catcher's input region so clicks on
        // the menu — the category rail most of all — land on the menu window
        // instead of being treated as click-outside-to-dismiss.
        mask: Region {
            item: Rectangle {
                x: Theme.snap(root.modalX, root.dpr)
                y: Theme.snap(root.modalY, root.dpr)
                width: Theme.px(root.modalWidth, root.dpr)
                height: Theme.px(root.modalHeight, root.dpr)
            }
            intersection: Intersection.Xor
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.menuOpen
            onClicked: root.close()
        }
    }

    PanelWindow {
        id: menuWindow
        visible: root.menuOpen || root.contentVisible
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WindowBlur {
            targetWindow: menuWindow
            blurX: 0
            blurY: 0
            blurWidth: root.contentVisible ? modal.width : 0
            blurHeight: root.contentVisible ? modal.height : 0
            blurRadius: Theme.cornerRadius
        }

        WlrLayershell.namespace: "vshell:vgs-menu"
        WlrLayershell.layer: LayerShell.fromEnv("VGS_MODAL_LAYER", WlrLayer.Overlay, {
            "allow": ["top", "overlay"],
            "invalidLayer": WlrLayer.Top,
            "label": "vgs menu",
            "error": true
        })
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: KeyboardFocus.keyboardFocus(root.keyboardActive, null)

        anchors {
            top: true
            left: true
        }

        WlrLayershell.margins {
            left: Theme.snap(root.modalX, root.dpr)
            top: Theme.snap(root.modalY, root.dpr)
        }

        implicitWidth: Theme.px(root.modalWidth, root.dpr)
        implicitHeight: Theme.px(root.modalHeight, root.dpr)

        VgsSurfaceChrome {
            id: modal
            x: 0
            y: 0
            width: Theme.px(root.modalWidth, root.dpr)
            height: Theme.px(root.modalHeight, root.dpr)
            radius: Theme.cornerRadius
            surfaceColor: Theme.popupSurfaceColor(Theme.surfaceContainer)
            borderWidth: BlurService.borderWidth
            borderColor: BlurService.borderColor
            opacity: root.contentVisible ? 1 : 0
            scale: root.contentVisible ? 1 : 0.985

            Behavior on opacity {
                NumberAnimation {
                    duration: root.contentVisible ? root.openDuration : root.closeDuration
                    easing.type: Theme.standardEasing
                }
            }

            Behavior on scale {
                NumberAnimation {
                    duration: root.contentVisible ? root.openDuration : root.closeDuration
                    easing.type: Theme.standardEasing
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onClicked: mouse => mouse.accepted = true
                onPressed: mouse => mouse.accepted = true
            }

            FocusScope {
                id: keyScope
                anchors.fill: parent
                focus: root.keyboardActive
                Keys.onPressed: event => root.handleKey(event)

                Row {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingM

                    Column {
                        id: categoryRail
                        width: root.categoryWidth
                        height: parent.height
                        spacing: Theme.spacingS

                        StyledText {
                            width: parent.width
                            height: Theme.fontSizeLarge + Theme.spacingS
                            text: "VGS"
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        Repeater {
                            model: ScriptModel {
                                values: root.categories
                                objectProp: "id"
                            }

                            delegate: CategoryButton {
                                required property var modelData
                                required property int index

                                width: categoryRail.width
                                category: modelData
                                selected: root.selectedCategoryIndex === index && root.query.trim().length === 0
                                onClicked: {
                                    root.selectedCategoryIndex = index;
                                    searchInput.forceActiveFocus();
                                }
                            }
                        }
                    }

                    Column {
                        width: parent.width - categoryRail.width - parent.spacing
                        height: parent.height
                        spacing: Theme.spacingM

                        StyledRect {
                            id: searchBar
                            width: parent.width
                            height: 56
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(searchInput.activeFocus ? Theme.primaryContainer : Theme.surfaceContainerHigh, Theme.popupTransparency)
                            border.width: searchInput.activeFocus ? 2 : 1
                            border.color: searchInput.activeFocus ? Theme.primary : Theme.outlineMedium

                            NerdIcon {
                                id: searchIcon
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingM
                                anchors.verticalCenter: parent.verticalCenter
                                glyph: "\uf002"
                                size: Theme.iconSize
                                color: searchInput.activeFocus ? Theme.primary : Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.left: searchIcon.right
                                anchors.leftMargin: Theme.spacingM
                                anchors.right: clearButton.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Search commands"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.outlineButton
                                visible: searchInput.text.length === 0
                                elide: Text.ElideRight
                            }

                            TextInput {
                                id: searchInput
                                anchors.left: searchIcon.right
                                anchors.leftMargin: Theme.spacingM
                                anchors.right: clearButton.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                height: parent.height
                                focus: true
                                clip: true
                                color: Theme.surfaceText
                                selectionColor: Theme.primaryContainer
                                selectedTextColor: Theme.primary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                verticalAlignment: TextInput.AlignVCenter
                                onTextChanged: root.query = text
                                Keys.onPressed: event => root.handleKey(event)
                            }

                            VgsActionButton {
                                id: clearButton
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                visible: searchInput.text.length > 0
                                iconName: "close"
                                iconSize: Theme.iconSizeSmall
                                buttonSize: 32
                                onClicked: {
                                    searchInput.text = "";
                                    searchInput.forceActiveFocus();
                                }
                            }
                        }

                        StyledRect {
                            width: parent.width
                            height: parent.height - searchBar.height - parent.spacing
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)

                            ListView {
                                id: resultList
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                clip: true
                                currentIndex: root.selectedItemIndex
                                boundsBehavior: Flickable.StopAtBounds
                                model: ScriptModel {
                                    values: root.visibleItems
                                    objectProp: "title"
                                }

                                delegate: ResultRow {
                                    required property var modelData
                                    required property int index

                                    width: resultList.width
                                    height: root.rowHeight
                                    itemData: modelData
                                    selected: root.selectedItemIndex === index
                                    categoryLabel: root.categoryFor(modelData.category)?.label || ""
                                    onClicked: {
                                        root.selectedItemIndex = index;
                                        root.executeItem(modelData);
                                    }
                                    onHovered: root.selectedItemIndex = index
                                }
                            }

                            Column {
                                anchors.centerIn: parent
                                spacing: Theme.spacingS
                                visible: root.visibleItems.length === 0

                                NerdIcon {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    glyph: "\uf002"
                                    size: Theme.iconSizeLarge
                                    color: Theme.surfaceVariantText
                                }

                                StyledText {
                                    width: 260
                                    text: "No matching commands"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceVariantText
                                    horizontalAlignment: Text.AlignHCenter
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    component NerdIcon: Item {
        id: nerdIcon

        property string glyph: ""
        property int size: Theme.iconSize
        property color color: Theme.surfaceText
        property real xOffset: 0

        width: Math.round(size)
        height: Math.round(size)

        FontLoader {
            id: nerdFont
            source: Qt.resolvedUrl("../../assets/fonts/nerd-fonts/FiraCodeNerdFont-Regular.ttf")
        }

        StyledText {
            x: nerdIcon.xOffset
            y: 0
            width: parent.width
            height: parent.height
            text: nerdIcon.glyph
            font.family: nerdFont.name
            font.pixelSize: nerdIcon.size
            font.weight: Font.Normal
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: nerdIcon.color
            wrapMode: Text.NoWrap
        }
    }

    component CategoryButton: StyledRect {
        id: categoryButton

        property var category: ({})
        property bool selected: false

        signal clicked

        height: 44
        radius: Theme.cornerRadius
        color: selected ? Theme.withAlpha(Theme.primary, 0.18) : categoryArea.containsMouse ? Theme.surfaceHover : "transparent"
        border.width: selected ? 1 : 0
        border.color: selected ? Theme.withAlpha(Theme.primary, 0.45) : "transparent"

        Row {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingS

            NerdIcon {
                width: Theme.iconSize
                height: parent.height
                glyph: categoryButton.category.icon || "\uf0c9"
                size: Theme.iconSizeSmall
                color: categoryButton.selected ? Theme.primary : Theme.surfaceVariantText
            }

            StyledText {
                width: parent.width - Theme.iconSize - parent.spacing
                height: parent.height
                text: categoryButton.category.label || ""
                font.pixelSize: Theme.fontSizeSmall
                font.weight: categoryButton.selected ? Font.Bold : Font.Medium
                color: categoryButton.selected ? Theme.primary : Theme.surfaceText
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: categoryArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: categoryButton.clicked()
        }
    }

    component ResultRow: StyledRect {
        id: resultRow

        property var itemData: ({})
        property bool selected: false
        property string categoryLabel: ""

        signal clicked
        signal hovered

        radius: Theme.cornerRadius
        color: selected ? Theme.withAlpha(Theme.primary, 0.16) : rowArea.containsMouse ? Theme.surfaceHover : "transparent"

        Row {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingM

            StyledRect {
                width: 40
                height: 40
                anchors.verticalCenter: parent.verticalCenter
                radius: Theme.cornerRadius
                color: Theme.withAlpha(resultRow.selected ? Theme.primary : Theme.surfaceVariantText, resultRow.selected ? 0.18 : 0.12)

                NerdIcon {
                    anchors.fill: parent
                    glyph: resultRow.itemData.icon || "\uf0c1"
                    size: Theme.iconSize
                    xOffset: -Math.round(Theme.iconSize * 0.08)
                    color: resultRow.selected ? Theme.primary : Theme.surfaceVariantText
                }
            }

            Column {
                width: parent.width - 40 - categoryPill.width - parent.spacing * 2
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                StyledText {
                    width: parent.width
                    text: resultRow.itemData.title || ""
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                StyledText {
                    width: parent.width
                    text: resultRow.itemData.subtitle || ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
            }

            StyledRect {
                id: categoryPill
                width: Math.min(118, categoryText.implicitWidth + Theme.spacingM)
                height: 24
                anchors.verticalCenter: parent.verticalCenter
                radius: height / 2
                color: Theme.withAlpha(Theme.secondary, 0.14)

                StyledText {
                    id: categoryText
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingS
                    text: resultRow.categoryLabel
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.Medium
                    color: Theme.secondary
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                }
            }
        }

        MouseArea {
            id: rowArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: resultRow.hovered()
            onClicked: resultRow.clicked()
        }
    }
}
