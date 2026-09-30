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
function length(value, min, max) {
    var out = { type: "length", value: value };
    if (min !== undefined) out.min = min;
    if (max !== undefined) out.max = max;
    return out;
}
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

// One typography role. `face` is `sans` or `mono`, the family of `font.family`
// the role draws in. `letterSpacing` is in em; Label multiplies it by the
// size, because QML takes letter spacing in pixels.
function role(face, sizeFactor, fontWeight, letterSpacing, lineHeight, uppercase, colorRole) {
    return {
        family: family("{font.family." + face + "}"),
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

// Reading text and tooltips draw in sans; chrome (labels, buttons, key
// caps, code and the bar) draws in mono at 11 to 13 px. The reference rule
// each role is read from is docs/reference/design-values.md § Text roles. A
// `lineHeight` is a multiple of the role's font size, chosen so a
// multi-line role's line box is a multiple of 4 px at the default size.
// Label turns it into a fixed line box unless that would undercut the
// font's own line box.
var TEXT = {
    display: role("sans", 2.27, 700, -0.02, 1.3, false, "textHeading"),
    h1: role("sans", 1.6, 700, -0.01, 1.333, false, "textHeading"),
    h2: role("sans", 1.33, 600, 0, 1.4, false, "textHeading"),
    h3: role("sans", 1.07, 600, 0, 1.5, false, "textHeading"),
    eyebrow: role("mono", 0.73, 700, 0.18, 1, true, "accent"),
    subheading: role("sans", 1.07, 400, 0, 1.75, false, "textMuted"),
    body: role("sans", 1, 400, 0, 1.6, false, "text"),
    bodyStrong: role("sans", 1, 600, 0, 1.6, false, "text"),
    // One line of text in a control's row, a menu entry, a select's
    // choice or a list item: body, hint and code at line height 1, so the
    // row centres its glyphs as it centres its icon and its inline label.
    item: role("sans", 1, 400, 0, 1, false, "text"),
    itemHint: role("sans", 0.87, 400, 0, 1, false, "textFaint"),
    itemCode: role("mono", 0.87, 500, 0, 1, false, "text"),
    label: role("mono", 0.73, 500, 0.08, 1, true, "textMuted"),
    hint: role("sans", 0.87, 400, 0, 1.55, false, "textFaint"),
    tooltip: role("sans", 0.8, 500, 0, 1.333, false, "text"),
    button: role("mono", 0.73, 500, 0.08, 1, true, "text"),
    kbd: role("mono", 0.73, 600, 0.02, 1, false, "text"),
    code: role("mono", 0.87, 500, 0, 1.5, false, "text"),
    bar: role("mono", 0.8, 500, 0.08, 1, true, "text")
};

// The name of one role of `text`, which a theme may point at any other
// role; the options are the roles themselves, never a second list.
function textRole(name) { return { type: "choice", value: name, options: Object.keys(TEXT) }; }

var TOKENS = {
    // Whether the theme is light or dark, stated by the theme and never
    // inferred from its colours. No shell component reads it: it chooses
    // which palette a plugin-owned appearance resolves, as
    // ThemeLogic.acceptAppearance states.
    scheme: {
        mode: { type: "choice", value: "dark", options: ["dark", "light"] }
    },

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
        // The boundary of an input that shows its state by its outline: a
        // checkbox, a radio, a switch's off track and a text field: the
        // raised surface's colour, read from the palette alone, moved
        // halfway toward black or white, whichever the background contrasts
        // with, so the readability judge's 3:1 boundary floor holds on
        // every resting surface.
        borderControl: color("mix(mix({palette.background}, {palette.foreground}, 0.075), contrast({palette.background}), 0.5)"),
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
        },
        // The list motion pattern, ListCursor and ListEntrance in qs.Ui:
        // the cursor travels to a new row and takes its height, fades in
        // and out with the list's cursor, and a row that arrives rises
        // `rise` into place, each of the first `staggerRows` one
        // `stagger` after the row before it.
        list: {
            travel: { duration: duration("{motion.duration.slow}"), easing: easing("{motion.easing.emphasized}") },
            resize: { duration: duration("{motion.duration.slow}"), easing: easing("{motion.easing.standard}") },
            fade: { duration: duration("{motion.duration.normal}"), easing: easing("{motion.easing.standard}") },
            enter: { duration: duration("mul({motion.duration.slow}, 1.2)"), easing: easing("{motion.easing.emphasized}") },
            stagger: duration(18),
            staggerRows: number(8, 0, 64),
            rise: length("{space.sm}")
        }
    },

    hyprland: {
        border: {
            size: length("{border.thick}", 0, 20)
        },
        window: {
            radius: length("{radius.md}", 0, 32),
            roundingPower: number(2, 1, 10)
        },
        motion: {
            preset: { type: "choice", value: "smooth", options: ["none", "snappy", "smooth"] }
        },
        shadow: {
            // Mix toward black before alpha so light themes keep a dark shadow.
            color: color("alpha(mix({palette.background}, #000000, 0.72), 0.55)")
        }
    },

    size: {
        // One-line control heights, Radix Themes' sizes 1, 2 and 3. A row's
        // height is the `row` group's own, so moving a control size never
        // moves list density.
        control: {
            sm: length(24),
            md: length(32),
            lg: length(40)
        },
        panel: {
            sm: length(280),
            md: length(360),
            lg: length(480),
            maxHeight: length(600)
        },
        // A window-like panel centred on its monitor: `width` wide, never
        // closer than `gutter` to either side of a narrower monitor, and
        // `heightShare` of the monitor's height tall.
        window: {
            width: length(600),
            heightShare: share(0.5),
            gutter: length("{space.lg}")
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
        size: length(15),
        family: {
            mono: family("JetBrains Mono"),
            sans: family("Inter Variable")
        }
    },

    text: TEXT,

    // The rhythm every one-line control follows: a button, a text field, a
    // select and a segmented control are `size.control.md` tall, with
    // `paddingX` a side and `gap` between an icon and its text. `sm` and
    // `lg` hold the same two for a button of that size. The values are
    // Radix Themes' button sizes 1, 2 and 3 on the 4 px unit.
    control: {
        paddingX: step(3),
        gap: step(2),
        sm: { paddingX: step(2), gap: step(1) },
        lg: { paddingX: step(4), gap: step(3) }
    },

    // The rhythm of a row that holds controls: a list item, a menu item and
    // a field pad their content `paddingX` a side; a row's inline label is
    // `labelWidth` wide and `gap` from its control; `lineGap` separates a
    // label from the line it names. `height` is a one-line row with a
    // control, `twoLineHeight` one with a secondary line, and
    // `compactHeight` a read-only key/value row that holds text alone.
    // Row density is its own scale, apart from `size.control`.
    row: {
        height: length(36),
        twoLineHeight: length(56),
        compactHeight: length(28),
        paddingX: length("{space.lg}"),
        gap: length("{space.lg}"),
        labelWidth: length(128),
        lineGap: length("{space.xs}")
    },

    inset: {
        window: length("{space.xl}"),
        dialog: length("{space.xl}"),
        popover: length("{space.lg}"),
        panel: length("{space.lg}")
    },

    // The gaps of a body: `row` between rows of one group, `group` between
    // its blocks, `section` before a section, and `inline` between
    // controls side by side in one group, such as a row of buttons.
    stack: {
        row: length("{space.xs}"),
        group: length("{space.lg}"),
        section: length("{space.xxl}"),
        inline: length("{space.md}")
    },

    surface: {
        radius: length("{radius.md}"),
        border: length("{border.thin}"),
        padding: length("{inset.panel}"),
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
        paddingX: length("{control.paddingX}"),
        gap: length("{control.gap}"),
        // Per size: the side padding, the icon-to-text gap and the icon.
        // `md` is the button's own `paddingX` and `gap`.
        size: {
            sm: { paddingX: length("{control.sm.paddingX}"), gap: length("{control.sm.gap}"), icon: length("{icon.size.sm}") },
            md: { paddingX: length("{button.paddingX}"), gap: length("{button.gap}"), icon: length("{icon.size.md}") },
            lg: { paddingX: length("{control.lg.paddingX}"), gap: length("{control.lg.gap}"), icon: length("{icon.size.md}") }
        },
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
            hover: color("alpha({palette.accent}, 0.22)"),
            pressed: color("alpha({palette.accent}, 0.3)"),
            foreground: color("{color.accent}"),
            border: color("{color.accent}")
        }
    },

    segmented: {
        height: length("{size.control.md}"),
        radius: length("{radius.sm}"),
        padding: length("{space.xxs}"),
        paddingX: length("{control.paddingX}"),
        gap: length("{space.xxs}"),
        background: color("{color.surfaceSunken}"),
        border: color("{color.border}"),
        foreground: color("{color.textMuted}"),
        selected: color("{color.surfaceRaised}"),
        selectedForeground: color("{color.text}"),
        hover: color("{color.surfaceHover}"),
        pressed: color("{color.border}")
    },

    toggle: {
        size: {
            sm: { width: length(28), height: length(16) },
            md: { width: length(36), height: length(20) }
        },
        inset: length("{space.xxs}"),
        radius: length("{radius.full}"),
        on: color("{color.accent}"),
        onHover: color("{color.accentHover}"),
        offHover: color("mix({toggle.off}, {palette.foreground}, 0.15)"),
        // The off track: the raised surface's colour moved 46% toward the
        // colour the background contrasts with, then 8% toward black. It
        // holds 3:1 on every resting surface, and in a dark theme it stays
        // dark enough that the knob that contrasts with it best is white.
        off: color("mix(mix(mix({palette.background}, {palette.foreground}, 0.075), contrast({palette.background}), 0.46), #000000, 0.08)"),
        knobOn: color("contrast({toggle.on})"),
        knobOff: color("contrast({toggle.off})"),
        gap: length("{control.gap}")
    },

    checkbox: {
        size: length("{icon.size.md}"),
        radius: length("{radius.sm}"),
        border: length("{border.thin}"),
        background: color("{color.surfaceSunken}"),
        borderColor: color("{color.borderControl}"),
        hoverBorder: color("{color.textFaint}"),
        pressed: color("{color.surfaceHover}"),
        checked: color("{color.accent}"),
        checkedHover: color("{color.accentHover}"),
        mark: color("contrast({checkbox.checked})"),
        gap: length("{control.gap}")
    },

    radio: {
        size: length("{icon.size.md}"),
        border: length("{border.thin}"),
        background: color("{color.surfaceSunken}"),
        borderColor: color("{color.borderControl}"),
        hoverBorder: color("{color.textFaint}"),
        pressed: color("{color.surfaceHover}"),
        checked: color("{color.accent}"),
        checkedHover: color("{color.accentHover}"),
        dot: length(6),
        gap: length("{control.gap}")
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
        paddingX: length("{control.paddingX}"),
        gap: length("{control.gap}"),
        background: color("{color.surfaceSunken}"),
        borderColor: color("{color.borderControl}"),
        hover: color("{color.textFaint}"),
        focus: color("{color.focus}"),
        error: color("{color.danger}"),
        placeholder: color("{color.textFaint}"),
        icon: color("{color.textMuted}"),
        selection: color("{color.selection}"),
        selectedText: color("{color.text}")
    },

    // `paddingX` defaults to zero because a field's label is unboxed text
    // on its container's content edge; a theme may indent field rows by
    // moving it. `gap` stacks the label, the control and the hint;
    // `labelGap` is the gap after an inline label.
    field: {
        inline: flag(false),
        paddingX: length(0),
        labelWidth: length("{row.labelWidth}"),
        labelGap: length("{row.gap}"),
        gap: length("{row.lineGap}")
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

    voiceOrb: {
        size: length(96),
        radius: share(0.28),
        gap: share(0.045),
        stroke: number("{icon.stroke}", 0.5, 4),
        arcStroke: number(0.75, 0.5, 4),
        amplitude: share(0.018),
        waveCount: number(3, 1, 4),
        arcSpan: number(2.4, 0.1, 6.28),
        arcOpacity: share(0.6),
        attack: duration(70),
        release: duration(250),
        period: duration(6000),
        tone: {
            accent: color("{palette.accent}"),
            info: color("{palette.info}"),
            success: color("{palette.success}"),
            warning: color("{palette.warning}"),
            danger: color("{palette.danger}"),
            muted: color("{color.textMuted}")
        }
    },

    badge: {
        radius: length("{radius.sm}"),
        size: {
            sm: { height: length(20), paddingX: length("{space.sm}") },
            md: { height: length("{size.control.sm}"), paddingX: length("{space.md}") }
        },
        gap: length("{space.xs}"),
        tone: {
            // A step above a raised surface, so a neutral chip keeps a
            // fill beside a toned one on every container.
            neutral: { background: color("{color.surfaceHover}"), foreground: color("{color.textMuted}") },
            accent: tone("accent"),
            success: tone("success"),
            warning: tone("warning"),
            danger: tone("danger"),
            info: tone("info")
        }
    },

    // A key cap: `height` tall, `paddingX` a side of its label's optical
    // width, never narrower than it is tall.
    kbd: {
        radius: length("{radius.sm}"),
        border: length("{border.thin}"),
        height: length("{badge.size.sm.height}"),
        paddingX: length("{space.sm}"),
        background: color("{color.surfaceRaised}"),
        borderColor: color("{color.borderStrong}"),
        foreground: color("{color.textMuted}")
    },

    // A command or path shown to copy: its text on a sunken fill, a Copy
    // button at its right edge, and `confirm` the milliseconds the button
    // shows a check mark after a copy.
    codeLine: {
        radius: length("{radius.sm}"),
        border: length("{border.thin}"),
        padding: length("{space.md}"),
        gap: length("{control.gap}"),
        background: color("{color.surfaceSunken}"),
        borderColor: color("{color.borderSubtle}"),
        foreground: color("{color.text}"),
        confirm: number(1500, 0, 10000)
    },

    // People as round faces in a square box `size` wide. One person fills
    // the box. Two to four overlap, clockwise from the top left, each
    // `face` of the box across and ringed `ringWidth` in `ring`; past four,
    // three faces and a `chip` disc that counts the rest. A face without
    // an image shows initials, `initials` of its diameter, on its tint, or
    // on `tint` when it names none.
    avatarGroup: {
        size: length(40),
        face: share(0.6),
        ringWidth: length("{border.thick}"),
        ring: color("{color.surface}"),
        tint: color("{color.surfaceHover}"),
        chip: color("{color.surfaceRaised}"),
        foreground: color("{color.text}"),
        initials: share(0.42),
        weight: weight(600)
    },

    tabs: {
        height: length("{size.control.md}"),
        paddingX: length("{control.paddingX}"),
        gap: length("{space.md}"),
        indicator: length("{border.thick}"),
        indicatorColor: color("{color.accent}"),
        foreground: color("{color.textMuted}"),
        hover: color("mix({color.textMuted}, {color.text}, 0.5)"),
        pressed: color("{color.surfaceHover}"),
        active: color("{color.text}"),
        border: color("{color.border}")
    },

    // `height` is a one-line row's; `twoLineHeight` a row with a
    // secondary line, whose two lines centre on the icon as one block.
    listItem: {
        height: length("{row.height}"),
        twoLineHeight: length("{row.twoLineHeight}"),
        paddingX: length("{row.paddingX}"),
        gap: length("{control.gap}"),
        iconGap: length("{space.lg}"),
        radius: length("{radius.sm}"),
        hover: color("{color.surfaceHover}"),
        pressed: color("{color.border}"),
        selected: color("{color.accentSubtle}"),
        selectedPressed: color("alpha({palette.accent}, 0.24)"),
        selectedForeground: color("{color.accent}")
    },

    sectionHeader: {
        paddingBottom: length("{stack.row}"),
        gap: length("{row.lineGap}")
    },

    iconButton: {
        restOpacity: share(0.6)
    },

    popover: {
        radius: length("{radius.md}"),
        padding: length("{inset.popover}"),
        gap: length("{space.xs}"),
        maxHeightShare: share(0.8),
        background: color("{color.surfaceRaised}"),
        border: color("{color.borderStrong}")
    },

    tooltip: {
        delay: number(500, 0, 5000),
        radius: length("{radius.sm}"),
        paddingX: length("{space.md}"),
        paddingY: length("{space.xs}"),
        gap: length("{space.xs}"),
        // A tooltip wraps its text past `maxWidth`, and never grows past its
        // output less `size.window.gutter` a side.
        maxWidth: length("{size.panel.sm}"),
        background: color("{color.inverse}"),
        foreground: color("contrast({tooltip.background})")
    },

    // `maxHeight` is the height the entries take before the menu scrolls,
    // nine entries; `typeahead` the milliseconds the letters typed to jump
    // to an entry are kept.
    menu: {
        minWidth: length(160),
        maxHeight: length("mul({menu.item.height}, 9)"),
        typeahead: number(1000, 0, 5000),
        radius: length("{radius.md}"),
        // The inset of the entries on every side; the scroll bar sits in
        // the right one, so the entries never move when they overflow.
        padding: length("{space.md}"),
        gap: length("{space.xs}"),
        // A menu never grows wider than `maxWidth`, nor wider than its
        // output less `size.window.gutter` a side; a longer entry elides.
        maxWidth: length("{size.panel.md}"),
        background: color("{color.surfaceRaised}"),
        border: color("{color.borderStrong}"),
        item: {
            height: length("{size.control.md}"),
            paddingX: length("{row.paddingX}"),
            gap: length("{control.gap}"),
            radius: length("{radius.sm}"),
            hover: color("{color.surfaceHover}"),
            pressed: color("{color.border}"),
            foreground: color("{color.text}"),
            shortcut: color("{color.textFaint}"),
            check: color("{color.accent}")
        }
    },

    select: {
        gap: length("{space.xs}"),
        highlight: color("{color.surfaceHover}"),
        selected: color("{color.accentSubtle}"),
        selectedForeground: color("{color.accent}")
    },

    // `gap` separates the toasts of the stack; `contentGap` the icon, the
    // text and the close button of one toast.
    toast: {
        width: length("{size.panel.md}"),
        margin: length("{space.lg}"),
        gap: length("{space.md}"),
        padding: length("{space.md}"),
        contentGap: length("{control.gap}"),
        radius: length("{radius.md}"),
        duration: number(5000, 0, 60000),
        corner: { type: "choice", value: "top-right", options: ["top-left", "top-right", "bottom-left", "bottom-right"] },
        background: color("{color.surfaceRaised}"),
        border: color("{color.borderStrong}")
    },

    // A confirmation card: `gap` separates its title, message, content and
    // row of actions, `actionGap` the actions; `titleRole` and `bodyRole`
    // name the roles of `text` its title and message draw in. `margin` is
    // the gap between the surface a host centres the card in and the edges
    // of the area other layers leave free.
    dialog: {
        width: length("{size.panel.md}"),
        margin: length("{space.lg}"),
        padding: length("{inset.dialog}"),
        gap: length("{stack.group}"),
        actionGap: length("{stack.inline}"),
        maxHeightShare: share(0.8),
        radius: length("{radius.md}"),
        background: color("{color.surfaceRaised}"),
        border: color("{color.borderStrong}"),
        titleRole: textRole("h3"),
        bodyRole: textRole("body")
    },

    // A card whose content is clipped to a parallelogram, its top edge
    // `skew` pixels right of its bottom edge. Its outline is `borderWidth`
    // of `border`, or `selectedBorderWidth` of `selectedBorder` while
    // selected, and `dim` washes the content of a dimmed card.
    angledCard: {
        skew: length(28),
        border: color("{color.borderStrong}"),
        borderWidth: length("{border.thin}"),
        selectedBorder: color("{color.accent}"),
        selectedBorderWidth: length(3),
        dim: color("alpha({palette.background}, 0.42)")
    },

    // A rail of angled cards: one expanded card between slices that
    // overlap each other by `overlap`, every length multiplied by one unit.
    // The unit is the carousel's width over the reference rail, the
    // expanded card plus `referenceSteps` slice steps plus
    // `referenceMargin` a side, or its height over the expanded card's
    // height, whichever is smaller, held between `minScale` and
    // `maxScale`; the two ranges meet at 1, so the clamp never inverts.
    // Cards within `band` slices past the ones shown stay built. The
    // selected card and its neighbours decode at their drawn size in
    // device pixels, the longer side no more than `decodeCap`, and the
    // rail moves over `duration`.
    carousel: {
        expandedWidth: length(768),
        expandedHeight: length(475),
        sliceWidth: length(108),
        sliceHeight: length(432),
        overlap: length(30),
        referenceSteps: number(13, 0, 64),
        referenceMargin: length(20),
        minScale: number(0.35, 0.1, 1),
        maxScale: number(2, 1, 4),
        band: number(2, 0, 16),
        decodeCap: length(4096),
        previewDwell: duration("{motion.duration.slow}"),
        duration: duration("{motion.duration.normal}")
    },

    desktopPreview: {
        referenceWidth: length(1600),
        referenceHeight: length(900),
        barHeight: length(42),
        gap: length("{space.xxl}"),
        terminalWidthShare: share(0.56),
        panelHeightShare: share(0.5),
        shadowOffset: length("{space.sm}"),
        wallpaperDim: share(0.5),
        barOpacity: share(0.86)
    },

    // The embedded bar: `barWidth` thick, `barInset` from the area's edge,
    // inside a `gutter` the content leaves free while it overflows; a thumb
    // never shorter than `minThumb`. It shows while hovered or scrolling
    // and fades to `idleOpacity` `fadeDelay` milliseconds after, over
    // `fade`.
    scrollArea: {
        barWidth: length("{space.xs}"),
        barInset: length("{space.xxs}"),
        gutter: length("mul({space.xs}, 2)"),
        minThumb: length("{size.control.sm}"),
        barRadius: length("{radius.full}"),
        bar: color("{color.borderStrong}"),
        barHover: color("{color.textFaint}"),
        idleOpacity: share(0),
        fadeDelay: number(800, 0, 5000),
        fade: duration("{motion.duration.slow}")
    },

    // A title that opens a menu of choices: its text over an underline
    // `underlineGap` below it, and a caret `gap` after it.
    titleButton: {
        gap: length("{space.xs}"),
        underline: length("{border.thin}"),
        underlineGap: length("{space.xxs}"),
        foreground: color("{color.textHeading}"),
        hover: color("{color.accent}"),
        underlineColor: color("{color.borderStrong}"),
        caret: color("{color.textMuted}")
    },

    bar: {
        height: length(28),
        background: color("{color.background}"),
        foreground: color("{color.text}"),
        active: color("{color.accent}"),
        onActive: color("contrast({bar.active})"),
        gap: length("{space.md}"),
        padding: length("{space.lg}"),
        // One item of the bar, a workspace pill or a widget's BarItem: its
        // height, its horizontal padding, the gap between items of one
        // widget, its icon's size, the gap between that icon and its text,
        // its corner, and its fills under hover and a press.
        item: {
            height: length("{size.control.sm}"),
            paddingX: length("{space.md}"),
            icon: length("{icon.size.md}"),
            gap: length("{space.xs}"),
            iconGap: length("{control.gap}"),
            radius: length("{radius.sm}"),
            hover: color("{color.surfaceHover}"),
            pressed: color("{color.border}")
        }
    }
};
