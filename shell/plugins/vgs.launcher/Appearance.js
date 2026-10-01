.pragma library

// The launcher's own look, the table the manifest's `appearance` names and
// ThemeLogic.acceptAppearance judges. Every value here is the Spotlight
// launcher's (px13 dotfiles, spotlight/Theme.qml, the method.menu Menu.qml
// literals and hooks/theme-set.d/spotlight-menu-tokens.sh), with each
// Omarchy style value the reference read stated as the value it resolved to
// there: Style.space(n) is n at the default spacing scale, and the font
// sizes are the Style.font steps at the 12 px base (caption 10, bodySmall
// 11, body 12, heading 16). The active theme reaches this table through
// two inputs alone, `palette.accent` and `motion.scale`, plus its
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
    // The theme's accent replaces this default; it lights the moving edge
    // reflection and the caret while a search runs.
    palette: {
        accent: color("#ff5a36")
    },

    motion: {
        scale: number(1, 0, 4),
        // The Material 3 duration scale the reference names, and the
        // caret blink's two holds.
        duration: {
            short2: duration(100),
            short3: duration(150),
            short4: duration(200),
            medium1: duration(250),
            medium2: duration(300),
            medium4: duration(400),
            long2: duration(500),
            stagger: duration(18),
            caretHold: duration(600),
            caretGap: duration(320)
        },
        curve: {
            standard: curve(0.2, 0, 0, 1),
            emphasizedDecel: curve(0.05, 0.7, 0.1, 1),
            emphasizedAccel: curve(0.3, 0, 0.8, 0.15)
        },
        // How long rows stay "new" after a rebuild, and the file search's
        // debounce.
        freshReset: wait(120),
        debounce: wait(45)
    },

    // The bundled mono family, the design the reference's JetBrainsMono
    // Nerd Font draws.
    font: {
        family: family("JetBrains Mono")
    },

    text: {
        // The hook's own neutral for a dark theme.
        foreground: color("#e8e8e8"),
        shadow: color("alpha(#000000, 0.45)"),
        header: { size: length(18), letterSpacing: offset(-0.2), idle: share(0.38) },
        label: { size: length(16), weight: weight(500), rest: share(0.86) },
        // A row's detail line and the empty list's message are reading
        // text, at the shell's 13 px floor; the flyout's entries and their
        // detail are chrome, at the 12 px floor
        // (docs/architecture/design-quality.md § Type).
        detail: { size: length(13), opacity: share(0.5) },
        empty: { size: length(13), opacity: share(0.38) },
        flyout: { size: length(12), detail: length(12) }
    },

    glass: {
        fill: color("alpha(#151515, 0.78)"),
        sheen: ink(0.045),
        sheenEnd: ink(0),
        sheenHeight: length(48),
        hairline: ink(0.09),
        hairlineWidth: length(1),
        divider: ink(0.07)
    },

    shadow: {
        wide: { color: color("alpha(#000000, 0.55)"), blur: length(90), offsetY: offset(28), spread: offset(-4) },
        tight: { color: color("alpha(#000000, 0.45)"), blur: length(30), offsetY: offset(10), spread: offset(-4) }
    },

    radius: {
        sm: length(8),
        md: length(12),
        // Larger than any side, so a corner rounds to a pill or a circle.
        full: length(4096)
    },

    card: {
        width: length(640),
        // Half the header plus the padding, 17 + 18: the bare search field
        // is a pill.
        radius: length(35),
        padding: length(18),
        gap: length(36),
        // The card's top line and its tallest height, as shares of the
        // screen, and its margin from the screen edge: the shell's window
        // gutter, so a narrow monitor keeps a frame around the card.
        top: share(0.2),
        tallest: share(0.6),
        margin: length(12),
        enterScale: share(0.965),
        exitScale: share(0.98),
        lift: length(10)
    },

    header: {
        height: length(34),
        glyphInset: length(10),
        textGap: length(12),
        textInset: length(10),
        buttonInset: length(2),
        // round(gap / 2) - 1, the hairline's place in the gap.
        dividerOffset: length(17)
    },

    search: {
        size: length(18),
        stroke: number(1.7, 0, 8),
        idle: share(0.45),
        active: share(0.75)
    },

    caret: {
        width: length(2),
        height: number(1.2, 0, 4),
        gap: length(1),
        rest: length(4),
        halo: color("alpha({palette.accent}, 0.18)"),
        haloIdle: ink(0.18)
    },

    button: {
        size: length(32),
        pressed: ink(0.14),
        hover: ink(0.09),
        checked: ink(0.06),
        rest: ink(0),
        border: ink(0.07),
        borderRest: ink(0),
        borderWidth: length(1),
        pressScale: share(0.9)
    },

    menuGlyph: {
        size: length(16),
        bar: number(1.6, 0, 8),
        gap: length(3),
        short: share(0.62),
        idle: share(0.55),
        active: share(0.95)
    },

    row: {
        height: length(50),
        detailHeight: length(58),
        spacing: length(4),
        // The tile's side inset equals its top inset, (50 - 30) / 2, and
        // the chevron keeps the same inset from the plate's other edge.
        iconInset: length(10),
        textGap: length(12),
        textInset: length(16),
        textRight: length(10),
        lineGap: length(2),
        enterX: length(18),
        enterY: length(6),
        staggerRows: number(8, 0, 64),
        dividerInset: length(4)
    },

    tile: {
        size: length(30),
        radius: length(9),
        glyph: length(15),
        stroke: number(1.5, 0, 8),
        top: ink(0.07),
        topActive: ink(0.12),
        bottom: ink(0.0315),
        bottomActive: ink(0.0615),
        border: ink(0.07),
        borderActive: ink(0.11),
        borderWidth: length(1),
        rest: share(0.82)
    },

    chevron: {
        width: length(7),
        height: length(12),
        stroke: number(1.5, 0, 8),
        inset: length(10),
        length: share(0.62),
        spread: share(0.21),
        idle: share(0.28),
        active: share(0.6)
    },

    highlight: {
        plate: ink(0.095),
        border: ink(0.09),
        sheen: ink(0.035),
        sheenEnd: ink(0),
        sheenStop: share(0.6),
        borderWidth: length(1)
    },

    scrollbar: {
        width: length(12),
        minHeight: length(24),
        thin: length(3),
        wide: length(6),
        idle: share(0.14),
        moving: share(0.35),
        active: share(0.45)
    },

    flyout: {
        width: length(240),
        padding: length(6),
        radius: length(16),
        rowHeight: length(34),
        separatorHeight: length(9),
        separatorInset: length(12),
        iconInset: length(8),
        iconSize: length(18),
        iconGap: length(9),
        textInset: length(10),
        detailGap: length(6),
        margin: length(8),
        openScale: share(0.94)
    },

    // Two point lights orbit just outside the card and its edge reflects
    // them. The neutral is the reference's grey, the foreground's luminance
    // times 1.08: 0.9098 * 1.08 = 0.9826 of white, #fbfbfb.
    edge: {
        neutral: color("#fbfbfb"),
        thickness: number(1.25, 0, 16),
        reach: number(170, 0, 2000),
        lift: number(26, 0, 512),
        speed: number(95, 0, 2000),
        strengthA: number(1.25, 0, 8),
        strengthB: number(0.7, 0, 8),
        base: share(0.1)
    }
};

// Light mode: the hook's light glass and neutral, and the reference's light
// alphas. The grey is 0.1647 * 1.08 = 0.1779 of white, #2d2d2d.
var LIGHT = {
    text: {
        foreground: "#2a2a2a",
        shadow: "alpha(#000000, 0.08)"
    },
    glass: {
        fill: "alpha(#efefef, 0.8)",
        sheen: "alpha({text.foreground}, 0.35)",
        hairline: "alpha({text.foreground}, 0.1)",
        divider: "alpha({text.foreground}, 0.08)"
    },
    shadow: {
        wide: { color: "alpha(#000000, 0.2)" },
        tight: { color: "alpha(#000000, 0.16)" }
    },
    tile: {
        top: "alpha({text.foreground}, 0.06)",
        topActive: "alpha({text.foreground}, 0.11)",
        bottom: "alpha({text.foreground}, 0.027)",
        bottomActive: "alpha({text.foreground}, 0.057)"
    },
    highlight: {
        plate: "alpha({text.foreground}, 0.08)"
    },
    edge: {
        neutral: "#2d2d2d"
    }
};
