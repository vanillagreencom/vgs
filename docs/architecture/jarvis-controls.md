# Jarvis controls and wire

Covers: shell/plugins/vgs.jarvis/manifest.json, shell/plugins/vgs.jarvis/Service.qml, shell/plugins/vgs.jarvis/JarvisProtocol.js, shell/plugins/vgs.jarvis/Session.js, shell/plugins/vgs.jarvis/backend/jarvisd.js, shell/plugins/vgs.jarvis/backend/session-runner.js, scripts/fixtures/jarvis/scripted.js, scripts/smoke/rows/jarvis-keys.sh, scripts/test-jarvis-daemon.js, scripts/test-jarvis-protocol.js

The [Jarvis architecture](jarvis.md) owns the service, child lease and Session regions. The installed daemon remains unconfigured. It installs real [audio ports](jarvis-audio.md), while speech and indicator prerequisites remain unavailable. Its [router](jarvis-approval.md) registers the [window and application executors](jarvis-desktop-tools.md) and [clipboard, media and notify executors](jarvis-tools.md), which no brain calls yet. The controls cannot open a microphone, speaker or provider.

## Keys and modes

The manifest declares only controls with a consumer. Settings edits mode and the declared keys through the core's existing page. Always mode, confirmation and console binds remain absent until their assigned owners implement them.

