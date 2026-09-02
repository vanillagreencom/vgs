import QtQml
import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Services
import qs.Widgets

FocusScope {
    id: content

    property real scrollStep: 60
    property var activeFlickable: mainFlickable
    property bool showFloatingToggle: true
    property bool floating: false
    property alias searchField: searchField

    // The dialog sizes itself from the widest key and description it will
    // actually draw, so the columns fit their text instead of eliding it and
    // the window stops at the content rather than running to a screen edge.
    // Measured off hidden StyledTexts so the metrics come from the same font
    // resolution the badges use.
    readonly property var textExtents: {
        const cats = KeybindsService.cheatsheet.binds || {};
        let categories = 0;
        let key = "";
        let desc = "";
        for (const cat in cats) {
            const list = cats[cat] || [];
            let counted = false;
            for (let i = 0; i < list.length; i++) {
                const bind = list[i];
                if (bind.hideOnOverlay)
                    continue;
                if (!counted) {
                    counted = true;
                    categories++;
                }
                const k = (bind.key || "").replace(/\+/g, " + ");
                if (k.length > key.length)
                    key = k;
                const d = bind.desc || bind.action || "";
                if (d.length > desc.length)
                    desc = d;
            }
        }
        return {
            "categories": categories,
            "key": key,
            "desc": desc
        };
    }

    readonly property int categoryCount: textExtents.categories

    readonly property real keyColumnWidth: Math.max(120, Math.min(380, keyMetrics.implicitWidth + Theme.spacingS * 2))
    readonly property real descColumnWidth: Math.max(200, Math.min(460, descMetrics.implicitWidth + Theme.spacingS))
    readonly property real columnWidth: keyColumnWidth + Theme.spacingM + descColumnWidth
    readonly property int preferredColumns: Math.max(1, Math.min(3, categoryCount))
    // Floored: the cheatsheet is fetched when the dialog opens, so the first
    // open measures an empty list and would otherwise map at its minimums and
    // then jump once the binds land.
    readonly property real preferredWidth: Math.max(720, preferredColumns * columnWidth + (preferredColumns - 1) * Theme.spacingM + Theme.spacingL * 2)

    StyledText {
        id: keyMetrics
        visible: false
        text: content.textExtents.key
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        isMonospace: true
        wrapMode: Text.NoWrap
        elide: Text.ElideNone
    }

    StyledText {
        id: descMetrics
        visible: false
        text: content.textExtents.desc
        font.pixelSize: Theme.fontSizeMedium
        wrapMode: Text.NoWrap
        elide: Text.ElideNone
    }

    signal closeRequested
    signal floatingToggleRequested

    function scrollDown() {
        if (!activeFlickable)
            return;
        let newY = activeFlickable.contentY + scrollStep;
        newY = Math.min(newY, activeFlickable.contentHeight - activeFlickable.height);
        activeFlickable.contentY = newY;
    }

    function scrollUp() {
        if (!activeFlickable)
            return;
        let newY = activeFlickable.contentY - scrollStep;
        newY = Math.max(0, newY);
        activeFlickable.contentY = newY;
    }

    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_J:
            if (event.modifiers & Qt.ControlModifier) {
                scrollDown();
                event.accepted = true;
            }
            return;
        case Qt.Key_K:
            if (event.modifiers & Qt.ControlModifier) {
                scrollUp();
                event.accepted = true;
            }
            return;
        case Qt.Key_Down:
            scrollDown();
            event.accepted = true;
            return;
        case Qt.Key_Up:
            scrollUp();
            event.accepted = true;
            return;
        }
    }

    Column {
        anchors.fill: parent
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingL

        RowLayout {
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                Layout.alignment: Qt.AlignLeft
                text: KeybindsService.cheatsheet.title || I18n.tr("Keybinds")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.primary
            }

            Item {
                Layout.fillWidth: true
            }

            VgsActionButton {
                visible: content.showFloatingToggle
                iconName: content.floating ? "close_fullscreen" : "open_in_new"
                tooltipText: content.floating ? I18n.tr("Dock window") : I18n.tr("Open as window")
                onClicked: content.floatingToggleRequested()
            }

            VgsTextField {
                id: searchField
                Layout.alignment: Qt.AlignRight
                leftIconName: "search"
                keyForwardTargets: [content]
                onTextEdited: searchDebounce.restart()
                Keys.onEscapePressed: event => {
                    content.closeRequested();
                    event.accepted = true;
                }
            }
        }

        Timer {
            id: searchDebounce
            interval: 50
            repeat: false
            onTriggered: {
                mainFlickable.categories = mainFlickable.generateCategories(searchField.text);
            }
        }

        VgsFlickable {
            id: mainFlickable
            width: parent.width
            height: parent.height - parent.spacing - 40
            contentWidth: rowLayout.implicitWidth
            contentHeight: rowLayout.implicitHeight
            clip: true

            property var rawBinds: KeybindsService.cheatsheet.binds || {}

            function generateCategories(query) {
                const lowerQuery = query ? query.toLowerCase().trim() : "";
                const lowerQueryWords = query.split(/\s+/);
                const processed = {};

                for (const cat in rawBinds) {
                    const binds = rawBinds[cat];
                    const catLower = cat.toLowerCase();
                    const subcats = {};
                    let hasSubcats = false;
                    for (let i = 0; i < binds.length; i++) {
                        const bind = binds[i];
                        const keyLower = (bind.key || "").toLowerCase();
                        const descLower = (bind.desc || "").toLowerCase();
                        const actionLower = (bind.action || "").toLowerCase();

                        if (bind.hideOnOverlay)
                            continue;
                        let shouldContinue = false;
                        for (let j = 0; j < lowerQueryWords.length; j++) {
                            const word = lowerQueryWords[j];
                            if (!(word.length === 0 || keyLower.includes(word) || descLower.includes(word) || catLower.includes(word) || actionLower.includes(word))) {
                                shouldContinue = true;
                                break;
                            }
                        }
                        if (shouldContinue)
                            continue;

                        if (bind.subcat) {
                            hasSubcats = true;
                            if (!subcats[bind.subcat])
                                subcats[bind.subcat] = [];
                            subcats[bind.subcat].push(bind);
                        } else {
                            if (!subcats["_root"])
                                subcats["_root"] = [];
                            subcats["_root"].push(bind);
                        }
                    }

                    if (Object.keys(subcats).length === 0)
                        continue;

                    processed[cat] = {
                        hasSubcats: hasSubcats,
                        subcats: subcats,
                        subcatKeys: Object.keys(subcats)
                    };
                }

                return processed;
            }

            property var categories: generateCategories("")

            function estimateCategoryHeight(catName) {
                const catData = categories[catName];
                if (!catData)
                    return 0;
                let bindCount = 0;
                for (const key of catData.subcatKeys) {
                    bindCount += catData.subcats[key]?.length || 0;
                    if (key !== "_root")
                        bindCount += 1;
                }
                return 40 + bindCount * 34;
            }

            property var categoryKeys: Object.keys(categories)

            function distributeCategories(cols) {
                const columns = [];
                const heights = [];
                for (let i = 0; i < cols; i++) {
                    columns.push([]);
                    heights.push(0);
                }
                const sorted = [...categoryKeys].sort((a, b) => estimateCategoryHeight(b) - estimateCategoryHeight(a));
                for (const cat of sorted) {
                    let minIdx = 0;
                    for (let i = 1; i < cols; i++) {
                        if (heights[i] < heights[minIdx])
                            minIdx = i;
                    }
                    columns[minIdx].push(cat);
                    heights[minIdx] += estimateCategoryHeight(cat);
                }
                return columns;
            }

            Row {
                id: rowLayout
                width: mainFlickable.width
                spacing: Theme.spacingM

                // Categories are atomic in the masonry, so asking for more
                // columns than there are categories only makes empty ones.
                property int numColumns: Math.max(1, Math.min(3, content.categoryCount, Math.floor(width / content.columnWidth)))
                property var columnCategories: mainFlickable.distributeCategories(numColumns)

                Repeater {
                    model: rowLayout.numColumns

                    Column {
                        id: masonryColumn
                        width: (rowLayout.width - rowLayout.spacing * (rowLayout.numColumns - 1)) / rowLayout.numColumns
                        spacing: Theme.spacingXL

                        Repeater {
                            model: rowLayout.columnCategories[index] || []

                            Column {
                                id: categoryColumn
                                width: parent.width
                                spacing: Theme.spacingXS

                                property string catName: modelData
                                property var catData: mainFlickable.categories[catName]

                                StyledText {
                                    text: categoryColumn.catName
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.primary
                                }

                                Rectangle {
                                    width: parent.width
                                    height: 1
                                    color: Theme.primary
                                    opacity: 0.3
                                }

                                Item {
                                    width: 1
                                    height: Theme.spacingXS
                                }

                                Column {
                                    width: parent.width
                                    spacing: Theme.spacingM

                                    Repeater {
                                        model: categoryColumn.catData?.subcatKeys || []

                                        Column {
                                            width: parent.width
                                            spacing: Theme.spacingXS

                                            property string subcatName: modelData
                                            property var subcatBinds: categoryColumn.catData?.subcats?.[subcatName] || []

                                            StyledText {
                                                visible: parent.subcatName !== "_root"
                                                text: parent.subcatName
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.DemiBold
                                                color: Theme.primary
                                                opacity: 0.7
                                            }

                                            Column {
                                                width: parent.width
                                                spacing: Theme.spacingXS

                                                Repeater {
                                                    model: parent.parent.subcatBinds

                                                    KeybindsBindRow {
                                                        width: parent.width
                                                        keyColumnWidth: content.keyColumnWidth
                                                        keyLabel: (modelData.key || "").replace(/\+/g, " + ")
                                                        description: modelData.desc || modelData.action || ""
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
