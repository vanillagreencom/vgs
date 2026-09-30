---
name: vgs-plugin
description: "Load to create, change or review a v2 shell plugin: a bar widget, a bar, a panel, an overlay, a menu, a window, a service or a background."
summary: "The plugin contract as a checklist, a scaffold command, templates for every kind, and the API a plugin may use."
license: MIT
user-invocable: true
argument-hint: "new <author.name> --kinds <kind,...> | check <dir>"
metadata:
  author: vanillagreen
  source: in-place
  repository: "https://github.com/vanillagreencom/vgs"
  bugs: "https://github.com/vanillagreencom/vgs/issues"
  version: "0.5.0"
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

- One directory, one `manifest.json` at its root, one QML entry point per kind. Copy the templates. The field table is [`docs/architecture/plugin-manifest.md` § Manifest](../../../docs/architecture/plugin-manifest.md#manifest); an unknown key is refused.
- Declare surfaces, never dependencies. Every external command the plugin runs goes in the manifest's `requirements`, with its package per manager, `optional` when the plugin works without it, and a one-line `purpose`; a requirement names a command, never another plugin: [`docs/architecture/requirements.md`](../../../docs/architecture/requirements.md). The core shows its notice when the plugin is installed or enabled without a command it needs; a button that asks the user to install one of the plugin's own commands calls `shell.requirements.offer`, never a package manager.
- Imports and names: the allowed table in [`references/api.md`](references/api.md) § Allowed imports, and nothing else. `scripts/check-plugin-boundary.py` refuses the rest.
- Every entry point declares `property var shell: null` or inherits it from `BarWidget`. Capabilities come from `shell.<name>` after naming them in `capabilities`; a widget never reads them from `bar`.
- Settings default in the manifest's `settings` and arrive as `shell.settings` for every kind; a bar widget also reads them with `setting(name, fallback)`. A change reaches the running instance as a new `shell`; hold no copy.
- The manifest is the plugin's settings page: name an `icon` from the shipped Lucide set, and give every setting a user would reasonably change, and the plugin reads, a `schema` entry, with `min`, `max` and `step` on a number and a `group` for its section; a constant earns an entry only when a user has a reason to change it. A key is `hyprland.binds`, never a schema entry. The Settings window draws the page from these alone: [`docs/architecture/plugin-manifest.md` § Manifest](../../../docs/architecture/plugin-manifest.md#manifest), [D032](../../../docs/decisions/D032-settings-plugin-and-manifest-settings-convention.md).
- A bar widget extends `BarWidget` from `qs.Ui` and sizes itself with `implicitWidth` and `implicitHeight`. The core assigns `bar`, `moduleName` and `settings` after creation; the widget sets none of them.
- A bar declares `leftSection`, `centerSection` and `rightSection`. The core mounts every plugin widget; a widget the bar draws itself registers through `shell.builtins`.
- A surface the user works in, moves or tiles, such as a settings or tools window, is kind `window`, a Hyprland window; a flyout from a widget is an anchored `panel` or `menu`, which closes on a click outside it: [`docs/architecture/surfaces.md`](../../../docs/architecture/surfaces.md), [D044](../../../docs/decisions/D044-application-windows-are-hyprland-toplevels.md).
- Compose the components of `qs.Ui` ([`references/api.md` § Components in `qs.Ui`](references/api.md#components-in-qsui)) before drawing anything by hand. Every colour, size, font, radius, opacity and duration reads a token through `Theme` in `qs.Commons`. `scripts/check-design-tokens.py` refuses a `Theme` path that names no token and reports each literal it finds.
- A list whose rows each take one selection declares one `ListCursor` from `qs.Ui` and names it in each row's `cursor`; keys and hover write the list's one selection, and no row draws its own hover or highlight fill: [`docs/architecture/motion.md`](../../../docs/architecture/motion.md).
- A plugin whose design must look the same under every theme owns its look instead: the manifest's `appearance` names a table of its own, every value is `look.<path>` from `Theme.appearance(TOKENS, LIGHT)`, and the theme reaches it through its mode, accent and motion scale alone. [`docs/architecture/appearance.md`](../../../docs/architecture/appearance.md) is the contract; it reads no other `Theme` member.
- One owner per timer, watcher, poller and subprocess, inside the entry point's tree. A `Process` gets its stdout parser before it starts.
- A value the plugin's widgets, flyout or Settings page show is plugin status: declare it in the manifest's `status`, name capability `status`, write it from the one instance that owns its source, the service, with `shell.status.set`, and read it from `shell.status.values`. One writer per key; a credential's value never enters status, only its presence. [`docs/architecture/status.md`](../../../docs/architecture/status.md), [D037](../../../docs/decisions/D037-plugin-status.md).
- A plugin that needs a Hyprland key or a blur rule declares it as data in the manifest's `hyprland` key and never writes Hyprland configuration: the core renders it into the one Hyprland layer, [`docs/architecture/hyprland.md`](../../../docs/architecture/hyprland.md).
- A command the user must see or answer runs in a floating TUI: a script under the plugin's `tui/`, declared as data in the manifest's `tui` key and opened with `shell.tui.run`, never a command string: [`docs/architecture/tui-capability.md` § The capability](../../../docs/architecture/tui-capability.md#the-capability).
- No cache keyed by data other applications supply without a ceiling.
- Every Quickshell type, property and signal comes from the 0.3.1 reference on Context7: `ctx7 docs /websites/quickshell_v0_3_1 <query>`.
- A first-party plugin's README shows a screenshot made by `scripts/readme-shots.sh`, with its row in `docs/images/plugins/shots.tsv`: [`docs/architecture/readme-images.md`](../../../docs/architecture/readme-images.md).
- Land with `scripts/validate manifests`, `scripts/validate boundary` and `scripts/validate qml` clean, the last with the readback rows [`workflows/new-plugin.md`](workflows/new-plugin.md) step 9 names.

## Workflows

| Workflow | Trigger |
|----------|---------|
| [`workflows/new-plugin.md`](workflows/new-plugin.md) | Creating a plugin from nothing |
| [`workflows/review-plugin.md`](workflows/review-plugin.md) | Reviewing or changing an existing plugin |

## References

- [`references/api.md`](references/api.md): what a plugin receives and may call, per kind.
- [`templates/`](templates/): `manifest.json.tmpl`, `BarWidget.qml`, `Service.qml`, `Panel.qml`, `Window.qml`, `Bar.qml`, `Background.qml`, `tui.sh`.
