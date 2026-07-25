pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

Singleton {
    id: root

    readonly property bool locationAvailable: VGSBackendService.isConnected && VGSBackendService.capabilities.includes("location")
    readonly property bool valid: latitude !== 0 || longitude !== 0

    property var latitude: 0.0
    property var longitude: 0.0

    signal locationChanged(var data)

    onLocationAvailableChanged: {
        if (locationAvailable && !valid)
            getState();
    }

    Connections {
        target: VGSBackendService

        function onLocationStateUpdate(data) {
            if (!locationAvailable)
                return;
            handleStateUpdate(data);
        }
    }

    function handleStateUpdate(data) {
        const lat = data.latitude;
        const lon = data.longitude;
        if (lat === 0 && lon === 0)
            return;

        root.latitude = lat;
        root.longitude = lon;
        root.locationChanged(data);
    }

    function getState() {
        if (!locationAvailable)
            return;

        VGSBackendService.sendRequest("location.getState", null, response => {
            if (response.result)
                handleStateUpdate(response.result);
        });
    }
}
