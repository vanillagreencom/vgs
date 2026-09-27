.pragma library

// The token table: every value the shell draws with, its type and its
// default. The defaults are the `vgs` theme. ThemeLogic.js judges a shell
// document against this table and resolves it; the design-system topic under
// docs/architecture states the tiers and the expression grammar.
//
// A value is a literal, a reference `{group.token}`, or one call of `mix`,
// `alpha`, `contrast` or `mul`. A component token derives from its own
// component first, so a theme that sets one fill keeps the text on it
// readable.

function color(value) { return { type: "color", value: value }; }
function length(value) { return { type: "length", value: value }; }
function duration(value) { return { type: "duration", value: value }; }
function family(value) { return { type: "family", value: value }; }
function weight(value) { return { type: "weight", value: value }; }
function flag(value) { return { type: "flag", value: value }; }
function easing(value) { return { type: "easing", value: value }; }
function number(value, min, max) { return { type: "number", value: value, min: min, max: max }; }

// A share of one, such as an opacity.
function share(value) { return number(value, 0, 1); }

// A step of the spacing scale, in units of `space.unit`.
function step(units) { return length("mul({space.unit}, " + units + ")"); }

// A font size, as a multiple of `font.size`.
function scaled(factor) { return length("mul({font.size}, " + factor + ")"); }

// A neutral between the background and the foreground.
function neutral(amount) { return color("mix({palette.background}, {palette.foreground}, " + amount + ")"); }

// A text colour between the foreground and the background.
function faded(amount) { return color("mix({palette.foreground}, {palette.background}, " + amount + ")"); }

// One typography role. `letterSpacing` is in em; Label multiplies it by the
// size, because QML takes letter spacing in pixels.
function role(sizeFactor, fontWeight, letterSpacing, lineHeight, uppercase, colorRole) {
    return {
        family: family("{font.family.mono}"),
        size: scaled(sizeFactor),
        weight: weight(fontWeight),
        letterSpacing: number(letterSpacing, -0.2, 1),
        lineHeight: number(lineHeight, 0.8, 3),
        uppercase: flag(uppercase),
        color: color("{color." + colorRole + "}")
    };
}

// The three colours of one status: the role, the text on it and its faint
// fill.
function status(name) {
    var out = {};
    out[name] = color("{palette." + name + "}");
    out["on" + name[0].toUpperCase() + name.slice(1)] = color("contrast({palette." + name + "})");
    out[name + "Subtle"] = color("alpha({palette." + name + "}, 0.14)");
    return out;
}

function merge() {
    var out = {};
    for (var i = 0; i < arguments.length; i++)
        for (var key in arguments[i])
            out[key] = arguments[i][key];
    return out;
}

var TOKENS = {
    palette: {
        background: color("#000000"),
        foreground: color("#d7d7d9"),
        accent: color("#ff5a36"),
        success: color("#b4c96f"),
        warning: color("#ffb000"),
        danger: color("#f43f5e"),
        info: color("#74a7f7")
    },

    color: merge({
        background: color("{palette.background}"),
        surface: neutral(0.05),
        surfaceRaised: neutral(0.075),
        surfaceSunken: neutral(0.025),
        surfaceHover: neutral(0.11),
        border: neutral(0.19),
        borderStrong: neutral(0.27),
        borderSubtle: neutral(0.13),
        text: color("{palette.foreground}"),
        textHeading: color("mix({palette.foreground}, contrast({palette.background}), 0.55)"),
        textMuted: faded(0.21),
        textFaint: faded(0.42),
        textDisabled: faded(0.6),
        accent: color("{palette.accent}"),
        accentHover: color("mix({palette.accent}, {palette.foreground}, 0.18)"),
        accentPressed: color("mix({palette.accent}, {palette.background}, 0.18)"),
        accentSubtle: color("alpha({palette.accent}, 0.14)"),
        onAccent: color("contrast({palette.accent})"),
        inverse: color("{palette.foreground}"),
        inverseHover: color("mix({palette.foreground}, {palette.background}, 0.12)"),
        onInverse: color("contrast({palette.foreground})"),
        focus: color("{palette.accent}"),
        selection: color("alpha({palette.accent}, 0.35)"),
        scrim: color("alpha({palette.background}, 0.6)")
    }, status("success"), status("warning"), status("danger"), status("info")),

    space: {
        unit: length(4),
        xxs: step(0.5),
        xs: step(1),
        sm: step(1.5),
        md: step(2),
        lg: step(3),
        xl: step(4),
        xxl: step(6),
        xxxl: step(8)
    },

    radius: {
        sm: length(0),
        md: length(0),
        lg: length(0),
        full: length(4096)
    },

    border: {
        thin: length(1),
        thick: length(2)
    },

    opacity: {
        disabled: share(0.5)
    },

    motion: {
        scale: number(1, 0, 4),
        duration: {
            fast: duration(100),
            normal: duration(150),
            slow: duration(250)
        },
        easing: {
            standard: easing("outCubic"),
            emphasized: easing("outQuint")
        }
    },

    size: {
        control: {
            sm: length(24),
            md: length(30),
            lg: length(36)
        },
        panel: {
            sm: length(280),
            md: length(360),
            lg: length(480),
            maxHeight: length(600)
        }
    },

    icon: {
        stroke: number(1.5, 0.5, 4),
        size: {
            xs: length(12),
            sm: length(14),
            md: length(16),
            lg: length(20),
            xl: length(24)
        }
    },

    font: {
        size: length(13),
        family: {
            mono: family("JetBrains Mono"),
            sans: family("{font.family.mono}")
        }
    },

    text: {
        display: role(2.3, 700, -0.02, 1.1, false, "textHeading"),
        h1: role(1.7, 700, -0.01, 1.2, false, "textHeading"),
        h2: role(1.4, 600, 0, 1.25, false, "textHeading"),
        h3: role(1.15, 600, 0, 1.3, false, "textHeading"),
        eyebrow: role(0.85, 600, 0.12, 1.2, true, "accent"),
        subheading: role(1, 400, 0, 1.5, false, "textMuted"),
        body: role(1, 400, 0, 1.45, false, "text"),
        bodyStrong: role(1, 600, 0, 1.45, false, "text"),
        label: role(0.85, 600, 0.08, 1.2, true, "textMuted"),
        hint: role(0.85, 400, 0.01, 1.35, false, "textFaint"),
        tooltip: role(0.85, 500, 0.02, 1.3, false, "text"),
        button: role(0.85, 500, 0.08, 1, true, "text"),
        code: role(0.92, 400, 0, 1.4, false, "text")
    },

    field: {
        labelWidth: length(120)
    },

    bar: {
        height: length(26),
        background: color("{color.background}"),
        foreground: color("{color.text}"),
        active: color("{color.accent}"),
        onActive: color("contrast({bar.active})"),
        gap: length("{space.md}"),
        padding: length("{space.lg}")
    }
};
