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

// One button variant: its fill, the text on it, the hover and pressed
// fills moved from that fill, and its outline. `path` is the variant's own
// path, so a theme that sets one fill keeps every value derived from it.
function variant(path, background, fontWeight, hoverToward, pressedToward) {
    return {
        background: color(background),
        foreground: color("contrast({" + path + ".background})"),
        hover: color("mix({" + path + ".background}, {" + hoverToward + "}, 0.12)"),
        pressed: color("mix({" + path + ".background}, {" + pressedToward + "}, 0.24)"),
        border: color("{" + path + ".background}"),
        weight: weight(fontWeight)
    };
}

// One badge tone: a faint fill of the role with the role as its text.
function tone(role) {
    return { background: color("{color." + role + "Subtle}"), foreground: color("{color." + role + "}") };
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
        code: role(0.92, 400, 0, 1.4, false, "text"),
        // Bar chrome. The reference, plugins.omarchy.org (stylesheet read
        // 2026-09-27), sets chrome in mono at 12 to 13 px with line height
        // 1; 0.92 of the 13 px base is 12 px. A line height of 1 makes the
        // line box the font's own height, so centring the box centres the
        // glyphs.
        bar: role(0.92, 500, 0.02, 1, false, "text")
    },

    surface: {
        radius: length("{radius.md}"),
        border: length("{border.thin}"),
        padding: length("{space.lg}"),
        level: {
            base: { background: color("{color.surface}"), border: color("{color.border}") },
            raised: { background: color("{color.surfaceRaised}"), border: color("{color.borderStrong}") },
            sunken: { background: color("{color.surfaceSunken}"), border: color("{color.borderSubtle}") }
        }
    },

    divider: {
        thickness: length("{border.thin}"),
        color: color("{color.border}")
    },

    focusRing: {
        width: length("{border.thick}"),
        offset: length(2),
        radius: length("{radius.sm}"),
        color: color("{color.focus}")
    },

    button: {
        radius: length("{radius.md}"),
        border: length("{border.thin}"),
        paddingX: length("{space.md}"),
        gap: length("{space.xs}"),
        variant: {
            primary: variant("button.variant.primary", "{color.accent}", 700, "palette.foreground", "palette.background"),
            secondary: variant("button.variant.secondary", "{color.inverse}", 500, "palette.background", "palette.background"),
            tertiary: merge(variant("button.variant.tertiary", "{color.surface}", 500, "palette.foreground", "palette.foreground"), {
                foreground: color("{color.text}"),
                border: color("{color.border}")
            }),
            ghost: merge(variant("button.variant.ghost", "alpha({palette.background}, 0)", 500, "palette.foreground", "palette.foreground"), {
                foreground: color("{color.text}"),
                hover: color("{color.surfaceHover}"),
                pressed: color("{color.surfaceRaised}"),
                border: color("alpha({palette.background}, 0)")
            }),
            danger: variant("button.variant.danger", "{color.danger}", 600, "palette.foreground", "palette.background")
        },
        checked: {
            background: color("{color.accentSubtle}"),
            foreground: color("{color.accent}"),
            border: color("{color.accent}")
        }
    },

    segmented: {
        height: length("{size.control.md}"),
        radius: length("{radius.sm}"),
        padding: length("{space.xxs}"),
        gap: length("{space.xxs}"),
        background: color("{color.surfaceSunken}"),
        border: color("{color.border}"),
        foreground: color("{color.textMuted}"),
        selected: color("{color.surfaceRaised}"),
        selectedForeground: color("{color.text}")
    },

    toggle: {
        width: length(36),
        height: length(20),
        inset: length("{space.xxs}"),
        radius: length("{radius.full}"),
        on: color("{color.accent}"),
        off: color("{color.borderStrong}"),
        knobOn: color("contrast({toggle.on})"),
        knobOff: color("contrast({toggle.off})"),
        gap: length("{space.sm}")
    },

    checkbox: {
        size: length("{icon.size.md}"),
        radius: length("{radius.sm}"),
        border: length("{border.thin}"),
        background: color("{color.surfaceSunken}"),
        borderColor: color("{color.borderStrong}"),
        checked: color("{color.accent}"),
        mark: color("contrast({checkbox.checked})"),
        gap: length("{space.sm}")
    },

    radio: {
        size: length("{icon.size.md}"),
        border: length("{border.thin}"),
        background: color("{color.surfaceSunken}"),
        borderColor: color("{color.borderStrong}"),
        checked: color("{color.accent}"),
        dot: length(6),
        gap: length("{space.sm}")
    },

    slider: {
        track: length(4),
        handle: length(14),
        radius: length("{radius.full}"),
        trackColor: color("{color.borderStrong}"),
        fill: color("{color.accent}"),
        handleColor: color("{color.text}"),
        handleBorder: color("{color.background}")
    },

    textField: {
        height: length("{size.control.md}"),
        radius: length("{radius.sm}"),
        border: length("{border.thin}"),
        paddingX: length("{space.sm}"),
        gap: length("{space.xs}"),
        background: color("{color.surfaceSunken}"),
        borderColor: color("{color.border}"),
        hover: color("{color.borderStrong}"),
        focus: color("{color.focus}"),
        error: color("{color.danger}"),
        placeholder: color("{color.textFaint}"),
        icon: color("{color.textMuted}"),
        selection: color("{color.selection}"),
        selectedText: color("{color.text}")
    },

    field: {
        inline: flag(false),
        labelWidth: length(120),
        gap: length("{space.xxs}")
    },

    spinner: {
        size: length("{icon.size.md}"),
        stroke: number("{icon.stroke}", 0.5, 4),
        color: color("{color.accent}"),
        track: color("{color.border}"),
        duration: duration(900)
    },

    progress: {
        height: length("{space.xs}"),
        radius: length("{radius.full}"),
        track: color("{color.border}"),
        fill: color("{color.accent}"),
        indeterminateShare: share(0.3),
        duration: duration(1200)
    },

    badge: {
        height: length(20),
        radius: length("{radius.sm}"),
        paddingX: length("{space.xs}"),
        tone: {
            neutral: { background: color("{color.surfaceRaised}"), foreground: color("{color.textMuted}") },
            accent: tone("accent"),
            success: tone("success"),
            warning: tone("warning"),
            danger: tone("danger"),
            info: tone("info")
        }
    },

    kbd: {
        radius: length("{radius.sm}"),
        border: length("{border.thin}"),
        paddingX: length("{space.xxs}"),
        background: color("{color.surfaceRaised}"),
        borderColor: color("{color.borderStrong}"),
        foreground: color("{color.textMuted}")
    },

    tabs: {
        height: length("{size.control.md}"),
        gap: length("{space.md}"),
        indicator: length("{border.thick}"),
        indicatorColor: color("{color.accent}"),
        foreground: color("{color.textMuted}"),
        active: color("{color.text}"),
        border: color("{color.border}")
    },

    listItem: {
        height: length("{size.control.lg}"),
        paddingX: length("{space.sm}"),
        gap: length("{space.sm}"),
        radius: length("{radius.sm}"),
        hover: color("{color.surfaceHover}"),
        selected: color("{color.accentSubtle}"),
        selectedForeground: color("{color.accent}")
    },

    sectionHeader: {
        paddingTop: length("{space.md}"),
        paddingBottom: length("{space.xs}")
    },

    popover: {
        radius: length("{radius.md}"),
        padding: length("{space.md}"),
        gap: length("{space.xs}"),
        background: color("{color.surfaceRaised}"),
        border: color("{color.borderStrong}")
    },

    tooltip: {
        delay: number(500, 0, 5000),
        radius: length("{radius.sm}"),
        paddingX: length("{space.sm}"),
        paddingY: length("{space.xxs}"),
        gap: length("{space.xs}"),
        background: color("{color.inverse}"),
        foreground: color("contrast({tooltip.background})")
    },

    menu: {
        minWidth: length(160),
        radius: length("{radius.md}"),
        padding: length("{space.xxs}"),
        gap: length("{space.xs}"),
        background: color("{color.surfaceRaised}"),
        border: color("{color.borderStrong}"),
        item: {
            height: length("{size.control.md}"),
            paddingX: length("{space.sm}"),
            radius: length("{radius.sm}"),
            hover: color("{color.surfaceHover}"),
            foreground: color("{color.text}"),
            shortcut: color("{color.textFaint}")
        }
    },

    select: {
        maxHeight: length(280),
        gap: length("{space.xs}"),
        highlight: color("{color.surfaceHover}"),
        selected: color("{color.accentSubtle}"),
        selectedForeground: color("{color.accent}")
    },

    toast: {
        width: length("{size.panel.md}"),
        margin: length("{space.lg}"),
        gap: length("{space.sm}"),
        padding: length("{space.md}"),
        radius: length("{radius.md}"),
        duration: number(5000, 0, 60000),
        corner: { type: "choice", value: "top-right", options: ["top-left", "top-right", "bottom-left", "bottom-right"] },
        background: color("{color.surfaceRaised}"),
        border: color("{color.borderStrong}")
    },

    scrollArea: {
        barWidth: length("{space.xs}"),
        barRadius: length("{radius.full}"),
        bar: color("{color.borderStrong}"),
        barHover: color("{color.textFaint}")
    },

    bar: {
        height: length(26),
        background: color("{color.background}"),
        foreground: color("{color.text}"),
        active: color("{color.accent}"),
        onActive: color("contrast({bar.active})"),
        gap: length("{space.md}"),
        padding: length("{space.lg}"),
        // One item of the bar, such as a workspace pill: its horizontal
        // padding, the gap between items of one widget, and its corner.
        item: {
            paddingX: length("{space.sm}"),
            gap: length("{space.xs}"),
            radius: length("{radius.sm}")
        }
    }
};
