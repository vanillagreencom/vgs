pragma Singleton
import QtQuick

// Stands in for Quickshell.Io's FileViewError enum, whose plugin does not
// load outside the shell. The record reader only needs FileNotFound so it
// can ignore a file removed between a listing row and the read.
QtObject {
    enum Error {
        FileNotFound = 1
    }
}
