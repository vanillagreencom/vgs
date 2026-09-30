# D041: Agent Warden observes the warden vsys ships; the enforcer stays a systemd user timer

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: [v2-platform-roadmap.md](../plans/v2-platform-roadmap.md) § Decisions row 4 and § vgs.agent-warden, from the research report `agent-warden.md` (options A-F, § Tradeoffs)

**Refines**: [D037](D037-plugin-status.md), [D035](D035-manifest-requirements.md)

**Context**: The owner's agent warden keeps AI coding agents inside `agents.slice`. It moves escaped processes by pidfd through libsystemd, caps scopes without limits, and stops leftover work that has become harmful. A systemd user timer runs it every 30 s in `background.slice`. The owner wants every VGS user to see, on every screen, whether their agents stay within limits, without knowing what a cgroup is. The shell cannot take the enforcer's place, for three reasons. QML cannot hold a pidfd or call libsystemd. Correction must keep working while the shell restarts or has crashed. And the plugin manager may not install systemd units or ask for privilege ([D007](D007-install-runs-no-plugin-code.md), overview invariant 5). vsys now ships the warden, `vsys warden install` sets it up as the user, and the warden writes a versioned `status.json` of numbers and ids every tick ([vsys warden-status.md](https://github.com/vanillagreencom/vsys/blob/main/docs/architecture/warden-status.md), schema 1.0).

**Decision**: The warden stays a systemd user timer that vsys ships and the user installs. `vgs.agent-warden` observes it and never enforces.

- **Reader.** The plugin's service is the one reader of `$XDG_RUNTIME_DIR/agent-warden/status.json`, through `WatchedFile`. `WardenLogic.readStatus` reads schema major 1 and checks only the fields the plugin uses. A newer minor's fields and enum values are skipped, and any other major is refused whole, as the vsys contract asks of consumers. The service makes the directory before its watch starts, because a watcher never sees a file appear in a directory that did not exist when it was built ([runtime-qml.md](../architecture/runtime-qml.md)).
- **States.** `WardenLogic.derive` maps one read and the current time to one of seven consumer states: Calm, Working, Needs a look, Problem, Not checking, Not set up and Update the warden. A status more than 90 s from now is stale, which is three missed ticks. `WardenLogic.nextChange` names the next moment the state can change with the file unchanged: the stale moment, or the end of a recent event's window. The service holds one single-shot timer to that moment, so a warden that stops writing reads as Not checking 90 s after its last tick, not at the next tick of the shared minute clock. A `state.json` without a `status.json` is an older warden, shown as Update the warden. The plugin never parses that file, since it is the old warden's private state.
- **Published.** The service publishes `warden`, `agents`, `lastCheck` and `vsys` as the plugin's read-only Settings rows, and `detail` as data for the widget and the flyout, through the `status` capability ([D037](D037-plugin-status.md)). `detail` carries numbers and tool names and never a process id or a scope unit, so the flyout cannot show one.
- **vsys presence.** The `vsys` row reads the scan's answer for the plugin's declared requirement through `shell.requirements.missing`. That is a read of the probe [D035](D035-manifest-requirements.md) already runs, so the plugin runs no probe of its own.
- **Notices.** The plugin takes over the warden's desktop notices through the warden's hand-off: while `$XDG_RUNTIME_DIR/agent-warden/notifier` is less than 120 s old, the warden sends none. The service touches that file every 60 s. It lands in the same change as the notices the plugin sends, because a heartbeat with no sender turns the warden's notices off and puts nothing in their place. For the same reason the service touches it only while it reads a status and the scan finds `notify-send`: a status the plugin cannot read, such as a newer schema major, or a desktop without `notify-send`, gives the notices back to the warden within 120 s. `notify: off` keeps the heartbeat, so the user's off silences both notifiers; without it, off would bring back the warden's developer-worded notices the user just turned off. A shell that hangs without exiting silences both notifiers until the heartbeat is 120 s old. This is accepted. The notices' rules are [agent-warden.md § Notifications](../architecture/agent-warden.md#notifications).
- **Summary.** `vsys --once --summary` runs inside the flyout, once each time it opens. A panel is built on summon and destroyed on hide, so its lifetime is exactly one open. The service receives no signal when a panel opens, and the plugin contract has no channel from a panel to a service.
- **Links.** Open vsys and Set up run through the core `tui` capability ([D033](D033-floating-tuis-are-core.md)). The plugin never builds a command string or asks for privilege.

### The options

| Option | Verdict |
|---|---|
| A. The plugin observes, notifies and links; the warden stays a systemd user timer | Taken. The enforcer keeps its own failure domain and runs whether or not the shell does. The plugin needs no capability the core lacks. |
| B. Port the corrector into a VGS `service` | Rejected. QML has no pidfd or libsystemd path, correction would stop with the shell, and the shell process would carry an agent mover's failure modes ([D010](D010-facade-scope-not-sandbox.md)). |
| C. Poll `agent-warden --status` | Rejected. It prints a text table and scans every process's environment on each call. |
| D. Poll `vsys --once` from the bar | Rejected. It is a full collection with a scratch scan, and it exports no verdict. The flyout runs the cheap `--summary` once per open instead. |
| E. Merge the warden into the vsys dashboard | Rejected. The dashboard's promise is read-only unless the user confirms an action, and an automatic corrector breaks it. |
| F. Ship the warden from the vsys repository as a separate component | Taken with A. vsys observes and the warden corrects (the vsys decision to ship the warden as a separate vsys component, in the [vsys decision log](https://github.com/vanillagreencom/vsys/blob/main/docs/decisions/INDEX.md)), with one agent-tool list and one install story. |

**Rationale**:

- Enforcement has to survive the shell. Observation does not, so observation belongs in the shell and enforcement stays out of it.
- One reader and one published record follow D037: the service reads one file for every screen's widget, the flyout and the Settings page, and they read its answer.
- Numbers and ids on the wire, with the words in the plugin, let the warden stay silent about wording. The plugin can then rewrite its copy without a warden release.
- Refusing an unknown major rather than reading what can be read turns a format change into a visible Not checking state. A silently wrong Calm is the failure this rule prevents.

## Where VGS differs from Omarchy

Checked against basecamp/omarchy `main` at `e332dc9`: `shell/plugins/agents/{manifest.json,Main.qml,Panel.qml,README.md}`, `bin/omarchy-agent-usage-update`, `shell/plugins/bar/widgets/SystemUpdate.qml`. Omarchy has no counterpart to the warden: nothing confines agents or reports confinement. Its `omarchy.agents` plugin shows AI subscription usage, and it is the closest pattern.

| Omarchy | VGS | Why |
|---|---|---|
| A collector command writes one display-ready JSON record per agent under `~/.local/state/omarchy/agents/usage/`, and the plugin only watches and draws them. | The warden writes `status.json`, and the plugin only watches and draws it. | Taken: an outside program owns the data, and the shell is strictly a display. |
| The records carry display text. | The file carries numbers and ids, and the plugin owns every word. | The vsys contract keeps words in the consumer, so copy changes need no warden release. |
| The plugin runs the collector on a 900 s `Timer` and on each refresh. | The plugin runs nothing on a timer; the warden's own timer writes the file. | The warden already ticks every 30 s outside the shell. A second schedule would only add work. |
| The bar widget and its popup are one instance, so opening the popup calls `refreshLimits()` directly. | The panel is its own instance and runs `vsys --once --summary` in its own tree. | A VGS panel is a separate instance with no channel to the service, and it lives exactly one open. |
| `SystemUpdate.qml` shows a quiet icon and opens `omarchy-update` in a floating terminal on click. | The widget shows a quiet shield and opens vsys through a declared floating TUI. | Taken: the status-widget pattern. VGS passes the command as argv through the `tui` capability. |

**Revisit When**: The warden writes a status schema major other than 1; VGS gains a channel from a panel to its service; the core gains a notification capability or toast actions; or the warden moves into a runtime the shell can host.

**Verification**: `scripts/test-agent-warden-logic.js` reads vsys's fixtures and pins every refusal, every state, the next moment each state can change, the warden row and the published keys, with a control per rule, among them a logic copy that ignores staleness. `scripts/smoke/rows/agent-warden.sh` writes each fixture into the sandbox's runtime directory by rename and reads the published status and the Settings rows back. It reads `vsys` absent and present as a stub on PATH comes and goes. A status written 85 s back and left unchanged turns stale on the service's timer. Its controls are a copy of the plugin that ignores staleness, which reads a stale status as calm, and a copy whose timer derives nothing, which keeps the unchanged status calm past its stale moment. `scripts/test-agent-warden-notices.js` pins when the service owns the notices, the episodes each status opens, keeps and clears, the 64-episode ceiling, the notices each setting sends, their words and the `notify-send` argv, with a control per rule, among them a copy without episode memory and one that owns a status it cannot read. The smoke row records every notice through a stand-in `notify-send`: the heartbeat while a status reads, one notice per episode across ticks and again after it clears, nothing under `off`, a move as a toast under `everything`, a press that opens the vsys TUI, a failed or unstarted run sent again, and runs waiting for a press stopped at eight. Its notice controls are a copy without episode memory, one that keeps a failed run's episodes, one that never counts a waiting run and one that never gives a place back. `scripts/smoke/rows/notices.sh` reads `shell.requirements.missing` before and after the fixture's command is installed and removed.

**References**: [D007](D007-install-runs-no-plugin-code.md), [D010](D010-facade-scope-not-sandbox.md), [D033](D033-floating-tuis-are-core.md), [D035](D035-manifest-requirements.md), [D037](D037-plugin-status.md), [status.md](../architecture/status.md), [README](../../shell/plugins/vgs.agent-warden/README.md)
