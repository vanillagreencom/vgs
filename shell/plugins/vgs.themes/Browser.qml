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
// step: the theme view's install, apply and download, whose next step it
// starts itself, and the wallpaper view's set, download and the apply
// after it.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    // The view the browser shows, "" before the first open.
    property string view: ""
    readonly property bool busy: page.item !== null && page.item.busy

    function open(payloadJson) {
        const payload = BrowserLogic.parsePayload(payloadJson);
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
        source: root.view === "" ? "" : BrowserLogic.viewSource(root.view)
        // A view takes the shell through a binding, so a settings change's
        // new shell object reaches it as it reaches the browser.
        onLoaded: {
            item.shell = Qt.binding(() => root.shell);
            item.closeRequested.connect(root.dismiss);
        }
    }
}
