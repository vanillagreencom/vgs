# VGS architecture

VGS is a desktop shell for Hyprland and Niri. QML owns the interface, a Go daemon owns live system integration, and the Python helper owns generation and privileged operations.

## The one idea

Each resource has one owner. QML consumes the owner's state instead of starting another watcher or keeping a competing copy.

## Vocabulary

- `vshell`: the runtime and CLI name. The product name is VGS.
- Theme package: palette, wallpapers and optional app files composed from built-in files and user overlays.
- Target: an application's generated theme output, declared under `themes/targets/`.
- Capability: a named group of methods advertised by the backend.
- Bundled plugin: product UI loaded through the plugin system.
- Pad: an application window managed as a scratchpad.

## Boundaries

- QML owns UI and orchestration. Parsing, template generation and privileged writes belong in the helper. Review this boundary against `bin/vshell-helper` and `quickshell/vshell/Services/VGSBackendService.qml`; no static check proves the whole boundary.
- The Go daemon owns live system state. Theme generation stays in the helper, and display power stays in `Services/IdleService.qml`.
- Theme packages own colours and app styling. Shell geometry stays in `Common/Theme.qml` and `Common/Appearance.qml`.
- Shipped configuration is seed data. Mutable user state belongs outside the repository.

## Invariants

- Runtime paths use the `vshell` name. `scripts/check-naming.sh` checks the owned source set.
- Registered backend methods require a capability entry. `scripts/check-backend-inventory.py` compares registration and caller references against `backend/methods.json`.
- Backend one-shot commands use bounded execution. `scripts/check-execbound-adoption.py` checks adoption of `backend/internal/execbound`.
- The live-session safety rule and validation status contract are in [../../AGENTS.md](../../AGENTS.md).

## Decisions

[Decision index](../decisions/INDEX.md): [D001](../decisions/D001-quickshell-0-3-0-upstream-defects.md), [D005](../decisions/D005-dependency-version-constraints.md), [D007](../decisions/D007-ci-single-job-economics.md).

## Topics

- [shell.md](shell.md): runtime state ownership and shared services.
- [design-language.md](design-language.md): tokens, shared controls and surface geometry.
- [session.md](session.md): lock, idle, screensaver and greeter changes.
- [notifications.md](notifications.md): notification ownership and takeover.
- [plugins.md](plugins.md): plugin loading, overrides and dependencies.
- [theme.md](theme.md): palettes, app targets and wallpapers.
- [helper.md](helper.md): privileged operations and helper integrations.
- [backend.md](backend.md): backend methods, processes and watchers.
- [cloud-sync.md](cloud-sync.md): file sync and rclone supervision.
