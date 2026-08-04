pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Shows the "What's New" modal once per shipped version.
//
// The version is the one in `quickshell/vshell/VERSION` (via ShellVersionService),
// not a hand-maintained constant: a release bump is what makes the changelog
// re-display, so a note written into ChangelogContent.qml reaches users exactly
// when the release carrying it ships. Dismissal is persisted per version by
// `~/.config/vshell/.changelog-<version>`, so a marker written for 0.1.0 does
// not suppress 0.2.0. Fresh installs are suppressed by FirstLaunchService and
// have their marker written silently, so a new user never sees upgrade notes
// for an upgrade they did not make.
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
            const marker = markerPathFor(version);
            changelogCheckProcess.command = ["sh", "-c", "[ -f '" + marker + "' ] && echo 'seen' || echo 'show'"];
            changelogCheckProcess.running = true;
        }
    }

    function touchMarker(version) {
        if (!versionUsable(version))
            return;
        touchMarkerProcess.command = ["sh", "-c", "mkdir -p '" + configDir + "' && touch '" + markerPathFor(version) + "'"];
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

        stdout: SplitParser {
            onRead: data => {
                const result = data.trim();
                root.checkComplete = true;

                switch (result) {
                case "seen":
                    root.changelogDismissed = true;
                    break;
                case "show":
                    root.changelogRequested();
                    break;
                }
            }
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
