# Bundled module development

## Scope
VGS bundled modules currently use the internal package loader and live in:
```text
config/vshell/plugins/<id>/
```

They are VGS-owned product components, not third-party plugins or a stable public plugin API. Widget surfaces appear in Bar → Widgets and are always available; the Plugins settings page is reserved for user and system extensions installed outside VGS.

## Minimum structure
```text
plugin.json
Component.qml
Settings.qml optional
*.js optional
```

## Manifest fields
Common fields:
```json
{
  "id": "myPlugin",
  "name": "My Plugin",
  "description": "Short purpose",
  "version": "1.0.0",
  "author": "VGS",
  "type": "widget",
  "component": "./MyPlugin.qml",
  "settings": "./MyPluginSettings.qml",
  "permissions": ["settings_read", "settings_write"]
}
```

Composite daemon example:
```json
{
  "id": "vgsMenu",
  "name": "VGS Menu",
  "type": "composite",
  "capabilities": ["daemon"],
  "components": {
    "daemon": "./VGSMenu.qml"
  },
  "permissions": ["settings_read"]
}
```

Some existing manifests may carry compatibility flags for loader decisions.
Do not use those flags as permission to call shell commands at runtime.

`requires_shell` is optional, and when a bundled manifest declares one it must be satisfiable by the
shell in `VERSION` — `">=0.1.0"` is what the shipped manifests use. A bundled manifest's requirement
is never enforced, so an impossible one changes nothing where it is written; it fires where it is
copied, because an override is normally a copy of the shipped manifest and *is* judged by it. Every
shipped manifest once declared `">=1.0.0"` against a 0.1.0 shell, which made overriding any bundled
plugin impossible while looking like nothing was wrong. `scripts/test-bundled-override.js` fails the
build for it now (VGS-76).

Replacing a bundled module from `~/.config/vshell/plugins/<id>/` needs an explicit claim:

```json
{ "id": "vgsMenu", "overrides": "vgsMenu" }
```

Without it the package stays inert and the shipped module keeps the id. With it the package is
auto-enabled and cannot be disabled from Settings, and it is demoted back to the shipped module if
its `startupCheck` or components fail. See `docs/architecture/overlay-and-dependencies.md`.

## QML imports
Follow existing plugin imports. Common ones:
```qml
import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Services
import qs.Modules.Plugins
```

## UI rules
- Use VGS theme tokens through `Theme`.
- Use `StyledRect`, `StyledText`, `VgsIcon`, `VgsButton`, `VgsToggle` where existing patterns do.
- Avoid hardcoded hex colors.
- Avoid custom toggles/buttons when existing widgets fit.
- Keep bar pills compact.
- Keep popouts aligned to token spacing.

## Command rules
Use absolute VGS helper path from QML:
```qml
command: [Paths.vshellCli, "..."]
```

Do not use:
```qml
command: ["vgs", ...]
command: ["vshell", ...]
```

## Settings
Settings components should read/write through existing settings services or plugin settings APIs.
If a helper command is read-only, make UI read-only or hide mutation controls.
Do not show controls that call unimplemented helper paths.

## Validation
For plugin QML changes:
```bash
scripts/qml-smoke.sh
```

Never `qs -c vshell` in a live session — rule and recovery: AGENTS.md § Never
launch a second shell into the live session.

For command-backed plugins, also test helper command directly.
