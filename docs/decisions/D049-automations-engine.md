# D049: Automations run under systemd user timers, compiled and guarded by one judge, and notify through VGS hints

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: VGS-600

**Refines**: [D033](D033-floating-tuis-are-core.md), [D035](D035-manifest-requirements.md), [D037](D037-plugin-status.md)

**Context**: VGS-600 asks for a plugin that runs a user's shell command on a recurrence with Google Calendar's range of rules (weekdays, several times a day, every N days, weeks, months or years, the Nth weekday of a month, an end date or an end after N runs), keeps every run's transcript for up to 30 days, and tells the user about every failure. A run must happen whether or not the shell runs, and the shell never elevates. VGS-601 builds the editor, the preview and the history on top of this engine, so the engine must give it one answer for every question.

**Decision**: `vgs.automations` is a service plugin with a plugin-local engine, `bin/automations`, and one judge, `AutomationsLogic.js`, which the engine, the service and the tests load. The contract is [automations.md](../architecture/automations.md); the hint contract is [notification-hints.md](../architecture/notification-hints.md).

- **Scheduler.** Each enabled automation is a `vgs-automation-<id>.timer` and `.service` pair under `~/.config/systemd/user/`, written by rename, then `daemon-reload` and `enable --now` through `systemctl --user`. `Persistent=` follows the automation's catch-up setting. Where no systemd user manager answers `show-environment`, sync keeps a marked block in the user's crontab instead.
- **Compiler and guard.** The judge compiles a rule into the tightest calendar each scheduler can state: one `OnCalendar=` expression per time of day, or one cron line per time. What a calendar cannot state (an interval counted from the start date, the start, the end date, the end after N) is applied by the runner's guard, which runs the latest occurrence at or before the trigger that it has not handled, and skips a late one unless the automation catches up. The same judge answers the preview's next occurrences, so the preview, the units and the guard cannot disagree.
- **Runner.** The service unit runs `flock -n -E 75 -o <lock> node <engine copy> run --scheduled <id>`, never the command. The runner runs the command as `<login shell> -l -c <command>` in its own process group with the automation's timeout, writes a started record before it and an ended record after it by rename, and writes a timestamped transcript capped at 1 MiB.
- **Engine copy.** Sync copies the engine and the judge to `$XDG_DATA_HOME/vgs/automations/engine/<hash>/`, and the units name that copy. The shell runs a plugin from a snapshot a restart removes ([D014](D014-source-revisions-are-published-snapshots.md)), so a unit cannot name the snapshot; the copy is the revision the shell last synced, as a floating TUI runs from a copy of its snapshot ([D042](D042-tui-scripts-run-from-a-copy-of-the-whole-snapshot.md)).
- **Notifications.** Option (a) of the issue: the runner sends freedesktop notifications with `notify-send`, carrying four VGS hints (`x-vgs-icon`, `x-vgs-tone`, `x-vgs-open`, `x-vgs-click`), and `vgs.notifications` gains a hint handler that names no sender. An error always notifies, critical, red and with the last stderr lines; a start and a finish notify only under the automation's `notifyEveryRun`. A click on an `open` card opens the file through the notifications plugin's own `open` floating TUI, `$EDITOR` or `xdg-open`.
- **Store and CLI.** The automations live in `~/.config/vgs/automations/automations.json`, written by the engine alone under a lock. The engine's verbs (list, add, edit, enable, disable, remove, run-now, history, clear, prune, preview, sync) are the one door for the service, VGS-601's user interface and the tests. The history retention is the manifest setting `historyDays`, 1 to 30, which the engine reads through `vgsh plugin settings`.
- **Lingering.** User timers stop when the user's manager does, at logout, unless lingering is on. The status shows it, and the manifest's `linger` TUI turns it on with `loginctl enable-linger`, run by the user in a terminal they see.

### The options

| Question | Taken | Rejected, and why |
|---|---|---|
| Scheduler | systemd user timers, cron where no user manager answers | A timer in the shell: nothing runs while the shell is down. `systemd-run --on-calendar` transient timers: they vanish at reboot and cannot carry catch-up. |
| Rules calendars cannot state | The tightest calendar plus the runner's guard | One transient timer per next occurrence, rearmed after each run: a missed rearm stops the automation for good, and the unit set is state no file holds. |
| End after N | The first N occurrences from the start, as Google Calendar counts | N runs executed: the count would live in history the 30-day prune removes, and a machine that was off would move the end. |
| Run overlap | `flock -n -o` holds one lock per automation for a run's life; the command inherits none | A pid file: a reused pid or a crash leaves it lying. |
| Notifications | (a) VGS hints on freedesktop notifications | (b) The service watches the records and raises shell toasts: nothing notifies while the shell is down, and a toast keeps no history or click after a restart. libnotify actions: `notify-send --action` blocks the sender and dies unanswered when the shell restarts. |
| CLI home | A plugin-local `bin/automations` | `vgsh automations` verbs: the core would name a plugin, which the boundary refuses ([D003](D003-everything-is-a-plugin.md)), and bin/vgsh has no system for plugin verbs. |
| Global retention | The manifest setting `historyDays` | A key in the store: the Settings page draws only manifest settings ([D032](D032-settings-plugin-and-manifest-settings-convention.md)), so the user could not set it there. |

