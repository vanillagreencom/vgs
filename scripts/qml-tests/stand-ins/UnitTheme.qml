pragma Singleton
import QtQuick

// What a unit test drives the theme with. The stand-in ThemeSource attaches
// itself here, so `override` and `reset` reach the one Theme instance.
QtObject {
    id: unit

    property var source: null

    function attach(themeSource) { source = themeSource; }

    // Publish a theme that overrides `tokens`; answers "ok" or the refusal line.
    function override(tokens) {
        return source.load(JSON.stringify({ schemaVersion: 1, name: "unit", tokens: tokens }));
    }

    function reset() { source.reset(); }
}
