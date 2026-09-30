# Jarvis

Covers: shell/Core/SessionLock.qml, shell/plugins/vgs.jarvis/, scripts/test-jarvis-session.js, scripts/test-jarvis-session-runner.js, scripts/test-jarvis-protocol.js, scripts/test-jarvis-daemon.js, scripts/fixtures/jarvis/, scripts/smoke/fixtures/plugins/acme.session/, scripts/smoke/rows/session.sh, scripts/smoke/rows/jarvis.sh, docs/plans/v2-jarvis-plan.md, shell/Hosts/LayerHost.qml

The [Jarvis plan](../plans/v2-jarvis-plan.md) defines the voice assistant's scope. The service owns one Node child and publishes its health and Session state. The daemon runs the region reducer, but this skeleton captures no audio, opens no account or socket, and runs no tool. [D064](../decisions/D064-jarvis-child-lease.md) records the process choice. The installed [action policy](jarvis-policy.md) judges reserved calls without making them usable.

The service also owns a metadata-only key presence probe. Settings opens the masked Add key terminal. Storage, lookup and the reference contract for future adapters and the accounts picker are in [jarvis-secrets.md](jarvis-secrets.md). The daemon still opens no provider account.

The [voice text contract](jarvis-voice.md) defines the shipped guidance and speech-text APIs for future engines. These modules do not start an engine or change the service's current behavior.

## Local speech inputs

[jarvis-local.md](jarvis-local.md) defines the independent artifact declaration, bounded model inputs, measurement instrument and execution oracle. [D066](../decisions/D066-pinned-local-speech-and-bounded-inputs.md) records the selected exports and caption path. These inputs register no plugin and do not implement the sidecar, setup or admission.

## Session observation

A privacy-sensitive service declares capability `session` and binds to `shell.session.locked`. The [capability contract](capabilities.md) defines that state and its tests. It grants no lock authority and introduces no dependency on a lock plugin: [D056](../decisions/D056-read-only-session-state.md).

The service treats a missing shell or lock value as locked. Each hello carries the observed lock state. The daemon answers `locked` or `ready` for health, and neither answer permits capture. Session stays down with reason `locked` or `unconfigured`. The core capability does not enforce capture or action policy.

## Session

`Session.js::reduce` owns all transitions. `Session.js::REGIONS` owns the tagged state shape; `phaseOf` owns phase priority. The reducer reads time only from the event. It returns a new state and ordered effects without changing its inputs.

- `shell/plugins/vgs.jarvis/backend/session-runner.js::SessionRunner` owns callback stamping, the event queue and the next deadline. Synchronous adapter callbacks enter the queue after the current transition's effects. It replaces its deadline timer after each drain. Lease loss forces brain close and releases the timer. Late callbacks cannot rearm a closed owner.
- The daemon supplies unavailable adapter ports. An acquisition through those ports throws an invariant error, never a simulated success. Every hello produces a real snapshot event; every resulting state reaches the service through the wire and becomes the plugin's `detail` status.
- The runner stamps capture, transcript, brain, playback, tool and approval callbacks with their effect's identity. A callback must match the region's live operation and generation. Session counts discarded callbacks. Cancellation acknowledgments and eventual tool outcomes retain their original identity across stop; they cannot update a newer turn.
- Conversation start, end and session-setting changes invalidate generation identity. `SESSION_SETTINGS` owns which settings end the session. Next-capture settings do not end it. The hello still accepts only empty settings; later settings enter the wire when the service can produce and the daemon can consume them.
- A repeated held edge changes nothing. A new press after release and the explicit interrupt event use `Session.js::interrupt`. It retires the previous collection and held approval, cancels thinking and flushes playback. A delayed final from the previous hold cannot close or replace the new hold. Release without hold demand changes nothing. Toggle collapse uses event time. The plan's debounce and thinking, approval and cancellation deadlines are behavioral rules, not measured latency budgets.
- Interrupt preserves a running tool. Stop requests tool cancellation only while the tool offers it. No new proposal starts in an interrupted conversation, alongside a running tool or while approval is held. Session grants no permission and accepts no confirmation; the policy and router own those decisions.
- Capture requires an up gate, unmuted state, a shown indicator and no fault or turn cancellation. Half-duplex also requires idle playback. Playback waits for capture's close acknowledgment before it starts without echo cancellation. Mute remains `muting` until that acknowledgment.
- Thinking cancellation retains its operation until acknowledgment or its deadline, then emits adapter close. Arriving callbacks also check expiry, so a delayed timer cannot admit late content. Each tool proposal carries its table row's deadline. An expired tool reports `unknown` but keeps the serial slot until its eventual completion, failure or unknown outcome. The outcome effect names the original brain operation even after stop. No audit writer or real brain delivery exists yet.

The `brain` region retains the acquired adapter identity after a response completes. A later send names that same owner while its turn receives a new operation. Conversation end closes a completed adapter immediately; an active response keeps its cancellation deadline. Lease loss forces either owner closed. Tool outcomes still name the original turn and tool operation after adapter close, not a newer conversation.

The `input` region retains demand while capture opens, closes or waits for playback. `conversation` separates active, interrupted and ended lifetimes. `indicator` and `duplex` record capture prerequisites. Playback admission, tool cancellation and tool deadline are tagged values inside their owning regions. They introduce no key handling, mode selection or audio implementation.

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
- The daemon's normal exit 78 is permanent configuration failure. The service publishes its Node-needed cause without a restart. VGS's package floor remains Node 18; only Jarvis requires Node 22.
- Node below the plugin floor refuses before reading hello. The manifest names the daemon and key flow's commands. D035 supplies the install notice; the plugin runs no installer.

