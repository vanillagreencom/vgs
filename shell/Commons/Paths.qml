pragma Singleton
import QtQuick
import Quickshell

// The directories the shell reads user files from. Derived once here;
// Config reads shell.json and Color reads theme.json under configDir.
Singleton {
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/vgs"
}
