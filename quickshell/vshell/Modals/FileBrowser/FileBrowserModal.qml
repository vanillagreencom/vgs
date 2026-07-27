import QtQuick
import Quickshell
import qs.Common
import qs.Widgets

FloatingWindow {
    id: fileBrowserModal

    property bool disablePopupTransparency: false
    property string browserTitle: "Select File"
    property string browserType: "generic"
    property var fileExtensions: ["*.*"]
    property alias filterExtensions: fileBrowserModal.fileExtensions
    property bool showHiddenFiles: false
    property bool saveMode: false
    property string defaultFileName: ""
    property var parentModal: null
    parentWindow: parentModal
    property bool shouldHaveFocus: visible
    property bool allowFocusOverride: false
    property bool shouldBeVisible: visible
    property bool allowStacking: true

    signal fileSelected(string path)
    signal dialogClosed

    function open() {
        visible = true;
    }

    function close() {
        visible = false;
    }

    objectName: "fileBrowserModal"
    title: "Files - " + browserTitle
    minimumSize: Qt.size(500, 400)
    implicitWidth: 800
    implicitHeight: 600
    color: "transparent"
    visible: false

    onClosed: close()

    onVisibleChanged: {
        if (visible) {
            if (parentModal && "shouldHaveFocus" in parentModal) {
                parentModal.shouldHaveFocus = false;
                parentModal.allowFocusOverride = true;
            }
            Qt.callLater(() => {
                if (content) {
                    content.reset();
                    content.forceActiveFocus();
                }
            });
        } else {
            if (parentModal && "allowFocusOverride" in parentModal) {
                parentModal.allowFocusOverride = false;
                parentModal.shouldHaveFocus = Qt.binding(() => parentModal.shouldBeVisible);
            }
            dialogClosed();
        }
    }

    VgsFloatingSurface {
        anchors.fill: parent
        targetWindow: fileBrowserModal

        Loader {
            id: contentLoader
            anchors.fill: parent
            active: fileBrowserModal.visible
            sourceComponent: FileBrowserContent {
                id: content
                anchors.fill: parent
                focus: true
                closeOnEscape: false
                windowControls: fileBrowserModal.windowControlsRef

                browserTitle: fileBrowserModal.browserTitle
                browserType: fileBrowserModal.browserType
                fileExtensions: fileBrowserModal.fileExtensions
                showHiddenFiles: fileBrowserModal.showHiddenFiles
                saveMode: fileBrowserModal.saveMode
                defaultFileName: fileBrowserModal.defaultFileName

                Component.onCompleted: initialize()

                onFileSelected: path => fileBrowserModal.fileSelected(path)
                onCloseRequested: fileBrowserModal.close()
            }
        }
    }

    property alias content: contentLoader.item
    property alias windowControlsRef: windowControls

    FloatingWindowControls {
        id: windowControls
        targetWindow: fileBrowserModal
    }
}