## Wire

`JarvisProtocol.js::accept` owns the implemented v1 shapes and directions. Its header defines the current type set. Unknown types, extra or missing fields and oversized lines fail with a keyed protocol error. Future wire types enter that judge only when both endpoints consume them.

The service takes settings from `shell.settings`, the revision from the registry-owned `shell.manifest.__revision`, state storage from `Paths.stateDir`, and data/runtime roots from the shell's XDG environment. This skeleton has no settings or binds, so those hello records are empty. The daemon validates the complete snapshot and creates none of those directories. A lock change sends a new snapshot while the child is starting or ready. A failure or teardown permits no further send.

The daemon owns generation identity. Hello carries the service's last observation, initially zero; it cannot assign a daemon generation. Status and state carry the current generation and snapshot revision. State also carries the ordered sequence, regions and phase. `JarvisProtocol.accept` uses `Session.validate` for the record and `Session.phaseOf` for the phase. One daemon writer and the stdin/stdout pipes preserve order. The service filters replies to earlier lock observations and clears detail before child restart. Other intent and adapter messages remain outside the wire.

Key presence uses a separate service-owned reader, not a new daemon wire type.

Both endpoints frame chunks before retaining an unfinished line. QML uses `SplitParser` with an empty `splitMarker`, not its default unbounded line buffer. The daemon uses a UTF-8 decoder across reads. [The Quickshell 0.3.1 reference](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/SplitParser/) documents arbitrary chunk lengths for the empty marker. The [Process reference](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/Process/) documents stdin closure, explicit environments and restart from `runningChanged`.

## Boundaries still owned by later rows

J12 owns keys, mode selection and mute controls. J13 owns audio process lifetime, forced daemon death ending its children, and actual capture teardown during lock, mute or unknown lock state. J16 owns the mapped indicator handshake. J19 owns the policy-approved tool router and confirmation authority. The reducer's ports do not implement those owners. Engines, adapters, accounts and user interfaces stay with their assigned issues. [The action policy](jarvis-policy.md) names the separate routing, approval, audit, release and confinement owners.

## Evidence

- `scripts/test-jarvis-protocol.js` pins shape, direction, unknown-type and UTF-8 line-bound refusals with per-rule controls.
- `scripts/test-jarvis-session.js` tests transitions, ordered event pairs and state-shape refusals. The matrix retains seed-owner callbacks and discovers effects produced by the first event for live second callbacks. It covers capture, collection, brain, playback, tool and approval callbacks, including every deadline owner. Each created pair pins a transition or effect. Independent controls omit each callback family or deadline pair, or change created identities into stale seed identities. Separate mutations break hold replacement, approval retirement, retained brain ownership, identity, muted capture and the other lifetime rules.
- `scripts/test-jarvis-session-runner.js` uses in-memory ports and an injectable clock. Its stand-in brain connection stays open after done until the close port releases it. It proves lease, stop and setting teardown after completed responses, callback identity, synchronous callback ordering, deadline replacement, eventual tool outcomes and timer release. These pure suites start no child or socket.
- `scripts/test-jarvis-daemon.js` runs the real daemon and lease controls through the [J09 test world](validation-jarvis.md). Its fixture parameters enter as arguments. No caller environment reaches the world.
- `scripts/smoke/rows/jarvis.sh` proves zero-retry hello, Session detail delivery, disable cleanup and bounded recovery. Removing state publication breaks the real consumer assertion. Recovery checks name their retry count. Its suppressed first reply retains the timeout log and fails the ordinary startup assertion once. Its six-retry copy breaks the five-retry assertion.
- Its gated real daemon proves startup lock forwarding beside the test-only lock holder. That holder locks and unlocks through the core without authentication. Removing the startup resend forces recovery rather than accepting the current lock snapshot. The row also proves Node-floor exit 78 does not retry.
- Every IPC JSON reader in that row follows the shared [smoke reader rule](validation-smoke-harness.md). State words and empty replies do not enter a direct JSON parse.
- `scripts/smoke/rows/read-only-prefix.sh` adds the shared observer to its disposable installed tree. It requires zero-retry hello from the non-writable prefix and checks that startup changes no installed file. `scripts/smoke/rows/start-order.sh` uses the same fresh-start read for the default set.
- Smoke instruments only disposable service copies to launch the child through the real J09 helper. `scripts/fixtures/jarvis/prepare.js` keeps that instrumentation in one place. The helper itself owns worktree-local scratch allocation. A fixture launcher carries the stdin pipe through a descriptor, because Bash replaces stdin with `/dev/null` for the helper's asynchronous namespace supervisor. It restores stdin inside the namespace before executing the real daemon.

## Omarchy comparison

The read-only Omarchy shell reference's `plugins/agents/Main.qml` separates display from external collectors. VGS keeps that separation, with the daemon as the worker and the service as its health publisher. Omarchy's collectors do not own a continuously leased child.

The read-only omarchy-voice reference's `share/omarchy-voice.service` uses a graphical-session systemd unit with restart limiting. VGS keeps bounded restart but ties the daemon to the enabled service's stdin instead. A unit can outlive the shell and its future capture indicator. J13 and J16 must enforce the audio and indicator promises before capture exists.

omarchy-voice's `session.py` forwards local control commands through a socket; its `playback.py` owns the playback queue. VGS keeps effect ownership separate from state transitions. One pure reducer must judge overlapping capture, playback, tools and approvals without sharing mutable flags between adapter callbacks.
