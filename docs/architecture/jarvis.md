# Jarvis

Covers: shell/Core/SessionLock.qml, shell/plugins/vgs.jarvis/, scripts/test-jarvis-protocol.js, scripts/test-jarvis-daemon.js, scripts/fixtures/jarvis/, scripts/smoke/fixtures/plugins/acme.session/, scripts/smoke/rows/session.sh, scripts/smoke/rows/jarvis.sh, docs/plans/v2-jarvis-plan.md, shell/Hosts/LayerHost.qml

The [Jarvis plan](../plans/v2-jarvis-plan.md) defines the voice assistant's scope. The service owns one Node child and publishes its health. This skeleton captures no audio, opens no account or socket, and runs no tool. [D064](../decisions/D064-jarvis-child-lease.md) records the process choice.

## Session observation

A privacy-sensitive service declares capability `session` and binds to `shell.session.locked`. The [capability contract](capabilities.md) defines that state and its tests. It grants no lock authority and introduces no dependency on a lock plugin: [D056](../decisions/D056-read-only-session-state.md).

The service must treat a missing lock state as unknown, not unlocked. The skeleton treats a missing shell as locked. Each hello carries the observed lock state. The daemon answers `locked` or `ready`, and neither state permits capture. The core capability does not enforce capture or action policy.

## Setting options

The starred strings in [the plan's settings section](../plans/v2-jarvis-plan.md#310-settings-status-and-files) use `optionsFrom`: voice, language, microphone, speaker, brain, model and coding agent. The service that owns discovery publishes each offer list through its plugin's declared `choices` status. A label names the choice to the user; its stable id is the setting.

[status.md § Setting choices](status.md#setting-choices) defines the generic shape, bounds, empty-string first-offered convention and retained unavailable ids. [D057](../decisions/D057-setting-options-from-status.md) records the core choice and its Omarchy comparison. The future Jarvis consumer resolves empty string from its own first offer and treats no offers as no selection. Discovery failure must not silently change the configured provider or device.

The generic fixture `acme.status`, not a Jarvis skeleton, proves the Settings Select in `scripts/smoke/rows/settings.sh`. It uses synthetic offers and writes only the sandbox's configuration. No microphone, speaker, provider account or network is needed.

## Passive input

The core supports the [passive layer input contract](layers.md), refined by [D058](../decisions/D058-layer-input-union.md). The bubble's layout and capture indicator remain plugin work in the [plan's Bubble and orb section](../plans/v2-jarvis-plan.md#43-bubble-and-orb).

## Ownership

- `Service.qml` owns the Process, its parsers, the hello deadline and the restart timer. Disable destroys that owner. It closes stdin before Quickshell destroys the Process. A crashed shell closes the pipe without running QML teardown.
- The daemon exits when stdin closes. No systemd unit or detached process keeps it alive. It uses the shared library loader from the real VGS tree, passed as argv, because its published plugin snapshot contains no core files.
- A successful hello does not replenish the restart allowance. Five restarts use exponential delays, then the service publishes a problem and raises one toast. The hello deadline bounds a child that starts but sends no answer. These are recovery rules, not measured latency budgets.
- Node below the plugin floor refuses before reading hello. The manifest names only the command this skeleton runs. D035 supplies the install notice; the plugin runs no installer.

## Wire

`JarvisProtocol.js::accept` owns the implemented v1 shapes and directions. Its header defines the current type set. Unknown types, extra or missing fields and oversized lines fail with a keyed protocol error. Future wire types enter that judge only when both endpoints consume them.

The service takes settings from `shell.settings`, the revision from the registry-owned `shell.manifest.__revision`, state storage from `Paths.stateDir`, and data/runtime roots from the shell's XDG environment. This skeleton has no settings or binds, so those hello records are empty. The daemon validates the complete snapshot and echoes its revision and generation in status. It creates none of those directories. A lock change sends a new snapshot. Conversation generations and the region reducer belong to J11.

Both endpoints frame chunks before retaining an unfinished line. QML uses `SplitParser` with an empty `splitMarker`, not its default unbounded line buffer. The daemon uses a UTF-8 decoder across reads. [The Quickshell 0.3.1 reference](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/SplitParser/) documents arbitrary chunk lengths for the empty marker. The [Process reference](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/Process/) documents stdin closure, explicit environments and restart from `runningChanged`.

## Boundaries still owned by later rows

J13 owns audio process lifetime, forced daemon death ending its children, and capture refusal during lock, mute or unknown lock state. J16 owns the mapped indicator handshake. This skeleton has no audio or indicator implementation. The region state, modes, policy, engines, accounts and user interfaces stay with their assigned issues.

## Evidence

- `scripts/test-jarvis-protocol.js` pins shape, direction, unknown-type and UTF-8 line-bound refusals with per-rule controls.
- `scripts/test-jarvis-daemon.js` runs the real daemon and lease controls through the [J09 test world](validation-jarvis.md). Its fixture parameters enter as arguments. No caller environment reaches the world.
- `scripts/smoke/rows/jarvis.sh` reads a real answer, disables the service, reads both owned PIDs gone, and exhausts the restart allowance. Its disposable six-retry copy breaks the five-retry assertion.
- Every IPC JSON reader in that row follows the shared [smoke reader rule](validation-smoke-harness.md). State words and empty replies do not enter a direct JSON parse.
- `scripts/smoke/rows/read-only-prefix.sh` adds the shared test observer to its disposable installed tree, then starts the installed service and gets its answer with the prefix non-writable. The existing tree snapshot assertion checks that startup changes no installed file.
- Smoke instruments only disposable service copies to launch the child through the real J09 helper. `scripts/fixtures/jarvis/prepare.js` keeps that instrumentation in one place. The helper itself owns worktree-local scratch allocation. A fixture launcher carries the stdin pipe through a descriptor, because Bash replaces stdin with `/dev/null` for the helper's asynchronous namespace supervisor. It restores stdin inside the namespace before executing the real daemon.

## Omarchy comparison

The read-only Omarchy shell reference's `plugins/agents/Main.qml` separates display from external collectors. VGS keeps that separation, with the daemon as the worker and the service as its health publisher. Omarchy's collectors do not own a continuously leased child.

The read-only omarchy-voice reference's `share/omarchy-voice.service` uses a graphical-session systemd unit with restart limiting. VGS keeps bounded restart but ties the daemon to the enabled service's stdin instead. A unit can outlive the shell and its future capture indicator. J13 and J16 must enforce the audio and indicator promises before capture exists.
