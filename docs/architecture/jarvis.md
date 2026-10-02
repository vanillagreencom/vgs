# Jarvis

Covers: shell/Core/SessionLock.qml, shell/plugins/vgs.jarvis/, scripts/test-jarvis-protocol.js, scripts/test-jarvis-daemon.js, scripts/fixtures/jarvis/, scripts/smoke/fixtures/plugins/acme.session/, scripts/smoke/rows/session.sh, scripts/smoke/rows/jarvis.sh, scripts/smoke/rows/jarvis-keys.sh, docs/plans/v2-jarvis-plan.md, shell/Hosts/LayerHost.qml

[Input facts](input-facts.md) defines the fresh core target and key observations. [Jarvis input](jarvis-input.md) defines their policy and transport consumer.

The [Jarvis plan](../plans/v2-jarvis-plan.md) defines the voice assistant's scope. The service owns one Node child and publishes its health and Session state. The daemon installs the [audio owner](jarvis-audio.md) and its real reducer ports and persists privacy mute. The [bubble](jarvis-bubble.md) supplies the presented-indicator handshake. The stock daemon captures no audio because it has no speech engine. It observes and stops recorded coding tasks. The [chained engine](jarvis-engine.md) connects the brain to the registered tools, but its stock speech table stays unconfigured. [D064](../decisions/D064-jarvis-child-lease.md) records the process choice. The installed [action policy](jarvis-policy.md) judges reserved calls without making them usable.

The service owns metadata-only key and [account discovery](jarvis-accounts.md) readers. Settings opens the masked Add key and Accounts terminals. [Jarvis secrets](jarvis-secrets.md) owns key storage and references. The daemon still opens no provider connection.

The [voice text contract](jarvis-voice.md) defines the shipped guidance and speech-text APIs for future engines. These modules do not start an engine or change the service's current behavior.

[Jarvis audit](jarvis-audit.md) defines redaction and pre-action persistence. [Action routing and approval](jarvis-approval.md) defines the installed serial router, action grants and reducer confirmation judge. The daemon audits refused confirmations and privacy cleanup. It registers the [window and application executors](jarvis-desktop-tools.md) after their Hyprland probe, [input executors](jarvis-input.md) after harmless transport probes and the [clipboard, media and notify executors](jarvis-tools.md) whose commands are present. The [chained engine](jarvis-engine.md) routes the brain's calls. The [tool bridge](jarvis-bridge.md) gives a harness brain's MCP calls the same router; the daemon creates its owner on first hello, and only a harness brain's conversation opens a session and its `tools.sock`. The [Codex harness](jarvis-codex.md) is the brain the chained engine selects for a Codex subscription; its approval requests reach the same router. The [Claude Code harness](jarvis-claude.md) opens a session per conversation; the chained engine does not select it yet.

The installed [release policy and transport](jarvis-release.md) define the outbound interface for adapters. The daemon does not create that transport yet.

The [wire brain](jarvis-brain.md) defines the shared owner, OpenAI-compatible driver and provider table. [Anthropic Messages](jarvis-anthropic.md) uses the same release, request lifetime and event stream reader. The [chained engine](jarvis-engine.md) connects speech, brain, router, release and audit per conversation. No speech row ships, so the daemon stays unconfigured.

## Chained engine

[jarvis-engine.md](jarvis-engine.md) defines the turn loop, the speech adapter contract, barge-in with the heard prefix, conversation lifetime and the selection path.

The [GPT-Live engine](jarvis-live.md) defines the duplex speech session, its audio path, interruption and idle close, and the Session regions it uses. The daemon creates no engine yet.

## Local speech inputs

[jarvis-local.md](jarvis-local.md) defines the artifact declaration, bounded model inputs and execution oracle. [D066](../decisions/D066-pinned-local-speech-and-bounded-inputs.md) records the choices. [Local setup](jarvis-setup.md) verifies installation and publishes readiness. The sidecar and admission remain separate owners.

