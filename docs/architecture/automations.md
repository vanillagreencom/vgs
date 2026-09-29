# Automations

Covers: shell/plugins/vgs.automations/**, scripts/test-automations-logic.js, scripts/test-automations-engine.js, scripts/test-automations-linger.sh, scripts/smoke/rows/automations.sh

How `vgs.automations` turns a recurrence into systemd user timers, runs a command, keeps its history and tells the user about it. The plugin's [README](../../shell/plugins/vgs.automations/README.md) says what the user sees; [D049](../decisions/D049-automations-engine.md) records the choices.

## The parts

- `AutomationsLogic.js` makes every decision: the store's schema, the recurrence model and its presets, the compiled calendars, the occurrences, the guard, the unit and crontab text, the records, the history rows, pruning, the notifications and the status. `bin/automations`, `Service.qml` and the tests load it; the engine loads it through `bin/lib/qml-library.js`.
- `bin/automations` owns the store, the units, the crontab block, the runner and the run files. Its header lists every verb, its output and its refusals.
- `Service.qml` asks the engine, one call at a time: `sync` at start, `prune` at start, on a `historyDays` change and once a day, and `list --json` after each run file comes or goes and a second after the next run is due. It writes every status value.
- `tui/linger.sh` shows whether lingering is on and turns it on with `loginctl enable-linger` after the user answers yes.

## Files

| Path | Holds | Writer |
|---|---|---|
| `$XDG_CONFIG_HOME/vgs/automations/automations.json` | The store: `{ version: 1, automations }` | the engine, under `locks/store.lock` |
| `$XDG_CONFIG_HOME/systemd/user/vgs-automation-<id>.timer`, `.service` | One pair per enabled automation | `sync` |
| `$XDG_STATE_HOME/vgs/automations/runs/<id>@<run>.started.json`, `.ended.json`, `.log` | One run: its records and its transcript; `<run>` is `<start ms>-<runner pid>` | the runner |
| `$XDG_STATE_HOME/vgs/automations/guard/<id>.json` | `{ handledThrough }`: the last occurrence the guard decided on | `add`, `enable` and the runner |
| `$XDG_STATE_HOME/vgs/automations/locks/<id>.lock` | The lock one run holds | `flock` |
| `$XDG_DATA_HOME/vgs/automations/engine/<hash>/` | The copy of the engine and the judge the units run | `sync` |

Every file the engine writes is written whole under a hidden name in its directory and renamed into place. A record is never rewritten: a run's end is a new file, so a directory listing notices it ([runtime-qml.md](runtime-qml.md)).

## The recurrence

`AutomationsLogic.scheduleError` judges `{ frequency, interval, weekdays?, monthly?, yearly?, times, start, end }`; its comment states each key. Times are local wall-clock times. The presets `daily`, `weekdays`, `weekly`, `biweekly`, `monthly-date`, `monthly-weekday` and `yearly` make a schedule from a start date and a time, as a picker's shortcuts do before Custom.

- An interval counts from the start date: days from it, ISO weeks from its Monday, months from its month, years from its year.
- An end date is the last day that may run. An end after N is the first N occurrences from the start, as Google Calendar counts them, whether or not each ran.
- A daylight saving change that skips a time skips that occurrence, and one that repeats a time runs it once, at its first instant, as `systemd-analyze calendar` answers.
- A rule with no occurrence in 400 years, such as 29 February every 4 years from a year that is not a leap year, is refused.

## The compiler and the guard

`calendarExpressions` gives one `OnCalendar=` expression per time of day and `cronFields` one cron line per time, each the tightest calendar its scheduler can state:

| Rule | OnCalendar= | cron |
|---|---|---|
| every day | `*-*-* 09:00:00` | `0 9 * * *` |
| weekdays | `Mon,Wed *-*-* 09:00:00` | `0 9 * * 1,3` |
| a day of the month | `*-*-15 09:00:00` | `0 9 15 * *` |
| the Nth weekday | `Tue *-*-08..14 09:00:00` | `0 9 * * 2` |
| the last weekday | `Fri *-*~07/1 09:00:00` | `0 9 * * 5` |
| a day of the year | `*-03-15 09:00:00` | `0 9 15 3 *` |

cron ORs a day with a weekday, so a week of the month is its weekday alone there. The interval, the start and the end are the guard's. On a scheduled trigger the runner asks `guard`: it takes the latest occurrence at or before now, runs nothing when that occurrence is at or before `handledThrough`, and skips it when it is more than 10 minutes old and the automation does not catch up. It then records the occurrence as handled. A trigger on a day the rule skips (an off week, a Tuesday outside its week, a day past the end) therefore finds an occurrence it already handled and runs nothing. `add` and `enable` set `handledThrough` to now, so an occurrence from before them never runs.

`nextOccurrences` is the preview `automations preview` prints, and the same function the guard's answers come from.

## Sync

`sync` makes the units, or the crontab block, match the store. With no automation, no unit and no engine copy, it runs nothing.

- The scheduler is `systemd` when `systemctl --user show-environment` answers, else `cron` when `crontab` is on PATH, else `none`, which `sync` refuses.
- Under systemd, sync disables and deletes the units of an automation that is gone or paused, checks each changed timer's calendars with `systemd-analyze calendar`, writes the changed files, reloads the manager when a file changed, runs `enable --now` on every wanted timer, and restarts a changed timer that was already there so it reads its new calendar. It also drops a crontab block an earlier fallback left.
- Under cron, sync replaces the lines between the `# BEGIN vgs.automations` and `# END vgs.automations` markers with one line per time of each enabled automation and leaves every other line of the user's crontab as it was. A crontab holding one marker without the other is refused.
- The timer carries `AccuracySec=1s` and `Persistent=` from the automation's catch-up setting. The service is `Type=oneshot`, which has no start timeout, and counts exit 75, a trigger during a live run, as success.
- A unit or crontab line hands the runner the configuration, state and data directories the engine resolved, since a user manager's environment need not hold the user's.

## The runner

A unit, a crontab line and Run now all start `flock -n -E 75 -o <lock> <node> <engine copy> --tree <tree> run --scheduled|--manual <id>`. flock holds the automation's lock for the runner's life and hands the runner no descriptor, so the command inherits no lock and a second run of the automation exits 75 at once.

- The runner writes the started record, sends the start notification, then runs `<login shell> -l -c <command>` in the working directory, the home directory when none is set. The login shell is the user's own from the password database, so PATH is what the user's terminal sees. The command runs in a process group of its own with no stdin, and learns `VGS_AUTOMATION_ID` and `VGS_AUTOMATION_RUN`. Under cron, where no session bus is set, the runner points `DBUS_SESSION_BUS_ADDRESS` at `$XDG_RUNTIME_DIR/bus`.
- At the timeout the runner sends SIGTERM to the command's group and SIGKILL 10 seconds later.
- The transcript holds a header, one `HH:MM:SS.mmm out|err | <line>` line per line of output as it arrives, and a footer with the outcome and the duration. Past 1 MiB it writes one marker line and drops the rest; the footer is always written.
- The outcome is `succeeded` on exit 0, `failed` on another exit or a signal, `timeout`, or `failed-start` when the command never ran: a missing working directory or login shell, a spawn error, or a store or guard file the judge refuses.
- After the ended record, the runner prunes its automation's history with the plugin's `historyDays`, read through `vgsh plugin settings`. A read that fails logs `automations: prune=skipped` and prunes nothing.

## History

`history` reads every run file. A run with an ended record has its outcome. A run with a started record alone is `running` while a runner holds the automation's lock and it is the automation's newest open run, and `vanished` otherwise, as after a logout without lingering killed it. `prune` removes every run that started before the retention window and is not running; `clear` removes every run that is not running.

## Notifications

`notificationFor` decides and `notifySendArgs` builds `notify-send`'s argv, with the summary and body after `--` and the body escaped, since the server reads markup:

| Event | When | Urgency | Icon, tone | Click |
|---|---|---|---|---|
| start | `notifyEveryRun` | low | `play`, warning | dismisses |
| finish | `notifyEveryRun` and success | low, replacing the start | `circle-check`, success | opens the transcript |
| error | every failure | critical, replacing the start when one was sent | `circle-x`, danger; the body is the reason and the last 5 stderr lines, or stdout's without stderr | opens the transcript |

The hints are [notification-hints.md](notification-hints.md)'s. A `notify-send` that is missing or fails is logged and the run goes on.

## Invariants

1. The preview, the units and the guard answer one question once: `scripts/test-automations-logic.js` compares every rule shape's next ten occurrences with `systemd-analyze calendar --iterations` under UTC and under a zone with daylight saving, and pins the guard, with a control per rule. Without `systemd-analyze` it exits 77.
2. No test reaches the user's systemd manager, crontab or notification server: `scripts/test-automations-engine.js` runs every case in a scratch home with stand-ins and an allow-list of host tools, and the smoke row's commands resolve to stand-ins in the sandbox, whose runtime directory and buses are its own.
3. A run's records land whole, the started one before the command; a timeout ends the command's whole group; the transcript keeps its cap and its footer; an error always notifies; prune keeps the window and a running run. Enforced by `scripts/test-automations-engine.js`, with a control per rule.
4. The service lists after a run file lands. Enforced by `scripts/smoke/rows/automations.sh`, whose control is a copy of the service that does not.
