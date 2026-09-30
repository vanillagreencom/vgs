.pragma library

// The notifications' own look, the table the manifest's `appearance` names
// and ThemeLogic.acceptAppearance judges. Every value is the Spotlight
// notification stack's (px13 dotfiles, method.notifications Service.qml,
// components/NotificationCard.qml and InboxHeader.qml, spotlight/Theme.qml,
// GlassSurface.qml, EdgeLight.qml, PillButton.qml and Switch.qml, and
// hooks/theme-set.d/spotlight-menu-tokens.sh), with each Omarchy style value
// the reference read stated as the value it resolved to there: Style.space(n)
// is n at the default spacing scale, Style.gapsOut is 5, the font sizes are
// the Style.font steps at the 12 px base (bodySmall 11, title 14) and the
// subtitle role is caption plus one, 11. The theme's foreground the hook
// wrote is the hook's own neutral here. The active theme reaches this table
// through two inputs alone, `palette.accent` and `motion.scale`, plus its
// `scheme.mode`, which applies LIGHT; no other theme value can.

function color(value) { return { type: "color", value: value }; }
function length(value) { return { type: "length", value: value }; }
function duration(value) { return { type: "duration", value: value }; }
function family(value) { return { type: "family", value: value }; }
function weight(value) { return { type: "weight", value: value }; }
function number(value, min, max) { return { type: "number", value: value, min: min, max: max }; }
function share(value) { return number(value, 0, 1); }
// A signed pixel offset, such as a shadow's negative spread.
function offset(value) { return number(value, -512, 512); }
// A wait that is not an animation, in milliseconds, so motion.scale leaves it.
function wait(value) { return number(value, 0, 10000); }
// One cubic bezier's two control points, as Easing.BezierSpline reads them.
function curve(x1, y1, x2, y2) { return { x1: share(x1), y1: share(y1), x2: share(x2), y2: share(y2) }; }
// The foreground at one alpha: every tint the glass draws over its fill.
function ink(alpha) { return color("alpha({text.foreground}, " + alpha + ")"); }