## Coding-task records

[jarvis-tasks.md](jarvis-tasks.md) defines the disk record owner, copied event producer and four-fact replay. [D072](../decisions/D072-coding-task-records-and-four-fact-state.md) records the choice. The daemon validates those records before ready. [jarvis-task-control.md](jarvis-task-control.md) defines launch, identity, stop and display; the daemon observes and stops recorded tasks and registers no task executor yet. [jarvis-task-claude.md](jarvis-task-claude.md) defines the Claude Code profile, its hooks and the permission and question relay. The Codex profile and task voice remain later work.

## Session observation

A privacy-sensitive service declares capability `session` and binds to `shell.session.locked`. The [capability contract](capabilities.md) defines that state and its tests. It grants no lock authority and introduces no dependency on a lock plugin: [D056](../decisions/D056-read-only-session-state.md).

The service treats a missing shell or lock value as locked. Each hello carries the observed lock state. The daemon answers `locked` or `ready` for health, and neither answer permits capture. Session stays down with reason `locked` or `unconfigured`. The core capability does not enforce capture or action policy.

## Controls

[jarvis-controls.md](jarvis-controls.md) defines the implemented keys, modes, persistent mute and wire. [jarvis-widget.md](jarvis-widget.md) defines the bar widget's states and its mute path. The stock daemon remains unconfigured. Only disposable test copies acquire scripted capture or playback.

## Session

[jarvis-session.md](jarvis-session.md) defines the region reducer, effect owner and lifetime rules, with their owning test evidence.

## Setting options

