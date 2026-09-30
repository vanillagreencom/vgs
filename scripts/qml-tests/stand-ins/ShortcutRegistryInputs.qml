pragma Singleton
import QtQml

// The enabled, judged sections that the real Registry supplies. Tests
// replace them to exercise the shipped provider without a compositor.
QtObject {
    property var hyprlandSections: []
}
