pragma Singleton
import QtQuick

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
