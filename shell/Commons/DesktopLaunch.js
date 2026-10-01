.pragma library

// The one rule for starting what a user picked, read by the launcher and
// by Jarvis, which runs this file under node through bin/lib/qml-library.js.
// Each returns the argv a caller hands to shell.run.detached.
//
// entry(ENTRY): the parsed Exec of ENTRY, a Quickshell DesktopEntry or an
// object with its `command` and `runInTerminal`. Quickshell leaves the
// terminal to the caller, so a terminal entry runs through
// xdg-terminal-exec; its window then carries the terminal's class.
function entry(desktopEntry) {
    var argv = Array.from(desktopEntry.command);
    return desktopEntry.runInTerminal === true ? ["xdg-terminal-exec"].concat(argv) : argv;
}

// open(TARGET): a file, folder or URL opened with its default application.
function open(target) {
    return ["gio", "open", target];
}
