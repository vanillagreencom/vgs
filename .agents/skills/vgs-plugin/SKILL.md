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
  version: "0.2.0"
tags: [plugins, quickshell]
---

# vgs-plugin

Write a plugin for the v2 shell. The contract is [`docs/architecture/plugins.md`](../../../docs/architecture/plugins.md); this skill holds the steps, the scaffold command and the templates.

```bash
.agents/skills/vgs-plugin/scripts/vgs-plugin new acme.weather --kinds bar-widget,service
.agents/skills/vgs-plugin/scripts/vgs-plugin check shell/plugins/acme.weather
```

## Rules

- One directory, one `manifest.json` at its root, one QML entry point per kind. Copy the templates.
- Declare surfaces, never dependencies. A `requires` key is refused.
- Imports and names: the allowed table in [`references/api.md`](references/api.md) § Allowed imports, and nothing else. `scripts/check-plugin-boundary.py` refuses the rest.
- Every entry point declares `property var shell: null`. Capabilities come from `shell.<name>` after naming them in `vgs.capabilities`; a widget never reads them from `bar`.
- A bar widget extends `BarWidget` from `qs.Ui`, sets `moduleName` to the plugin id, sizes itself with `implicitWidth` and `implicitHeight`, and reads settings with `setting(name, fallback)`.
- A bar builds widgets only through `shell.widgets.create` and `shell.widgets.destroy`.
- Colours and sizes come from `Color` and `Style` in `qs.Commons`.
- One owner per timer, watcher, poller and subprocess, inside the entry point's tree. A `Process` gets its stdout parser before it starts.
- No cache keyed by data other applications supply without a ceiling.
- Every Quickshell type, property and signal comes from the 0.3.1 reference on Context7: `ctx7 docs /websites/quickshell_v0_3_1 <query>`.
- Land with `scripts/validate manifests`, `scripts/validate boundary` and `scripts/validate qml` clean, the last with a row in `scripts/qml-smoke.sh` that asserts the plugin appears in `built`.

## Workflows

| Workflow | Trigger |
|----------|---------|
| [`workflows/new-plugin.md`](workflows/new-plugin.md) | Creating a plugin from nothing |
| [`workflows/review-plugin.md`](workflows/review-plugin.md) | Reviewing or changing an existing plugin |

## References

- [`references/api.md`](references/api.md): what a plugin receives and may call, per kind.
- [`templates/`](templates/): `manifest.json.tmpl`, `BarWidget.qml`, `Service.qml`, `Panel.qml`, `Bar.qml`.
