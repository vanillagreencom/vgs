# VGS design language — "Flatline" (shadcn / Vercel inspired)

This document describes the shell-wide visual language introduced in the
`redesign/shadcn-vercel` work. Read it before touching primitives in `Widgets/`,
the token facade (`Common/Theme.qml`, `Common/Appearance.qml`), or the flagship
surfaces (Settings, Launcher).

## Intent

Move the shell from a **Material 3 Expressive** look (tonal container fills,
large radii, ripples + state layers, drop-shadow elevation) toward a
**shadcn / Vercel** look: quiet neutral surfaces, hairline borders, tight
radii, restrained motion, clear typographic hierarchy, and generous whitespace.

Non-goals — things we deliberately did **not** change:

- **The color engine.** Palettes are still generated per-wallpaper by the theme
  engine (`bin/vshell-helper` → `theme.json`). "Flatline" is about *form*, so it
  rides on whatever accent/neutral palette the active theme provides. A neutral
  zinc/slate palette is a *theme* choice, not a UI-language choice.
- **Elevation, entirely.** Floating surfaces sit over the wallpaper, not a solid
  page, so shadows still carry the figure/ground separation shadcn gets from a
  flat background. Elevation is toned down and paired with crisp borders, not
  removed. It remains user-tunable (`SettingsData.m3Elevation*`).
- **User preferences.** Radius/elevation/ripple/animation remain configurable.
  Flatline only changes the *defaults* (the values used when the user has not
  overridden surface geometry).

## Form tokens

All of these live in `Common/Theme.qml` unless noted.

| Token | Old | New | Notes |
|-------|-----|-----|-------|
| `maxSurfaceRadius` | 20 | 14 | Ceiling for window/surface radius |
| `defaultContainerRadius` | 15 | 10 | Cards, popouts, modals |
| `defaultControlRadius` | 10 | 7 | Buttons, inputs, chips, rows |
| `Appearance.rounding.small` | 8 | 6 | |
| `Appearance.rounding.normal` | 12 | 8 | `StyledRect` default |
| `Appearance.rounding.large` | 16 | 11 | |
| `Appearance.rounding.extraLarge` | 24 | 14 | |

Radius is the single highest-leverage change: it propagates through the ~393
files that consume `Theme.controlRadius` / `Theme.cornerRadius` /
`Appearance.rounding.*`.

## Borders (the shadcn signature)

Flatline is **border-forward**. Surfaces read as figure via a 1px hairline, not
(only) a shadow. Existing tokens already model this; use them:

- `Theme.borderColor` — default hairline for cards/content surfaces.
- `Theme.borderColorStrong` — emphasis / focused container edge.
- `Theme.outlineMedium` / `outlineLight` — translucent variants for glass layers.

New:

- `Theme.focusRing` — accent ring color for keyboard focus (`primary` @ 0.55).
- `Theme.focusRingWidth` — 2.
- `Theme.hairline` — opaque 1px separator for lists/dividers (`outline` @ low alpha).

## Motion

shadcn motion is quick and subtle. Keep the existing duration tokens (short
150ms is already correct). The un-shadcn element is the **ripple** — retained
globally (user preference `enableRippleEffects`) but **not used** in redesigned
navigation/list surfaces, which use a hover/active background wash instead.

## Typography

- Body / control label: `fontSizeMedium` (14), `Font.Medium`.
- Group headers in navigation: **small, uppercase, letter-spaced, muted**
  (`fontSizeSmall - 1`, `Font.DemiBold`, `surfaceVariantText`) — replaces the
  old bold, full-size, ripple-backed category rows.
- Section (card) titles: `fontWeightSectionHeader` (DemiBold).
- Secondary/description text: `surfaceTextSecondary` / `surfaceVariantText`.

## Surfaces & buttons

- **Primary button**: solid `primary` fill, `primaryText`, medium weight, 36–40px
  height, `controlRadius`. Keyboard focus draws `focusRing`.
- **Secondary button**: transparent fill, 1px `secondaryOutline` border, hover
  wash — a shadcn "outline" button. (`variant: "secondary"`.)
- **Ghost / nav row**: no border, transparent, subtle hover/active wash.
- **Cards**: `surfaceContainer` (or content surface) + 1px `borderColor`,
  `containerRadius`, minimal or no shadow inside the settings reading pane.

## Settings layout

The old sidebar was a collapsible-accordion tree with bold category rows,
ripples, guide-rails, and glass fills. Flatline replaces it with a **flat,
always-visible grouped nav** (Vercel/Linear style):

- Static small-caps muted group labels; child rows are flat, quiet, with a subtle
  active pill (`surfaceSelected` wash + `surfaceText`, optional 2px accent bar).
- Hairline separators between groups; no per-row ripple.
- The reading pane keeps its near-opaque background for legibility and lays
  content out on a centered max-width column with consistent card rhythm.

See `Modals/Settings/SettingsSidebar.qml` and `SettingsContent.qml`.

## Element polish rubric

Apply this to every surface. The goal is that nothing is hand-tuned in
isolation — each element pulls from the same tokens and scales so the shell
reads as one system.

