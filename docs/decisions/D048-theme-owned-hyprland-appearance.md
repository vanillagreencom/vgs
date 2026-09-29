# D048: Themes own bounded Hyprland appearance groups through manifest switches

[← Decision Index](INDEX.md)

**Date**: 2026-09-29
**Status**: Active
**Research**: VGS-585
**Refines**: [D015](D015-tokens-are-a-judged-table.md), [D028](D028-one-generated-hyprland-layer.md)

**Context**: A theme already sets Hyprland border colours through the generated layer. It did not set border thickness, window corners, grouped-window tab corners or motion. The owner needed theme packages to carry those values without taking over layout, gaps, blur strength, opacity, cursor, fonts or user keybinds.

**Decision**: Theme documents gain a top-level `hyprland` token group. The generated Hyprland layer writes three fixed appearance groups in this order: `borders`, `radius`, `motion`.

- `borders` writes the existing border colours, `general.border_size` and `decoration.shadow.color`. Shadow colour follows the palette. Shadow enabled state and shadow size stay the user's.
- `radius` writes `decoration.rounding`, `decoration.rounding_power`, `group.groupbar.rounding` and `group.groupbar.gradient_rounding`.
- `motion` writes one VGS preset, `none`, `snappy` or `smooth`, for window, layer, workspace and fade animation leaves. `global` and `border` stay the user's.

The `vgs.themes` manifest declares three Settings switches: window borders default on, corner radius default on, and window animations default off. Its `hyprland.appearance` object maps each appearance group to the boolean schema key that controls it. The manifest judge accepts only the fixed group names, only boolean schema keys and only a plugin with capability `theme`.

The core does not name `vgs.themes`. Among enabled plugin sections that declare `hyprland.appearance`, the first plugin by id owns the switches. Later declarations are reported as Hyprland problems and ignored. If no enabled plugin declares a group, the core defaults apply: borders on, radius on and motion off.

**Rationale**:

- A manifest declaration keeps the core's plugin boundary intact. The boundary check rejects core literals that name a `vgs.*` plugin id.
- A core `shell.json` key would need bespoke Settings UI. Manifest schema already draws plugin settings, per [D032](D032-settings-plugin-and-manifest-settings-convention.md).
- Hyprland window radius is its own token, `hyprland.window.radius`, with default `{radius.md}`. Panels and windows match by default, and a theme can separate them. The token is bounded from 0 to 32 because Hyprland accepts large rounding values but desktop windows above that range stop reading as the shell's medium panel radius.
- Grouped-window tabs use the window radius times the highest Hyprland monitor scale, bounded 0 to 20. Hyprland scales window corners per monitor but not group bar tabs, so one generated tab value must fit the highest-scale monitor.
- Motion presets keep raw bezier text out of theme files. The theme chooses a judged enum, and the core formats numbers and names every curve with a `vgs` prefix so a user curve cannot collide with it.
- `motion.scale` multiplies Hyprland speeds. A scale of 0 acts as `none`.

## Motion presets

| Preset | Effect |
|---|---|
| `none` | Writes `animations.enabled = false`. |
| `snappy` | Uses short VGS curves and shorter speeds for windows, layers, fades and workspaces. |
| `smooth` | Uses Omarchy's default `easeOutQuint`, `almostLinear`, `quick` and `linear` curves and its window, layer and fade speeds. VGS differs by enabling a workspace leaf in the preset, while Omarchy disables workspace animation. |

## Omarchy comparison

Checked against basecamp/omarchy `b421b1b`.

| Omarchy | VGS | Difference |
|---|---|---|
| `default/hypr/looknfeel.lua` sets border size, default animations and curves directly in Lua. | VGS renders judged theme tokens through one generated layer. | VGS keeps theme files as data, not Lua code. |
| `themes/solitude/hyprland.lua` sets raw Lua border colours plus `rounding = 6` and `rounding_power = 3`. | VGS packages set `hyprland.window.radius` and `hyprland.window.roundingPower` tokens. | VGS refuses unknown keys and out-of-range values before Lua is written. |
| Omarchy owns the user's Hyprland configuration order. | VGS owns one include line loaded first. | A user's setting after the include still wins. |

## What stays the user's

Gaps, layouts, blur amount, opacity, cursor theme and size, fonts, global animation defaults, border animation, shadow enabled state and shadow size stay outside the theme tokens.

**Revisit When**: A second compositor is supported, Hyprland drops Lua appearance functions used by the layer, or a theme must set layout-affecting values.

**Verification**: `scripts/test-theme-logic.js` covers the tokens, bounded lengths and refused unknown `hyprland` keys. `scripts/test-hyprland-layer.js` covers manifest `hyprland.appearance`, owner resolution, group switches, section order, radius scaling and motion presets. `scripts/smoke/rows/hyprland.sh` reads `border_size`, `rounding`, animations and `configerrors` from the nested compositor.

**References**: [D015](D015-tokens-are-a-judged-table.md), [D028](D028-one-generated-hyprland-layer.md), [D032](D032-settings-plugin-and-manifest-settings-convention.md), [hyprland.md](../architecture/hyprland.md), [design-system.md](../architecture/design-system.md)
