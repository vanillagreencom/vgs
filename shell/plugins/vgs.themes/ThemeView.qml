import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "BrowserLogic.js" as BrowserLogic

// The theme view of the browser: every shipped, installed and catalog
// theme as an angled card on a rail, a scope control, a typed filter, and
// Enter or a click on the selected card installing a catalog theme if it
// needs it and applying it. After an apply of a theme whose wallpapers are
// not downloaded, a Dialog offers the download; Download runs it on the
// download lane, shows its progress from `last.downloading` and applies the
// theme again, so its first wallpaper shows. A step that fails leaves the
// view open with a line naming it and the reason; a step that succeeds and
// offers nothing asks the browser to close.
//
// Keys: Left, Right, Tab, Shift+Tab, Home, End and the wheel move through
// the rail, as the carousel takes them, and Up and Down step as Left and
// Right do. A printable character types into the filter, Backspace erases
// a character, Ctrl+Backspace a word and Ctrl+U the whole filter. Escape
// clears the filter, then asks to close. Enter applies the selected card.
//
// The view is built with the overlay and destroyed with it, so it reads
// everything on open: the list, the catalog and every image, again after
// each apply and whenever the displayed theme changes.
FocusScope {
    id: root

    property var shell: null

    // Asks the browser to close; the browser holds it while `busy`.
    signal closeRequested()

    // The last answers: the list's packages, the catalog's entries and
    // every package's images, each null before it arrives or after it
    // failed, beside the reason it failed or "".
    property var packages: null
    property string listReason: ""
    property var entries: null
    property string catalogReason: ""
    property var images: null
    property string imagesReason: ""
    // Whether the first list, catalog and image list have all answered.
    property bool loaded: false
    property bool started: false

    property var cards: []
    property string filterText: ""
    property int scopeIndex: 0
    readonly property var shownCards: BrowserLogic.shown(cards, filterText, BrowserLogic.SCOPES[scopeIndex].scope)
    // The selected theme's name, kept across a filter and a refresh; the
    // displayed theme's until the first card is chosen.
    property string selectedName: ""
    readonly property var selected: carousel.currentIndex < shownCards.length ? shownCards[carousel.currentIndex] : null

    // The step this view runs, { step, name } with `step` `install`,
    // `apply` or `download`, or null.
    property var job: null
    // An apply result can arrive before Theme publishes the applied package.
    // Keep that result here until the theme name confirms the same package.
    property var pendingApply: null
    readonly property bool busy: job !== null
    // The card whose wallpapers the Dialog offers, or null.
    property var offer: null
    // `last.downloading` as last read while a download this view started
    // runs, else null.
    property var downloading: null
    // What the last step that failed answered, "" when none did.
    property string problem: ""

    // Read the list, the catalog and every image, then build the cards and
    // run THEN, when given. Each answer is kept as it arrives.
    function refresh(then) {
        let waiting = 3;
        const answered = () => {
            waiting -= 1;
            if (waiting > 0) return;
            root.loaded = true;
            if (root.selectedName === "") root.selectedName = Theme.name;
            root.cards = root.packages === null ? [] : BrowserLogic.cards(root.packages, root.entries, root.images, Theme.name);
            if (then !== undefined) then();
        };
        shell.theme.list(result => {
            root.listReason = result.reason === null ? "" : result.reason;
            root.packages = result.reason === null ? result.packages : null;
            answered();
        });
        shell.theme.catalog(result => {
            root.catalogReason = result.reason === null ? "" : result.reason;
            root.entries = result.reason === null ? result.entries : null;
            answered();
        });
        const reply = shell.theme.images("all", result => {
            root.imagesReason = result.state === "ok" ? "" : result.reason;
            root.images = result.state === "ok" ? result.images : null;
            answered();
        });
        if (reply !== "ok") throw new Error("themes: images all " + reply);
    }

    // Keep the selection on its theme when the shown cards change, else on
    // the first card.
    onShownCardsChanged: {
        const index = BrowserLogic.selection(shownCards, selectedName);
        carousel.currentIndex = index;
        if (index < shownCards.length) selectedName = shownCards[index].name;
    }

    function focusRail() { carousel.forceActiveFocus(); }

    // End the running step with LINE, "" for none.
    function finish(line) {
        job = null;
        problem = line;
    }

    // Enter or a click on the selected card.
    function activate() {
        const card = selected;
        if (busy || offer !== null || card === null) return;
        problem = "";
        if (card.state !== "ok") {
            problem = card.label + " is refused: " + card.reason + ". The Themes panel shows its package.";
            return;
        }
        if (card.installed) apply(card.name);
        else install(card.name);
    }

    function install(name) {
        job = { step: "install", name: name };
        const reply = shell.theme.install(name, result => {
            const line = BrowserLogic.problem("install", name, result);
            if (line !== "") root.finish(line);
            else root.apply(name);
        });
        if (reply !== "ok") finish(reply);
    }

    // Apply NAME; once the refreshed cards hold its catalog state, offer its
    // wallpapers or ask to close.
    function apply(name) {
        job = { step: "apply", name: name };
        const reply = shell.theme.apply(name, result => {
            const line = BrowserLogic.problem("apply", name, result);
            if (!BrowserLogic.applied(result)) {
                root.finish(line);
                return;
            }
            root.completeApply(name, line);
        });
        if (reply !== "ok") finish(reply);
    }

    function completeApply(name, line) {
        if (Theme.name !== name) {
            pendingApply = { name: name, line: line };
            return;
        }
        pendingApply = null;
        root.refresh(() => {
            const card = root.cards.find(c => c.name === name) || null;
            root.finish(line);
            if (BrowserLogic.downloadOffer(card)) root.offer = card;
            else if (line === "") root.closeRequested();
        });
    }

    function download() {
        const name = offer.name;
        job = { step: "download", name: name };
        const reply = shell.theme.wallpapers(name, result => {
            root.offer = null;
            root.downloading = null;
            root.focusRail();
            const line = BrowserLogic.problem("download", name, result);
            if (line !== "") root.finish(line);
            else root.apply(name);
        });
        if (reply !== "ok") {
            offer = null;
            finish(reply);
            focusRail();
            return;
        }
        downloading = shell.theme.last.downloading;
    }

    function declineOffer() {
        offer = null;
        focusRail();
    }

    // Escape: the filter first, then the browser.
    function cancel() {
        if (filterText !== "") filterText = "";
        else closeRequested();
    }

    function editFilter(edit) {
        filterText = BrowserLogic.editFilter(filterText, edit);
    }

    function start() {
        if (started || shell === null) return;
        started = true;
        refresh();
        focusRail();
    }

    Component.onCompleted: start()
    onShellChanged: start()

    // An apply from elsewhere moves the displayed badge.
    Connections {
        target: Theme
        function onRevisionChanged() {
            if (root.pendingApply !== null) root.completeApply(root.pendingApply.name, root.pendingApply.line);
            else if (!root.busy) root.refresh();
        }
    }

    Timer {
        interval: BrowserLogic.PROGRESS_POLL_MS
        repeat: true
        running: root.job !== null && root.job.step === "download"
        onTriggered: root.downloading = root.shell.theme.last.downloading
    }

    // Keys the carousel passes on.
    Keys.onPressed: event => {
        // The Dialog holds the keys while it shows; what it passes on edits
        // nothing under it.
        if (offer !== null) {
            event.accepted = true;
            return;
        }
        const control = (event.modifiers & Qt.ControlModifier) !== 0;
        const other = (event.modifiers & (Qt.AltModifier | Qt.MetaModifier)) !== 0;
        if (event.key === Qt.Key_Escape) cancel();
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) activate();
        else if (event.key === Qt.Key_Up) carousel.step(-1);
        else if (event.key === Qt.Key_Down) carousel.step(1);
        else if (event.key === Qt.Key_Backspace && !other) editFilter({ kind: control ? "eraseWord" : "erase" });
        else if (event.key === Qt.Key_U && control && !other && (event.modifiers & Qt.ShiftModifier) === 0) editFilter({ kind: "clear" });
        else if (!control && !other && BrowserLogic.typable(event.text)) editFilter({ kind: "type", text: event.text });
        else return;
        event.accepted = true;
    }

    SegmentedControl {
        id: scope
        anchors.top: parent.top
        anchors.topMargin: Theme.space.xxxl
        anchors.horizontalCenter: parent.horizontalCenter
        model: BrowserLogic.SCOPES.map(s => s.label)
        currentIndex: root.scopeIndex
        onActivated: index => {
            root.scopeIndex = index;
            root.focusRail();
        }
    }

    CardCarousel {
        id: carousel
        anchors.top: scope.bottom
        anchors.topMargin: Theme.space.xl
        anchors.bottom: caption.top
        anchors.bottomMargin: Theme.space.xl
        anchors.left: parent.left
        anchors.right: parent.right
        focus: true
        model: ScriptModel {
            values: root.shownCards.map(card => Object.assign({ key: card.name + "\n" + card.image }, card))
            objectProp: "key"
        }
        delegate: ThemeCard {
            busy: root.job !== null && root.job.name === modelData.name
        }
        onCurrentIndexChanged: if (currentIndex < root.shownCards.length) root.selectedName = root.shownCards[currentIndex].name
        onActivated: root.activate()
    }

    Label {
        role: "body"
        anchors.centerIn: carousel
        visible: root.shownCards.length === 0 && root.listReason === ""
        text: !root.loaded ? "Loading themes" : root.filterText === "" ? "No theme is installed" : "No theme matches " + JSON.stringify(root.filterText)
    }

    Column {
        id: caption
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.space.xxxl
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 2 * Theme.space.xxl, Theme.carousel.expandedWidth)
        spacing: Theme.space.sm

        Label {
            role: "display"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.selected === null ? "" : root.selected.label
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.space.xs
            Badge {
                visible: root.selected !== null && root.selected.displayed
                text: "Displayed"
                tone: "accent"
            }
            Badge {
                visible: root.selected !== null && !root.selected.installed
                text: "Not installed"
            }
            Badge {
                visible: root.selected !== null && root.selected.state !== "ok"
                text: "Refused"
                tone: "danger"
            }
            Badge {
                visible: root.selected !== null && root.selected.imagery !== null && !root.selected.imagery.installed
                text: root.selected === null || root.selected.imagery === null ? "" : "Wallpapers " + BrowserLogic.sizeText(root.selected.imagery.size)
                tone: "info"
            }
        }

        Label {
            role: "h3"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideMiddle
            visible: root.filterText !== ""
            text: root.filterText
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.space.sm
            visible: root.job !== null && root.job.step !== "download"
            Spinner { anchors.verticalCenter: parent.verticalCenter }
            Label {
                role: "body"
                anchors.verticalCenter: parent.verticalCenter
                text: root.job === null ? "" : (root.job.step === "install" ? "Installing " : "Applying ") + BrowserLogic.label(root.job.name)
            }
        }

        Repeater {
            model: [
                root.problem,
                root.listReason === "" ? "" : "The theme list failed: " + root.listReason,
                root.catalogReason === "" ? "" : "The catalog failed: " + root.catalogReason,
                root.imagesReason === "" ? "" : "The image list failed: " + root.imagesReason
            ].filter(line => line !== "")
            Label {
                required property string modelData
                role: "body"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: Theme.color.danger
                text: modelData
            }
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.space.sm
            Kbd { text: "Enter" }
            Label { role: "hint"; anchors.verticalCenter: parent.verticalCenter; text: "Apply" }
            Kbd { text: "Esc" }
            Label { role: "hint"; anchors.verticalCenter: parent.verticalCenter; text: root.filterText === "" ? "Close" : "Clear the filter" }
            Label { role: "hint"; anchors.verticalCenter: parent.verticalCenter; text: "Type to filter" }
        }
    }

    Scrim {
        visible: root.offer !== null
        onClicked: if (!root.busy) root.declineOffer()
    }

    Dialog {
        id: prompt
        anchors.centerIn: parent
        visible: root.offer !== null
        busy: root.job !== null && root.job.step === "download"
        title: root.offer === null ? "" : "Download wallpapers for " + root.offer.label + " (" + BrowserLogic.sizeText(root.offer.imagery.size) + ")?"
        message: root.offer === null ? "" : root.offer.label + " is applied without its wallpapers."
        actions: [
            { label: "Download", role: "accept" },
            { label: "Not now", role: "cancel" }
        ]
        onVisibleChanged: if (visible) forceActiveFocus()
        onAccepted: root.download()
        onRejected: root.declineOffer()

        ProgressBar {
            width: parent.width
            visible: prompt.busy
            indeterminate: BrowserLogic.progressValue(root.downloading) === null
            value: BrowserLogic.progressValue(root.downloading) === null ? 0 : BrowserLogic.progressValue(root.downloading)
        }
        Label {
            role: "hint"
            width: parent.width
            visible: prompt.busy
            text: BrowserLogic.progressText(root.downloading)
        }
    }
}
