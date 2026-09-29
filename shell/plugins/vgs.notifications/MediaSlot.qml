import QtQuick
import Quickshell.Widgets
import qs.Ui
import "NotificationLogic.js" as Logic

// The one slot a card's media sits in: a square the size of its tier's
// `look.media` entry, whatever the media, so the text after it starts at
// the same x on every card of that tier. `kind` names what it draws:
// `faces`, the people `names` holds through the AvatarGroup of qs.Ui, one
// person as a circle that fills the slot; `thumbnail`, the image `source`
// cropped to the square with the tier's corner radius; `icon`, the
// application icon `source` drawn at the tier's icon size in the middle;
// `glyph`, the Lucide icon `glyph` names at the tier's glyph size in
// `glyphColor`, the x-vgs-icon hint's.
Item {
    id: slot

    required property var look
    property string tier: "regular"
    property string kind: ""
    property string source: ""
    // The people, the count past them, one image per person where the
    // sender's cache knows one, and the image the notification carries,
    // which the first face shows when no per-person image is known.
    property var names: []
    property int more: 0
    property var images: []
    property string carried: ""
    property string glyph: ""
    property color glyphColor: look.text.foreground
    readonly property var spec: look.media[tier]
    // False while the image or icon the slot draws failed to load, so the
    // card leaves the slot out.
    readonly property bool drawable: kind === "faces" || (kind === "thumbnail" && thumbnail.status !== Image.Error) || (kind === "icon" && icon.status !== Image.Error) || (kind === "glyph" && glyphIcon.paths[0] !== "")

    function imageFor(index) {
        if (index < images.length && images[index] !== "") return images[index];
        return index === 0 ? carried : "";
    }

    implicitWidth: spec.size
    implicitHeight: spec.size

    AvatarGroup {
        visible: slot.kind === "faces"
        size: slot.spec.size
        people: slot.kind === "faces" ? slot.names.map((name, i) => ({ image: slot.imageFor(i), initials: Logic.initialsOf(name), tint: slot.look.face.tint[Logic.faceTint(name)] })) : []
        more: slot.kind === "faces" ? slot.more : 0
        faceShare: slot.look.face.share
        ringWidth: slot.look.face.ringWidth
        ring: slot.look.face.ring
        tint: slot.look.face.chip
        chip: slot.look.face.chip
        foreground: slot.look.text.foreground
        fontFamily: slot.look.font.family
        initialsShare: slot.look.face.initials
        initialsWeight: slot.look.face.initialsWeight
    }

    ClippingRectangle {
        anchors.fill: parent
        visible: slot.kind === "thumbnail"
        radius: slot.spec.radius
        color: "transparent"

        Image {
            id: thumbnail
            anchors.fill: parent
            source: slot.kind === "thumbnail" ? slot.source : ""
            sourceSize.width: slot.spec.size * Screen.devicePixelRatio
            sourceSize.height: slot.spec.size * Screen.devicePixelRatio
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            smooth: true
        }
    }

    Image {
        id: icon
        anchors.centerIn: parent
        width: slot.spec.icon
        height: slot.spec.icon
        visible: slot.kind === "icon"
        source: slot.kind === "icon" ? slot.source : ""
        sourceSize.width: slot.spec.icon * Screen.devicePixelRatio
        sourceSize.height: slot.spec.icon * Screen.devicePixelRatio
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
    }

    Icon {
        id: glyphIcon
        anchors.centerIn: parent
        visible: slot.kind === "glyph"
        name: slot.kind === "glyph" ? slot.glyph : ""
        size: slot.spec.glyph
        stroke: slot.look.card.glyphStroke
        color: slot.glyphColor
    }
}
