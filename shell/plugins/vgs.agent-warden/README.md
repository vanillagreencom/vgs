# Agent Warden

`vgs.agent-warden` shows whether the agent warden keeps your AI agents within their memory and task limits. The warden ships with [vsys](https://github.com/vanillagreencom/vsys) and runs as a systemd user timer every 30 seconds, whether or not the shell runs. The plugin reads what the warden reports. It never starts, stops or configures the warden, and never moves or stops an agent. [D041](../../../docs/decisions/D041-agent-warden-observes-the-vsys-warden.md) records why.

## Setting up the warden

1. Install vsys: `curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vsys/main/install.sh | bash`, or `paru -S vsys` on Arch Linux.
2. Run `vsys warden install` once. It writes the warden's systemd user units and starts its timer.

The plugin's Settings page shows both commands with a Copy button.

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
- `scripts/smoke/rows/agent-warden.sh` writes each fixture into the sandbox's runtime directory by rename, as the warden does, and reads the published status and the Settings rows back. A status written 85 seconds back and left unchanged turns stale on the service's timer. Its controls are a copy of the plugin whose logic ignores staleness, which reads a stale status as calm, and a copy whose timer derives nothing, which keeps the unchanged status calm past its stale moment.
