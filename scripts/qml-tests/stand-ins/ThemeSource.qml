import QtQuick
import qs.Unit
import "Tokens.js" as Tokens
import "ThemeLogic.js" as ThemeLogic

// The unit tests' theme source: the same members as the shipped
// ThemeSource, with a document handed over by UnitTheme in place of the
// file. It calls the shipped accept, so a test proves the shipped judge and
// publication and never a copy.
QtObject {
    id: source

    readonly property var defaults: ThemeLogic.defaults(Tokens.TOKENS)
    property string name: defaults.name
    property var values: defaults.values
    property int revision: 0
    property string state: "unit"

    // Accept one document; answers "ok" or the refusal line, which is also
    // what a refused document leaves published.
    function load(text) {
        const accepted = ThemeLogic.accept(Tokens.TOKENS, text);
        if (!accepted.ok) return ThemeLogic.refusalLine(accepted);
        name = accepted.name;
        values = accepted.values;
        revision += 1;
        return "ok";
    }

    function reset() {
        name = defaults.name;
        values = defaults.values;
        revision += 1;
    }

    Component.onCompleted: UnitTheme.attach(source)
}
