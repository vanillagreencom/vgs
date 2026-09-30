import QtQuick
import qs.Ui

// The row side of ListCursor, declared inside a row of `qs.Ui`: while
// `holds` is true it hands `cursor` the row it is declared in, and a hover
// on the row that the cursor lets move the selection emits `pointed`, for
// the list to make the row its selection. With no cursor it does nothing,
// and the row draws its own highlight.
HoverHandler {
    id: root

    // The list's ListCursor. Typed as Item: a copy of a component loaded
    // from its file path, as the smoke's popup copies are, registers this
    // module's types again, and a typed property refuses a cursor of the
    // other registration.
    property Item cursor: null
    property bool holds: false

    signal pointed()

    enabled: cursor !== null

    function claim() { if (cursor !== null) cursor.follow(parent, holds); }
    onHoldsChanged: claim()
    onCursorChanged: if (holds) claim()
    Component.onCompleted: if (holds) claim()

    onPointChanged: if (hovered && cursor !== null && cursor.hoverTakes(point.scenePosition)) pointed()
}
