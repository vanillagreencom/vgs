# D012: Plugin settings surfaces share five type roles, enforced by a guard

[← Decision Index](INDEX.md)

**Date**: 2026-09-07 **Status**: Active **Research**: —

**Context**: Every bundled plugin builds its own settings page. The shell has a settings widget library (`Modules/Settings/Widgets/`: `SettingsCard`, `SettingsToggleRow`, `SettingsDropdownRow`) that already encodes a type hierarchy, but `config/vshell/AGENTS.md` confines plugin imports to `qs.Common`, `qs.Widgets`, `qs.Services` and `qs.Modules.Plugins`, so no plugin can use it. Each page therefore re-states the hierarchy in loose `StyledText` declarations, and the eight of them had drifted: section headers rendered at `Theme.fontSizeSmall` — smaller than the controls they introduced — while control labels sat at `fontSizeMedium`, so a reader could not tell a heading from a label from a caption. Separately, `Theme.isSettingsItem()` walks the parent chain for a `settingsSurface: true` marker that only `Modals/Settings/SettingsContent.qml` declared, so every plugin control silently rendered its description at the non-settings size.

**Decision**: Five roles, named in tokens, for every settings surface under `config/vshell/plugins`:

| Role | Size | Weight | Colour |
|------|------|--------|--------|
| Page title | `Theme.fontSizeLarge` | `Theme.fontWeightSectionHeader` | `Theme.surfaceText` |
| Section header | `Theme.fontSizeMedium` | `Theme.fontWeightSectionHeader` | `Theme.surfaceText` |
| Control label | `Theme.fontSizeMedium` | `Font.Medium` / `Font.Normal` | `Theme.surfaceText` |
| Body | `Theme.fontSizeMedium` | — | `Theme.surfaceText` |
| Sub text | `Theme.settingsFontSize` | — | `Theme.surfaceVariantText` |

A header and a control label share a size and are separated by **weight**; a label and its sub text share a weight and are separated by **size and colour**. `Theme.fontSizeSmall` is the bar's size and is not a settings role.

`settingsSurface: true` is declared in `Modules/Plugins/PluginSettings.qml`, so every plugin's settings-application page inherits settings typography for free. A page also embedded outside that base — `AiUsageDisplaySettings.qml` in the aiUsage popout, `MercuryPopoutSettings.qml` in mercury's — declares the marker itself, so the same controls cannot render in two typographies depending on which surface opened them.

**Rationale**:

- The alternative was relaxing the plugin import boundary so plugins could use `Modules/Settings/Widgets/`. That boundary exists so a plugin cannot reach into a feature directory, and widening it for typography would have opened the whole tree; D004 set that boundary deliberately. Tokens plus a guard get the consistency without the coupling.
- Roles are enforced rather than documented because eight pages had already drifted while nominally following the same convention. The guard reads the shipped QML, so a ninth plugin cannot start out wrong.
- The marker goes in the shared base rather than in each page: the failure it prevents is a page *forgetting*, and a rule each author must remember is the rule that produced this drift.
- Sub text moves up to `settingsFontSize` (13) rather than the pages moving down to `fontSizeSmall` (12), because 13 is what `VgsToggle` and `VgsDropdown` already render their own descriptions at once the surface is marked. Choosing the other direction would have left every built-in control disagreeing with the prose beside it.

**Revisit When**: The plugin import boundary changes and `Modules/Settings/Widgets/` becomes reachable from a plugin (the guard and the tokens then duplicate what those components already enforce), or a settings surface needs a sixth role — a dense list or a numeric readout — that no existing token expresses.

**Verification**: `scripts/check-settings-type.py` walks every settings surface, resolves each `font.pixelSize` to its enclosing block by brace matching, and reports any size outside the table, any title or header off `fontWeightSectionHeader`, and any sub text off `surfaceVariantText`. `scripts/test-settings-type.py` holds 17 controls over it: one per refused role, plus the recognition paths (marker, `PluginSettings` root) and the brace-walking hazards a QML reader fails on — a brace inside a string, a brace inside a comment, a commented-out size, and a weight borrowed from a neighbouring block. It also pins a floor on the number of surfaces recognised, so the guard reporting success because it recognised nothing fails instead.

**References**: D004 (the plugin boundary this decision works within), PR #252.
