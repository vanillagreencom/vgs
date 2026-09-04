# Design language

Covers: quickshell/vshell/Widgets/, quickshell/vshell/Common/, quickshell/vshell/Modules/Plugins/

Shared tokens define form while the palette supplies colour. The token sources are `Common/Theme.qml` and `Common/Appearance.qml`.

## Boundaries

- Theme colours use semantic tokens. Black and white with alpha may express material effects. This is a review rule; the control tests do not enforce a blanket literal ban.
- Radius, elevation and motion remain user settings. A component reads the shared tokens rather than setting a separate scale.

## Invariants

- Transparent controls use state washes; filled controls use `Theme.hoverOn`, `pressedOn` and `selectedOn`. See `Common/Theme.qml`; `scripts/test-flatline-controls.js` covers the shared controls it names.
- Popout surfaces remain anchored to the output while input and dismissal track the body rectangle. See `Modules/Plugins/PluginPopout.qml`, `scripts/test-popout-dismiss-envelope.js` and the popout check in `scripts/qml-smoke.sh`.
- The blur allowlist includes only namespaces whose full rectangle can be blurred. `test_hyprland_blur_script` in `scripts/check-vshell-helper.py` checks membership and namespace matches.
- Layer-surface tooltips use `Widgets/VgsTooltip.qml`; floating windows use `Widgets/VgsInlineTooltip.qml`. The shared body receives an explicit backdrop property.
- Pushed plugin settings are view state. Escape returns to the previous page; other dismissal closes the surface. See `Modules/Plugins/PluginPopout.qml`.
