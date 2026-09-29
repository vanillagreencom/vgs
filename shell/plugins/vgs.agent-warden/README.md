# Agent Warden

`vgs.agent-warden` shows whether the agent warden keeps your AI agents within their memory and task limits. The warden ships with [vsys](https://github.com/vanillagreencom/vsys) and runs as a systemd user timer every 30 seconds, whether or not the shell runs. The plugin reads what the warden reports and never moves or stops an agent. It changes the warden only when you press a setup button in its panel. [D041](../../../docs/decisions/D041-agent-warden-observes-the-vsys-warden.md) records why.

`bin/vgsh plugin enable vgs.agent-warden` puts the shield in the bar's right section.

## Setting up the warden

1. Install vsys: `curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vsys/main/install.sh | bash`, or `paru -S vsys` on Arch Linux.
2. Run `vsys warden install` once. It writes the warden's systemd user units and starts its timer.

The plugin's Settings page shows both commands with a Copy button. The panel offers the same steps as buttons: Get vsys raises the shell's install notice for vsys, and Set up opens `vsys warden install` in a floating terminal.

## The shield

The bar widget draws one shield in the tone of the service's state, with the Lucide icon and the `Theme.badge.tone` group below. The words, icons and tones are `ViewLogic.js`.

| State | Icon | Tone | Count | Tooltip, for example |
|---|---|---|---|---|
| `calm` | `shield-check` | neutral | agents running | 3 agents running within their limits |
| `working` | `shield-check` | accent, one pulse on entering | agents running | Moved 1 agent back into limits 2 min ago |
| `look` | `shield-alert` | warning | things that need a look | claude in vgs is using a lot of memory |
| `problem` | `shield-x` | danger | things that need attention | Agents are close to their memory limit |
| `not-checking` | `shield-off` | neutral | none | Agent Warden hasn't checked in 3 min |
| `not-set-up` | `shield-question-mark` | neutral | none | Agent Warden isn't set up |
| `update-warden` | `shield-alert` | warning | none | Agent Warden needs an update |

A count of zero is not drawn. A click opens or closes the panel under the shield.

| Setting | Default | Effect |
|---|---|---|
| `showCount` | `true` | Draws the count beside the shield. |
| `hideWhenIdle` | `false` | Hides the shield while the state is `calm` and no agent runs. |

## The panel

The panel shows the heading Agents, one sentence for the state, at most three items, most serious first, and the agent group's memory against its slowdown point. The meter is hidden when the warden did not report the memory or a limit. No text names a process id or a scope unit, because the published `detail` holds neither. A footer shows the time of the last check and Open vsys, which opens the `vsys` TUI: the vsys dashboard in a wide floating terminal. While vsys is missing, the link is Get vsys.

When vsys is installed, each open runs `vsys --once --summary` once, and the panel shows vsys's verdict on the whole computer as one line: nothing wrong, the number of things worth a look, or the number of problems. It reads only the verdict's levels ([vsys verdict.md § Summary JSON](https://github.com/vanillagreencom/vsys/blob/main/docs/architecture/verdict.md#summary-json)) and never shows a verdict's subject. A run that fails, or a summary of another schema, is logged as `agent-warden: summary=...` and shows no line.

A state that needs a setup step shows one button in place of the items:

| State | Button | What it does |
|---|---|---|
| `not-set-up` | Set up | Opens the `setup` TUI, which runs `vsys warden install`. |
| `update-warden` | Update | The same: the installer rewrites an older warden's units. |
| `not-checking`, stale | Start it | Runs `systemctl --user start agent-warden.timer` through the `run` capability. |
| `not-set-up` or `update-warden` without vsys | Get vsys | Raises the shell's requirement notice for vsys through `shell.requirements.offer`. |

A press that hands off closes the panel. A refusal stays in the panel as one sentence, such as "No terminal was found to open it in.", and is logged as `agent-warden: action=<action> <reply>`.

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

The service publishes these values through the core `status` capability ([status.md](../../../docs/architecture/status.md)). The first four are the plugin's read-only rows on its Settings page.

| Key | Type | Value |
|---|---|---|
| `warden` | state | Checking, Last scan failed, Stopped checking, Status unreadable, Status format not supported, Not set up, or Update the warden. The row shows `vsys warden install` to copy. |
| `agents` | count | The agents running at the last check: lanes with an identified agent that are not leftover work. Not reported until a status lists them. |
| `lastCheck` | time | The time of the last status the warden wrote. |
| `vsys` | presence | `present` or `absent`, as the shell's last plugin scan found `vsys` on PATH. The row shows the vsys installer to copy. |
| `detail` | data | `{ state, reason, checkedAt, agents, issues, items, memory }`, which the plugin's widget and flyout read: the state and its reason, the check time in milliseconds, the agent count, the number of `problem` and `look` items, the items most serious first, and the agent group's memory in bytes, `{ used, high, max }`, or null when unknown. Each item is `{ kind, level, ... }` with numbers and tool names, and never a process id or a scope name. `WardenLogic.itemsOf` lists the kinds. |

`WardenLogic.gib` turns a byte count into the figure the plugin's copy shows with "GB": gibibytes, one decimal below 10 and whole from 10.

## IPC

| Name | Reply |
|---|---|
| `status` | The published values as one JSON line. |

`bin/vgsh ipc call vgs.agent-warden invoke status`

## Validation

- `scripts/test-agent-warden-logic.js` reads vsys's fixtures and pins every refusal, every state, the next moment each state can change, the Settings row and the published keys, with a control per rule.
- `scripts/test-agent-warden-view.js` pins the shield, the panel's sentence, items, meter, buttons and check time for each fixture and each other state, the words for each reply, and the summary reading. It checks that no text names a fixture's scope unit or process id. Its controls include a logic copy that hands the view a scope name.
- `scripts/smoke/rows/agent-warden.sh` writes each fixture into the sandbox's runtime directory by rename, as the warden does, and reads the published status and the Settings rows back. A status written 85 seconds back and left unchanged turns stale on the service's timer. It reads the shield's icon, tone, count and tooltip and every text of the panel back for each state, and checks that none names a scope unit or a process id. Set up and Open vsys hand a stand-in terminal their TUI's argv, Start it hands a stand-in `systemctl` its arguments, and Get vsys raises the shell's notice on a host without vsys. Its controls are a copy of the plugin whose logic ignores staleness, which reads a stale status as calm, a copy whose timer derives nothing, which keeps the unchanged status calm past its stale moment, and a copy whose logic hands the view each lane's scope unit, which the panel then draws.
