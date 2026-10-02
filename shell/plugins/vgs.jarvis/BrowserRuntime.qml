import QtQuick

// Browser readiness uses the same setup status reader as local voice.
LocalRuntime {
    statusKey: "browser"
    tuiName: "setup-browser"
    program: String(Qt.resolvedUrl("backend/browser-setup.js")).replace(/^file:\/\//, "")
    command: ["node", program, "status"]
}
