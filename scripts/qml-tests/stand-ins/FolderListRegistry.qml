pragma Singleton
import QtQuick

// Registry for the FolderListModel stand-in. The real Qt type is found
// through the QML object tree; the unit test needs the created model so it
// can drive the listing and drop one change by hand.
QtObject {
    property var models: []

    function add(model) {
        models = models.concat([model]);
    }

    function remove(model) {
        models = models.filter(row => row !== model);
    }

    function clear() {
        models = [];
    }
}
