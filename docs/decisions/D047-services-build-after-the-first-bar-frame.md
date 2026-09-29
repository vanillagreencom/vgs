# D047: Services build after the first bars present a frame

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: VGS-587, which measured each build of the first scan's turn with an instrumented copy of the shell; VGS-592

**Context**: After the first plugin scan the core built every enabled instance in one synchronous turn: the bar and its widgets, each background and each service. `Plugins.attemptInstance` calls `Qt.createComponent` and `createObject` synchronously. The bar's layer surface reaches the compositor only after that turn returns, so every service build delayed the first bar. VGS-587 measured the vgs.notifications service alone at 43 to 50 ms. Every first-party plugin with a kind other than `bar` is enabled by default, so a live session builds seven services before its first bar. On host cachy on 2026-09-29, `scripts/qml-smoke.sh --first-bar-runs 12 --plugin-set default` read 307 to 344 ms on the tree before this change; the smoke's own set, which disables six of the nine shipped plugins, read 215 to 281 ms.

**Decision**: The core builds services only after every bar it built for the first applied scan has presented its first frame. `shell/Core/ServiceGate.qml` holds the decision and its latch, and `ServiceHost` builds nothing until the latch opens.

- **The latch.** It opens once per shell process and never closes. A service enabled later, a rescan, a screen change or a bar rebuild builds services at once, as before.
- **The frame.** A bar has presented when its window emits `frameSwapped`, which Qt emits when a frame is queued for presenting ([runtime-qml.md](../architecture/runtime-qml.md)). One event-loop turn is not enough. A copy of the gate that released on its first deferred judgement read 288 to 330 ms over 12 default-set runs on the same host, close to the tree with no gate.
- **Judged outside the scan's turn.** The gate judges on a deferred call after `scanFinished`, on each bar frame and on each change of the build records. It judges nothing before an applied scan and a ready configuration. Inside the scan's turn a binding can still hold its value from before the scan.
- **No bar.** With no bar built for that scan, the latch opens at once, with reason `no-bar`. This covers no screen, and an active bar that is disabled, unknown, refused or broken.
- **Deadline.** A bar that never presents, as on a monitor the compositor configures no surface for, holds the services for 358 ms at most. That is twice the highest wait the gate logged over 33 first-bar runs, 179 ms. The release then logs one warning naming the bar hosts that did not present.
- **Readback.** The release logs `plugins: services released reason=<first-frame|no-bar|deadline> waited_ms=<ms>`. `waited_ms` runs from the first judgement that found a bar unpresented. `scripts/qml-smoke.sh --first-bar-runs` prints each run's release beside its first-bar reading.
- **Lending at start.** Bars, their widgets and backgrounds build in the scan's turn and claim first. So a surface plugin wins an exclusive capability (`lock`, `polkit`) that a service also names. The tree without the gate gave the same answer on the smoke fixtures, through the order in which the scan reaches the hosts' bindings. The gate makes that order a rule. After start, lending is first come, as before.
- **Theme follow.** The follow on `scanFinished` stays independent of the gate. It is queued in the turn each scan ends, the start's included, and never waits for a bar frame.

### The options

| Option | Verdict |
|---|---|
| A. The core builds services after the first bars present a frame | Taken. No service build delays the first bar, whatever a plugin imports, and no plugin changes. |
| B. The core builds services one event-loop turn after the bars | Rejected. Measured at 288 to 330 ms, against 206 to 271 ms for A: the deferred call runs before the bar reaches the compositor. |
| C. A plugin-contract rule: split each service's entry point into a `Loader`-held subcomponent | Rejected. QML compiles a component's imports when the component is created, so every plugin would need the change, and one that skips it delays the bar again. |
| D. Build services asynchronously through `Component.incubateObject` | Rejected. The build records, the lending check and the facade assignment run synchronously around `createObject`. An incubated build would need a second path through all three. |

**Rationale**:

- The bar is the first thing a user sees. A service has no surface, and no user waits on it in the first second.
- One owner decides and latches. Every host keeps its own build path, and a later enable keeps today's timing.
- A bounded wait keeps a bar that never presents from holding the services forever. Its warning names the host, so the fault is not silent.

## Where VGS differs from Omarchy

Checked against basecamp/omarchy `main` at `b421b1b`: `shell/shell.qml` (`defaultBarLoader`, `_syncServices`, `ensureService`). Omarchy's shell compiles its default bar in and loads it in a `Loader` when the shell completes, with no wait for the plugin scan. It builds each service synchronously, through `Qt.createComponent(url, Component.PreferSynchronous)`, when the scan lands. Its first bar therefore never waits on a service, because the bar never waits on the scan.

| Omarchy | VGS | Why |
|---|---|---|
| The default bar is part of the shell and needs no scan. | The bar is a plugin the scan finds ([D003](D003-everything-is-a-plugin.md)). | VGS names no plugin in its core, so the bar cannot build before the scan. The services wait instead. |
| Services build synchronously in the scan's turn. | Services build after the first bar frame. | In VGS that turn also builds the bar, so its services would delay it. |

**Revisit When**: Quickshell or Qt gives a layer surface a signal for its first presented frame; a service must be running before the first bar maps; or the core builds plugin instances asynchronously.

**Verification**: `scripts/smoke/rows/start-order.sh` restarts the sandbox over the default set, plus a background and a service that both name `lock`, with no compiled QML cache. It reads the first bar within the default set's budget and the release with reason `first-frame`. From the probe's start order it reads every bar frame before the first service build, and the start's follow queued in its scan's turn. It reads the lock held by the background, and one follow for a rescan. With the bar disabled it reads `no-bar`. With a bar window that is never shown it reads `deadline`, the warning and the services built. Its controls are copies of the tree: a service host with no gate builds a service before the first frame; a background host that waits for a built service leaves the lock with the service; a follow on the release is queued after its scan's turn; a follow held to the gate queues none for a rescan; a gate that waits when no bar is built never releases; and a gate with no deadline never releases past a bar that never presents. The readings are in [validation-latency.md](../architecture/validation-latency.md).

**References**: [D003](D003-everything-is-a-plugin.md), [D008](D008-validation-row-per-change.md), [runtime.md § Performance](../architecture/runtime.md#performance), [capabilities.md](../architecture/capabilities.md)
