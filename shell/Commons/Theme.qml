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
// group holds the new theme. The bundled font loads here, so its family is
// available before any component asks for it; a family a theme names that
// Qt does not list is logged once and drawn with the bundled family.
Singleton {
    id: root

    readonly property string name: source.name
    readonly property int revision: source.revision

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
    readonly property var field: published.field
    readonly property var bar: published.bar

    // The accepted values converted once, as one frozen tree. It follows
    // the font too, so a family judged before the bundled font was ready
    // is judged again.
    readonly property var published: convert(source.values, bundled.status === FontLoader.Ready ? bundled.name : "")

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

    // The QML value of one resolved token. `available` is the bundled
    // family once it is loaded, or "" while it is not; `families` lists the
    // families Qt knows, read once per conversion.
    function convertLeaf(leaf, value, available, families, missing) {
        switch (leaf.type) {
        case "color":
            return toColor(value);
        case "easing":
            return easings[value];
        case "family":
            if (available === "" || value === available || families().indexOf(value) !== -1) return value;
            if (missing.indexOf(value) === -1) {
                missing.push(value);
                console.warn("theme: font=" + value + " unavailable; drawing " + available);
            }
            return available;
        default:
            return value;
        }
    }

    function convert(values, available) {
        const missing = [];
        let known = null;
        const families = () => {
            if (known === null) known = Qt.fontFamilies();
            return known;
        };
        const walk = (table, node) => {
            const out = {};
            for (const key of Object.keys(table))
                out[key] = ThemeLogic.isLeaf(table[key]) ? convertLeaf(table[key], node[key], available, families, missing) : walk(table[key], node[key]);
            return Object.freeze(out);
        };
        return walk(Tokens.TOKENS, values);
    }

    FontLoader {
        id: bundled
        source: Qt.resolvedUrl("../assets/fonts/JetBrainsMono-Variable.ttf")
        onStatusChanged: if (status === FontLoader.Error) console.error("theme: bundled font failed to load: " + source)
    }

    ThemeSource { id: source }
}
