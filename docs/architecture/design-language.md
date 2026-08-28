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
| `defaultControlRadius` | 10 | 7 | Buttons, chips, rows |
| `Appearance.rounding.small` | 8 | 6 | |
| `Appearance.rounding.normal` | 12 | 8 | `StyledRect` default |
| `Appearance.rounding.large` | 16 | 11 | |
| `Appearance.rounding.extraLarge` | 24 | 14 | |

Radius is the single highest-leverage change: it propagates through the ~260
files that consume `Theme.controlRadius` / `Theme.cornerRadius` /
`Appearance.rounding.*` — count them with
`grep -rlE 'Theme\.(controlRadius|cornerRadius)|Appearance\.rounding\.' quickshell/vshell | wc -l`
rather than trusting the number here.

## Borders (quiet hairlines)

Flatline is **fill-first**: contrast comes from fill/wash and typography; the 1px border, where present, defines the edge rather than the contrast:

- `Theme.borderColor` — compact-card/content hairline and control resting edge; kept low,
  so it reads as surface, not ring.
- `Theme.borderColorStrong` — emphasis / focused edge: full `outline`, the one border that
  may be visible.
- `Theme.outlineMedium` / `outlineLight` — translucent variants for glass layers.

New:

- `Theme.focusRing` — accent ring color for keyboard focus (`primary` @ 0.55).
- `Theme.focusRingWidth` — 2.
- `Theme.separatorColor` — 1px separator for lists/dividers (`outline` blend @ low alpha).

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

- **Primary button**: solid `primary` fill, `primaryText`, medium weight, 36–40px height, `controlRadius`; keyboard focus draws `focusRing`.
- **Settings choice**: label on the left, dropdown on the right. Single-choice settings do not use segmented controls; true multi-select settings use checkbox options and report the selected count.
- **Secondary button**: `buttonBg` text link, no fill/border, underline on hover.
  Inline rows space links and preceding filled buttons equally; input-field actions omit it; danger may override `textColor`.
- **Ghost / nav row**: no border, transparent, subtle hover/active wash.
- **Text input**: transparent with a 1px underline; idle text is dim, focused text brightens, and trailing actions sit inside the line.
- **Cards**: `surfaceContainer` (or content surface) + `containerRadius`; large settings cards use fill only, while compact cards may use a quiet `borderColor` hairline.
- **Row alignment**: shared row components own their height and vertically center mixed-height labels, icons, switches, and actions; callers do not add optical offsets.

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
| Compact card/control border | `Theme.borderColor` (emphasis: `borderColorStrong`) |
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
chips/tiles/rows; `width/2` (`Appearance.rounding.full`) **only** for true
circles/pills (avatars, media transport, status dots). Fill-first: a card is
`surfaceContainer*` + the fill step; the 1px `borderColor` hairline only defines the edge.

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
  `elevationLevel1..5` alphas are cut ~40% so surfaces lean on fill steps and
  quiet edges, not drop-shadows. Elevation remains for wallpaper-backed surfaces — just
  quieted. Still user-tunable via `SettingsData.m3Elevation*`.
- **Fill-only large cards** — `SettingsCard` has no resting border; its fill sits a
  step above the reading pane. Compact toggle/slider cards keep the quiet hairline.
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

## Popout surfaces are screen-tall (and frosted)

Every dropdown's layer surface is anchored **top and bottom**, so the compositor
sizes its HEIGHT to the output and a content resize never reaches the
compositor; the popup body is positioned and animated inside it
(`Widgets/VgsPopoutStandalone.qml`, `contentContainer`). Only the height axis is
pinned — `onAlignedWidthChanged` still commits `implicitWidth` and the left
margin, harmless only because no popout animates its width.

That is the fix for the **resize** flash specifically: a surface whose height
tracks its content re-commits wl_surface geometry on every frame of a resize.
Measured before VGS-133, one dropdown took five distinct surface heights across
four in-place height changes; after, one. (`VgsPopoutStandalone.qml` records two
other flashes this does not touch: a shrink whose running animation has its
duration re-evaluated mid-flight, and an entrance overshoot that bounces before
settling.) Never bind a popout window's `implicitHeight` to its content, and add
no per-popout opt-out — two geometry paths is how the two behaviours drifted
apart. Collapsing to one path also made the entrance-morph geometry snap
(`_settlingToOpen`) apply to every popout rather than the two that used to opt
in; that is intended, not an oversight to re-narrow.

Input and dismissal track the body rect, not the surface — the content window's
input region and the background window's dismiss carve-out both do.
`scripts/qml-smoke.sh` (`popout_check`) asserts the height; its degenerate-surface
heuristic is screen-width **and** screen-height together, since screen height
alone is now correct, so do not split that test.

### Frost survives it, but not for the reason the pixels suggest

The blur PASS is not clipped to the painted body. In Hyprland 0.56.2,
`LayerSurface.cpp::onCommit` damages the whole `geomFixed` on every commit, and
`Pass.cpp` builds the blur region from the bounding boxes of live-blur elements
intersected with damage and expanded by the blur radius. What clips the RESULT is
`ignore_alpha`, which `OpenGL.cpp::renderTextureWithBlurInternal` turns into a
`DISCARD_ALPHA` stencil discarding the already-blurred texture wherever the
surface is transparent. A screen-tall dropdown therefore blurs its whole column
and then throws most of it away.

The pixels agree: measured over a noise wallpaper, detail outside the popup body
was unchanged to within 0.0% where blurring the same frame end to end drops it
98%, and it held with `ignore_alpha` forced to 0. The result is confined; the
cost is not.

