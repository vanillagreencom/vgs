# D012: Plugin settings surfaces share five type roles, enforced by a guard

[← Decision Index](INDEX.md)

**Date**: 2026-09-07 **Status**: Active **Research**: —

**Context**: Every bundled plugin builds its own settings page. The shell has a settings widget library (`Modules/Settings/Widgets/`: `SettingsCard`, `SettingsToggleRow`, `SettingsDropdownRow`) that already encodes a type hierarchy, but `config/vshell/AGENTS.md` confines plugin imports to `qs.Common`, `qs.Widgets`, `qs.Services` and `qs.Modules.Plugins`, so no plugin can use it. Each page therefore re-states the hierarchy in loose `StyledText` declarations, and the eight of them had drifted: section headers rendered at `Theme.fontSizeSmall` — smaller than the controls they introduced — while control labels sat at `fontSizeMedium`, so a reader could not tell a heading from a label from a caption. Separately, `Theme.isSettingsItem()` walks the parent chain for a `settingsSurface: true` marker that only `Modals/Settings/SettingsContent.qml` declared, so every plugin control silently rendered its description at the non-settings size.

**Decision**: Five roles, named in tokens, for every settings surface under `config/vshell/plugins`:

| Role | Size | Weight | Colour |
|------|------|--------|--------|
| Page title | `Theme.fontSizeLarge` | `Theme.fontWeightSectionHeader` | `Theme.surfaceText` |
| Section header | `Theme.fontSizeMedium` | `Theme.fontWeightSectionHeader` | `Theme.surfaceText` |
| Body / list row | `Theme.settingsFontSize` | — | `Theme.surfaceText` |
| Status line | `Theme.settingsFontSize` | — | a state colour |
| Sub text | `Theme.settingsFontSize` | — | `Theme.surfaceVariantText` |

A **control label** also sits at `fontSizeMedium`, but a settings page never writes one: `VgsToggle` and `VgsDropdown` render their own from their `text` property. Hand-written text at that size is therefore always a heading, which is what lets the guard *require* the header weight there rather than accepting either weight and so enforcing neither. The first version of the guard did accept both, and a heading reverted to `Font.Medium` produced no violation — the exact drift this decision exists to stop.

The smaller tier carries body, list rows, sub text and status lines together, so it is constrained by a closed colour set rather than a single colour: a near-miss such as `Theme.surfaceTextMedium` reads as sub text at a different alpha and is reported. `Theme.fontSizeSmall` is the bar's size and is not a settings role.

`settingsSurface: true` is declared in `Modules/Plugins/PluginSettings.qml`, so every plugin's settings-application page inherits settings typography for free. A page also embedded outside that base — `AiUsageDisplaySettings.qml` in the aiUsage popout, `MercuryPopoutSettings.qml` in mercury's — declares the marker itself, so the same controls cannot render in two typographies depending on which surface opened them.

**Rationale**:

- The alternative was relaxing the plugin import boundary so plugins could use `Modules/Settings/Widgets/`. That boundary exists so a plugin cannot reach into a feature directory, and widening it for typography would have opened the whole tree; D004 set that boundary deliberately. Tokens plus a guard get the consistency without the coupling.
- Roles are enforced rather than documented because eight pages had already drifted while nominally following the same convention. The guard reads the shipped QML, so a ninth plugin cannot start out wrong.
- The marker goes in the shared base rather than in each page: the failure it prevents is a page *forgetting*, and a rule each author must remember is the rule that produced this drift.
- Sub text moves up to `settingsFontSize` (13) rather than the pages moving down to `fontSizeSmall` (12), because 13 is what `VgsToggle` and `VgsDropdown` already render their own descriptions at once the surface is marked. Choosing the other direction would have left every built-in control disagreeing with the prose beside it.
- The guard requires the header weight at `fontSizeMedium` instead of admitting a control-label weight there. A rule that accepts both cannot report either, and the review of this change found exactly that hole before it shipped.

**Revisit When**: The plugin import boundary changes and `Modules/Settings/Widgets/` becomes reachable from a plugin (the guard and the tokens then duplicate what those components already enforce), or a settings surface needs a sixth role — a dense list or a numeric readout — that no existing token expresses.

**Verification**: `scripts/check-settings-type.py` walks every settings surface, resolves each `font.pixelSize` to its enclosing block by brace matching, and reports any size outside the table, any title or header off `fontWeightSectionHeader`, and any colour in the smaller tier outside the closed set. It found a live defect on its first run: cloudSync's detected-rclone line on `Theme.surfaceTextMedium`. `scripts/test-settings-type.py` holds 22 controls over it: one per refused role, the accepted shapes a real page needs (a status line's state colour, a list row dimming through a ternary), the recognition paths (marker, `PluginSettings` root), and the brace-walking hazards a QML reader fails on — a brace inside a string, a brace inside a comment, a commented-out size, and a weight borrowed from a neighbouring block. Root detection is a line scan rather than one pattern, with a control that 400 blank lines complete in under two seconds; the pattern it replaced was flagged `py/redos` by CodeQL and took minutes on 40. It also pins a floor on the number of surfaces recognised, so the guard reporting success because it recognised nothing fails instead.

**References**: D004 (the plugin boundary this decision works within), PR #252.
