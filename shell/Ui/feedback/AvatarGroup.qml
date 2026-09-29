import QtQuick
import qs.Commons
import qs.Ui

// People as round faces in a square box `size` wide. `people` is a list of
// { image, initials, tint }, the caller's reading of each person; `more`
// counts the people past them. One person fills the box with no ring. Two
// to four overlap in the box's corners, clockwise from the top left: two
// on the diagonal, three as a triangle with its point at the top, four as
// a 2 by 2 cluster. Past four, three faces and a "+N" chip in the fourth
// place count the rest. Each face is `faceShare` of the box across, ringed
// `ringWidth` in `ring`, the colour of the surface under the group, so an
// overlap reads as a cut, and each lies over the one before it, the chip
// last. Every value defaults to its `avatarGroup` token.
Item {
    id: group

    property var people: []
    property int more: 0
    property real size: Theme.avatarGroup.size
    property real faceShare: Theme.avatarGroup.face
    property real ringWidth: Theme.avatarGroup.ringWidth
    property color ring: Theme.avatarGroup.ring
    property color tint: Theme.avatarGroup.tint
    property color chip: Theme.avatarGroup.chip
    property color foreground: Theme.avatarGroup.foreground
    property string fontFamily: Theme.font.family.sans
    property real initialsShare: Theme.avatarGroup.initials
    property int initialsWeight: Theme.avatarGroup.weight

    readonly property int total: people.length + Math.max(0, more)
    // The faces drawn, and whether a chip counts the rest.
    readonly property int faces: Math.min(people.length, total > 4 ? 3 : 4)
    readonly property bool chipShown: total > faces
    readonly property int places: faces + (chipShown ? 1 : 0)
    readonly property real faceSize: places <= 1 ? size : size * faceShare

    // Each place's top left as a share of the room a face leaves in the
    // box, clockwise from the top left.
    readonly property var layouts: [
        [],
        [[0, 0]],
        [[0, 0], [1, 1]],
        [[0.5, 0], [1, 1], [0, 1]],
        [[0, 0], [1, 0], [1, 1], [0, 1]]
    ]

    implicitWidth: total > 0 ? size : 0
    implicitHeight: implicitWidth

    Repeater {
        model: group.places

        AvatarFace {
            required property int index
            readonly property bool isChip: index >= group.faces
            readonly property var person: isChip ? null : group.people[index]
            x: group.layouts[group.places][index][0] * (group.size - group.faceSize)
            y: group.layouts[group.places][index][1] * (group.size - group.faceSize)
            z: index
            width: group.faceSize
            height: group.faceSize
            image: person !== null && person.image ? person.image : ""
            initials: isChip ? "+" + (group.total - group.faces) : person !== null && person.initials ? person.initials : ""
            tint: isChip ? group.chip : person !== null && person.tint ? person.tint : group.tint
            ring: group.ring
            ringWidth: group.places > 1 ? group.ringWidth : 0
            foreground: group.foreground
            fontFamily: group.fontFamily
            fontSize: group.faceSize * group.initialsShare
            fontWeight: group.initialsWeight
        }
    }
}