**Rationale**:

- A run must happen with the shell down, so the schedule belongs to the user's service manager. The shell only writes the units and reads the records.
- One judge for the calendar, the guard and the preview removes the class of bug where the preview shows a run the scheduler never makes, or the scheduler fires one the rule excludes. The logic suite compares the preview with `systemd-analyze calendar --iterations` for each rule shape.
- Records written once under new names let the service notice a run with one directory listing, as the TUI exit records do ([tui-records.md](../architecture/tui-records.md)).
- A hint is data any sender can add, so `vgs.notifications` stays free of any plugin's name ([D005](D005-kinds-are-surfaces-no-dependencies.md)), and the click survives a shell restart because the card stores it with the notification.
- The notifications state file gains four roles and moves to version 2. No reader of version 1 ships: a state file written before this change is refused once, as the plugin refuses any other defect, and Clear history starts it over.

## Where VGS differs from Omarchy

Checked against basecamp/omarchy at `8b4eae6`: `bin/omarchy-reminder`, `docs/notifications.md`, `bin/omarchy-notification-send`, `bin/omarchy-launch-editor`, `plans/backup.md`.

| Omarchy | VGS | Why |
|---|---|---|
| No recurring scheduler. `omarchy-reminder` makes one-shot transient timers with `systemd-run --user --collect --on-active=<n>m` and lists them with `systemctl --user list-timers`. | Persistent `.timer` and `.service` files per automation, synced from a store. | A recurrence must outlive a reboot and carry catch-up; a transient timer does neither. Taken from Omarchy: the systemd user manager as the scheduler, and `--collect` for Run now's transient unit. |
| The backup plan uses `OnCalendar=` with `Persistent=true` for catch-up and needs no lingering. | `Persistent=` follows the automation's catch-up setting, and the linger TUI offers lingering. | A user automation may be meant to run at night with the user logged out. |
| A click command rides in the `omarchy-exec-argv` hint, run by the shell detached, so a click survives a restart; the sender calls `Notify` over `busctl`. | A click opens the file `x-vgs-open` names, through a declared floating TUI; the sender is `notify-send` with the text after `--`. | Taken: the click as hint data, stored with the notification. VGS carries a path, not a command, so no notification can make the shell run a program; `--` keeps a summary from being read as an option, which Omarchy's `busctl` call solves the same way. |
| `omarchy-launch-editor` picks the editor from its own defaults file and opens a terminal editor in a TUI. | The `open` TUI runs `$EDITOR`, split on white space, and falls back to `xdg-open`. | VGS keeps no defaults file of its own; `$EDITOR` is the user's setting. |

**Revisit When**: VGS gains a core notification capability that carries clicks; systemd drops user timers or `Persistent=`; a user needs a rule the four frequencies cannot express; or the transcript cap or the 30-day ceiling proves too small in use.

**Verification**: `scripts/test-automations-logic.js` pins the compiler, the preview, the guard, the store judge, the unit and crontab text, the history and the notification decisions, and compares every rule shape's next ten occurrences with `systemd-analyze calendar --iterations`, with a control per rule. `scripts/test-automations-engine.js` runs the engine against stand-in `systemctl`, `systemd-run`, `crontab`, `notify-send` and `loginctl` in scratch homes, with a control per rule. `scripts/test-notifications-logic.js` pins the hint judge and the click routes; `scripts/test-notifications-open.sh` and `scripts/test-automations-linger.sh` pin the two TUIs. `scripts/smoke/rows/automations.sh` and `scripts/smoke/rows/notifications.sh` read both plugins back in the nested sandbox.

**References**: [automations.md](../architecture/automations.md), [notification-hints.md](../architecture/notification-hints.md), [README](../../shell/plugins/vgs.automations/README.md), [D003](D003-everything-is-a-plugin.md), [D005](D005-kinds-are-surfaces-no-dependencies.md), [D014](D014-source-revisions-are-published-snapshots.md), [D032](D032-settings-plugin-and-manifest-settings-convention.md), [D033](D033-floating-tuis-are-core.md), [D035](D035-manifest-requirements.md), [D037](D037-plugin-status.md), [D042](D042-tui-scripts-run-from-a-copy-of-the-whole-snapshot.md)