The starred strings in [the plan's settings section](../plans/v2-jarvis-plan.md#310-settings-status-and-files) use `optionsFrom`: voice, language, microphone, speaker, brain, model and coding agent. The service that owns discovery publishes each offer list through its plugin's declared `choices` status. A label names the choice to the user; its stable id is the setting.

[status.md § Setting choices](status.md#setting-choices) defines the generic shape, bounds, empty-string first-offered convention and retained unavailable ids. [D057](../decisions/D057-setting-options-from-status.md) records the core choice and its Omarchy comparison. Each discovery owner resolves empty string from its own first offer and treats no offers as no selection. Discovery failure must not silently change the configured provider or device.

The generic fixture `acme.status` proves the Settings Select in `scripts/smoke/rows/settings.sh`. Jarvis publishes its own [read-only device offers](jarvis-audio.md#device-discovery). Both use synthetic offers in validation and write only sandbox configuration. No real microphone, speaker, provider account or network is needed.

## Passive input

The [bubble contract](jarvis-bubble.md) defines layout, presentation and input through the [passive layer input contract](layers.md), refined by [D058](../decisions/D058-layer-input-union.md).

## Ownership

- `Service.qml` owns the Process, its parsers, the hello deadline and the restart timer. Disable destroys that owner. It closes stdin before Quickshell destroys the Process. A crashed shell closes the pipe without running QML teardown.
- The daemon exits when stdin closes. No systemd unit or detached process keeps it alive. It uses the shared library loader from the real VGS tree, passed as argv, because its published plugin snapshot contains no core files.
- A successful hello does not replenish the restart allowance. Five restarts use exponential delays, then the service publishes a problem and raises one toast. The hello deadline bounds a child that starts but sends no answer. These are recovery rules, not measured latency budgets.
- The daemon's normal exit 78 is permanent configuration failure. The service publishes its cause without a restart. Node below the plugin floor and privacy-record failures take this path. VGS's package floor remains Node 18; only Jarvis requires Node 22.
- Node below the plugin floor refuses before reading hello. The manifest names the daemon, audio, key-flow, task-record, sandbox, local-setup and file-opening commands. D035 supplies the system package notice; the user-started local setup installs only private Python and model files.

## Wire

The wire contract is in [jarvis-controls.md § Wire](jarvis-controls.md#wire).

## Boundaries still owned by later rows

[The audio owner](jarvis-audio.md) implements audio process lifetime and capture teardown. [Half duplex](jarvis-audio-duplex.md) implements J15 and answers R3. [Playback accounting](jarvis-playback.md) implements J14. J37 owns GPT-Live delegation; [the engine](jarvis-live.md#delegation) refuses a delegation until then. Selecting the duplex engine in the daemon waits for the voice and account selection. The [bubble](jarvis-bubble.md) supplies the mapped indicator handshake. J20 owns the approval bubble, confirm key and final-transcript matcher. The [chained engine](jarvis-engine.md) connects the brain to the installed router. J42 owns local toggle turn detection; J43 owns always runtime; J57 owns the console. Their settings and actions enter only with their consumers. The reducer's ports do not implement those owners. Engines, adapter integrations and user interfaces stay with their assigned issues. [Account discovery](jarvis-accounts.md) implements explicit API and local Verify through the outbound door, Claude subscription Verify through the [Claude Code harness](jarvis-claude.md#account-verify) and Codex Verify through the [Codex harness](jarvis-codex.md#verify). Speech-only verification remains with its separate owner. [The action policy](jarvis-policy.md) names the routing, approval, audit, release and confinement owners.

## Evidence

- `scripts/test-jarvis-protocol.js` pins shape, direction, unknown-type and UTF-8 line-bound refusals with per-rule controls.
- `scripts/test-jarvis-daemon.js` runs the real daemon and lease controls through the [J09 test world](validation-jarvis.md). Its fixture parameters enter as arguments. No caller environment reaches the world. It also runs startup task observation and the `task-stop` intent on a launcher group the test starts ([task control](jarvis-task-control.md#evidence)).
- `scripts/smoke/rows/jarvis.sh` proves zero-retry hello, Session detail delivery, disable cleanup and bounded recovery. Removing state publication breaks the real consumer assertion. Recovery checks name their retry count. Its suppressed first reply retains the timeout log and fails the ordinary startup assertion once. Its six-retry copy breaks the five-retry assertion.
- Its gated real daemon proves startup lock forwarding beside the test-only lock holder. That holder locks and unlocks through the core without authentication. Removing the startup resend forces recovery rather than accepting the current lock snapshot. The row also proves Node-floor exit 78 does not retry.
- The key row waits for the service's next `starting` state before reading the gated daemon's hello marker. Its fixture retry delay is not daemon startup time. The daemon suite runs the same row reads and shared poller with an injected clock; removing that state wait fails the hello assertion. It also proves that a fresh and a restarted scripted daemon write the marker before their reply gate opens, with an empty-marker control.
- Every IPC JSON reader in that row follows the shared [smoke reader rule](validation-smoke-harness.md). State words and empty replies do not enter a direct JSON parse.
- `scripts/smoke/rows/read-only-prefix.sh` adds the shared observer to its disposable installed tree. It requires zero-retry hello from the non-writable prefix and checks that startup changes no installed file. `scripts/smoke/rows/start-order.sh` uses the same fresh-start read for the default set.
- Smoke instruments only disposable service copies to launch the child through the real J09 helper. `scripts/fixtures/jarvis/prepare.js` keeps that instrumentation in one place. Its `--task-requests` option gives the [task row](jarvis-task-control.md#evidence) a gated daemon copy that sends task TUI requests. The helper itself owns worktree-local scratch allocation. A fixture launcher carries the stdin pipe through a descriptor, because Bash replaces stdin with `/dev/null` for the helper's asynchronous namespace supervisor. It restores stdin inside the namespace before executing the real daemon.

[Jarvis validation](jarvis-validation.md#evidence) also records the shared service checks. [Audio evidence](jarvis-audio.md#evidence) holds the child-lifetime and buffer checks.

## Omarchy comparison

[The service comparison](jarvis-validation.md#omarchy-comparison) and [the audio comparison](jarvis-audio.md#omarchy-comparison) name the adopted interfaces and different lifetimes.
