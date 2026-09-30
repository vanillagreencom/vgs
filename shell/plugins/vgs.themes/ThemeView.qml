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
// Keys: Left, Right, Home, End and the wheel move through the rail, and Up
// and Down step as Left and Right do. Tab and Shift+Tab switch the top
// tabs. Alt+I switches the scope. A printable character types into the
// filter, Backspace erases a character, Ctrl+Backspace a word and Ctrl+U
// the whole filter. Escape clears the filter, then asks to close. Enter
// applies the selected card.
//
// The view is built with the overlay and destroyed with it, so it reads
// everything on open: the list, the catalog and every image, again after
// each apply and whenever the displayed theme changes.
FocusScope {
    id: root

    property var shell: null
    property bool alive: true

    // Asks the browser to close; the browser holds it while `busy`.
    signal closeRequested()
    signal switchRequested(int direction)

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
    property var previewCache: ({})
    property var previewJobs: ({})
    property string wantedPreview: ""
    property string runningPreview: ""
    // What the last step that failed answered, "" when none did.
    property string problem: ""
    // The load the rail's images come from, a clock reading taken on
    // open: each card loads its image under it as the URL's stamp, so an
    // image replaced under its name since an earlier open is read again
    // rather than from Qt's pixmap cache.
    property real generation: 0

    // Read the list, the catalog and every image, then build the cards and
    // run THEN, when given. Each answer is kept as it arrives.
    function refresh(then) {
        const view = root;
        let waiting = 3;
        const answered = () => {
            waiting -= 1;
            if (waiting > 0) return;
            view.loaded = true;
            if (view.selectedName === "") view.selectedName = Theme.name;
            view.cards = view.packages === null ? [] : BrowserLogic.cards(view.packages, view.entries, view.images, Theme.name);
            if (then !== undefined) then();
        };
        shell.theme.list(result => {
            if (!view.alive) return;
            root.listReason = result.reason === null ? "" : result.reason;
            view.packages = result.reason === null ? result.packages : null;
            answered();
        });
        shell.theme.catalog(result => {
            if (!view.alive) return;
            root.catalogReason = result.reason === null ? "" : result.reason;
            view.entries = result.reason === null ? result.entries : null;
            answered();
        });
        const reply = shell.theme.images("all", result => {
            if (!view.alive) return;
            root.imagesReason = result.state === "ok" ? "" : result.reason;
            view.images = result.state === "ok" ? result.images : null;
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

    function toggleScope() {
        scopeIndex = (scopeIndex + 1) % BrowserLogic.SCOPES.length;
    }

    function navigate(direction) {
        switch (direction) {
        case "left":
        case "up":
            carousel.step(-1);
            break;
        case "right":
        case "down":
            carousel.step(1);
            break;
        default:
            throw new Error("themes: direction=" + direction);
        }
    }

    // End the running step with LINE, "" for none. A step that failed may
    // still have changed what is on disk, an install before the apply after
    // it failed, so the cards are read again and Enter retries the step
    // that failed, not one that landed.
    function finish(line) {
        job = null;
        problem = line;
        if (line !== "") refresh();
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

    function requestPreview(card) {
        wantedPreview = card === null || card.installed || card.previewImage !== null || card.image === null ? "" : card.name;
        if (wantedPreview === "" || previewCache[wantedPreview] !== undefined || previewJobs[wantedPreview] === true) return;
        previewTimer.restart();
    }

    function startPreview() {
        const name = wantedPreview;
        if (name === "" || runningPreview !== "" || previewCache[name] !== undefined || previewJobs[name] === true) return;
        const nextJobs = Object.assign({}, previewJobs);
        nextJobs[name] = true;
        previewJobs = nextJobs;
        runningPreview = name;
        const reply = shell.theme.preview(name, result => {
            root.runningPreview = "";
            const jobs = Object.assign({}, root.previewJobs);
            delete jobs[name];
            root.previewJobs = jobs;
            if (result.state === "ok") {
                const cache = Object.assign({}, root.previewCache);
                cache[name] = result.path;
                root.previewCache = cache;
            }
            if (root.wantedPreview !== "" && root.wantedPreview !== name) root.startPreview();
        });
        if (reply !== "ok") {
            runningPreview = "";
            const jobs = Object.assign({}, previewJobs);
            delete jobs[name];
            previewJobs = jobs;
        }
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
        generation = Date.now();
        refresh();
        focusRail();
    }

    Component.onCompleted: start()
    Component.onDestruction: alive = false
    onShellChanged: start()
    onSelectedChanged: requestPreview(selected)

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

    Timer {
        id: previewTimer
        interval: Theme.carousel.previewDwell
        onTriggered: root.startPreview()
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
        const alt = (event.modifiers & Qt.AltModifier) !== 0;
        const meta = (event.modifiers & Qt.MetaModifier) !== 0;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        const action = BrowserLogic.themeAction(event.key, shift, control, alt, meta);
        switch (action) {
        case "back":
            carousel.step(-1);
            break;
        case "forward":
            carousel.step(1);
            break;
        case "activate":
            activate();
            break;
        case "close":
            cancel();
            break;
        case "scope":
            toggleScope();
            break;
        case "tab-next":
            switchRequested(1);
            break;
        case "tab-previous":
            switchRequested(-1);
            break;
        case "":
            if (event.key === Qt.Key_Backspace && !alt && !meta) editFilter({ kind: control ? "eraseWord" : "erase" });
            else if (event.key === Qt.Key_U && control && !alt && !meta && !shift) editFilter({ kind: "clear" });
            else if (!control && !alt && !meta && BrowserLogic.typable(event.text)) editFilter({ kind: "type", text: event.text });
            else return;
            break;
        default:
            throw new Error("themes: theme action=" + action);
        }
        event.accepted = true;
    }

    Column {
        id: controls
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: carousel.top
        anchors.bottomMargin: Theme.space.lg
        spacing: Theme.space.lg

        Tabs {
            anchors.horizontalCenter: parent.horizontalCenter
            model: BrowserLogic.VIEWS.map(v => v.label)
            currentIndex: 0
            onActiveFocusChanged: if (activeFocus) Qt.callLater(root.focusRail)
            onCurrentIndexChanged: if (currentIndex !== 0) root.switchRequested(1)
        }

        Row {
            id: scope
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.space.sm

            SegmentedControl {
                anchors.verticalCenter: parent.verticalCenter
                model: BrowserLogic.SCOPES.map(s => s.label)
                currentIndex: root.scopeIndex
                // A segment click focuses the control, and a click on the chosen
                // segment emits no `activated`, so the control hands the keyboard
                // back to the rail whenever it takes it, after the click ends.
                onActiveFocusChanged: if (activeFocus) Qt.callLater(root.focusRail)
                onActivated: index => {
                    root.scopeIndex = index;
                    currentIndex = Qt.binding(() => root.scopeIndex);
                }
            }
            Kbd { anchors.verticalCenter: parent.verticalCenter; text: "Alt+I" }
        }
    }

    CardCarousel {
        id: carousel
        anchors.top: parent.top
        anchors.topMargin: controls.implicitHeight + Theme.space.xxxl * 3
        anchors.bottom: caption.top
        anchors.bottomMargin: Theme.space.xl
        anchors.left: parent.left
        anchors.right: parent.right
        focus: true
        devicePixelRatio: root.shell === null || root.shell.screens.current === null ? Screen.devicePixelRatio : root.shell.screens.current.devicePixelRatio
        tabSteps: false
        Keys.onTabPressed: event => { root.switchRequested(1); event.accepted = true; }
        Keys.onBacktabPressed: event => { root.switchRequested(-1); event.accepted = true; }
        model: ScriptModel {
            values: root.shownCards.map(card => {
                const sharpened = root.previewCache[card.name] === undefined ? card : Object.assign({}, card, { sharpenedImage: root.previewCache[card.name] });
                return Object.assign({ key: BrowserLogic.railKey(BrowserLogic.cardKey(sharpened), root.generation), generation: root.generation }, sharpened);
            })
            objectProp: "key"
        }
        delegate: ThemeCard {
            busy: root.job !== null && root.job.name === modelData.name
        }
        onCurrentIndexChanged: if (currentIndex < root.shownCards.length) {
            root.selectedName = root.shownCards[currentIndex].name;
            root.requestPreview(root.shownCards[currentIndex]);
        }
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
            Label { role: "hint"; anchors.verticalCenter: parent.verticalCenter; text: "Apply theme" }
            Kbd { text: "Tab" }
            Label { role: "hint"; anchors.verticalCenter: parent.verticalCenter; text: "Themes / Wallpapers" }
            Kbd { text: "Esc" }
            Label { role: "hint"; anchors.verticalCenter: parent.verticalCenter; text: root.filterText === "" ? "Close" : "Clear filter" }
            Label { role: "hint"; anchors.verticalCenter: parent.verticalCenter; text: "Type to search" }
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
