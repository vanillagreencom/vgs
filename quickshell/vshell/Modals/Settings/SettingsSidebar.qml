pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Modals.Settings
import qs.Services
import qs.Widgets

Rectangle {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property int currentIndex: 0
    property var parentModal: null

    signal tabChangeRequested(int tabIndex)
    property string _expandedIds: ","
    property string _collapsedIds: ","
    property string _autoExpandedIds: ","
    property bool searchActive: searchField.text.length > 0
    property int searchSelectedIndex: 0
    property int keyboardHighlightIndex: -1
    readonly property int navigationStateDuration: Theme.currentAnimationSpeed === SettingsData.AnimationSpeed.None ? 0 : Anims.settingsNavigationStateDuration

    function focusSearch() {
        searchField.forceActiveFocus();
    }

    function highlightNext() {
        var flatItems = getFlatNavigableItems();
        if (flatItems.length === 0)
            return;
        var currentPos = flatItems.findIndex(item => item.tabIndex === keyboardHighlightIndex);
        if (currentPos === -1) {
            currentPos = flatItems.findIndex(item => item.tabIndex === currentIndex);
        }
        var nextPos = (currentPos + 1) % flatItems.length;
        keyboardHighlightIndex = flatItems[nextPos].tabIndex;
        autoExpandForTab(keyboardHighlightIndex);
    }

    function highlightPrevious() {
        var flatItems = getFlatNavigableItems();
        if (flatItems.length === 0)
            return;
        var currentPos = flatItems.findIndex(item => item.tabIndex === keyboardHighlightIndex);
        if (currentPos === -1) {
            currentPos = flatItems.findIndex(item => item.tabIndex === currentIndex);
        }
        var prevPos = (currentPos - 1 + flatItems.length) % flatItems.length;
        keyboardHighlightIndex = flatItems[prevPos].tabIndex;
        autoExpandForTab(keyboardHighlightIndex);
    }

    function selectHighlighted() {
        if (keyboardHighlightIndex < 0)
            return;
        var oldIndex = currentIndex;
        var newIndex = keyboardHighlightIndex;
        tabChangeRequested(newIndex);
        autoCollapseIfNeeded(oldIndex, newIndex);
        keyboardHighlightIndex = -1;
        searchField.setFocus(false);
    }

    // Resolves each entry's tabIndex from SettingsRegistry so the registry
    // stays the single source of truth for tab numbering.
    function _withTabIndexes(cats) {
        return cats.map(cat => {
            const c = Object.assign({}, cat);
            if (c.children)
                c.children = c.children.map(ch => Object.assign({}, ch, {
                    "tabIndex": SettingsRegistry.tabIndexFor(ch.id)
                }));
            else if (!c.separator)
                c.tabIndex = SettingsRegistry.tabIndexFor(c.id);
            return c;
        });
    }

    readonly property var categoryStructure: _withTabIndexes([
        {
            "id": "personalization",
            "text": I18n.tr("Personalization"),
            "icon": "palette",
            "children": [
                {
                    "id": "theme",
                    "text": I18n.tr("Themes"),
                    "icon": "format_paint",
                },
                {
                    "id": "wallpaper",
                    "text": I18n.tr("Wallpaper"),
                    "icon": "wallpaper",
                    "treeChild": true
                },
                {
                    "id": "colors",
                    "text": I18n.tr("Colors"),
                    "icon": "palette",
                    "treeChild": true
                },
                {
                    "id": "icons",
                    "text": I18n.tr("Icons"),
                    "icon": "interests",
                    "treeChild": true
                },
                {
                    "id": "screensaver",
                    "text": I18n.tr("Screensaver"),
                    "icon": "screenshot_monitor",
                    "treeChild": true
                },
                {
                    "id": "interface",
                    "text": I18n.tr("Interface"),
                    "icon": "web_asset",
                },
                {
                    "id": "typography",
                    "text": I18n.tr("Typography"),
                    "icon": "text_fields",
                },
                {
                    "id": "motion",
                    "text": I18n.tr("Motion"),
                    "icon": "auto_awesome_motion",
                },
                {
                    "id": "time_weather",
                    "text": I18n.tr("Time & Weather"),
                    "icon": "schedule",
                },
                {
                    "id": "sounds",
                    "text": I18n.tr("Sounds"),
                    "icon": "volume_up",
                    "soundsOnly": true
                }
            ]
        },
        {
            "id": "bar",
            "text": I18n.tr("Bar"),
            "icon": "toolbar",
            "children": [
                {
                    "id": "bar_appearance",
                    "text": I18n.tr("Appearance"),
                    "icon": "palette",
                },
                {
                    "id": "bar_settings",
                    "text": I18n.tr("Behavior"),
                    "icon": "tune",
                },
                {
                    "id": "bar_widgets",
                    "text": I18n.tr("Widgets"),
                    "icon": "widgets",
                }
            ]
        },
        {
            "id": "windows",
            "text": I18n.tr("Windows & Workspaces"),
            "icon": "select_window",
            "children": [
                {
                    "id": "workspaces",
                    "text": I18n.tr("Workspaces"),
                    "icon": "view_module",
                },
                {
                    "id": "compositor_layout",
                    "text": (CompositorService.isNiri ? "Niri" : (CompositorService.isHyprland ? "Hyprland" : "MangoWC")) + " " + I18n.tr("Layout"),
                    "icon": "layers",
                    "layoutCapable": true
                },
                {
                    "id": "window_rules",
                    "text": I18n.tr("Window Rules"),
                    "icon": "rule",
                    "windowRulesCapable": true
                },
                {
                    "id": "scratchpads",
                    "text": I18n.tr("Scratchpads"),
                    "icon": "picture_in_picture"
                }
            ]
        },
        {
            "id": "workspaces_widgets",
            "text": I18n.tr("Widgets & Notifications"),
            "icon": "dashboard",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "vgs_dash",
                    "text": I18n.tr("Dash"),
                    "icon": "space_dashboard",
                },
                {
                    "id": "media_player",
                    "text": I18n.tr("Media Player"),
                    "icon": "music_note",
                },
                {
                    "id": "notifications",
                    "text": I18n.tr("Notifications"),
                    "icon": "notifications",
                },
                {
                    "id": "osd",
                    "text": I18n.tr("On-screen Displays"),
                    "icon": "tune",
                },
                {
                    "id": "desktop_widgets",
                    "text": I18n.tr("Desktop Widgets"),
                    "icon": "widgets",
                }
            ]
        },
        {
            "id": "dock_launcher",
            "text": I18n.tr("Dock & Launcher"),
            "icon": "shelf_auto_hide",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "dock",
                    "text": I18n.tr("Dock"),
                    "icon": "dock_to_bottom",
                },
                {
                    "id": "launcher",
                    "text": I18n.tr("Launcher"),
                    "icon": "grid_view",
                }
            ]
        },
        {
            "id": "keybinds",
            "text": I18n.tr("Keyboard Shortcuts"),
            "icon": "keyboard",
            "shortcutsOnly": true
        },
        {
            "id": "displays",
            "text": I18n.tr("Displays"),
            "icon": "monitor",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "display_config",
                    "text": I18n.tr("Configuration"),
                    "icon": "display_settings",
                },
                {
                    "id": "display_gamma",
                    "text": I18n.tr("Night Mode"),
                    "icon": "brightness_6",
                },
                {
                    "id": "display_widgets",
                    "text": I18n.tr("Widgets", "settings_displays"),
                    "icon": "widgets",
                }
            ]
        },
        {
            "id": "network",
            "text": I18n.tr("Network"),
            "icon": "wifi",
            "vgsOnly": true,
            "children": [
                {
                    "id": "network_status",
                    "text": I18n.tr("Status"),
                    "icon": "lan",
                },
                {
                    "id": "network_ethernet",
                    "text": I18n.tr("Ethernet"),
                    "icon": "settings_ethernet",
                },
                {
                    "id": "network_wifi",
                    "text": I18n.tr("Wi-Fi"),
                    "icon": "wifi",
                },
                {
                    "id": "network_vpn",
                    "text": I18n.tr("VPN"),
                    "icon": "vpn_key",
                }
            ]
        },
        {
            "id": "applications",
            "text": I18n.tr("Applications"),
            "icon": "apps",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "default_apps",
                    "text": I18n.tr("Default Apps"),
                    "icon": "star",
                },
                {
                    "id": "developer",
                    "text": I18n.tr("Developer"),
                    "icon": "code",
                },
                {
                    "id": "running_apps",
                    "text": I18n.tr("Running Apps"),
                    "icon": "app_registration",
                    "hyprlandNiriOnly": true
                },
                {
                    "id": "autostart",
                    "text": I18n.tr("Autostart"),
                    "icon": "line_start",
                    "autostartOnly": true
                }
            ]
        },
        {
            "id": "system",
            "text": I18n.tr("System"),
            "icon": "memory",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "audio",
                    "text": I18n.tr("Audio"),
                    "icon": "headphones",
                },
                {
                    "id": "locale",
                    "text": I18n.tr("Locale"),
                    "icon": "language",
                },
                {
                    "id": "clipboard",
                    "text": I18n.tr("Clipboard"),
                    "icon": "content_paste",
                    "clipboardOnly": true
                },
                {
                    "id": "printers",
                    "text": I18n.tr("Printers"),
                    "icon": "print",
                    "cupsOnly": true
                },
                {
                    "id": "multiplexers",
                    "text": I18n.tr("Multiplexers"),
                    "icon": "terminal",
                },
                {
                    "id": "users",
                    "text": I18n.tr("Users"),
                    "icon": "manage_accounts",
                }
            ]
        },
        {
            "id": "power_security",
            "text": I18n.tr("Power & Security"),
            "icon": "security",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "battery",
                    "text": I18n.tr("Battery"),
                    "icon": "battery_charging_full",
                },
                {
                    "id": "lock_screen",
                    "text": I18n.tr("Lock Screen"),
                    "icon": "lock",
                },
                {
                    "id": "greeter",
                    "text": I18n.tr("Greeter"),
                    "icon": "login",
                },
                {
                    "id": "power_sleep",
                    "text": I18n.tr("Power & Sleep"),
                    "icon": "power_settings_new",
                }
            ]
        },
        {
            "id": "plugins",
            "text": I18n.tr("Plugins"),
            "icon": "extension",
        },
        {
            "id": "separator",
            "separator": true
        },
        {
            "id": "about",
            "text": I18n.tr("About"),
            "icon": "info",
        }
    ])

    function isItemVisible(item) {
        if (item.vgsOnly && NetworkService.usingLegacy)
            return false;
        if (item.cupsOnly && !CupsService.cupsAvailable)
            return false;
        if (item.shortcutsOnly && !KeybindsService.available)
            return false;
        if (item.soundsOnly && !AudioService.soundsAvailable)
            return false;
        if (item.hyprlandNiriOnly && !CompositorService.isNiri && !CompositorService.isHyprland)
            return false;
        if (item.windowRulesCapable && !CompositorService.isNiri && !CompositorService.isHyprland && !CompositorService.isMango)
            return false;
        if (item.layoutCapable && !CompositorService.isNiri && !CompositorService.isHyprland && !CompositorService.isMango)
            return false;
        if (item.niriOnly && !CompositorService.isNiri)
            return false;
        if (item.clipboardOnly && (!VGSBackendService.isConnected || !VGSBackendService.capabilities.includes("clipboard") || !VGSBackendService.methods.includes("clipboard.getConfig")))
            return false;
        if (item.autostartOnly && !DesktopService.autostartAvailable)
            return false;
        return true;
    }

    function hasVisibleChildren(category) {
        if (!category.children)
            return false;
        return category.children.some(child => isItemVisible(child));
    }

    function isCategoryVisible(category) {
        if (category.separator)
            return true;
        if (!isItemVisible(category))
            return false;
        if (category.children && !hasVisibleChildren(category))
            return false;
        return true;
    }

    function _setExpanded(id, expanded) {
        var marker = "," + id + ",";
        if (expanded) {
            if (_expandedIds.indexOf(marker) < 0)
                _expandedIds = _expandedIds + id + ",";
            _collapsedIds = _collapsedIds.replace(marker, ",");
        } else {
            _expandedIds = _expandedIds.replace(marker, ",");
            if (_collapsedIds.indexOf(marker) < 0)
                _collapsedIds = _collapsedIds + id + ",";
        }
        SessionData.setSettingsSidebarState(_expandedIds, _collapsedIds);
    }

    function _setAutoExpanded(id, value) {
        var marker = "," + id + ",";
        if (value) {
            if (_autoExpandedIds.indexOf(marker) < 0)
                _autoExpandedIds = _autoExpandedIds + id + ",";
        } else {
            _autoExpandedIds = _autoExpandedIds.replace(marker, ",");
        }
    }

    function _isAutoExpanded(id) {
        return _autoExpandedIds.indexOf("," + id + ",") >= 0;
    }

    function isCategoryExpanded(categoryId) {
        if (_collapsedIds.indexOf("," + categoryId + ",") >= 0)
            return false;
        if (_expandedIds.indexOf("," + categoryId + ",") >= 0)
            return true;
        var category = categoryStructure.find(cat => cat.id === categoryId);
        if (category && category.collapsedByDefault)
            return false;
        return true;
    }

    function isChildActive(category) {
        if (!category.children)
            return false;
        return category.children.some(child => child.tabIndex === currentIndex);
    }

    function findParentCategory(tabIndex) {
        for (var i = 0; i < categoryStructure.length; i++) {
            var cat = categoryStructure[i];
            if (cat.children) {
                for (var j = 0; j < cat.children.length; j++) {
                    if (cat.children[j].tabIndex === tabIndex) {
                        return cat;
                    }
                }
            }
        }
        return null;
    }

    function autoExpandForTab(tabIndex) {
        var parent = findParentCategory(tabIndex);
        if (!parent)
            return;

        if (!isCategoryExpanded(parent.id)) {
            _setExpanded(parent.id, true);
            _setAutoExpanded(parent.id, true);
        }
    }

    function autoCollapseIfNeeded(oldTabIndex, newTabIndex) {
        var oldParent = findParentCategory(oldTabIndex);
        var newParent = findParentCategory(newTabIndex);

        if (oldParent && oldParent !== newParent && _isAutoExpanded(oldParent.id)) {
            _setExpanded(oldParent.id, false);
            _setAutoExpanded(oldParent.id, false);
        }
    }

    function navigateNext() {
        var flatItems = getFlatNavigableItems();
        var currentPos = flatItems.findIndex(item => item.tabIndex === currentIndex);
        var oldIndex = currentIndex;
        var newIndex;
        if (currentPos === -1) {
            newIndex = flatItems[0]?.tabIndex ?? 0;
        } else {
            var nextPos = (currentPos + 1) % flatItems.length;
            newIndex = flatItems[nextPos].tabIndex;
        }
        tabChangeRequested(newIndex);
        autoCollapseIfNeeded(oldIndex, newIndex);
        autoExpandForTab(newIndex);
    }

    function navigatePrevious() {
        var flatItems = getFlatNavigableItems();
        var currentPos = flatItems.findIndex(item => item.tabIndex === currentIndex);
        var oldIndex = currentIndex;
        var newIndex;
        if (currentPos === -1) {
            newIndex = flatItems[0]?.tabIndex ?? 0;
        } else {
            var prevPos = (currentPos - 1 + flatItems.length) % flatItems.length;
            newIndex = flatItems[prevPos].tabIndex;
        }
        tabChangeRequested(newIndex);
        autoCollapseIfNeeded(oldIndex, newIndex);
        autoExpandForTab(newIndex);
    }

    function getFlatNavigableItems() {
        var items = [];
        for (var i = 0; i < categoryStructure.length; i++) {
            var cat = categoryStructure[i];
            if (cat.separator || !isCategoryVisible(cat))
                continue;

            if (cat.tabIndex !== undefined && !cat.children) {
                items.push(cat);
            }

            if (cat.children) {
                for (var j = 0; j < cat.children.length; j++) {
                    var child = cat.children[j];
                    if (isItemVisible(child)) {
                        items.push(child);
                    }
                }
            }
        }
        return items;
    }

    function resolveTabIndex(name: string): int {
        if (!name)
            return -1;

        var normalized = name.toLowerCase().replace(/[_\-\s]/g, "");
        if (normalized === "compositor")
            normalized = "workspaces";

        for (var i = 0; i < categoryStructure.length; i++) {
            var cat = categoryStructure[i];
            if (cat.separator)
                continue;

            var catId = (cat.id || "").toLowerCase().replace(/[_\-\s]/g, "");
            if (catId === normalized) {
                if (cat.tabIndex !== undefined)
                    return cat.tabIndex;
                if (cat.children && cat.children.length > 0)
                    return cat.children[0].tabIndex;
            }

            if (cat.children) {
                for (var j = 0; j < cat.children.length; j++) {
                    var child = cat.children[j];
                    var childId = (child.id || "").toLowerCase().replace(/[_\-\s]/g, "");
                    if (childId === normalized)
                        return child.tabIndex;
                }
            }
        }
        return -1;
    }

    property real __maxTextWidth: Math.max(__m1.advanceWidth, __m2.advanceWidth, __m3.advanceWidth, __m4.advanceWidth, __m5.advanceWidth, __m6.advanceWidth)
    property real __calculatedWidth: Math.max(270, __maxTextWidth + Theme.iconSize * 2 + Theme.spacingM * 4 + Theme.spacingS * 2)

    implicitWidth: __calculatedWidth
    width: __calculatedWidth
    height: parent.height
    // With glass on, the sidebar is the translucent material (macOS System
    // Settings layering): only a thin elevation tint over the window's glass,
    // while the content pane opposite goes near-opaque for readability.
    color: Theme.popupGlassEffect ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.30) : Theme.popupSurfaceColor(Theme.surfaceContainerHigh)
    radius: Theme.cornerRadius

    Component.onCompleted: {
        root._expandedIds = SessionData.settingsSidebarExpandedIds;
        root._collapsedIds = SessionData.settingsSidebarCollapsedIds;
    }

    // Flat nav row; groups stay expanded and active state uses a quiet tinted pill.
    component NavRow: Rectangle {
        id: navRow

        property string label: ""
        property string icon: ""
        property int tabIndex: -1
        property bool isChild: false

        signal activated(int tabIndex)

        readonly property bool isActive: root.currentIndex === tabIndex && tabIndex >= 0
        readonly property bool isHighlighted: root.keyboardHighlightIndex === tabIndex && tabIndex >= 0

        width: parent ? parent.width : 0
        height: 34
        radius: Theme.controlRadius
        // Accent-tinted fill and text, without a separate indicator bar.
        color: isActive ? Theme.withAlpha(Theme.primary, 0.12) : ((navMouse.containsMouse || isHighlighted) ? Theme.surfaceHover : "transparent")

        Behavior on color {
            ColorAnimation {
                duration: root.navigationStateDuration
                easing.type: Theme.standardEasing
            }
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            VgsIcon {
                name: navRow.icon
                size: Theme.iconSize - 4
                color: navRow.isActive ? Theme.primary : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
                visible: navRow.icon !== ""
            }

            StyledText {
                text: navRow.label
                font.pixelSize: Theme.fontSizeMedium
                font.weight: navRow.isActive ? Font.DemiBold : Font.Normal
                color: navRow.isActive ? Theme.primary : Theme.surfaceTextMedium
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                width: parent.width - (navRow.icon !== "" ? (Theme.iconSize - 4 + Theme.spacingS) : 0)
            }
        }

        MouseArea {
            id: navMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                root.keyboardHighlightIndex = -1;
                searchField.setFocus(false);
                navRow.activated(navRow.tabIndex);
            }
        }
    }

    StyledTextMetrics {
        id: __m1
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        text: I18n.tr("Widgets & Notifications")
    }
    StyledTextMetrics {
        id: __m2
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        text: I18n.tr("Typography")
    }
    StyledTextMetrics {
        id: __m3
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        text: I18n.tr("Keyboard Shortcuts")
    }
    StyledTextMetrics {
        id: __m4
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        text: I18n.tr("Power & Security")
    }
    StyledTextMetrics {
        id: __m5
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        text: I18n.tr("Dock & Launcher")
    }
    StyledTextMetrics {
        id: __m6
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        text: I18n.tr("Windows & Workspaces")
    }

    function selectSearchResult(result) {
        if (!result)
            return;
        if (result.section) {
            SettingsSearchService.navigateToSection(result.section);
        }
        var oldIndex = root.currentIndex;
        tabChangeRequested(result.tabIndex);
        autoCollapseIfNeeded(oldIndex, result.tabIndex);
        autoExpandForTab(result.tabIndex);
        searchField.text = "";
        SettingsSearchService.clear();
        searchSelectedIndex = 0;
        keyboardHighlightIndex = -1;
        searchField.setFocus(false);
    }

    function navigateSearchResults(delta) {
        if (SettingsSearchService.results.length === 0)
            return;
        searchSelectedIndex = Math.max(0, Math.min(searchSelectedIndex + delta, SettingsSearchService.results.length - 1));
    }

    GlassSurfaceOverlay {
        anchors.fill: parent
        radius: root.radius
        // Nested panel inside a glass window: sheen only. A rim here reads as
        // a stray border line along the sidebar.
        rimEnabled: false
        sheenOpacity: 0.6
        z: 0
    }

    VgsFlickable {
        z: 1
        anchors.fill: parent
        clip: true
        contentHeight: sidebarColumn.height

        Column {
            id: sidebarColumn
            width: parent.width
            leftPadding: Theme.spacingM
            // Keep content clear of the overlay scrollbar.
            rightPadding: Theme.spacingL
            bottomPadding: Theme.spacingL
            topPadding: Theme.spacingM + 2
            spacing: Theme.spacingXXS

            ProfileSection {
                width: parent.width - parent.leftPadding - parent.rightPadding
                parentModal: root.parentModal
            }

            VgsTextField {
                id: searchField
                width: parent.width - parent.leftPadding - parent.rightPadding
                leftInset: Theme.spacingM
                rightInset: Theme.spacingXXS
                placeholderText: I18n.tr("Search...")
                normalBorderColor: Theme.borderColor
                focusedBorderColor: Theme.primary
                leftIconName: "search"
                leftIconSize: Theme.iconSize - 4
                showClearButton: text.length > 0
                usePopupTransparency: true
                onTextChanged: {
                    SettingsSearchService.search(text);
                    root.searchSelectedIndex = 0;
                }
                keyForwardTargets: [keyHandler]

                Item {
                    id: keyHandler
                    function navNext() {
                        if (root.searchActive) {
                            root.navigateSearchResults(1);
                        } else {
                            root.highlightNext();
                        }
                    }
                    function navPrev() {
                        if (root.searchActive) {
                            root.navigateSearchResults(-1);
                        } else {
                            root.highlightPrevious();
                        }
                    }
                    function navSelect() {
                        if (root.searchActive && SettingsSearchService.results.length > 0) {
                            root.selectSearchResult(SettingsSearchService.results[root.searchSelectedIndex]);
                        } else if (root.keyboardHighlightIndex >= 0) {
                            root.selectHighlighted();
                        }
                    }
                    Keys.onDownPressed: event => {
                        navNext();
                        event.accepted = true;
                    }
                    Keys.onUpPressed: event => {
                        navPrev();
                        event.accepted = true;
                    }
                    Keys.onTabPressed: event => {
                        navNext();
                        event.accepted = true;
                    }
                    Keys.onBacktabPressed: event => {
                        navPrev();
                        event.accepted = true;
                    }
                    Keys.onReturnPressed: event => {
                        navSelect();
                        event.accepted = true;
                    }
                    Keys.onEscapePressed: event => {
                        if (root.searchActive) {
                            searchField.text = "";
                            SettingsSearchService.clear();
                        } else {
                            root.keyboardHighlightIndex = -1;
                        }
                        event.accepted = true;
                    }
                }
            }

            Column {
                id: searchResultsColumn
                width: parent.width - parent.leftPadding - parent.rightPadding
                spacing: Theme.spacingXXS
                visible: root.searchActive

                Item {
                    width: parent.width
                    height: Theme.spacingS
                }

                Repeater {
                    model: ScriptModel {
                        values: SettingsSearchService.results
                    }

                    Rectangle {
                        id: resultDelegate
                        required property int index
                        required property var modelData

                        width: searchResultsColumn.width
                        height: resultContent.height + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: {
                            if (root.searchSelectedIndex === index)
                                return Theme.buttonBg;
                            if (resultMouseArea.containsMouse)
                                return Theme.surfaceHover;
                            return "transparent";
                        }

                        VgsRipple {
                            id: resultRipple
                            rippleColor: root.searchSelectedIndex === resultDelegate.index ? Theme.buttonText : Theme.surfaceText
                            cornerRadius: resultDelegate.radius
                            animationDuration: Anims.settingsNavigationRippleDuration
                        }

                        Row {
                            id: resultContent
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingM

                            VgsIcon {
                                name: resultDelegate.modelData.icon || "settings"
                                size: Theme.iconSize - 2
                                color: root.searchSelectedIndex === resultDelegate.index ? Theme.buttonText : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                width: parent.width - Theme.iconSize - Theme.spacingM
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXXS

                                StyledText {
                                    text: resultDelegate.modelData.label
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: root.searchSelectedIndex === resultDelegate.index ? Theme.buttonText : Theme.surfaceText
                                    width: parent.width
                                    wrapMode: Text.Wrap
                                    horizontalAlignment: Text.AlignLeft
                                }

                                StyledText {
                                    text: resultDelegate.modelData.category
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: root.searchSelectedIndex === resultDelegate.index ? Theme.withAlpha(Theme.buttonText, 0.7) : Theme.surfaceVariantText
                                    width: parent.width
                                    wrapMode: Text.Wrap
                                    horizontalAlignment: Text.AlignLeft
                                }
                            }
                        }

                        MouseArea {
                            id: resultMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: mouse => resultRipple.trigger(mouse.x, mouse.y)
                            onClicked: root.selectSearchResult(resultDelegate.modelData)
                        }

                        Behavior on color {
                            ColorAnimation {
                                duration: root.navigationStateDuration
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Anims.expressiveEffects
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    text: I18n.tr("No matches")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    horizontalAlignment: Text.AlignHCenter
                    visible: searchField.text.length > 0 && SettingsSearchService.results.length === 0
                    topPadding: Theme.spacingM
                }
            }

            Item {
                width: parent.width - parent.leftPadding - parent.rightPadding
                height: Theme.spacingXS
                visible: !root.searchActive
            }

            Repeater {
                model: root.categoryStructure

                delegate: Column {
                    id: categoryDelegate
                    required property int index
                    required property var modelData

                    readonly property bool isSeparator: modelData.separator === true
                    readonly property bool isGroup: modelData.children !== undefined
                    readonly property bool isStandalone: !isSeparator && !isGroup && modelData.tabIndex !== undefined

                    width: parent.width - parent.leftPadding - parent.rightPadding
                    visible: !root.searchActive && root.isCategoryVisible(modelData)
                    spacing: Theme.spacingXXS

                    // Hairline separator between top-level areas.
                    Item {
                        width: parent.width
                        height: Theme.spacingM * 2 + 1
                        visible: categoryDelegate.isSeparator
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width
                            height: 1
                            color: Theme.separatorColor
                        }
                    }

                    // Lead gap so standalone top-level rows (Keybinds, Plugins,
                    // About) get the same breathing room above them as groups.
                    Item {
                        width: parent.width
                        height: Theme.spacingL
                        visible: categoryDelegate.isStandalone
                    }

                    // Small-caps group label with more space above than below.
                    Item {
                        width: parent.width
                        height: groupHeaderText.implicitHeight + Theme.spacingXL + Theme.spacingXS
                        visible: categoryDelegate.isGroup

                        StyledText {
                            id: groupHeaderText
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Theme.spacingXS
                            text: (categoryDelegate.modelData.text || "").toUpperCase()
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.weight: Font.DemiBold
                            font.letterSpacing: 0.6
                            color: Theme.surfaceVariantText
                        }
                    }

                    // Standalone top-level tab (no children) as a flat nav row.
                    NavRow {
                        visible: categoryDelegate.isStandalone
                        label: categoryDelegate.modelData.text || ""
                        icon: categoryDelegate.modelData.icon || ""
                        tabIndex: categoryDelegate.modelData.tabIndex !== undefined ? categoryDelegate.modelData.tabIndex : -1
                        onActivated: ti => root.tabChangeRequested(ti)
                    }

                    // Group children — always visible, flat nav rows.
                    Repeater {
                        model: categoryDelegate.modelData.children || []

                        delegate: NavRow {
                            required property int index
                            required property var modelData

                            visible: root.isItemVisible(modelData)
                            isChild: true
                            label: modelData.text || ""
                            icon: modelData.icon || ""
                            tabIndex: modelData.tabIndex !== undefined ? modelData.tabIndex : -1
                            onActivated: ti => root.tabChangeRequested(ti)
                        }
                    }
                }
            }
        }
    }
}
