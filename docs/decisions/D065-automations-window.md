# D065: Automations use one window, one engine client and shared recurrence controls

[← Decision Index](INDEX.md)

**Date**: 2026-09-29
**Status**: Active
**Research**: VGS-601
**Refines**: [D044](D044-application-windows-are-hyprland-toplevels.md), [D052](D052-automations-engine.md)

**Context**: VGS-600 shipped the automation engine: the store, scheduler, runner, history and notification hints. VGS-601 needed the user interface for editing recurrence rules, previewing next runs and reading history. A settings page would have hidden the workflow inside manifest fields, and a transient panel would have put a long editing session in a surface that closes on outside clicks. Omarchy has menu and floating-terminal patterns, but no recurring scheduler UI in its default branch.

**Decision**: `vgs.automations` owns a `window` kind for the Automations UI. The window uses a master-detail page flow: Automations is the list page, History is the history page, and a list row or New pushes the editor page. The window uses the Settings window width rule and asks for `size.panel.maxHeight`, capped by the monitor gutter, so the recurrence editor and preview stay visible without side-by-side crowding. It does not write the store, units, crontab or run records. It sends every read and mutation through a shared `EngineClient.qml`, the same serialized subprocess client the service uses for `bin/automations`. The recurrence editor composes qs.Ui controls: date, time, weekday and path fields. Once remains the engine's count-1 schedule shape, but `AutomationsLogic.summaryText` names it as one plain-language occurrence. A transcript opens through the plugin's floating TUI, and Test run follows the newest history row for the saved automation and shows its transcript inline.

**Rationale**:
- A `window` keeps a long editing session under Hyprland's focus, frame, close and tiling rules, as D044 requires.
- A page push keeps the list legible at the Settings window width. A side-by-side detail pane made the list too narrow for name, summary, next run, last run, enabled and Run now at the default size.
- A shared engine client keeps one process queue and one refusal shape around the engine, while D052 keeps the engine the only store and scheduler owner.
- Once as a count-1 schedule avoids a new engine frequency while making the UI and summary readable.
- Date, time, weekday and path fields belong in `qs.Ui` because other recurrence and file-picking flows need the same controls. The folder picker is a `FolderListModel` popover, not `QtQuick.Dialogs.FolderDialog`, because VGS popovers already follow the shell's focus-grab and outside-click rules. It does not call the xdg-desktop-portal file chooser because the shell has no portal helper and the picker only needs local directories.
- VGS takes Omarchy's pattern of launcher entries opening top-level actions and visible floating terminals for user commands. VGS differs by using a structured window for recurring schedules because the user edits data, previews engine output and reviews history together. Omarchy has no recurring scheduler UI.

**Revisit When**: Automations need a second surface class, the engine exposes a long-lived API that replaces CLI calls, or Quickshell gains a native folder picker that works inside a shell window.

**Verification**: `scripts/test-automations-logic.js`, `scripts/test-automations-view-logic.js`, `scripts/qml-tests/tst_automation_controls.qml`, `scripts/test-qml-unit.sh`, `scripts/smoke/rows/automations.sh` and `scripts/sandbox-shots.sh`.

**References**: [D044](D044-application-windows-are-hyprland-toplevels.md), [D052](D052-automations-engine.md), [automations.md](../architecture/automations.md), [components.md](../architecture/components.md), [tui.md](../architecture/tui.md)
