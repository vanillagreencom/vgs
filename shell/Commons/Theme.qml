pragma Singleton
import QtQuick
import Quickshell
import "Tokens.js" as Tokens
import "ThemeLogic.js" as ThemeLogic

// The design tokens as QML values: one read-only group per top-level group
// of Tokens.js, so a file reads `Theme.color.accent` or `Theme.text.body`.
// Every group is a deep-frozen object of primitives, so a write from any
// file changes nothing: a colour is the string `#aarrggbb` a colour
// property takes, never a colour value, whose channels a frozen object
// cannot protect. A theme change replaces the groups and rebuilds no component:
// a binding on a group re-evaluates, and a handler that needs every group
// from one theme runs on `revisionChanged`, which fires after the last
// group holds the new theme. The bundled fonts load here, so their families
// are available before any component asks for them; a family a theme names
// that Qt does not list is logged once and drawn with the bundled family the
// token's default names.
Singleton {
    id: root

    readonly property string name: source.name
    readonly property int revision: source.revision
    // The theme file's state as ThemeSource last read it: `pending`, then
    // `loaded`, `absent`, `refused` or `unreadable`. A refused edit moves it
    // without a new revision.
    readonly property string fileState: source.state

    readonly property var palette: published.palette
    readonly property var color: published.color
    readonly property var space: published.space
    readonly property var radius: published.radius
    readonly property var border: published.border
    readonly property var opacity: published.opacity
    readonly property var motion: published.motion
    readonly property var size: published.size
    readonly property var icon: published.icon
    readonly property var font: published.font
    readonly property var text: published.text
    readonly property var control: published.control
    readonly property var row: published.row
    readonly property var surface: published.surface
    readonly property var divider: published.divider
    readonly property var focusRing: published.focusRing
    readonly property var button: published.button
    readonly property var segmented: published.segmented
    readonly property var toggle: published.toggle
    readonly property var checkbox: published.checkbox
    readonly property var radio: published.radio
    readonly property var slider: published.slider
    readonly property var textField: published.textField
    readonly property var field: published.field
    readonly property var spinner: published.spinner
    readonly property var progress: published.progress
    readonly property var badge: published.badge
    readonly property var kbd: published.kbd
    readonly property var tabs: published.tabs
    readonly property var listItem: published.listItem
    readonly property var sectionHeader: published.sectionHeader
    readonly property var scrollArea: published.scrollArea
    readonly property var popover: published.popover
    readonly property var tooltip: published.tooltip
    readonly property var menu: published.menu
    readonly property var select: published.select
    readonly property var toast: published.toast
    readonly property var bar: published.bar

    // The accepted values converted once, as one frozen tree. It follows
    // the fonts too, so a family judged before a bundled font was ready is
    // judged again.
    readonly property var published: convert(source.values, [mono, sans].filter(font => font.status === FontLoader.Ready).map(font => font.name))

    // A resolved colour is `#rrggbbaa`; Qt reads eight digits with alpha
    // first, so the alpha moves to the front here and nowhere else.
    function toColor(text) {
        return "#" + text.slice(7, 9) + text.slice(1, 7);
    }

    // Every easing the judge accepts, by its QML enumerator. A name the
    // engine lacks is a defect of this file, not of a theme.
    readonly property var easings: {
        const out = {};
        for (const name of ThemeLogic.EASINGS) {
            const key = name[0].toUpperCase() + name.slice(1);
            if (Easing[key] === undefined) throw new Error("theme: easing " + name + " has no QML enumerator");
            out[name] = Easing[key];
        }
        return out;
    }

    // The QML value of one resolved token. `fallback` is the token's
    // default value, `loaded` the bundled families that are ready, and
    // `families` the families Qt knows, read once per conversion. A family
    // stands until the one its default names is loaded, so an unavailable
    // family always has a bundled family to draw in its place.
    function convertLeaf(leaf, value, fallback, loaded, families, missing) {
        switch (leaf.type) {
        case "color":
            return toColor(value);
        case "easing":
            return easings[value];
        case "family":
            if (loaded.indexOf(fallback) === -1 || loaded.indexOf(value) !== -1 || families().indexOf(value) !== -1) return value;
            const substitution = value + "\n" + fallback;
            if (missing.indexOf(substitution) === -1) {
                missing.push(substitution);
                console.warn("theme: font=" + value + " unavailable; drawing " + fallback);
            }
            return fallback;
        default:
            return value;
        }
    }

    function convert(values, loaded) {
        const missing = [];
        let known = null;
        const families = () => {
            if (known === null) known = Qt.fontFamilies();
            return known;
        };
        const walk = (table, node, defaults) => {
            const out = {};
            for (const key of Object.keys(table))
                out[key] = ThemeLogic.isLeaf(table[key]) ? convertLeaf(table[key], node[key], defaults[key], loaded, families, missing) : walk(table[key], node[key], defaults[key]);
            return Object.freeze(out);
        };
        return walk(Tokens.TOKENS, values, source.defaults.values);
    }

    FontLoader {
        id: mono
        source: Qt.resolvedUrl("../assets/fonts/JetBrainsMono-Variable.ttf")
        onStatusChanged: if (status === FontLoader.Error) console.error("theme: bundled font failed to load: " + source)
    }

    FontLoader {
        id: sans
        source: Qt.resolvedUrl("../assets/fonts/InterVariable.ttf")
        onStatusChanged: if (status === FontLoader.Error) console.error("theme: bundled font failed to load: " + source)
    }

    ThemeSource { id: source }
}