### 1. Colors map to semantic tokens — never hardcode

No raw hex / fixed `Qt.rgba` for themable surfaces, text, or accents. Map intent
to a token so the wallpaper-dynamic palette drives everything:

| Intent | Token |
|--------|-------|
| Window / base | `Theme.background`, `Theme.surface` |
| Card / container | `Theme.surfaceContainer`, `surfaceContainerHigh` |
| Nested row/tile on a card | `Theme.elevatedRowColor` / `surfaceContainerHighest` |
| Card border (hairline) | `Theme.borderColor` (emphasis: `borderColorStrong`) |
| Divider / separator | `Theme.separatorColor` |
| Primary text | `Theme.surfaceText` |
| Secondary text | `Theme.surfaceTextMedium` (≈0.7) |
| Tertiary / hint text | `Theme.surfaceTextSecondary` / `surfaceVariantText` |
| Input hint / placeholder | `Theme.inputHintFor(fieldBackground)` (`inputHintText` for the standard field surface) |
| Accent | `Theme.primary` (+ `primaryText` on top of it) |
| Error/warn/info/success | `Theme.error` / `warning` / `info` / `success` (+ `*Container`) |

The only legitimate literals are pure black/white used *with alpha* for glass
rims, sheens, and shadow scrims (`withAlpha("#ffffff", …)`), which are
material effects, not palette colors.

### 2. Interactive state scale (use consistently)

| State | Neutral control | Accented control |
|-------|-----------------|------------------|
| Rest | `transparent` / `surfaceContainer` | `primary` |
| Hover | `Theme.surfaceHover` | `Theme.primaryHover` |
| Pressed | `Theme.surfacePressed` | `Theme.primaryPressed` |
| Selected / active | `Theme.surfaceSelected` | `Theme.primary` (fill) |
| Focus (keyboard) | `Theme.focusRing` ring @ `focusRingWidth` | same |
| Disabled | `opacity: 0.4` (or text `withAlpha(surfaceText, 0.38)`) | same |

**`surfaceHover`/`surfacePressed`/`surfaceSelected` are translucent overlays,
not fills.** They are ~8–15% washes of `surfaceVariant`, sized to sit on a
control that is **transparent at rest** (ghost rows, nav items, list entries):

```qml
color: hovered ? Theme.surfaceHover : "transparent"   // correct
```

Assigning one to a control that is **opaque at rest** replaces its fill with an
8% wash, so the element goes see-through on hover instead of lighting up:

```qml
color: hovered ? Theme.surfaceHover : Theme.surfaceContainer   // WRONG
color: hovered ? Theme.hoverOn(Theme.surfaceContainer)
                : Theme.surfaceContainer                        // correct
```

`Theme.hoverOn(base)` / `pressedOn(base)` / `selectedOn(base)` return a solid
colour for an opaque base. Use them for cards, filled rows, and anything that
already has a fill.

They tint toward `surfaceText` (the Material "state layer" model), **not**
toward `surfaceVariant`. `surfaceVariant` only reads as a highlight over the
darker base surfaces; composited onto an already-elevated fill such as
`surfaceContainerHighest` it is a near-invisible *darkening* — the opposite of
what hover should do. Tinting toward the on-surface colour always moves away
from the fill: lighter on dark themes, darker on light ones. On the default
dark palette the ramp is `#2c2c43` → `#393a51` → `#404158` → `#44465e`.

**Toggle** (`VgsToggle`) canonical states — match these anywhere a switch is
hand-rolled: on → `primary` track + `primaryText` thumb; off → `surfaceVariantAlpha`
track + `surface` thumb; disabled → `surfaceText`@0.12 track, muted thumb.

### 3. Typography

Only these sizes: `fontSizeSmall` 12 / `fontSizeMedium` 14 / `fontSizeLarge` 16 /
`fontSizeXLarge` 20. Weights: body `Normal`; control labels & active nav
`Medium`; card/section titles `fontWeightSectionHeader` (DemiBold); nav group
headers small-caps DemiBold `surfaceVariantText` with `letterSpacing: 0.6`.
Descriptions/subtitles one step down in size **and** color.

### 4. Spacing — even by default

Use only the spacing scale: `spacingXXS` 2 / `XS` 4 / `S` 8 / `M` 12 / `L` 16 /
`XL` 24. Rules:

- **Even insets:** a container's padding is equal on all four sides unless there's
  a real reason (e.g. an optical adjustment for a trailing control). Prefer
  `anchors.margins`/`padding` over per-side margins when they're meant to match.
- Card inner padding: `spacingL` (16), or `popoutPadding` (20) for popouts/modals.
- Row content inset: `spacingM` (12). Gaps between sibling rows: `spacingXXS`–`S`.
- Section gaps (group → group): `spacingXL` (24) above a header, tight below.
- Icon↔label gap: `spacingS` (8). Label↔description gap: `spacingXXS` (2).

### 5. Radii & borders

