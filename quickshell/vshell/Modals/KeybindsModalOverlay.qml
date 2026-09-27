import QtQml
import QtQuick
import qs.Common
import qs.Modals
import qs.Modals.Common
import qs.Services

VgsModal {
    id: overlay

    signal floatingToggleRequested

    layerNamespace: "vshell:keybinds"
    useOverlayLayer: true
    // Use the content width request because each category remains within one column.
    property real _maxW: Math.min(overlay.screenWidth * 0.92, contentLoader.item ? contentLoader.item.preferredWidth : 720)
    property real _maxH: Math.min(overlay.screenHeight * 0.92, 940)
    modalWidth: _maxW
    modalHeight: _maxH
    onBackgroundClicked: close()
    onOpened: {
        Qt.callLater(() => {
            modalFocusScope.forceActiveFocus();
            if (contentLoader.item?.searchField)
                contentLoader.item.searchField.forceActiveFocus();
        });
        if (!Object.keys(KeybindsService.cheatsheet).length && KeybindsService.cheatsheetAvailable)
            KeybindsService.loadCheatsheet();
    }

    content: Component {
        KeybindsContent {
            showFloatingToggle: true
            floating: false
            onCloseRequested: overlay.close()
            onFloatingToggleRequested: overlay.floatingToggleRequested()
        }
    }
}
