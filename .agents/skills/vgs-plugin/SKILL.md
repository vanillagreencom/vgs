---
name: vgs-plugin
description: "Load to create, change or review a v2 shell plugin: a bar widget, a bar, a panel, an overlay, a menu, a service or a background."
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

VGS delivery policy overrides the shared workflow's mandatory review, CI-wait, branch-size and commit-hook gates. Work targets main. Reviews and PRs are optional; push directly or merge a PR immediately with gh, without a review loop, queue or CI wait. Do not arm git guards. Run scripts/validate once on the final relevant diff; use --changed <last-validated-commit> for a fix round, and reuse passing results while those inputs are unchanged. Do not rerun a full battery at commit, push or submission. Use --full only for an explicit full sweep or an unmapped dependency. Keep the live-session safety rules.

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
- Every entry point declares `property var shell: null` or inherits it from `BarWidget`. Capabilities come from `shell.<name>` after naming them in `capabilities`; a widget never reads them from `bar`.
- Settings default in the manifest's `settings` and arrive as `shell.settings` for every kind; a bar widget also reads them with `setting(name, fallback)`. A change reaches the running instance as a new `shell`; hold no copy.
- A bar widget extends `BarWidget` from `qs.Ui` and sizes itself with `implicitWidth` and `implicitHeight`. The core assigns `bar`, `moduleName` and `settings` after creation; the widget sets none of them.
- A bar declares `leftSection`, `centerSection` and `rightSection`. The core mounts every plugin widget; a widget the bar draws itself registers through `shell.builtins`.
- Compose the components of `qs.Ui` ([`references/api.md` § Components in `qs.Ui`](references/api.md#components-in-qsui)) before drawing anything by hand. Every colour, size, font, radius, opacity and duration reads a token through `Theme` in `qs.Commons`. `scripts/check-design-tokens.py` refuses a `Theme` path that names no token and reports each literal it finds.
- A plugin whose design must look the same under every theme owns its look instead: the manifest's `appearance` names a table of its own, every value is `look.<path>` from `Theme.appearance(TOKENS, LIGHT)`, and the theme reaches it through its mode, accent and motion scale alone. [`docs/architecture/appearance.md`](../../../docs/architecture/appearance.md) is the contract; it reads no other `Theme` member.
- One owner per timer, watcher, poller and subprocess, inside the entry point's tree. A `Process` gets its stdout parser before it starts.
- A plugin that needs a Hyprland key or a blur rule declares it as data in the manifest's `hyprland` key and never writes Hyprland configuration: the core renders it into the one Hyprland layer, [`docs/architecture/hyprland.md`](../../../docs/architecture/hyprland.md).
- No cache keyed by data other applications supply without a ceiling.
- Every Quickshell type, property and signal comes from the 0.3.1 reference on Context7: `ctx7 docs /websites/quickshell_v0_3_1 <query>`.
- Land with `scripts/validate manifests`, `scripts/validate boundary` and `scripts/validate qml` clean, the last with the readback rows [`workflows/new-plugin.md`](workflows/new-plugin.md) step 8 names.

## Workflows

| Workflow | Trigger |
|----------|---------|
| [`workflows/new-plugin.md`](workflows/new-plugin.md) | Creating a plugin from nothing |
| [`workflows/review-plugin.md`](workflows/review-plugin.md) | Reviewing or changing an existing plugin |

## References

- [`references/api.md`](references/api.md): what a plugin receives and may call, per kind.
- [`templates/`](templates/): `manifest.json.tmpl`, `BarWidget.qml`, `Service.qml`, `Panel.qml`, `Bar.qml`, `Background.qml`.