var TOKENS = {
    // The theme's accent replaces this default. It lights the edge
    // reflection of a critical notification and the Silence switch while on.
    palette: {
        accent: color("#ff5a36")
    },

    motion: {
        scale: number(1, 0, 4),
        // The Material 3 duration scale the reference names, and the delay
        // between rows of a cascade.
        duration: {
            short2: duration(100),
            short3: duration(150),
            short4: duration(200),
            medium1: duration(250),
            medium2: duration(300),
            medium3: duration(350),
            medium4: duration(400),
            long2: duration(500),
            stagger: duration(18)
        },
        curve: {
            standard: curve(0.2, 0, 0, 1),
            standardDecel: curve(0, 0, 0, 1),
            emphasizedDecel: curve(0.05, 0.7, 0.1, 1),
            emphasizedAccel: curve(0.3, 0, 0.8, 0.15)
        },
        // How many rows of a panel cascade carry their own delay, and the
        // wait after the last row fades before the rows go.
        staggerRows: number(10, 0, 64),
        settle: wait(40)
    },

    font: {
        family: family("Liberation Sans")
    },

    text: {
        // The hook's own neutral for a dark theme.
        foreground: color("#e8e8e8"),
        // A 1 px shadow under a title lifts it off the glass: the header's,
        // and the summary's, which the card draws a shade lighter.
        shadow: color("alpha(#000000, 0.45)"),
        summaryShadow: color("alpha(#000000, 0.4)"),
        title: { size: length(14), weight: weight(700) },
        // The subtitle is the inbox header's count, chrome at the 11 px
        // floor. The body's colour is the foreground at the subtitle's
        // opacity, so an image inline in the body draws at full strength.
        subtitle: { size: length(11), opacity: share(0.5), color: color("alpha({text.foreground}, {text.subtitle.opacity})") },
        // A card's body: the subtitle's colour at the shell's 13 px reading
        // floor (docs/architecture/design-quality.md), above the
        // reference's 11.
        body: { size: length(13) },
        label: { size: length(11), weight: weight(500), opacity: share(0.7) }
    },

    glass: {
        // The toast fill the hook writes for [notifications].
        base: color("#101010"),
        fill: color("alpha({glass.base}, 0.8)"),
        sheen: ink(0.045),
        sheenEnd: ink(0),
        sheenHeight: length(48),
        hairline: ink(0.09),
        hairlineWidth: length(1),
        // The bead a toast is while it is still a dot: a shade toward the
        // bottom and a specular spot at the top left.
        orbShadeStop: share(0.45),
        orbShade: color("alpha(#000000, 0.35)"),
        orbClear: color("alpha(#000000, 0)"),
        orbSpot: color("alpha(#ffffff, 0.42)"),
        orbSpotEnd: color("alpha(#ffffff, 0)"),
        orbSpotX: share(0.3),
        orbSpotY: share(0.42),
        orbSpotWidth: share(0.46),
        orbSpotHeight: share(0.3),
        orbSpotAngle: offset(-18)
    },

    shadow: {
        color: color("alpha(#000000, 0.45)"),
        blur: length(30),
        offsetY: offset(10),
        spread: offset(-4)
    },

    radius: {
        // Larger than any side, so a corner rounds to a pill or a circle.
        full: length(4096),
        // How far inside a rounded end's curve the corners of text stay.
        clearance: length(4)
    },

    stack: {
        // The stack's gap below the reserved space, the room left for the
        // cards' side shadows, and the scroll room under the last card.
        top: length(5),
        pad: length(40),
        tail: length(24),
        bottom: length(12)
    },

    card: {
        width: length(420),
        gap: length(8),
        // The dot a toast morphs from, how far it drops in, how much the
        // landing squashes it and how far a hover lifts it.
        dot: length(34),
        drop: length(14),
        squashWide: share(0.16),
        squashFlat: share(0.14),
        lift: length(2),
        // The space around the card's content, the same above, below and at
        // both ends at every height. The card grows with its text up to
        // maxHeight and no further: the body then shows the whole lines
        // that fit. At maxHeight the capsule's ends are circles of radius
        // maxHeight / 2, and a content corner `pad` in from both edges stays
        // inside them while pad >= (1 - 1/sqrt(2)) / 2 * maxHeight, 13.8
        // for 94; scripts/test-notifications-logic.js holds the table to it.
        pad: length(14),
        maxHeight: length(94),
        // Between the media slot and the text, at either tier.
        gapIcon: length(12),
        // The stroke of the Lucide icon an x-vgs-icon hint names, in pixels.
        glyphStroke: length(2),
        lineGap: length(2),
        summaryLines: number(2, 1, 8),
        panelEnterScale: share(0.97),
        fadeScale: share(0.96),
        exitScale: share(0.3)
    },

    // The slot a card's image, people or application icon sits in, square
    // and `size` wide at each tier NotificationLogic.mediaTier names:
    // `compact` for a card of one line, `regular` for every other. The
    // tier alone places the text, `card.pad + size + card.gapIcon` in, so
    // every card of a tier starts its text at the same x. An image is
    // cropped to the square with corners of `radius`, an application icon
    // is drawn `icon` wide in the middle, a hinted Lucide icon `glyph` wide
    // in the middle, and people fill it as faces.
    // `regular` keeps the reference's 40 px icon slot, the one slot
    // Omarchy's notification card draws every image and icon in
    // (shell/plugins/notifications/components/NotificationCard.qml on
    // quattro, read 2026-09-29); `compact` is 28, so a one-line card with
    // media is 28 plus twice `card.pad` tall.
    media: {
        compact: { size: length(28), icon: length(24), radius: length(6), glyph: length(20) },
        regular: { size: length(40), icon: length(40), radius: length(8), glyph: length(28) }
    },

    // The people a notification names, as faces in the media slot, laid
    // out by the AvatarGroup of qs.Ui: one alone fills the slot; two to
    // four overlap clockwise, each `share` of the slot across, ringed in
    // the glass and laid over the one before it; past four, three faces
    // and a "+N" chip.
    face: {
        share: share(0.6),
        ring: color("{glass.base}"),
        ringWidth: length(2),
        // Every face is opaque, so a face over another cuts it out rather
        // than showing it through. A person's face takes one tint, picked
        // by NotificationLogic.faceTint from the name; the chip is neutral.
        // Each is mixed into the glass, so light mode lightens it and the
        // foreground stays readable on it.
        chip: color("mix({glass.base}, {text.foreground}, 0.26)"),
        tint: {
            coral: color("mix({glass.base}, #e8715a, 0.6)"),
            amber: color("mix({glass.base}, #e0a23a, 0.6)"),
            green: color("mix({glass.base}, #5fb36b, 0.6)"),
            blue: color("mix({glass.base}, #4aa3c7, 0.6)"),
            indigo: color("mix({glass.base}, #7a7ee0, 0.6)"),
            magenta: color("mix({glass.base}, #c46fb4, 0.6)"),
            teal: color("mix({glass.base}, #3fb8a6, 0.6)"),
            rose: color("mix({glass.base}, #e06a8c, 0.6)")
        },
        // The initials' size as a share of the face's diameter.
        initials: share(0.42),
        initialsWeight: weight(600)
    },

    // The colour of a hinted icon per x-vgs-tone, one per design-system
    // status tone and each the default theme's `palette` value of the same
    // name; LIGHT darkens them for the pale glass.
    tone: {
        success: color("#b4c96f"),
        warning: color("#ffb000"),
        danger: color("#f43f5e"),
        info: color("#74a7f7")
    },

    // The workspace a summary names, as its small rounded icon before it.
    badge: {
        size: length(16),
        radius: length(4),
        gap: length(6),
        // Under the icon, which covers it.
        fill: ink(0)
    },

    // The hover actions: pills at the right end, over a fade of the glass so
    // the text under them does not collide with them.
    tray: {
        spacing: length(6),
        slide: length(8),
        fadeOverhang: length(6),
        fadeReach: length(56),
        fadeStop: share(0.35),
        fadeStart: color("alpha({glass.base}, 0)"),
        fadeEnd: color("alpha({glass.base}, 0.9)")
    },

    pill: {
        // Each side's padding around the label.
        padX: length(12),
        height: length(28),
        pressed: ink(0.16),
        hover: ink(0.11),
        emphasized: ink(0.07),
        rest: ink(0.045),
        border: ink(0.1),
        borderRest: ink(0.06),
        borderWidth: length(1),
        pressScale: share(0.95),
        idle: share(0.8)
    },

    toggle: {
        width: length(36),
        height: length(20),
        // The height the toggle takes a press over, the pills' height, so
        // it lines up with them and a press beside the track still lands.
        hitHeight: length(28),
        track: ink(0.12),
        border: ink(0.08),
        borderWidth: length(1),
        inset: length(2),
        knob: color("#ffffff"),
        knobShadow: color("alpha(#000000, 0.22)"),
        knobShadowGrow: length(2),
        knobShadowDrop: length(1),
        pressScale: share(0.9)
    },

    header: {
        width: length(420),
        height: length(48),
        gap: length(4),
        drop: length(10),
        lineGap: length(1),
        controlsInset: length(10),
        controlsGap: length(8),
        labelGap: length(7)
    },

    // The slim bar a scrolling stack shows in its side room, as the
    // launcher's list does: thin at rest, wide under the pointer.
    scrollbar: {
        width: length(12),
        gap: length(4),
        minHeight: length(24),
        thin: length(3),
        wide: length(6),
        idle: share(0.14),
        moving: share(0.35),
        active: share(0.45)
    },

    // Two point lights orbit just outside a card and its edge reflects them.
    // The neutral is the reference's grey, the foreground's luminance times
    // 1.08: 0.9098 * 1.08 = 0.9826 of white, #fbfbfb.
    edge: {
        neutral: color("#fbfbfb"),
        thickness: number(1.25, 0, 16),
        reach: number(125, 0, 2000),
        lift: number(18, 0, 512),
        speed: number(95, 0, 2000),
        strengthA: number(1.25, 0, 8),
        strengthB: number(0.7, 0, 8),
        base: share(0.1),
        // While a toast is a dot its lights whirl and glow brighter, and a
        // hover brightens them: extra orbits per second, and the boosts.
        spin: number(2.4, 0, 16),
        orbBoost: number(0.9, 0, 8),
        hoverBoost: number(0.45, 0, 8)
    }
};

// Light mode: the hook's light toast and neutral, and the reference's light
// alphas. The grey is 0.1647 * 1.08 = 0.1779 of white, #2d2d2d.
var LIGHT = {
    text: {
        foreground: "#2a2a2a",
        shadow: "alpha(#000000, 0.08)"
    },
    glass: {
        base: "#f2f2f2",
        fill: "alpha({glass.base}, 0.85)",
        sheen: "alpha({text.foreground}, 0.35)",
        hairline: "alpha({text.foreground}, 0.1)"
    },
    shadow: {
        color: "alpha(#000000, 0.16)"
    },
    edge: {
        neutral: "#2d2d2d"
    },
    tone: {
        success: "mix(#b4c96f, #2a2a2a, 0.35)",
        warning: "mix(#ffb000, #2a2a2a, 0.3)",
        danger: "mix(#f43f5e, #2a2a2a, 0.15)",
        info: "mix(#74a7f7, #2a2a2a, 0.3)"
    }
};
