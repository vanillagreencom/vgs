# Agent Warden service

Covers: shell/plugins/vgs.agent-warden/Service.qml, shell/plugins/vgs.agent-warden/WardenLogic.js, shell/plugins/vgs.agent-warden/Notices.js, scripts/test-agent-warden-logic.js, scripts/test-agent-warden-view.js, scripts/test-agent-warden-notices.js, scripts/test-agent-warden-tui.sh, scripts/smoke/rows/agent-warden.sh

The contract of the `vgs.agent-warden` service, the plugin's one reader of the warden's status and its one sender of notices. The plugin's [README](../../shell/plugins/vgs.agent-warden/README.md) says what the user sees.

## What the service reads

The service is the plugin's one reader of `$XDG_RUNTIME_DIR/agent-warden/status.json`, which the warden replaces on every tick. The file holds numbers and ids only; vsys's [warden-status.md](https://github.com/vanillagreencom/vsys/blob/main/docs/architecture/warden-status.md) is its contract. The service reads it again on every change and derives one state from it in `WardenLogic.js`:

| State | When |
|---|---|
| `calm` | A fresh status with nothing below. |
| `working` | The warden moved an agent back into its limits in the last 5 minutes, and nothing else needs attention. |
| `look` | An agent is near its task or memory ceiling, the agent group is above its slowdown point, or leftover work from a finished agent remains. |
| `problem` | The warden's last scan failed, moves wait for memory headroom, or in the last 5 minutes a move failed, a move was partial, or the warden stopped leftover work. |
| `not-checking` | The status is more than 90 seconds from now (`stale`), cannot be read (`unreadable`), or has a schema major other than 1 (`schema`). |
| `not-set-up` | Neither `status.json` nor `state.json` exists. |
| `update-warden` | `state.json` exists and `status.json` does not: an older warden, which writes no status. |

The state is also derived again, with no file change, at the moment `WardenLogic.nextChange` names: 90 seconds after the status's time, when it turns stale, or the end of a recent event's 5-minute window, whichever comes first. The service holds one single-shot timer to that moment. A warden that stops writing therefore reads as `not-checking` 90 seconds after its last tick. The service makes the warden's directory at start, so that a warden set up while the shell runs is seen.

## Published status

The service publishes these values through the core `status` capability ([status.md](status.md)). The first four are the plugin's rows on its Settings page, where the warden and vsys rows offer their setup step as a button ([D061](../decisions/D061-no-manual-commands.md)).

| Key | Type | Value |
|---|---|---|
| `warden` | state | Checking, Last scan failed, Stopped checking, Status unreadable, Status format not supported, Not set up, or Update the warden. While `WardenLogic.setupStep` answers `setup`, a warden not set up or too old with vsys present, the value carries `action: true` and the row offers Set up, the `setup` TUI, the step the panel offers; `vsys warden install` shows behind Show command. |
| `agents` | count | The agents running at the last check: lanes with an identified agent that are not leftover work. Not reported until a status lists them. |
| `lastCheck` | time | The time of the last status the warden wrote. |
| `vsys` | presence | `present` or `absent`, as the shell's last plugin scan found `vsys` on PATH. While absent the row offers Install vsys, the requirement notice for the `vsys` package; the vsys installer shows behind Show command for a system with no package. |
| `detail` | data | `{ state, reason, checkedAt, agents, issues, items, memory }`, which the plugin's widget and flyout read: the state and its reason, the check time in milliseconds, the agent count, the number of `problem` and `look` items, the items most serious first, and the agent group's memory in bytes, `{ used, high, max }`, or null when unknown. Each item is `{ kind, level, ... }` with numbers and tool names, and never a process id or a scope name. `WardenLogic.itemsOf` lists the kinds. |

`WardenLogic.gib` turns a byte count into the figure the plugin's copy shows with "GB": gibibytes, one decimal below 10 and whole from 10.

## Notifications

The service sends the desktop notices about agents in place of the warden. The warden stops its own notices while `$XDG_RUNTIME_DIR/agent-warden/notifier` is less than 120 s old ([vsys warden.md § Notifications](https://github.com/vanillagreencom/vsys/blob/main/docs/architecture/warden.md#notifications)). The service writes the time into that file every 60 s. It does so only while it reads a status and the scan finds `notify-send`. A status the plugin cannot read, or a desktop without `notify-send`, gives the notices back to the warden within 120 s. `notify: off` keeps the heartbeat, so the warden stays silent too, as the user asked. The service does not remove the file when it stops, so the warden stays silent for up to 120 s after the plugin is disabled or the shell stops.

`Notices.js` holds the rules and the words. An episode is a condition keyed `<kind>:<scope>`, as the warden keys its own. Each status opens and clears episodes, and the service sends a notice only for an episode that opens. The episode then goes out again only after it clears and opens again. An episode clears only on evidence: a fresh status that no longer holds it. A stale or unreadable status, lanes the warden could not list, or a counter it could not read keeps the episodes it cannot judge. The service remembers at most 64 open episodes. A new episode past that is not sent and is logged once as `agent-warden: notices=full`. The memory lives as long as the service, so a service built again sends each episode still open once more. Memory moves under every setting, so an episode that opened while notices were off is not sent when they come back on.

Each notice is one `notify-send -a 'Agent Warden' -u <urgency> [-A open='Open vsys'] -- <title> <body>` run. `--` keeps a title or body that starts with a dash as text. Open vsys is offered only while the scan finds vsys. `notify-send` waits for the notice to close when it offers a button, so at most 8 runs wait at once, and a later notice goes without the button. A press prints `open`, and the service opens the `vsys` TUI with `shell.tui.run("vsys")`. A `busy` reply means a vsys window is open, and the core focuses it. A run that fails is logged as `agent-warden: notice=<kind> failed=...`, and its episodes are forgotten, so the next status sends them again, as the warden retries a failed notice.

Omarchy (basecamp/omarchy `b421b1b`) sends its notices through `omarchy-notification-send`, which calls `org.freedesktop.Notifications.Notify` with `busctl` and carries a click command in a hint only its own daemon reads. VGS uses `notify-send` instead. Its `--action` prints the button pressed, which a `busctl` call cannot report, and any notification daemon draws the button. The `--` before the text gives the same protection against text read as options that Omarchy gets from `busctl`.

## Validation

- `scripts/test-agent-warden-logic.js` reads vsys's fixtures and pins every refusal, every state, the next moment each state can change, the Settings row and the published keys, with a control per rule.
- `scripts/test-agent-warden-view.js` pins the shield, the panel's sentence, items, meter, buttons and check time for each fixture and each other state, the words for each reply, and the summary reading. It checks that no text names a fixture's scope unit or process id. Its controls include a logic copy that hands the view a scope name.
- `scripts/test-agent-warden-notices.js` pins when the service owns the notices, the episodes each status opens, keeps and clears, the ceiling, the notices each setting sends, their words, the `notify-send` argv and the toast, and the reading of a press, with a control per rule. It checks that no notice names a fixture's scope unit or process id.
- `scripts/test-agent-warden-tui.sh` runs `tui/setup.sh` and `tui/vsys.sh` against a stand-in vsys: setup runs `vsys warden install` once, vsys runs vsys bare, and each ends with vsys's code, with a control per rule. The smoke's stand-in terminal runs neither script.
- `scripts/smoke/rows/agent-warden.sh` writes each fixture into the sandbox's runtime directory by rename, as the warden does, and reads the published status and the Settings rows back. A status written 85 seconds back and left unchanged turns stale on the service's timer. It reads the shield's icon, tone, count and tooltip and every text of the panel back for each state, and checks that none names a scope unit or a process id. Set up and Open vsys hand a stand-in terminal their TUI's argv, Start it hands a stand-in `systemctl` its arguments, and Get vsys raises the shell's notice on a host without vsys. A summary that fails when the open panel is summoned again leaves no earlier line. A stand-in `notify-send` records each notice: the row reads the heartbeat start with a readable status and again at once after an unreadable one, one notice per episode across ticks, the same episode again after it clears, nothing under `notify: off`, a move as a toast under `everything`, the vsys TUI's argv handed to the stand-in terminal on a press, a notice whose run fails or cannot start sent again on the next status, runs waiting for a press stopped at eight, and a run that ends giving its place back. Its controls are a copy of the plugin whose logic ignores staleness, which reads a stale status as calm, a copy whose timer derives nothing, which keeps the unchanged status calm past its stale moment, a copy whose logic hands the view each lane's scope unit, which the panel then draws, a panel copy that keeps its last summary line when a new run starts, which still draws it after a failed run, a notices copy without episode memory, which sends a lane's notice again on its next tick, and three service copies: one that keeps a failed run's episodes, which sends them once only, one that never counts a waiting run, which offers the button on every run, and one that never gives a place back, which sends later notices without the button.
