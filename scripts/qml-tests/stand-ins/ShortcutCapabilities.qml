pragma Singleton
import QtQml

// ShortcutRegistry's core registrations use this dependency at startup.
// The key-read tests exercise no name validation or native registration.
QtObject {
    function checkName(kind, name) {}
}
