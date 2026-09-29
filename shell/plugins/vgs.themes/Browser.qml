import QtQuick
import qs.Commons
import qs.Ui
import "BrowserLogic.js" as BrowserLogic

// The browsers' overlay: a scrim over the whole screen and one view drawn
// on it, named by the payload's `view` (BrowserLogic.VIEWS). The host calls
// `open` on summon and again on a summon while open: a payload naming the
// view that shows closes the browser, and one naming another view switches
// to it. A payload BrowserLogic refuses throws, and the host refuses the
// summon. Escape, a click on the scrim and the view's own close all go
// through `dismiss`, which holds the browser open while the view runs a
// step whose next step it starts itself: the apply after an install, the
// offer after an apply, the apply after a download.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    // The view the browser shows, "" before the first open.
    property string view: ""
    // Each view's component, by its name in BrowserLogic.VIEWS.
    readonly property var views: ({ themes: "ThemeView.qml" })
    readonly property bool busy: page.item !== null && page.item.busy

    function open(payloadJson) {
        const payload = BrowserLogic.parsePayload(payloadJson);
        if (!Object.prototype.hasOwnProperty.call(views, payload.view)) throw new Error("themes: refused: view=" + payload.view + " has no component");
        if (payload.view === view) Qt.callLater(dismiss);
        else if (!busy) view = payload.view;
    }

    function close() {}

    // Ask the host to take the browser down, unless a step runs.
    function dismiss() {
        if (busy) return;
        const reply = shell.surfaces.hide("overlay");
        if (reply !== "ok") console.warn("themes: hide overlay " + reply);
    }

    Scrim {
        onClicked: root.dismiss()
    }

    Loader {
        id: page
        anchors.fill: parent
        focus: true
        source: root.view === "" ? "" : root.views[root.view]
        onLoaded: {
            item.shell = root.shell;
            item.closeRequested.connect(root.dismiss);
        }
    }
}