The service registers talk with the [core hold-shortcut contract](hyprland-shortcuts.md#hold-shortcuts), recorded by [D071](../decisions/D071-hold-shortcuts-use-a-release-companion.md). The core owns repeated-down suppression, release, rebind cancellation and disposal. Jarvis adds no second physical-hold owner.

`Session.js` selects hold or toggle from its settings. In hold, down interrupts before collecting; up closes capture and the engine supplies its final transcript. In toggle, down opens or ends conversation demand; up does nothing. The existing Session debounce applies to toggle presses. A mode change ends the conversation. Local turn detection and always listening remain separate work.

Stop ends conversation demand; it does not stop a coding task ([task control](jarvis-task-control.md#stop)). During thinking it cancels the brain operation. During speaking it flushes playback. The existing Session identity check discards late content and playback callbacks from that ended turn.

The service waits for a complete effective key map before sending a snapshot. Enablement and disposal can change the registry before they change the instance. An unbound or conflicting key still appears as null in a complete map. The daemon validates the map's wire shape; the core remains the key-syntax and conflict judge.

## Privacy mute

The mute shortcut sends one intent. The [bar widget](jarvis-widget.md#mute-path) sends the same intent through the service's `mute` IPC handler. Session converts it to `mute-toggle`. From off, it ends conversation demand, cancels thinking, flushes playback and emits `mute-store(true)`. Mute stays muting until capture acknowledges close. A second mute press during that close does nothing. From on, the same intent emits `mute-store(false)` without restoring demand. Talk and stop cannot clear mute.

Before the first current state or during retry, the service retains one pending mute request in its existing lifetime. Repeated presses keep that request. An unavailable daemon has no current toggle state, so the pending request means mute on, never unmute. The service waits for a state matching the current lock observation. It sends mute only if that state is off, using its observed generation. It waits for on before clearing the request. A retry retains the request and cannot toggle a restored mute off. Talk and Stop are not buffered.

The pending notice tells the user that disabling Jarvis cancels an unconfirmed request. Disposal drops that owner without changing the saved mute record. A permanent problem refuses Mute with a toast naming the daemon's cause. An unconfirmed pending request also reports that cause when recovery ends. No pending request grants capture.

`session-runner.js` delivers the storage effect to the daemon. The daemon writes only `mute.json` in the hello's state directory. Its exact record is `{ "muted": boolean }`. The writer creates a private file and renames it whole; it never writes a plugin snapshot or shell configuration. Startup reads a bounded record before applying the first snapshot. An absent record means unmuted. A malformed or unreadable record refuses startup with exit 78.

A failed storage effect also exits 78 after Session teardown. The service reports that cause without automatic retry. That failure is not a successful privacy save. Normal daemon, service and shell restarts read the same persistent state directory. The daemon never copies mute into the mode setting.

## Wire

`JarvisProtocol.js::accept` owns the implemented v1 shapes and directions. Its header defines the current type set. Unknown types, extra or missing fields and oversized lines fail with a keyed protocol error. Future wire types enter that judge only when both endpoints consume them.

The service takes settings from `shell.settings`, the revision from the registry-owned `shell.manifest.__revision`, state storage from `Paths.stateDir`, and data/runtime roots from the shell's XDG environment. Hello carries the implemented mode, microphone, speaker and brain selections and effective shortcut map. The daemon validates the complete snapshot. Its first hello prepares the [coding-task store and data engine](jarvis-tasks.md) before restoring privacy mute. Later snapshots and intents do not repeat task recovery. Lock, mode, device selection, brain selection and effective-key changes send a new snapshot while the child is starting or ready. A failure or teardown permits no further send.

Intent carries its name, revision and observed generation. Talk down, talk up, mute and stop have both endpoint consumers. Mute reaches Session even while locked or unconfigured. An intent before hello or for another revision fails. A later hello cannot move the daemon to another state directory or revision.

Approval intent `confirm` adds `{id,digest,source}`. Source is key or button, never voice or model. Intent `cancel` adds `{id}`. Type `shown` carries `{v,type,gen,revision,id}`. The UUID names the held action; the digest is lower-case SHA-256 hex. Session checks the observed generation and live hold. Shown reaches the hold's existing operation, but a wrong id or generation cannot set its drawing time. Cancel cannot retire another hold. The current Service sends none of these messages; J20 supplies their user intent producers. Only daemon-internal final-transcript matching may produce voice confirmation.

The daemon owns generation identity. Hello and intent carry the service's last observation, initially zero; neither can assign a daemon generation. Key edges are ordered input, not adapter callbacks. The daemon accepts an up even when its observed generation predates the immediately preceding down. Status and state carry the current generation and snapshot revision. State also carries the ordered sequence, regions and phase. `JarvisProtocol.accept` uses `Session.validate` for the record and `Session.phaseOf` for the phase. One daemon writer and the stdin/stdout pipes preserve order. The service filters replies to earlier lock observations. It clears detail and its Session copy when the child ends, before it reports a retry or a problem, and again before child restart. Other adapter messages remain outside the wire.

A `transcript` message carries one speaker's caption segment: `role` user or assistant, `text` of at most 4096 characters without control characters, `stage` partial or final, and a rising `rev`. The daemon writes Session's `transcript` effects. The service publishes the current generation's caption, with its `gen`, as the `transcript` data status, and drops one from another generation.

Key presence uses a separate service-owned reader, not a new daemon wire type. The coding-task types `task-stop`, `tui-state`, `tasks` and `task-answer` belong to [task control](jarvis-task-control.md#display). Task display uses the shared `request` and `reply` owner below. Hello also carries `taskTerminal`.

The daemon asks the service to act with `request`; the service answers each with one `reply`. [Jarvis desktop tools § Request wire](jarvis-desktop-tools.md#request-wire) defines their kinds, bounds and stale replies.

Both endpoints frame chunks before retaining an unfinished line. QML uses `SplitParser` with an empty `splitMarker`, not its default unbounded line buffer. The daemon uses a UTF-8 decoder across reads. [The Quickshell 0.3.1 reference](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/SplitParser/) documents arbitrary chunk lengths for the empty marker. The [Process reference](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/Process/) documents stdin closure, explicit environments and restart from `runningChanged`.

## Evidence

- The Session suite tests mode selection, mute storage effects and muted key input. Its ordered event matrix includes mute-toggle. The runner suite tests both storage values and controls dropped delivery.
- The protocol suite pins the manifest defaults, settings and effective-key shape, implemented intent set, directions and refusals. Its mutation controls remove each new wire rule.
- The daemon suite runs stock and disposable scripted copies in the [private test world](validation-jarvis.md). It tests persisted mute, restart, corrupt and oversized records, storage failure, immediate down/up with an old observed generation, repeat, hold phases, toggle release and conversation close. Restored mute still publishes read-only device offers; tying discovery to the first reducer sequence breaks that assertion. Active Stop cases assert ended conversation, cancellation or flush, closed capture and idle playback. Their late callbacks increase the discarded count without restarting playback. Stop-to-talk-up controls retain the original dispatch and fail those same active assertions. Other controls drop the intent consumer, save or restore, and remove record bounds and shape checks. Its task cases belong to [task control](jarvis-task-control.md#evidence).
- `scripts/fixtures/jarvis/scripted.js` supplies only test ports and explicit file gates, including late callbacks after cancellation and flush. Tests copy it beside a disposable daemon and instrument that copy. The installed daemon has no fixture option, import or environment switch.
- `scripts/smoke/rows/jarvis-keys.sh` uses the existing physical-key helper and hold-row fixture functions. It reads listening, thinking, speaking and idle from the real service. It also reads active Stop teardown and late callback rejection, toggle demand, pending mute teardown, restart mute, muted key refusal and native shortcut cleanup. Startup and retry cases press physical Mute before the gated daemon can answer. They cover repeats, restored mute, lock changes and disable cancellation. A permanent-problem key case reads the real refusal toast and cause. Controls retain the key triggers and remove pending delivery or refusal, misroute Stop to talk-up, or drop release delivery. The same behavioral assertions fail once per control. State reads poll once per IPC round trip. The modifier-independent ordering marker works while talk remains held. No latency budget is claimed.

## Omarchy comparison

The read-only Omarchy shell reference's `plugins/agents/Main.qml` keeps the worker outside the display. VGS keeps its leased daemon and service boundary.

The read-only omarchy-voice reference's `share/bindings.lua.snippet` supplies a toggle key that calls its CLI. `src/omarchy_voice/session.py` forwards control over a Unix socket. VGS uses the existing shortcut capability and the child's ordered stdio wire instead. It needs no per-key process or second control socket. Hold remains the plan's default. Privacy mute is separate from conversation demand and persists before a later process can acquire capture.
