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
| `notify` | `problems` | Which notices go out: `problems`, `everything` or `off`. [§ Notifications](#notifications) lists each one. |

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

## Notifications

The service sends one desktop notification when something starts to need a look, and again only after it has cleared and comes back. It takes over from the warden's own notices and words them for people. The service's contract, the heartbeat that takes the notices over and the rules for each episode are [agent-warden.md § Notifications](../../../docs/architecture/agent-warden.md#notifications).

| Kind | Scope | Opens when | Title, for example | Urgency | Open vsys |
|---|---|---|---|---|---|
| `tasks` | the lane's unit | an agent's lane is near its task ceiling | An agent is starting a lot of processes | normal | yes |
| `memory` | the lane's unit | an agent's lane is near its memory ceiling | An agent is using a lot of memory | normal | yes |
| `not-moving` | `agents.slice` | moves wait for memory headroom | Agents are close to their memory limit | critical | yes |
| `move-failure` | the tree's unit | a move failed or left part behind in the last 5 minutes | Couldn't fully move an agent | normal | yes |
| `reaped` | the leftover unit | leftover work was stopped in the last 5 minutes | Cleaned up after a finished agent | low | no |
| `not-checking` | `agent-warden` | the status is stale | Agent Warden has stopped checking | normal | no |
| `moved` | the tree's unit | an agent was moved back into its limits in the last 5 minutes | Moved an agent back into its limits | toast | no |

`problems`, the default, sends every kind but `moved`, which the panel shows. `everything` also shows each move as a toast, the only toast the plugin shows. `off` sends nothing. The cleanups and the moves one status opens go out as one notice. The body gives the numbers from `status.json`, GB for GiB values through `WardenLogic.gib`, and the tool and worktree as the panel names them, and never a process id or a scope unit.

## IPC

| Name | Reply |
|---|---|
| `status` | The published values as one JSON line. |

`bin/vgsh ipc call vgs.agent-warden invoke status`

## Validation

The service's reading, notices and their checks: [agent-warden.md § Validation](../../../docs/architecture/agent-warden.md#validation).
