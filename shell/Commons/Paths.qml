pragma Singleton
import QtQuick
import Quickshell

// The directories the shell reads user files from. Derived once here;
// Config reads shell.json and ThemeSource reads theme.json under configDir,
// and stateDir is where `vgsh theme` keeps what it applied.
Singleton {
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/vgs"
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/vgs"
}
