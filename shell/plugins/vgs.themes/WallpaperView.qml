import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "BrowserLogic.js" as BrowserLogic

// The wallpaper view of the browser: the applied theme's wallpapers, or
// every package's and the user folder's, as angled cards on a rail, a
// source control, Theme or All, and with two screens or more a scope
// control, All monitors or This monitor. Enter or a click on the selected
// image sets it for the scope: on every screen, each screen's own image
// cleared, or on the screen the browser shows on. The browser stays open
// while the set runs, closes once it lands, and shows a line naming the
// reason when it fails. Under Theme, a last card downloads the applied
// catalog theme's wallpapers when they are missing, or updates them when
// the catalog pins a newer archive; it shows the download's progress from
// `last.downloading`, applies the theme again so its image shows, reads
// the lists again and stays open.
//
// Keys, BrowserLogic.WALLPAPER_KEYS: Left, Up and A step back, Right, Down
// and D forward, Home and End go to the first and the last card, Enter
// sets the selected image or runs the selected card, Escape asks to close,
// S flips the source, and W, Tab and Shift+Tab flip the scope while its
// control shows; without it Tab and Shift+Tab step. The view holds the
// keyboard itself and the rail never takes the focus, because the rail
// takes Tab as a step.
//
// The view is built with each open and destroyed with the browser, so the
// scope starts on All monitors every time. It reads every image and the
// catalog on open, again after a download and whenever the applied theme
// changes. The selection starts on the image the chosen scope shows, and
// follows it until a key or a click moves it.
FocusScope {
    id: root

    property var shell: null

    // Asks the browser to close; the browser holds it while `busy`.
    signal closeRequested()

    // The last answers: every source's images and the catalog's entries,
    // each null before it arrives or after it failed, beside the reason it
    // failed or "".
    property var images: null
    property string imagesReason: ""
    property var entries: null
    property string catalogReason: ""
    // Whether the first image list and catalog have both answered.
    property bool loaded: false
    property bool started: false

    property int sourceIndex: 0
    property int scopeIndex: 0
    readonly property string source: BrowserLogic.WALLPAPER_SOURCES[sourceIndex].source
    readonly property int screenCount: shell === null ? 0 : shell.screens.all.length
    readonly property bool scoped: BrowserLogic.scopeShown(screenCount)
    readonly property string scope: BrowserLogic.screenScope(scopeIndex, screenCount)
    // The output the browser shows on, "" before the shell arrives.
    readonly property string screenName: shell === null || shell.screens.current === null ? "" : shell.screens.current.name
    readonly property string applied: Theme.name
    readonly property var cards: images === null ? [] : BrowserLogic.wallpaperCards(images, entries, applied, source)
    // The image the chosen scope shows now, "" for none.
    readonly property string shownPath: BrowserLogic.shownPath(scope, wallpaper.path, wallpaper.screenPaths, screenName)
    // The selected card's key once a key or a click moved it.
    property string selectedKey: ""
    property bool moved: false
    // True while the view itself moves the rail, so the move is no choice.
    property bool seeding: false
    readonly property var selected: carousel.currentIndex < cards.length ? cards[carousel.currentIndex] : null

    // The step this view runs, { step, key, name } with `step` `set`,
    // `download`, `update` or `apply`, `key` the card it runs for and
    // `name` the image file or the package, or null.
    property var job: null
    readonly property bool busy: job !== null
    // `last.downloading` as last read while a download this view started
    // runs, else null.
    property var downloading: null
    // What the last step that failed answered, "" when none did.
    property string problem: ""

    WallpaperState { id: wallpaper }

    // Read every image and the catalog; each answer is kept as it arrives.
    function refresh() {
        let waiting = 2;
        const answered = () => {
            waiting -= 1;
            if (waiting === 0) root.loaded = true;
        };
        const reply = shell.theme.images("all", result => {
            root.imagesReason = result.state === "ok" ? "" : result.reason;
            root.images = result.state === "ok" ? result.images : null;
            answered();
        });
        if (reply !== "ok") throw new Error("themes: images all " + reply);
        shell.theme.catalog(result => {
            root.catalogReason = result.reason === null ? "" : result.reason;
            root.entries = result.reason === null ? result.entries : null;
            answered();
        });
    }

    // Select the card the user chose, or until one moved the rail, the
    // image the chosen scope shows; the first card when neither is shown.
    function reselect() {
        seeding = true;
        carousel.currentIndex = BrowserLogic.wallpaperSelection(cards, moved ? selectedKey : shownPath);
        seeding = false;
    }

    onCardsChanged: reselect()
    onShownPathChanged: if (!moved) reselect()

    function flipSource() {
        sourceIndex = (sourceIndex + 1) % BrowserLogic.WALLPAPER_SOURCES.length;
    }

    // A new scope selects the image it shows.
    function chooseScope(index) {
        scopeIndex = index;
        moved = false;
        reselect();
    }

    function flipScope() {
        chooseScope((scopeIndex + 1) % BrowserLogic.SCREEN_SCOPES.length);
    }

    function takeKeys() { root.forceActiveFocus(); }

    // End the running step with LINE, "" for none, and read the lists
    // again: a step that failed may still have changed what is on disk.
    function finish(line) {
        job = null;
        problem = line;
        refresh();
    }

    // Enter or a click on the selected card.
    function activate() {
        const card = selected;
        if (busy || card === null) return;
        problem = "";
        switch (card.kind) {
        case "image":
            setImage(card);
            break;
        case "download":
        case "update":
            download(card.kind);
            break;
        default:
            throw new Error("themes: wallpaper card kind=" + card.kind);
        }
    }

    function setImage(card) {
        job = { step: "set", key: card.key, name: card.background };
        const reply = shell.theme.set(card.path, BrowserLogic.setScreen(scope, screenName), result => {
            const line = BrowserLogic.problem("set", card.background, result);
            root.job = null;
            if (line === "") root.closeRequested();
            else root.problem = line;
        });
        if (reply !== "ok") {
            job = null;
            problem = reply;
        }
    }

    // Download or update, as KIND names, the applied theme's wallpapers,
    // then apply it again so its image shows.
    function download(kind) {
        const name = applied;
        job = { step: kind, key: kind, name: name };
        const reply = shell.theme.wallpapers(name, result => {
            root.downloading = null;
            const line = BrowserLogic.problem(kind, name, result);
            if (line !== "") root.finish(line);
            else root.reapply(name);
        }, kind === "update" ? { update: true } : undefined);
        if (reply !== "ok") {
            finish(reply);
            return;
        }
        downloading = shell.theme.last.downloading;
    }

    function reapply(name) {
        job = { step: "apply", key: "", name: name };
        const reply = shell.theme.apply(name, result => {
            // The selection follows the image the apply shows.
            root.moved = false;
            root.finish(BrowserLogic.problem("apply", name, result));
        });
        if (reply !== "ok") finish(reply);
    }

    function start() {
        if (started || shell === null) return;
        started = true;
        refresh();
        takeKeys();
    }

    Component.onCompleted: start()
    onShellChanged: start()

    // An apply from elsewhere changes the applied theme's images.
    Connections {
        target: Theme
        function onRevisionChanged() {
            if (!root.busy) root.refresh();
        }
    }

    Timer {
        interval: BrowserLogic.PROGRESS_POLL_MS
        repeat: true
        running: root.job !== null && (root.job.step === "download" || root.job.step === "update")
        onTriggered: root.downloading = root.shell.theme.last.downloading
    }

    Keys.onPressed: event => {
        const chord = (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) !== 0;
        const action = BrowserLogic.wallpaperAction(event.key, (event.modifiers & Qt.ShiftModifier) !== 0, chord, root.scoped);
        switch (action) {
        case "":
            return;
        case "back":
            carousel.step(-1);
            break;
        case "forward":
            carousel.step(1);
            break;
        case "first":
            carousel.currentIndex = 0;
            break;
        case "last":
            carousel.currentIndex = Math.max(0, root.cards.length - 1);
            break;
        case "activate":
            root.activate();
            break;
        case "close":
            root.closeRequested();
            break;
        case "source":
            root.flipSource();
            break;
        case "scope":
            root.flipScope();
            break;
        default:
            throw new Error("themes: wallpaper action=" + action);
        }
        event.accepted = true;
    }

    Row {
        id: controls
        anchors.top: parent.top
        anchors.topMargin: Theme.space.xxxl
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Theme.space.lg

        SegmentedControl {
            id: sourceControl
            model: BrowserLogic.WALLPAPER_SOURCES.map(s => s.label)
            currentIndex: root.sourceIndex
            onActivated: index => {
                root.sourceIndex = index;
                currentIndex = Qt.binding(() => root.sourceIndex);
                root.takeKeys();
            }
        }

        SegmentedControl {
            id: scopeControl
            visible: root.scoped
            model: BrowserLogic.SCREEN_SCOPES.map(s => s.label)
            currentIndex: root.scopeIndex
            onActivated: index => {
                root.chooseScope(index);
                currentIndex = Qt.binding(() => root.scopeIndex);
                root.takeKeys();
            }
        }
    }

    CardCarousel {
        id: carousel
        anchors.top: controls.bottom
        anchors.topMargin: Theme.space.xl
        anchors.bottom: caption.top
        anchors.bottomMargin: Theme.space.xl
        anchors.left: parent.left
        anchors.right: parent.right
        model: ScriptModel {
            values: root.cards
            objectProp: "key"
        }
        delegate: WallpaperCard {
            busy: root.job !== null && root.job.key === modelData.key
        }
        onCurrentIndexChanged: {
            if (root.seeding || currentIndex >= root.cards.length) return;
            root.moved = true;
            root.selectedKey = root.cards[currentIndex].key;
        }
        onActivated: root.activate()
    }

    Label {
        role: "body"
        anchors.centerIn: carousel
        visible: root.cards.length === 0 && root.imagesReason === ""
        text: BrowserLogic.wallpaperEmpty(root.loaded, root.source, root.applied)
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
            elide: Text.ElideMiddle
            text: root.selected === null ? "" : root.selected.label
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.space.xs
            Badge {
                visible: root.selected !== null && root.selected.kind === "image" && root.selected.path === root.shownPath
                text: "Shown"
                tone: "accent"
            }
            Badge {
                visible: root.selected !== null && (root.source === "all" || root.selected.kind !== "image")
                text: root.selected === null ? "" : root.selected.sourceLabel
            }
            Badge {
                visible: root.selected !== null && root.selected.kind !== "image"
                text: root.selected === null || root.selected.kind === "image" ? "" : BrowserLogic.sizeText(root.selected.size)
                tone: "info"
            }
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.space.sm
            visible: root.job !== null && (root.job.step === "set" || root.job.step === "apply")
            Spinner { anchors.verticalCenter: parent.verticalCenter }
            Label {
                role: "body"
                anchors.verticalCenter: parent.verticalCenter
                text: root.job === null ? "" : root.job.step === "set" ? "Setting " + root.job.name : "Applying " + BrowserLogic.label(root.job.name)
            }
        }

        ProgressBar {
            width: parent.width
            visible: root.job !== null && (root.job.step === "download" || root.job.step === "update")
            indeterminate: BrowserLogic.progressValue(root.downloading) === null
            value: BrowserLogic.progressValue(root.downloading) === null ? 0 : BrowserLogic.progressValue(root.downloading)
        }
        Label {
            role: "hint"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: root.job !== null && (root.job.step === "download" || root.job.step === "update")
            text: BrowserLogic.progressText(root.downloading)
        }

        Repeater {
            model: [
                root.problem,
                root.imagesReason === "" ? "" : "The image list failed: " + root.imagesReason,
                root.catalogReason === "" ? "" : "The catalog failed: " + root.catalogReason
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
            Label {
                role: "hint"
                anchors.verticalCenter: parent.verticalCenter
                text: root.selected === null || root.selected.kind === "image" ? "Set" : root.selected.kind === "download" ? "Download" : "Update"
            }
            Kbd { text: "S" }
            Label { role: "hint"; anchors.verticalCenter: parent.verticalCenter; text: "Theme or all" }
            Kbd { visible: root.scoped; text: "W" }
            Label { role: "hint"; visible: root.scoped; anchors.verticalCenter: parent.verticalCenter; text: "Monitors" }
            Kbd { text: "Esc" }
            Label { role: "hint"; anchors.verticalCenter: parent.verticalCenter; text: "Close" }
        }
    }
}
