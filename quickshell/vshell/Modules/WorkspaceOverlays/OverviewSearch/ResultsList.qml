pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    property var controller: null
    property int gridColumns: controller?.gridColumns ?? 4
    property bool leadingSectionHeaderAtBottom: false
    property var _visualRows: []
    property var _flatIndexToRowMap: ({})
    property var _cumulativeHeights: []
    property var transientSurfaceTracker: null
    readonly property bool _bottomSectionHeaderActive: leadingSectionHeaderAtBottom && (controller?.sections?.length ?? 0) > 0

    // Share backend state across the empty-state message, hint and icon. The controller supplies the kind and query.
    readonly property string _fileQuery: controller ? controller.fileSearchQuery() : ""
    readonly property bool _fileQuerySearchable: !!controller
        && DSearchService.queryIsSearchable(controller.fileSearchKind(), _fileQuery)
    readonly property string _fileBackendState: controller
        ? DSearchService.backendState(controller.fileSearchKind(), _fileQuery) : "unknown"
    readonly property string _missingBackendCommand: controller && _fileBackendState === "missing"
        ? DSearchService.backendCommandFor(controller.fileSearchKind()) : ""
    // A search the gate refused for want of an answer, rather than one that ran
    // and found nothing.
    readonly property bool _fileSearchDeclined: !!controller && _fileQuerySearchable
        && !DSearchService.canDispatch(controller.fileSearchKind(), _fileQuery)

    readonly property var _emptyStateFacts: ({
        backendState: _fileBackendState,
        missingCommand: _missingBackendCommand,
        probeState: DSearchService.statusState,
        queryLength: _fileQuery.length,
        searchable: _fileQuerySearchable,
        declined: _fileSearchDeclined,
        searchError: controller?.fileSearchError ?? "",
        legActive: _fileLegActive
    })
    readonly property string _fileStateKey: fileEmptyStateKey(_emptyStateFacts)
    readonly property bool _fileLegActive: fileLegActive(controller?.searchMode ?? "", _fileQuerySearchable)

    signal itemRightClicked(int index, var item, real mouseX, real mouseY)

    // BEGIN EMPTY STATE DECISION
    // declined means tools could not be checked; searchError describes a search that ran and failed.
    function fileEmptyStateKey(facts) {
        const f = facts || {};
        if (f.backendState === "missing")
            return f.missingCommand === "rg" ? "missing-rg" : "missing-fd";

        if (f.queryLength === 0)
            return "prompt";
        if (!f.searchable)
            return "short";
        if (f.backendState === "checking")
            return "checking";
        if (f.declined)
            return "unchecked";
        if (f.searchError)
            return "error";
        return "empty";
    }

    // Show installation hints only for a missing tool on an active file-search path. Unknown tools require the probe error.
    function fileHintKey(facts) {
        const f = facts || {};
        if (!f.legActive)
            return "";
        if (f.backendState === "missing")
            return f.missingCommand === "rg" ? "install-rg" : "install-fd";
        if (!f.declined)
            return "";
        // The initial probe has no failure to report yet, even though requests are declined while it runs.
        if (f.probeState === "pending")
            return "";
        // Ask the user to retry only after automatic probe retries are exhausted.
        return f.probeState === "failed" ? "probe-failed" : "probe-retrying";
    }

    // Display file-search messages only for file mode or a searchable file query, never over plugin results.
    function fileLegActive(searchMode, searchable) {
        return searchMode === "files" || !!searchable;
    }

    // Bound helper errors for a single-line label and remove control and bidi characters. Preserve full errors in the log.
    function errorLine(text) {
        const first = String(text || "").split("\n")[0];
        const clean = first.replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, " ").trim();
        return clean.length > 160 ? clean.slice(0, 159) + "…" : clean;
    }

    function fileEmptyIcon(stateKey, fileType) {
        if (stateKey === "checking")
            return "hourglass_empty";
        if (stateKey === "missing-rg" || stateKey === "missing-fd"
                || stateKey === "unchecked" || stateKey === "error")
            return "search_off";
        if (fileType === "text")
            return "article";
        if (fileType === "file")
            return "insert_drive_file";
        return "folder_open";
    }
    // END EMPTY STATE DECISION

    function _rebuildVisualModel() {
        var sections = root.controller?.sections ?? [];
        var rows = [];
        var indexMap = {};
        var cumHeights = [];
        var cumY = 0;

        for (var s = 0; s < sections.length; s++) {
            var section = sections[s];
            var sectionId = section.id;

            if (!root._bottomSectionHeaderActive || s > 0) {
                cumHeights.push(cumY);
                rows.push({
                    _rowId: "h_" + sectionId,
                    type: "header",
                    section: section,
                    sectionId: sectionId,
                    height: 32
                });
                cumY += 32;
            }

            if (section.collapsed)
                continue;

            var versionTrigger = root.controller?.viewModeVersion ?? 0;
            void (versionTrigger);
            var mode = root.controller?.getSectionViewMode(sectionId) ?? "list";
            var items = section.items ?? [];
            var flatStartIndex = section.flatStartIndex ?? 0;

            if (mode === "list") {
                for (var i = 0; i < items.length; i++) {
                    var flatIdx = flatStartIndex + i;
                    indexMap[flatIdx] = rows.length;
                    cumHeights.push(cumY);
                    rows.push({
                        _rowId: items[i].id,
                        type: "list_item",
                        item: items[i],
                        flatIndex: flatIdx,
                        sectionId: sectionId,
                        height: 56
                    });
                    cumY += 56;
                }
            } else {
                var cols = root.controller?.getGridColumns(sectionId) ?? root.gridColumns;
                var cellWidth = mode === "tile" ? Math.floor(root.width / 3) : Math.floor(root.width / root.gridColumns);
                var cellHeight = mode === "tile" ? cellWidth * 0.75 : cellWidth + 24;
                var numRows = Math.ceil(items.length / cols);

                for (var r = 0; r < numRows; r++) {
                    var rowItems = [];
                    for (var c = 0; c < cols; c++) {
                        var idx = r * cols + c;
                        if (idx >= items.length)
                            break;
                        var fi = flatStartIndex + idx;
                        indexMap[fi] = rows.length;
                        rowItems.push({
                            item: items[idx],
                            flatIndex: fi
                        });
                    }
                    cumHeights.push(cumY);
                    rows.push({
                        _rowId: "gr_" + sectionId + "_" + r,
                        type: "grid_row",
                        items: rowItems,
                        sectionId: sectionId,
                        viewMode: mode,
                        cols: cols,
                        height: cellHeight
                    });
                    cumY += cellHeight;
                }
            }
        }

        root._flatIndexToRowMap = indexMap;
        root._cumulativeHeights = cumHeights;
        root._visualRows = rows;
    }

    onGridColumnsChanged: Qt.callLater(_rebuildVisualModel)
    onWidthChanged: Qt.callLater(_rebuildVisualModel)
    onLeadingSectionHeaderAtBottomChanged: Qt.callLater(_rebuildVisualModel)

    Connections {
        target: root.controller
        function onSectionsChanged() {
            Qt.callLater(root._rebuildVisualModel);
        }
        function onViewModeVersionChanged() {
            Qt.callLater(root._rebuildVisualModel);
        }
        function onSearchModeChanged() {
            root._visualRows = [];
            root._cumulativeHeights = [];
            root._flatIndexToRowMap = {};
        }
        function onSectionExpanded(sectionId) {
            Qt.callLater(() => {
                root._rebuildVisualModel();
                Qt.callLater(() => root.revealExpandedSection(sectionId));
            });
        }
    }

    function resetScroll() {
        mainListView.contentY = mainListView.originY;
    }

    function revealExpandedSection(sectionId) {
        for (var i = 0; i < _visualRows.length; i++) {
            if (_visualRows[i].sectionId === sectionId) {
                mainListView.positionViewAtIndex(i, ListView.Beginning);
                return;
            }
        }
    }

    function ensureVisible(index) {
        if (index < 0 || !controller?.flatModel || index >= controller.flatModel.length)
            return;
        var entry = controller.flatModel[index];
        if (!entry || entry.isHeader)
            return;
        var rowIndex = _flatIndexToRowMap[index];
        if (rowIndex === undefined)
            return;

        mainListView.positionViewAtIndex(rowIndex, ListView.Contain);

        if (stickyHeader.visible && rowIndex < _cumulativeHeights.length) {
            var rowY = _cumulativeHeights[rowIndex];
            var scrollY = mainListView.contentY - mainListView.originY;
            if (rowY < scrollY + stickyHeader.height) {
                mainListView.contentY = Math.max(mainListView.originY, rowY - stickyHeader.height + mainListView.originY);
            }
        }
    }

    function getSelectedItemPosition() {
        var fallback = mapToItem(null, width / 2, height / 2);
        if (!controller?.flatModel || controller.selectedFlatIndex < 0)
            return fallback;

        var entry = controller.flatModel[controller.selectedFlatIndex];
        if (!entry || entry.isHeader)
            return fallback;

        var rowIndex = _flatIndexToRowMap[controller.selectedFlatIndex];
        if (rowIndex === undefined)
            return fallback;

        var rowY = (rowIndex < _cumulativeHeights.length) ? _cumulativeHeights[rowIndex] : 0;
        var row = _visualRows[rowIndex];
        if (!row)
            return fallback;

        var itemX = width / 2;
        var itemH = row.height;

        if (row.type === "grid_row") {
            var rowItems = row.items;
            for (var i = 0; i < rowItems.length; i++) {
                if (rowItems[i].flatIndex === controller.selectedFlatIndex) {
                    var cellWidth = row.viewMode === "tile" ? Math.floor(width / 3) : Math.floor(width / row.cols);
                    itemX = i * cellWidth + cellWidth / 2;
                    break;
                }
            }
        }

        var visualY = rowY - mainListView.contentY + mainListView.originY + itemH / 2;
        var clampedY = Math.max(40, Math.min(height - 40, visualY));
        return mapToItem(null, itemX, clampedY);
    }

    Connections {
        target: root.controller
        function onSelectedFlatIndexChanged() {
            if (root.controller?.keyboardNavigationActive) {
                Qt.callLater(() => root.ensureVisible(root.controller.selectedFlatIndex));
            }
        }
    }

    Item {
        id: listClip
        anchors.fill: parent
        anchors.topMargin: BlurService.enabled && stickyHeader.visible ? 32 : 0
        anchors.bottomMargin: bottomSectionHeader.visible ? bottomSectionHeader.height : 0
        clip: true

        VgsListView {
            id: mainListView
            y: -listClip.anchors.topMargin
            width: parent.width
            height: parent.height + listClip.anchors.topMargin
            clip: true
            scrollBarTopMargin: (root.controller?.sections?.length > 0) ? 32 : 0

            model: ScriptModel {
                values: root._visualRows
                objectProp: "_rowId"
            }

            add: null
            remove: null
            displaced: null
            move: null

            delegate: Item {
                id: delegateRoot
                required property var modelData
                required property int index

                width: mainListView.width
                height: modelData?.height ?? 52

                SectionHeader {
                    anchors.fill: parent
                    visible: delegateRoot.modelData?.type === "header"
                    section: delegateRoot.modelData?.section ?? null
                    controller: root.controller
                    viewMode: {
                        var vt = root.controller?.viewModeVersion ?? 0;
                        void (vt);
                        return root.controller?.getSectionViewMode(delegateRoot.modelData?.sectionId ?? "") ?? "list";
                    }
                    canChangeViewMode: {
                        var vt = root.controller?.viewModeVersion ?? 0;
                        void (vt);
                        return root.controller?.canChangeSectionViewMode(delegateRoot.modelData?.sectionId ?? "") ?? false;
                    }
                    canCollapse: root.controller?.canCollapseSection(delegateRoot.modelData?.sectionId ?? "") ?? false
                    transientSurfaceTracker: root.transientSurfaceTracker
                }

                ResultItem {
                    anchors.fill: parent
                    anchors.topMargin: 2
                    anchors.bottomMargin: 2
                    visible: delegateRoot.modelData?.type === "list_item"
                    item: delegateRoot.modelData?.type === "list_item" ? (delegateRoot.modelData?.item ?? null) : null
                    isSelected: delegateRoot.modelData?.type === "list_item" && (delegateRoot.modelData?.flatIndex ?? -1) === root.controller?.selectedFlatIndex
                    controller: root.controller
                    flatIndex: delegateRoot.modelData?.type === "list_item" ? (delegateRoot.modelData?.flatIndex ?? -1) : -1

                    onClicked: {
                        if (root.controller && delegateRoot.modelData?.item) {
                            root.controller.executeItem(delegateRoot.modelData.item);
                        }
                    }

                    onRightClicked: (mouseX, mouseY) => {
                        root.itemRightClicked(delegateRoot.modelData?.flatIndex ?? -1, delegateRoot.modelData?.item ?? null, mouseX, mouseY);
                    }
                }

                Row {
                    id: gridRowContent
                    anchors.fill: parent
                    visible: delegateRoot.modelData?.type === "grid_row"

                    Repeater {
                        model: delegateRoot.modelData?.type === "grid_row" ? (delegateRoot.modelData?.items ?? []) : []

                        Item {
                            id: gridCellDelegate
                            required property var modelData
                            required property int index

                            readonly property real cellWidth: delegateRoot.modelData?.viewMode === "tile" ? Math.floor(delegateRoot.width / 3) : Math.floor(delegateRoot.width / (delegateRoot.modelData?.cols ?? root.gridColumns))

                            width: cellWidth
                            height: delegateRoot.height

                            GridItem {
                                width: parent.width - 4
                                height: parent.height - 4
                                anchors.centerIn: parent
                                visible: delegateRoot.modelData?.viewMode === "grid"
                                item: gridCellDelegate.modelData?.item ?? null
                                isSelected: (gridCellDelegate.modelData?.flatIndex ?? -1) === root.controller?.selectedFlatIndex
                                controller: root.controller
                                flatIndex: gridCellDelegate.modelData?.flatIndex ?? -1

                                onClicked: {
                                    if (root.controller && gridCellDelegate.modelData?.item) {
                                        root.controller.executeItem(gridCellDelegate.modelData.item);
                                    }
                                }

                                onRightClicked: (mouseX, mouseY) => {
                                    root.itemRightClicked(gridCellDelegate.modelData?.flatIndex ?? -1, gridCellDelegate.modelData?.item ?? null, mouseX, mouseY);
                                }
                            }

                            TileItem {
                                width: parent.width - 4
                                height: parent.height - 4
                                anchors.centerIn: parent
                                visible: delegateRoot.modelData?.viewMode === "tile"
                                item: gridCellDelegate.modelData?.item ?? null
                                isSelected: (gridCellDelegate.modelData?.flatIndex ?? -1) === root.controller?.selectedFlatIndex
                                controller: root.controller
                                flatIndex: gridCellDelegate.modelData?.flatIndex ?? -1

                                onClicked: {
                                    if (root.controller && gridCellDelegate.modelData?.item) {
                                        root.controller.executeItem(gridCellDelegate.modelData.item);
                                    }
                                }

                                onRightClicked: (mouseX, mouseY) => {
                                    root.itemRightClicked(gridCellDelegate.modelData?.flatIndex ?? -1, gridCellDelegate.modelData?.item ?? null, mouseX, mouseY);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        id: bottomShadow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: bottomSectionHeader.visible ? bottomSectionHeader.height : 0
        height: 24
        z: 100
        visible: {
            if (BlurService.enabled)
                return false;
            if (mainListView.contentHeight <= mainListView.height)
                return false;
            var atBottom = mainListView.contentY >= mainListView.contentHeight - mainListView.height + mainListView.originY - 5;
            if (atBottom)
                return false;

            var flatModel = root.controller?.flatModel;
            if (!flatModel || flatModel.length === 0)
                return false;
            var lastItemIdx = -1;
            for (var i = flatModel.length - 1; i >= 0; i--) {
                if (!flatModel[i].isHeader) {
                    lastItemIdx = i;
                    break;
                }
            }
            if (lastItemIdx >= 0 && root.controller?.selectedFlatIndex === lastItemIdx)
                return false;
            return true;
        }
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: "transparent"
            }
            GradientStop {
                position: 1.0
                color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
            }
        }
    }

    Rectangle {
        id: stickyHeader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 32
        z: 101
        color: Theme.floatingSurface
        visible: !root._bottomSectionHeaderActive && stickyHeaderSection !== null

        readonly property int versionTrigger: root.controller?.viewModeVersion ?? 0

        readonly property var stickyHeaderSection: {
            var scrollY = mainListView.contentY - mainListView.originY;
            if (scrollY <= 0)
                return null;

            var rows = root._visualRows;
            var heights = root._cumulativeHeights;
            if (rows.length === 0 || heights.length === 0)
                return null;

            var lo = 0;
            var hi = rows.length - 1;
            while (lo < hi) {
                var mid = (lo + hi + 1) >> 1;
                if (mid < heights.length && heights[mid] <= scrollY)
                    lo = mid;
                else
                    hi = mid - 1;
            }

            for (var i = lo; i >= 0; i--) {
                if (rows[i].type === "header")
                    return rows[i].section;
            }
            return null;
        }

        SectionHeader {
            width: parent.width
            section: stickyHeader.stickyHeaderSection
            controller: root.controller
            viewMode: {
                void (stickyHeader.versionTrigger);
                return root.controller?.getSectionViewMode(stickyHeader.stickyHeaderSection?.id) ?? "list";
            }
            canChangeViewMode: {
                void (stickyHeader.versionTrigger);
                return root.controller?.canChangeSectionViewMode(stickyHeader.stickyHeaderSection?.id) ?? false;
            }
            canCollapse: {
                void (stickyHeader.versionTrigger);
                return root.controller?.canCollapseSection(stickyHeader.stickyHeaderSection?.id) ?? false;
            }
            isSticky: true
            transientSurfaceTracker: root.transientSurfaceTracker
        }
    }

    SectionHeader {
        id: bottomSectionHeader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        z: 101
        visible: root._bottomSectionHeaderActive
        section: visible ? root.controller.sections[0] : null
        controller: root.controller
        viewMode: {
            var vt = root.controller?.viewModeVersion ?? 0;
            void (vt);
            return root.controller?.getSectionViewMode(section?.id ?? "") ?? "list";
        }
        canChangeViewMode: {
            var vt = root.controller?.viewModeVersion ?? 0;
            void (vt);
            return root.controller?.canChangeSectionViewMode(section?.id ?? "") ?? false;
        }
        canCollapse: root.controller?.canCollapseSection(section?.id ?? "") ?? false
        isSticky: true
        popupAbove: true
        transientSurfaceTracker: root.transientSurfaceTracker
    }

    Item {
        anchors.centerIn: parent
        visible: (!root.controller?.sections || root.controller.sections.length === 0) && !root.controller?.isFileSearching
        width: emptyColumn.implicitWidth
        height: emptyColumn.implicitHeight

        Column {
            id: emptyColumn
            spacing: Theme.spacingM

            VgsIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: getEmptyIcon()
                size: 48
                color: Theme.outlineButton

                function getEmptyIcon() {
                    var mode = root.controller?.searchMode ?? "all";
                    switch (mode) {
                    case "files":
                        return root.fileEmptyIcon(root._fileStateKey, root.controller?.fileSearchType ?? "all");
                    case "plugins":
                        return "extension";
                    case "apps":
                        return "apps";
                    default:
                        return "search_off";
                    }
                }
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter

                width: Math.min(360, Math.max(160, root.width - Theme.spacingXL * 2))
                text: getEmptyText()
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight

                function getEmptyText() {
                    var mode = root.controller?.searchMode ?? "all";
                    var hasQuery = root.controller?.searchQuery?.length > 0;

                    switch (mode) {
                    case "files":
                        switch (root._fileStateKey) {
                        case "checking":
                            return I18n.tr("Checking search tools", "Overview search empty state while the search-tool probe has not answered");
                        case "missing-rg":
                            return I18n.tr("Text search needs ripgrep", "Overview search empty state when the ripgrep binary is missing");
                        case "missing-fd":
                            return I18n.tr("File search needs fd", "Overview search empty state when the fd binary is missing");
                        case "unchecked":
                            return I18n.tr("Search tools could not be checked", "Overview search empty state when the probe failed and the search was not attempted");
                        case "error":
                            return root.errorLine(root.controller?.fileSearchError) || I18n.tr("Search failed");
                        case "prompt":
                            return I18n.tr("Type to search files");
                        case "short":
                            return I18n.tr("Type at least 2 characters");
                        }
                        switch (root.controller?.fileSearchType ?? "all") {
                        case "dir":
                            return I18n.tr("No folders found");
                        case "file":
                            return I18n.tr("No files found");
                        default:
                            return I18n.tr("No results found");
                        }
                    case "plugins":
                        return hasQuery ? I18n.tr("No plugin results") : I18n.tr("Browse or search plugins");
                    case "apps":
                        return I18n.tr("No apps found");
                    default:
                        return I18n.tr("No results found");
                    }
                }
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(320, Math.max(160, root.width - Theme.spacingXL * 2))
                visible: text.length > 0
                text: getDependencyHint()
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap


                function getDependencyHint() {
                    switch (root.fileHintKey(root._emptyStateFacts)) {
                    case "install-rg":
                        return I18n.tr("Install the ripgrep package to search inside file contents.", "Overview search hint when the ripgrep binary is missing");
                    case "install-fd":
                        return I18n.tr("Install the fd package (fd-find on Debian and Fedora) to search files and folders by name.", "Overview search hint when the fd binary is missing");
                    case "probe-retrying":
                        return I18n.tr("Still checking which search tools are installed: %1", "Overview search hint while the launcher-search status probe is being retried").arg(DSearchService.statusError);
                    case "probe-failed":
                        return I18n.tr("Could not check which search tools are installed: %1. Reopen the launcher to try again.", "Overview search hint when the launcher-search status probe failed").arg(DSearchService.statusError);
                    }
                    return "";
                }
            }
        }
    }
}
