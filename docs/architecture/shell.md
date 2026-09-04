# Shell runtime

Covers: quickshell/vshell/

QML draws the shell and coordinates services. A service owns long-lived state; a module consumes that state and draws a surface.

## Boundaries

- `Services/CompositorService.qml` owns the shared focus answer. Consumers may subscribe to the existing compositor singleton; a second external connection or competing focus owner requires review. `scripts/test-compositor-focus.js` tests focus expressions, not all subscriptions.
- `Services/CaptureService.qml` owns QML capture state. The bundled plugin id stays `screenRecord` for saved layouts.
- Shared launcher panels belong under `Widgets/Launcher/`; feature-only panels stay with their consumer. See [D004](../decisions/D004-overview-search-ownership-and-plugin-boundary.md).
- Consumers reach the shared tooltip body through `VgsTooltip` or `VgsInlineTooltip`, not through the public widgets import.

## Invariants

- Instance detection yields only when a live peer is provably older. Unavailable evidence permits startup. See `vgs_instance_report` in `bin/vshell-helper` and `test_duplicate_shell_guard` in `scripts/check-vshell-helper.py`.
- Plugin-backed properties remain bindings. Setters persist through the plugin service; dependent work responds to its change notification. See the plugin service implementations under `Modules/Plugins/`.
- Destructive pill actions require a click origin; unspecified origins are IPC calls. `scripts/test-pill-hover-safety.js` checks the shared dispatch and protected actions.
- Launcher selection follows pointer movement only while its hover gate is armed. `scripts/test-launcher-hover-latch.js` checks asynchronous result replacement.
- Provider replies carry their own identity and source-scoped state is cleared before reuse. `scripts/test-ai-usage-provider.js` and `scripts/test-ai-usage-lifecycle.js` cover the usage widget.

## Decisions

[D003](../decisions/D003-system-tray-transport.md).
