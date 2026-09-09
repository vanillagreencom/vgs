# Shell runtime

Covers: quickshell/vshell/

QML draws the shell and coordinates services. A service owns long-lived state; a module consumes that state and draws a surface.

## Boundaries

- Display settings consume native output state from `HyprlandService` or `NiriService`. `DisplayService` owns hardware brightness. `scripts/check-display-config-fixtures.js` tests device assignment, including ambiguous Apple display models.
- Settings sidebar and section tabs share `Modals/Settings/SettingsNavigation.qml`. The registry owns stable page indexes. `scripts/test-settings-navigation.js` checks group membership, support filtering and search expansion. `scripts/qml-smoke.sh --settings` opens each available page in the isolated session.
- `Services/CompositorService.qml` owns the shared focus answer. Consumers may subscribe to the existing compositor singleton; a second external connection or competing focus owner requires review. `scripts/test-compositor-focus.js` tests focus expressions, not all subscriptions.
- `Services/CaptureService.qml` owns QML capture state. The bundled plugin id stays `screenRecord` for saved layouts.
- Shared launcher panels belong under `Widgets/Launcher/`; feature-only panels stay with their consumer. See [D004](../decisions/D004-overview-search-ownership-and-plugin-boundary.md).
- Consumers reach the shared tooltip body through `VgsTooltip` or `VgsInlineTooltip`, not through the public widgets import.

## Invariants

- Instance detection yields only when a live peer is provably older. Unavailable evidence permits startup. See `vgs_instance_report` in `bin/vshell-helper` and `test_duplicate_shell_guard` in `scripts/check-vshell-helper.py`.
- Brightness pins use connector names, not position-dependent display labels. `scripts/check-display-config-fixtures.js` checks the shared Settings, Control Center and focused-screen readers.
- Display naming selectors share the state owner's identifier transition. It moves complete backend settings and pending edits before preview or profile extraction. `scripts/check-display-config-fixtures.js` checks both formats, collision refusal and cancellation.
- Plugin-backed properties remain bindings. Setters persist through the plugin service; dependent work responds to its change notification. See the plugin service implementations under `Modules/Plugins/`.
- Destructive pill actions require a click origin; unspecified origins are IPC calls. `scripts/test-pill-hover-safety.js` checks the shared dispatch and protected actions.
- Launcher selection follows pointer movement only while its hover gate is armed. `scripts/test-launcher-hover-latch.js` checks asynchronous result replacement.
- Provider replies carry their own identity, and each usage fetch channel is bound to one provider for its life, so a payload is only ever filed under the identity it names. `scripts/test-ai-usage-logic.js` and `scripts/test-ai-usage-lifecycle.js` cover the usage widget.
- The usage widget's provider catalog has one owner: `AiUsageLogic` names every provider, its icon and whether it needs a credential, and the bar slots, the filter, the popout deck and the fetch channels are all generated from it. `scripts/test-ai-usage-wiring.js` checks that no surface spells a provider out, and `scripts/test-ai-usage-sources.js` checks the catalog against the helper's.
- AI-usage credentials are written 0600 under the state directory and reach argv nowhere; the widget hands a key to the helper on stdin. `scripts/test-ai-usage-sources.js` checks both.

## Decisions

[D003](../decisions/D003-system-tray-transport.md).