So the allowlist criterion is about AREA, not paint: a namespace belongs in
`blurred_namespaces` (`bin/vshell-helper::_hyprland_blur_script`) when its whole
surface rectangle is an acceptable per-frame live-blur region. Three families
stay out, and only the first is about size:

- **Whole-output painters** — the wallpaper layer (`vshell:blurwallpaper`),
  overview overlays (`vshell:workspace-overview`), `vshell:screensaver`.
- **The popouts' own `:background` dismiss windows** — structurally unmatchable
  rather than merely unlisted: the pattern is `$`-anchored, so
  `vshell:control-center:background` cannot match, and the plugins arm is
  `[^:]+` for the same reason.
- **Backdrop-less by design** — context and tray menus, `VgsOSD`, `VgsSlideout`.
  They pass `blurAvailable: false` and have no backdrop to blur (§ Tooltips
  above). Adding them would restyle surfaces nobody asked to change.

`scripts/check-vshell-helper.py::test_hyprland_blur_script` enforces this —
exact allowlist membership plus a match/no-match table over namespaces real
surfaces declare — so the list and this section cannot drift apart quietly.

Two facts a reader cannot see from the QML:

- The rule emits `xray = false`, which makes `Renderer.cpp` take the per-frame
  LIVE dual-kawase path instead of the precomputed `m_blurFB`.
- `BlurService.backgroundEffectEnabled` is false whenever the Hyprland layer
  backend is present, so `WindowBlur`'s tight `blurX`/`blurY`/`blurWidth`/
  `blurHeight` region never bounds cost there; the layer rule does all of it.

Cost of going screen-tall, measured on this workstation (Ryzen 9 9950X, RTX 5090,
6016x3384 + 5120x2880 at scale 2, Hyprland 0.56.2): per-commit damage for a
formerly content-sized dropdown grew 6.70x (454x241 -> 454x1610) while opening and
closing, with zero steady-state cost and no throughput regression (1038 vs 1043
commits/s). That headroom is hardware-specific; re-measure before assuming it on
weaker hardware.

## In-surface pager (settings behind a page, not below the content)

A popout that grows a settings section downward pushes the thing you opened it
for off the bottom. Flatline's answer is a **pager**: the secondary view is a
page beside the current one, and the surface slides to it. Defined here because
the aiUsage popout is the first to need one (VGS-73) — follow this shape rather
than inventing a second one.

The form:

- **Two pages side by side in a clipped viewport.** A `Row` of full-width
  `Column`s inside an `Item` with `clip: true`; `x: -page * viewport.width` is
  the whole navigation model. Page 0 is the content the surface is *for*.
- **The viewport takes the height of the page that is showing**, animated. The
  surface grows *to* the settings page, not *by* it, so leaving the pager never
  costs the height it took.
- **Motion**: `mediumDuration` / `Easing.OutCubic` for the slide, `shortDuration`
  for the height. Slower than a hover, quick enough not to be a transition you
  wait through.
- **The disclosure control is also the back control.** `PopoutComponent`'s
  header has a title on the left and actions on the right, and no left-hand
  slot; a back chevron on the left would mean changing that shared component
  for every plugin. So the action that pushed the page becomes the one that
  pops it — icon `tune` → `arrow_back`, in place. The pointer is already there.
- **The header follows the page.** `headerText` and `detailsText` describe the
  page you are on, which is what makes the slide read as navigation rather than
  as content moving.
- **A pushed page is view state, and resets when the surface hides.** Reopening
  a popout on a settings page hides the thing it was opened for. Never persist
  it.

- **Escape pops one level; every other dismissal closes outright.** Keyboard
  focus belongs to `PluginPopout`'s container, above the plugin content, so a
  plugin cannot intercept Escape itself. It declares a pushed page instead and
  the container routes to it:

  | Member | Meaning |
  |--------|---------|
  | `canPopBack` | there is a pushed page to return from |
  | `popBack()` | return **one** level |

  Two members on the content root, no key handler (VGS-88). Content that
  declares neither behaves exactly as it did before. Escape falls through to
  closing the surface when nothing is pushed.

  The close button, a click outside, and the bar pill toggling all close the
  surface outright from any depth. Those gestures aim at the whole popout, and
  popping instead would trap the user — a second gesture to leave what one
  gesture asked to dismiss. Escape is the only gesture whose conventional
  meaning is "back one step", which is why it is the only one routed inward.

  `PluginPopout` also pops the content to page 0 on dismissal, whichever route
  closed it. That is what makes "a pushed page is view state" true in general
  rather than per plugin, so a pager must not implement its own reset.

Worked example: `config/vshell/plugins/aiUsage/AiUsageWidget.qml` (`pager`,
`pages`, `usagePage`, `settingsPage`, and `canPopBack`/`popBack` beside them).

## Where to look

| Concern | File |
|---------|------|
| Form tokens, colors, elevation | `Common/Theme.qml` |
| Rounding / spacing / motion scales | `Common/Appearance.qml` |
| Buttons, inputs, toggles, chips, tabs | `Widgets/Vgs*.qml` |
| Tooltips | `Widgets/VgsTooltip.qml`, `Widgets/VgsInlineTooltip.qml`, shared body in `Widgets/Tooltip/` |
| Popout surface geometry and frost | `Widgets/VgsPopoutStandalone.qml`, blur allowlist in `bin/vshell-helper` |
| Settings shell + nav | `Modals/Settings/*` |
| Shared launcher panels | `Widgets/Launcher/*` |
| niri overview search | `Modules/WorkspaceOverlays/OverviewSearch/*` |
