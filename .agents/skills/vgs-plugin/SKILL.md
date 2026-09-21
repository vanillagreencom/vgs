---
name: vgs-plugin
description: "Load to create, change or review a v2 shell plugin: a bar widget, a bar, a panel, an overlay, a menu or a service."
summary: "The plugin contract as a checklist, a scaffold command, templates for every kind, and the API a plugin may use."
license: MIT
user-invocable: true
argument-hint: "new <author.name> --kinds <kind,...> | check <dir>"
metadata:
  author: vanillagreen
  source: in-place
  repository: "https://github.com/vanillagreencom/vgs"
  bugs: "https://github.com/vanillagreencom/vgs/issues"
  version: "0.1.0"
tags: [plugins, quickshell]
---

# vgs-plugin

Write a plugin for the v2 shell. The contract is [`docs/architecture/plugins.md`](../../../docs/architecture/plugins.md); this skill turns it into steps, a scaffold and templates so a plugin is right the first time.

```bash
.agents/skills/vgs-plugin/scripts/vgs-plugin new acme.weather --kinds bar-widget,service
.agents/skills/vgs-plugin/scripts/vgs-plugin check shell/plugins/acme.weather
```

## Rules

- One directory, one `manifest.json` at its root, one QML entry point per kind. Copy the templates; do not invent a shape.
- Declare surfaces, never dependencies. A `requires` key is refused. If the surface a kind needs is absent, that kind is not shown and the rest of the plugin still runs.
- Import only `QtQuick`, `Quickshell`, `Quickshell.Io`, `Quickshell.Hyprland`, `Quickshell.Widgets`, `Quickshell.Services.*`, `qs.Commons`, `qs.Ui` and files under your own directory. Never `Quickshell.Wayland`, never `qs.Core`, never another plugin.
- Never create a window. No `PanelWindow`, `FloatingWindow`, `PopupWindow`, `WlSessionLock`. The core owns every surface.
- A bar widget extends `BarWidget` from `qs.Ui`, sets `moduleName` to the plugin id, sizes itself with `implicitWidth` and `implicitHeight`, and reads settings with `setting(name, fallback)`.
- Colours and sizes come from `Color` and `Style` in `qs.Commons`. No literal hex, no literal pixel size outside `Style`.
- An action on the compositor goes through a capability: name it in `vgs.capabilities` and call it as `shell.<capability>`. The list is in [`references/api.md`](references/api.md).
- One owner per timer, watcher, poller and subprocess, and every one of them lives inside your plugin's tree so unload destroys it. A `Process` gets its stdout parser before it starts.
- No cache keyed by data other applications supply without a ceiling.
- Every Quickshell type, property and signal comes from the 0.3.1 reference on Context7: `ctx7 docs /websites/quickshell_v0_3_1 <query>`. Never from memory.
- Land with validation: `scripts/validate manifests boundary` clean, a row in `scripts/qml-smoke.sh` that proves the plugin is built and shown, and no figure in a comment or manifest that a script did not measure.

## Workflows

| Workflow | Trigger |
|----------|---------|
| [`workflows/new-plugin.md`](workflows/new-plugin.md) | Creating a plugin from nothing |
| [`workflows/review-plugin.md`](workflows/review-plugin.md) | Reviewing or changing an existing plugin |

## References

- [`references/api.md`](references/api.md): what a plugin receives and may call, per kind.
- [`templates/`](templates/): `manifest.json.tmpl`, `BarWidget.qml`, `Service.qml`, `Panel.qml`, `Bar.qml`.
