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
  version: "0.3.0"
tags: [plugins, quickshell]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# vgs-plugin

Write a plugin for the v2 shell. The contract is [`docs/architecture/plugins.md`](../../../docs/architecture/plugins.md); this skill holds the steps, the scaffold command and the templates.

```bash
.agents/skills/vgs-plugin/scripts/vgs-plugin new acme.weather --kinds bar-widget,service
.agents/skills/vgs-plugin/scripts/vgs-plugin check shell/plugins/acme.weather
```

## Rules

- One directory, one `manifest.json` at its root, one QML entry point per kind. Copy the templates. The field table is [`docs/architecture/plugins.md` § Manifest](../../../docs/architecture/plugins.md#manifest); an unknown key is refused.
- Declare surfaces, never dependencies.
- Imports and names: the allowed table in [`references/api.md`](references/api.md) § Allowed imports, and nothing else. `scripts/check-plugin-boundary.py` refuses the rest.
- Every entry point declares `property var shell: null`. Capabilities come from `shell.<name>` after naming them in `capabilities`; a widget never reads them from `bar`.
- Settings default in the manifest's `settings` and arrive as `shell.settings` for every kind; a bar widget also reads them with `setting(name, fallback)`. A change reaches the running instance as a new `shell`; hold no copy.
- A bar widget extends `BarWidget` from `qs.Ui`, sets `moduleName` to the plugin id, and sizes itself with `implicitWidth` and `implicitHeight`.
- A bar declares `leftSection`, `centerSection` and `rightSection`. The core mounts every plugin widget; a widget the bar draws itself registers through `shell.builtins`.
- Colours and sizes come from `Color` and `Style` in `qs.Commons`.
- One owner per timer, watcher, poller and subprocess, inside the entry point's tree. A `Process` gets its stdout parser before it starts.
- No cache keyed by data other applications supply without a ceiling.
- Every Quickshell type, property and signal comes from the 0.3.1 reference on Context7: `ctx7 docs /websites/quickshell_v0_3_1 <query>`.
- Land with `scripts/validate manifests`, `scripts/validate boundary` and `scripts/validate qml` clean, the last with the rows [`workflows/new-plugin.md`](workflows/new-plugin.md) step 8 names.

## Workflows

| Workflow | Trigger |
|----------|---------|
| [`workflows/new-plugin.md`](workflows/new-plugin.md) | Creating a plugin from nothing |
| [`workflows/review-plugin.md`](workflows/review-plugin.md) | Reviewing or changing an existing plugin |

## References

- [`references/api.md`](references/api.md): what a plugin receives and may call, per kind.
- [`templates/`](templates/): `manifest.json.tmpl`, `BarWidget.qml`, `Service.qml`, `Panel.qml`, `Bar.qml`, `Background.qml`.
