pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Show release notes once per version reported by ShellVersionService.
// Fresh installs write the dismissal marker without showing upgrade notes.
Singleton {
    id: root
    readonly property var log: Log.scoped("ChangelogService")

    readonly property string currentVersion: ShellVersionService.semverVersion

    // Guard the version before it is interpolated into a shell command and a
    // path; an unreadable or malformed VERSION disables the surface rather than
    // producing a marker at a junk path. A function, not a derived property:
    // onCurrentVersionChanged runs before a property binding on the same
    // signal has been re-evaluated, so the property would still read false
    // when the version first arrives.
    function versionUsable(version) {
        return /^[A-Za-z0-9._+-]+$/.test(version);
    }

    readonly property string configDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.ConfigLocation)) + "/vshell"

    // Also a function rather than a binding, and for the same reason: the
    // commands below are built when a check starts, from the version that
    // started it, so a marker can never be read or written at a stale path.
    function markerPathFor(version) {
        return configDir + "/.changelog-" + version;
    }

    property bool checkComplete: false
    property bool changelogDismissed: false

    readonly property bool shouldShowChangelog: {
        if (!checkComplete)
            return false;
        if (changelogDismissed)
            return false;
        if (typeof FirstLaunchService !== "undefined" && FirstLaunchService.isFirstLaunch)
            return false;
        return true;
    }

    signal changelogRequested
    signal changelogCompleted

    Component.onCompleted: maybeStartCheck()

    // Both inputs arrive asynchronously (a VERSION read and the first-launch
    // probe), in either order; start once both are in and only once.
    function maybeStartCheck() {
        if (checkComplete || changelogCheckProcess.running)
            return;
        const version = ShellVersionService.semverVersion;
        if (!versionUsable(version)) {
            if (version.length > 0)
                log.warn("Unusable shell version, changelog suppressed: " + version);
            return;
        }
        if (!FirstLaunchService.checkComplete)
            return;
        handleFirstLaunchResult(version);
    }

    function handleFirstLaunchResult(version) {
        if (FirstLaunchService.isFirstLaunch) {
            checkComplete = true;
            changelogDismissed = true;
            touchMarker(version);
        } else {
            // Pass the marker path as an argument because XDG_CONFIG_HOME can contain shell quote characters.
            changelogCheckProcess.command = ["sh", "-c", 'test -f "$1"', "vshell-changelog", markerPathFor(version)];
            changelogCheckProcess.running = true;
        }
    }

    function touchMarker(version) {
        if (!versionUsable(version))
            return;
        touchMarkerProcess.command = ["sh", "-c", 'mkdir -p "$1" && touch "$2"', "vshell-changelog", configDir, markerPathFor(version)];
        touchMarkerProcess.running = true;
    }

    Connections {
        target: FirstLaunchService

        function onCheckCompleteChanged() {
            root.maybeStartCheck();
        }
    }

    onCurrentVersionChanged: maybeStartCheck()

    function dismissChangelog() {
        changelogDismissed = true;
        touchMarker(ShellVersionService.semverVersion);
        changelogCompleted();
    }

    Process {
        id: changelogCheckProcess

        running: false

        // Exit 0 means the marker exists, so this version was already seen.
        // Any other status means it is missing (or unreadable), and the safe
        // reading of "unreadable" is to show the notes rather than swallow them.
        onExited: exitCode => {
            root.checkComplete = true;
            if (exitCode === 0)
                root.changelogDismissed = true;
            else
                root.changelogRequested();
        }
    }

    Process {
        id: touchMarkerProcess

        running: false

        onExited: exitCode => {
            if (exitCode !== 0) {
                log.warn("Failed to create changelog marker");
            }
        }
    }
}