`containerRadius` (10) for cards/popouts/modals; `controlRadius` (7) for buttons/
inputs/chips/tiles/rows; `width/2` (`Appearance.rounding.full`) **only** for true
circles/pills (avatars, media transport, status dots). Border-forward: a card is
`surfaceContainer*` + 1px `borderColor`, not a shadow alone.

## Bold calibration (neutral surfaces, flat elevation, cards)

After the initial (deliberately restrained) pass read too subtle, the language
was pushed bolder. These are the knobs:

- **Neutral surfaces** — `MethodTheme._neutral()` desaturates the neutral
  surface family (background, surface, containers, outline) toward
  luminance-matched gray so surfaces read on a calmer shadcn-ish base, while
  accent (primary/secondary) and status colors keep full chroma. Intensity is a
  single knob, `flatlineNeutralAmount`. **Tuned to 0.12** — a light touch that
  keeps the theme's hue; 0.6+ read too grey / detached from the palette. This is
  the dial to turn if surfaces feel too colorful or too washed-out.
- **Flatter elevation** — shadow alphas (`shadowMedium`/`shadowStrong`) and the
  `elevationLevel1..5` alphas are cut ~40% so surfaces lean on borders, not
  drop-shadows. Elevation is not removed (surfaces float over wallpaper) — just
  quieted. Still user-tunable via `SettingsData.m3Elevation*`.
- **Border-forward cards** — `SettingsCard`/`SettingsToggleCard`/
  `SettingsSliderCard` carry a 1px `borderColor` hairline (the shadcn card
  signature) over a fill kept a step above the reading pane, so cards read in
  both glass and no-glass modes. Propagates to all ~131 settings cards.
- **Bolder titles** — `fontWeightSectionHeader` is `Font.Bold`.
- **Card rhythm** — inter-card gap in settings tabs is `spacingXL` (24).

Popout/CC/Dash cards are bespoke (no shared component); they inherit the neutral
+ flat-elevation + type language but were not individually given borders.

## Tooltips

One look, two hosts. Both render `Widgets/Tooltip/TooltipBody.qml`, so a tooltip
is the same object visually wherever it appears; what differs is only how it is
put on screen, and that is forced by Wayland rather than chosen.

| Use | When | Anchoring |
|-----|------|-----------|
| `VgsTooltip` | The surface is too small to contain a tooltip: bar widgets, the dock, bundled plugin pills | Its own `WlrLayershell` Overlay surface. Caller passes **screen-absolute** coordinates plus `targetScreen` |
| `VgsInlineTooltip` | The content sits in a window large enough to hold its own tooltip: Settings and Changelog (`FloatingWindow`), and the Dash / Control Center / Notification Center popouts | A `Popup` in the host window's `contentItem`. Caller passes the **anchor item**; the side is picked from the room available |

**Neither can do the other's job**, which is why both exist:

- A bar is a layer surface roughly one widget tall. An in-window `Popup` is
  clamped inside its window, so a tooltip below a bar pill would be squeezed
  into the strip. Being a separate surface also stops the tooltip stealing
  pointer/hover from the pill it describes.
- A `FloatingWindow` is an XDG toplevel, and **a Wayland client cannot learn
  where its own toplevel sits on screen**. `VgsTooltip`'s screen-absolute
  anchoring is therefore not computable for anything inside Settings or the
  Changelog.

So: pick by the host window, not by what nearby code happens to use. If you are
writing a bar/dock/plugin widget you want `VgsTooltip`; anywhere else you want
`VgsInlineTooltip`, and usually you want neither directly — `StateLayer` and
`VgsActionButton` already expose `tooltipText` / `tooltipSide` and handle the
hover delay for you.

`Widgets/Tooltip/` is not part of the `qs.Widgets` surface; it holds the shared
body only, and consumers should never import it.

The one thing the shared body cannot infer is whether it has a backdrop, so each
host declares it. `VgsTooltip` passes `blurAvailable: true` — its `WindowBlur` is
a real backdrop. `VgsInlineTooltip` passes `false`: a `Popup` blurs nothing
behind itself, and glass over nothing reads as a translucent surface floating on
a hard edge. This is the same call every other backdrop-less surface makes
(context menus, `VgsOSD`, `VgsSlideout`). Any future host of `TooltipBody` has to
answer the same question — it is not safe to inherit the default.

Reveal delays are owned by the caller and are **not** currently uniform —
`StateLayer` waits 400 ms, the dock and the plugin pills 250 ms. That predates
the convergence and is left alone deliberately: changing it is a behaviour
change, not a design-language one.

## Where to look

| Concern | File |
|---------|------|
| Form tokens, colors, elevation | `Common/Theme.qml` |
| Rounding / spacing / motion scales | `Common/Appearance.qml` |
| Buttons, inputs, toggles, chips, tabs | `Widgets/Vgs*.qml` |
| Tooltips | `Widgets/VgsTooltip.qml`, `Widgets/VgsInlineTooltip.qml`, shared body in `Widgets/Tooltip/` |
| Settings shell + nav | `Modals/Settings/*` |
| Launcher | `Modals/Launcher/*` |
