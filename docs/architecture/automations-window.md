# Automations window

Covers: shell/plugins/vgs.automations/Window.qml, shell/plugins/vgs.automations/*Page.qml, shell/plugins/vgs.automations/*Row.qml, shell/plugins/vgs.automations/RecurrenceSection.qml, shell/plugins/vgs.automations/PreviewPanel.qml, shell/plugins/vgs.automations/TranscriptPanel.qml, scripts/smoke/rows/automations.sh, scripts/sandbox-shots.sh

The Automations window is the user interface for `vgs.automations`. The engine, files and scheduler stay in [automations.md](automations.md).

## Pages

The Automations window is a `window` kind, [D065](../decisions/D065-automations-window.md). Hyprland handles the frame, focus, move, tile and close rules like the Settings, Dev Tools and Gallery windows ([surfaces.md](surfaces.md)). The window uses the Settings window width rule, asks for `size.panel.maxHeight`, and uses a page push: the list stays on the Automations page, and New or a row opens the editor page.

The editor starts with presets: Once, every day, weekdays, weekly on the start date's weekday, every two weeks, monthly by date, monthly by weekday, yearly and Custom. Once is not an engine preset. The UI writes it as a daily schedule ending after one occurrence, so the engine's schedule model stays unchanged and the summary reads `once`.

Custom exposes the engine model directly: every N days, weeks, months or years; weekday chips for weekly rules; monthly by date or weekday; yearly by month and day; and end never, on date or after a count. The time list accepts any number of distinct `HH:MM` values and keeps them sorted before the engine judges the schedule.

The editor reads top to bottom: Basics (the name, the command, then Test run, Copy command and Remove), the Test run transcript, Repeats, the Next runs panel under the rule it previews, and Run settings, so the fields a new draft needs are in view when it opens and Tab goes from the name to the command. The Next runs panel calls `preview --schedule <json> --count 5`. The list, save, edit, enable, disable, remove, Run now, history and clear controls call the matching engine verbs. A test run of an unsaved draft is refused until the draft is saved, because the engine's `run-now` verb runs a stored automation by id. A test run of a saved draft follows the newest history row for that automation that started after the click and shows the transcript inline, with a button that opens the same transcript through the `transcript` TUI.

The window groups history rows by local day and filters to the last 30 days. The History page has an automation filter. A row opens its transcript through the `transcript` TUI, which keeps `$EDITOR` in a visible floating terminal. Clear history calls `clear --all` or `clear <id>` only after the confirmation dialog accepts and names the filtered scope.

The launcher has Automations and New automation rows. They call the service IPC handlers, which summon this window.

Omarchy has no scheduling UI in its default branch. It exposes menu and TUI patterns through `omarchy-menu` and floating terminal helpers. VGS differs by keeping recurring command setup in a first-party application window, because the user edits a structured schedule, previews engine output and reviews history in one place. VGS still follows Omarchy's menu pattern where the launcher opens a top-level action and the floating TUI pattern where a visible terminal owns a command the user may answer.
