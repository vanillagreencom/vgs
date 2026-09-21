pragma Singleton
import QtQuick
import Quickshell

// Pure helpers shared by the core and every plugin.
Singleton {
    function alpha(c, opacity) {
        return Qt.rgba(c.r, c.g, c.b, opacity);
    }

    // A file:// URL for an absolute filesystem path.
    function fileUrl(path) {
        return path.indexOf("file://") === 0 ? path : "file://" + path;
    }

    // Single-quote a value for a POSIX shell.
    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'";
    }
}
