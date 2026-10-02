import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Appearance.js" as Appearance
import "NotificationLogic.js" as Logic

// The keyboard inbox and history panel. The service remains the only owner
// of notification state; this summoned panel reads snapshots and sends
// choices back through the plugin's IPC handlers.
FocusScope {
    id: root

    property var shell: null
    readonly property int statusRevision: shell === null ? 0 : shell.status.revision
    readonly property var look: Theme.appearance(Appearance.TOKENS, Appearance.LIGHT)
    property string mode: "inbox"
    property string subtitle: ""
    property bool silenced: false
    property var rows: []
    readonly property int rowCount: rows.length
    property int currentIndex: 0
    property int actionIndex: -1
    property string selectedKey: ""
    property string selectedHoverKey: ""
    property bool opened: false
    property bool refreshing: false
    property int refreshQueuedFor: -1
    property Item initialFocus: list

    // As wide as the column: the cards with their side room, where the
    // scroll bar sits, wider than the header they sit under.
    implicitWidth: column.implicitWidth
    readonly property real panelMaxHeight: look.header.height + look.header.gap + look.panel.rowCap * (look.card.maxHeight + look.card.gap) + look.stack.tail
    implicitHeight: Math.min(look.header.height + look.header.gap + listFrame.implicitHeight, panelMaxHeight)

    onCurrentIndexChanged: {
        if (refreshing) return;
        const row = rowAt(currentIndex);
        const key = row === null ? "" : row.key;
        if (selectedKey !== key) {
            selectedKey = key;
            actionIndex = -1;
        }
        actionIndex = -1;
        updateSelectionHover();
        nav.reveal(currentIndex);
    }

    onStatusRevisionChanged: {
        if (opened) scheduleRefresh();
    }

    function scheduleRefresh() {
        if (refreshQueuedFor === statusRevision) return;
        refreshQueuedFor = statusRevision;
        Qt.callLater(() => {
            const queued = refreshQueuedFor;
            refreshQueuedFor = -1;
            if (opened && statusRevision === queued) refresh();
        });
    }

    onActiveFocusChanged: {
        root.call("panel-focused", activeFocus ? "on" : "off");
        if (opened && !activeFocus) root.call("close", "");
    }

    function open(payloadJson) {
        const payload = parsePayload(payloadJson);
        mode = payload.mode;
        opened = true;
        call("panel-opened", mode);
        refresh();
        Qt.callLater(() => {
            selectIndex(rows.length > 0 ? 0 : -1);
            call("panel-focused", root.activeFocus ? "on" : "off");
        });
    }

    function close() {
        opened = false;
        call("panel-focused", "off");
        clearSelectionHover();
        call("panel-closed", "");
    }

    function parsePayload(payloadJson) {
        try {
            const payload = JSON.parse(String(payloadJson || "{}"));
            return { mode: payload.mode === "history" ? "history" : "inbox" };
        } catch (e) {
            return { mode: "inbox" };
        }
    }

    function call(name, arg) {
        if (shell === null) return "unknown: shell";
        return shell.ipc.call(name, arg === undefined ? "" : String(arg));
    }

    function refresh() {
        if (shell === null) return;
        const raw = call("panel-state", "");
        try {
            const state = JSON.parse(raw);
            const previousKey = selectedKey;
            const previousIndex = currentIndex;
            mode = state.mode === "history" ? "history" : "inbox";
            subtitle = String(state.subtitle || "");
            silenced = state.silenced === true;
            refreshing = true;
            rows = Array.isArray(state.rows) ? state.rows : [];
            const kept = indexOfKey(previousKey);
            if (rows.length === 0) currentIndex = -1;
            else if (kept !== -1) currentIndex = kept;
            else currentIndex = Math.max(0, Math.min(previousIndex, rows.length - 1));
            const row = rowAt(currentIndex);
            selectedKey = row === null ? "" : row.key;
            if (selectedKey !== previousKey || actionIndex >= actionsOf(currentIndex).length) actionIndex = -1;
            refreshing = false;
            updateSelectionHover();
            nav.reveal(currentIndex);
        } catch (e) {
            console.warn("notifications panel: state " + e.message);
            refreshing = true;
            rows = [];
            currentIndex = -1;
            selectedKey = "";
            actionIndex = -1;
            refreshing = false;
            updateSelectionHover();
        }
    }

    function indexOfKey(key) {
        if (key === "") return -1;
        for (let i = 0; i < rows.length; i++)
            if (rows[i].key === key) return i;
        return -1;
    }

    function selectIndex(index) {
        refreshing = true;
        currentIndex = index;
        const row = rowAt(index);
        const key = row === null ? "" : row.key;
        if (selectedKey !== key) {
            selectedKey = key;
            actionIndex = -1;
        }
        refreshing = false;
        updateSelectionHover();
        nav.reveal(currentIndex);
    }

    function rowAt(index) {
        return index >= 0 && index < rows.length ? rows[index] : null;
    }

    function actionsOf(index) {
        const row = rowAt(index);
        return row !== null && Array.isArray(row.actions) ? row.actions : [];
    }

    function choose(key, choice) {
        const reply = call("choose", JSON.stringify({ key: key, choice: choice }));
        if (reply !== "left" && reply !== "held") console.warn("notifications panel: choose " + reply);
        refresh();
        if (reply === "left") dropLocal(key);
        if (opened) Qt.callLater(() => {
            if (!opened) return;
            refresh();
            if (reply === "left") dropLocal(key);
            list.forceActiveFocus(Qt.TabFocusReason);
        });
        return reply;
    }

    function dropLocal(key) {
        const at = indexOfKey(key);
        if (at === -1) return;
        const next = rows.slice();
        next.splice(at, 1);
        rows = next;
        selectIndex(rows.length === 0 ? -1 : Math.min(at, rows.length - 1));
    }

    function openSelected() {
        const row = rowAt(currentIndex);
        if (row === null) return false;
        choose(row.key, "open");
        return true;
    }

    function dismissSelected() {
        const row = rowAt(currentIndex);
        if (row === null) return false;
        choose(row.key, "dismiss");
        return true;
    }

    function pressAction() {
        const row = rowAt(currentIndex);
        const actions = actionsOf(currentIndex);
        if (row === null || actionIndex < 0 || actionIndex >= actions.length) return false;
        choose(row.key, actions[actionIndex].id);
        return true;
    }

    function moveAction(delta) {
        const actions = actionsOf(currentIndex);
        if (actions.length === 0) return false;
        if (actionIndex < 0) actionIndex = delta > 0 ? 0 : actions.length - 1;
        else actionIndex = (actionIndex + delta + actions.length) % actions.length;
        return true;
    }

    function setHover(key, on) {
        if (key === "") return;
        call("hover", JSON.stringify({ key: key, on: on === true }));
    }

    function clearSelectionHover() {
        if (selectedHoverKey !== "") setHover(selectedHoverKey, false);
        selectedHoverKey = "";
    }

    function updateSelectionHover() {
        const row = rowAt(currentIndex);
        const key = row === null ? "" : row.key;
        if (selectedHoverKey === key) return;
        clearSelectionHover();
        selectedHoverKey = key;
        if (selectedHoverKey !== "") setHover(selectedHoverKey, true);
    }

    ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: look.header.gap

        InboxHeader {
            id: header
            look: root.look
            mode: root.mode
            subtitle: root.subtitle
            silenced: root.silenced
            textColumn: listScroll.textColumn
            shown: true
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: implicitWidth
            Layout.preferredHeight: implicitHeight
            onSilenceRequested: on => {
                root.call("silence", on ? "on" : "off");
                root.refresh();
            }
            onClearRequested: {
                root.call("clear-history", "");
                root.refresh();
            }
            onMarkReadRequested: root.call("mark-read", "")
            onModeRequested: nextMode => {
                root.call("panel-opened", nextMode);
                root.refresh();
            }
        }

        Item {
            id: listFrame
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: listScroll.implicitWidth
            Layout.preferredHeight: listScroll.implicitHeight
            // A room shorter than the panel asks for leaves the list what
            // is under the header, and it scrolls inside that; a fixed
            // height would run it past the panel's bottom.
            Layout.fillHeight: true
            Layout.minimumHeight: 0
            Layout.maximumHeight: listScroll.implicitHeight
            implicitHeight: Layout.preferredHeight

            CardScroll {
                id: listScroll
                anchors.fill: parent
                scrollObjectName: "notificationPanelScrollBar"
                look: root.look
                maxHeight: root.panelMaxHeight - header.height - root.look.header.gap

                Label {
                    Layout.preferredWidth: root.look.card.width
                    role: "hint"
                    visible: root.rows.length === 0
                    text: root.mode === "history" ? "No notification history yet" : "No unread notifications"
                    horizontalAlignment: Text.AlignHCenter
                }

                // focus-indicator: the selected notification card lifts and shows its actions
                Column {
                    id: list
                    Layout.preferredWidth: root.look.card.width
                    width: root.look.card.width
                    activeFocusOnTab: true
                    focusPolicy: Qt.StrongFocus
                    focus: true
                    Accessible.name: "Notifications list"
                    Keys.onPressed: event => event.accepted = nav.handle(event)

                    KeyNav {
                        id: nav
                        count: root.rows.length
                        currentIndex: root.currentIndex
                        wrap: false
                        crossAxis: true
                        viewHeight: listScroll.flickable.height
                        rowHeight: root.look.card.maxHeight + root.look.card.gap
                        // The list takes its cards' height a layout pass
                        // after a refresh, so the refresh's reveal measured
                        // the empty list and scrolled a long list's first
                        // card under the header; reveal again at the
                        // height the list took.
                        onViewHeightChanged: reveal(root.currentIndex)
                        flickable: listScroll.flickable
                        itemAt: index => rowRepeater.itemAt(index)
                        labelAt: index => {
                            const row = root.rowAt(index);
                            return row === null ? "" : row.summary;
                        }
                        onMoved: index => root.selectIndex(index)
                        onActivated: index => root.actionIndex >= 0 ? root.pressAction() : root.openSelected()
                        onRemoved: index => root.dismissSelected()
                        onCrossed: delta => root.moveAction(delta)
                    }

                    Repeater {
                        id: rowRepeater
                        model: root.rows

                        Item {
                            id: slot
                            required property var modelData
                            required property int index
                            readonly property bool selected: root.currentIndex === index
                            readonly property real hover: selected || face.hovered ? 1 : 0
                            width: root.look.card.width
                            height: face.height + root.look.card.gap

                            onSelectedChanged: if (selected) root.updateSelectionHover()

                            CardFace {
                                id: face
                                look: root.look
                                key: slot.modelData.key || ""
                                textColumn: listScroll.textColumn
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: root.look.card.gap - root.look.card.lift * slot.hover
                                width: card.fullWidth
                                height: card.fullHeight
                                app: slot.modelData.app || ""
                                appIcon: slot.modelData.appIcon || ""
                                summary: slot.modelData.summary || ""
                                body: slot.modelData.body || ""
                                image: slot.modelData.image || ""
                                desktopEntry: slot.modelData.desktopEntry || ""
                                urgency: slot.modelData.urgency === undefined ? Logic.URGENCY.normal : slot.modelData.urgency
                                hintIcon: slot.modelData.hintIcon || ""
                                hintTone: slot.modelData.hintTone || ""
                                workspace: slot.modelData.workspace || ""
                                workspaceIcon: slot.modelData.workspaceIcon || ""
                                faceImages: slot.modelData.faceImages || []
                                emoji: slot.modelData.emoji || null
                                actions: slot.modelData.actions || []
                                showActions: (slot.selected || hovered) && actions.length > 0
                                actionIndex: slot.selected ? root.actionIndex : -1
                                edgeVisible: slot.hover > 0
                                edgeBoost: 1 + root.look.edge.hoverBoost * slot.hover
                                onHoverRequested: (key, on) => root.setHover(key, on)
                                onActionTriggered: id => root.choose(slot.modelData.key, id)
                                onCloseRequested: root.choose(slot.modelData.key, "dismiss")
                                onCardClicked: root.choose(slot.modelData.key, "open")
                            }
                        }
                    }
                }

                KeyHints {
                    id: hintRow
                    Layout.preferredWidth: root.look.card.width
                    visible: root.rows.length > 0
                    hints: [
                        { key: "Delete", text: "dismiss" },
                        { key: "Left/Right", text: "actions" }
                    ]
                }
            }
        }
    }
}
