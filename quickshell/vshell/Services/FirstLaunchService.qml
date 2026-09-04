pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Detect first launch for ChangelogService and persist a marker to limit it to the current session.
Singleton {
    id: root
    readonly property var log: Log.scoped("FirstLaunchService")

    readonly property string configDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.ConfigLocation)) + "/vshell"
    readonly property string settingsPath: configDir + "/settings.json"
    readonly property string firstLaunchMarkerPath: configDir + "/.firstlaunch"

    property bool isFirstLaunch: false
    property bool checkComplete: false

    Component.onCompleted: {
        checkFirstLaunch();
    }

    function checkFirstLaunch() {
        firstLaunchCheckProcess.running = true;
    }

    Process {
        id: firstLaunchCheckProcess

        // Pass paths as arguments because XDG_CONFIG_HOME can contain shell quote characters.
        command: ["sh", "-c", `
            if [ -f "$2" ]; then
                echo 'skip'
            elif [ -f "$1" ]; then
                echo 'existing_user'
            else
                echo 'first'
            fi
        `, "vshell-firstlaunch", settingsPath, firstLaunchMarkerPath]
        running: false

        stdout: SplitParser {
            onRead: data => {
                const result = data.trim();

                if (result === "first") {
                    root.isFirstLaunch = true;
                    log.info("First launch detected");
                } else {
                    root.isFirstLaunch = false;
                    if (result === "existing_user")
                        log.info("Existing user detected, silently creating marker");
                }

                root.checkComplete = true;

                // Write the marker on any launch that lacks one (fresh install or
                // existing user) so detection fires exactly once. In-memory
                // isFirstLaunch stays true for this session for consumers.
                if (result !== "skip")
                    touchMarkerProcess.running = true;
            }
        }
    }

    Process {
        id: touchMarkerProcess

        command: ["sh", "-c", 'mkdir -p "$1" && touch "$2"', "vshell-firstlaunch", configDir, firstLaunchMarkerPath]
        running: false

        onExited: exitCode => {
            if (exitCode === 0) {
                log.info("First launch marker created");
            } else {
                log.warn("Failed to create first launch marker");
            }
        }
    }
}
