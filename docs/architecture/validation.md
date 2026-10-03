# Validation

Covers: scripts/validate, scripts/test-validate.sh, bin/lib/qml-library.js, scripts/test-qml-library.js, bin/lib/check-manifests.js, scripts/check-plugin-boundary.py, scripts/test-check-manifests.js, scripts/test-check-plugin-boundary.py, scripts/test-plugin-logic.js, scripts/test-inset.js, scripts/test-vgs-plugin.py, scripts/check-user-commands.py, scripts/test-check-user-commands.py, scripts/landing-times.py, scripts/test-landing-times.py

How the shell's changes are checked: the check selector and its rows. The nested sandbox, its harness and the smoke's verdicts are in [validation-smoke.md](validation-smoke.md).

The shared Jarvis test environment, its private services and its behavior controls are in [validation-jarvis.md](validation-jarvis.md). It belongs to test infrastructure, not the installed shell.

The QML unit runner and mutation controls are in [validation-qml-unit.md](validation-qml-unit.md).

The standalone GPU instrument and passive-layer presentation checks are in [validation-shaders.md](validation-shaders.md).

The [validation runner](validation-runner.md) defines row selection, repository checks, document limits and package checks.

## Jarvis rows

The [Jarvis Session](jarvis-session.md#session) has pure reducer and effect-owner rows in the `logic` area. The protocol row also selects on the Session state judge it imports. The real daemon and nested service rows use the private Jarvis environment.

The [bar widget](jarvis-widget.md#evidence) has a pure view row in `logic`, which selects on the view, the Session judge and the icon set. Both QML unit rows also select on the widget, its view and the Session judge.

The pure Jarvis guidance, speech text and language suites select from their modules, runtime assets and fixtures. Their [voice text contract](jarvis-voice.md) defines the consumer boundary and mutation evidence. The installed consumer runs in the install-tree suite and nested read-only prefix row.

The task record and event-producer rows exercise the [coding-task contract](jarvis-tasks.md) in the private Jarvis environment. They select on the record owner, the producer, the isolation helper and the service-instrumentation fixture. The [task runner](jarvis-task-control.md#evidence) row selects on the controller, launcher, agent profiles, record owner and producer, the router with its tool table and Policy, the fixture agent, the service-instrumentation and audio fixtures and the isolation helper.

The [playback rows](jarvis-playback.md#evidence) select on Audio, its child bootstrap, the Session judge and their shared test world. The private PipeWire row also selects on its null-sink configuration. It reads actual monitor PCM after interruption, not bytes sent to the player.

The [half-duplex audio tests](jarvis-audio-duplex.md#evidence) reuse the Session, Audio and audio daemon rows. The audio daemon row also selects on the scripted speech fixture it consumes, `scripts/fixtures/jarvis/scripted.js`.

The [Jarvis audit](jarvis-audit.md#evidence) has a redaction row in `logic` and a real-file writer row in `cli`. Both select on the tool schemas, shared fixture and private environment.

The [GPT-Live row](jarvis-live.md#evidence) in `cli` selects on the engine, the Session judge and runner, the shared release, transport, secret and guidance inputs, its pinned scripts and the loopback WebSocket fixture.

The [wire brain rows](jarvis-brain.md#evidence) select both drivers on shared history, release, transport, secret and stream inputs. Each driver's vendor scripts select its own row. The [Messages row](jarvis-anthropic.md#evidence) includes schema-pinned loopback and cancellation controls.

The [Codex harness rows](jarvis-codex.md#evidence) put the app-server judge in `logic`, selected by its excerpt and recording, and the harness in `cli`, selected by the harness, gate, account, bridge and router owners and its stub. The account, engine and audio daemon rows also select on the harness modules they load.

The [Jarvis account suites](jarvis-accounts.md#evidence) select from the account judge, provider declaration, secret owner, terminal and private fixtures. Their CLI rows use the shared isolated world. The nested Jarvis row reads account status and core TUI completion.

The [Claude Code harness row](jarvis-claude.md#evidence) in `cli` selects on the adapter, the bridge, shim, router, Policy and audit it carries a call through, the account judge its Verify cases run, its stand-in program and stream-json excerpt. The account rows and the audio daemon row also select on the adapter, since the account judge loads it.

The [vision row](jarvis-vision-validation.md#evidence) in `cli` selects on the executor, its geometry judge, the seam and the desktop owners it shares, the router, Policy, Audit, the manifest and its fixtures. The desktop executor and desktop tool rows and the audio daemon row also select on the two vision files the seam loads.

The [action router](jarvis-approval.md#evidence-and-comparison) has a `cli` row. Its inputs include Session, the effect runner, Policy, Tools, Denied, Audit, Private, Redact, the browser and computer-help owners, the shared fixture, the library loader and the private environment. The [audio daemon lifetime row](jarvis-audio.md#evidence) also selects on the installed router, the tool bridge, the desktop, input and child owners and their policy and audit dependencies. `scripts/test-validate.sh` removes each dependency edge in a disposable selector and detects the missing consumer.

The [file tools row](jarvis-files.md#evidence) in `cli` selects on the whole plugin directory, as the daemon row does, because its end-to-end case drives a disposable daemon copy through the desktop driver. It also selects on the core dispatch and launch modules that daemon loads, the shared policy and scripted fixtures, and the private environment.

The [desktop executor row](jarvis-desktop-tools.md#evidence) in `cli` selects on the executors, the request owner, the tool table, the protocol, the core's `Dispatch.js` and its fixtures. The request owner's row needs no world and runs in `logic`.

The [local setup contract](jarvis-setup.md#evidence) adds installer controls in `tools` and a nested Settings/TUI row. The installer doubles run inside J09 and never download or install a real runtime.

The [private browser suites](jarvis-browser.md#evidence-and-comparison) select from the driver owner, typed call and effect judges, stub, setup flow and their isolated fixtures. The executor suite also owns daemon EOF and SIGTERM browser teardown checks. Its row selects the daemon, copied backend, protocol, Session, imported core helpers and audio and desktop fixtures. The selector's controls remove these dependency edges and require the browser consumer to disappear. The nested browser row reads readiness and TUI completion with process doubles.

The shared guidance consumer selects the router and Browser suites on `ComputerHelp` and installed input guidance. The input owner and its help keep their own suite. Browser readiness adds its topic to the existing help offer. The Browser suite checks input help before setup, both topics after setup and one guidance registration. Its controls retain the installed skill files in every disposable backend copy.

## Other rows

- `scripts/check-readme-images.py` holds each first-party plugin README to its screenshots, the table `scripts/readme-shots.sh` makes them from and the files under `docs/images/plugins/`, and selects on any change under `shell/plugins/` or `docs/images/`: [readme-images.md](readme-images.md).
- `scripts/test-displays-brightness.py`, area `cli`, selects on the `vgs.displays` brightness helper and the device fixtures it uses; what it runs and its controls are in [displays.md](displays.md#validation). `scripts/test-displays-logic.js`, area `logic`, holds the plugin's decisions: [displays-plugin.md](displays-plugin.md#invariants).
- `scripts/check-user-commands.py`, area `boundary`, holds [D061](../decisions/D061-no-manual-commands.md)'s rule on the text a user reads: each plugin's Markdown and manifest, and every string literal of the shell's QML and JavaScript, read through `instruction`, with the drawn ones read by the rules below too. It fails a clause that tells the user to run a command or names one as the subject of a verb that does a step, `instruction`; a shell code block that starts with one, `shell-block`; inline code naming one in a drawn string, or a drawn string or a `CodeLine`'s text that reads as a command line, `code-command`; and a drawn property bound to a `commandLine`, the name a judge gives a whole command a reader could run, `drawn-command-line`, which keeps the requirement notice's install command behind its Show command. A path names the command its last part does, a template literal is read with each `${...}` as an argument, and a binding reaches back over the lines its statement wraps across. Its manifest fields are path patterns, and every key the judge admits is named there or in its exempt list. A command is a head its extractors read from `bin/`, every manifest's and the core's requirements and the package-manager table, with a floor and required members so a broken extractor exits 2 rather than passing. A `<details>` block whose summary is Show command is the allowed disclosure. `vgs-plugin check` runs it with `--plugin`. `scripts/test-check-user-commands.py` plants one violation per rule and runs a copy of the check without each rule, the disclosure's reach, the string blanking of `drawn-command-line`, each form above and the floor as its controls; its manifest classification reads the judge's key lists and fails on a key named in neither list. It reads nothing outside `shell/`: the top-level README's install commands install VGS itself, before any VGS surface exists, and `docs/` is read by maintainers, not users.
- `scripts/check-devtools-catalog.js` judges `shell/plugins/vgs.devtools/catalog.json` with the pure catalog judge and checks the plugin-owned appearance table in dark and light mode. Its control is `scripts/test-check-devtools-catalog.js`, which plants one catalog defect per rule and keeps accepted edge cases for backend regex options, non-latest tags and loopback database ports.
- `scripts/check-voiceorb-shader.py` compiles the passive core visual and compares its baked pack with the shipped bytes. Its control plants invalid source, stale or absent packs, a missing compiler, iteration and texture input. Both rows select on shader source and pack changes. The compiler contract and the distinction between unit properties and compiled shader status are in [runtime-qml-shaders.md](runtime-qml-shaders.md).

## Test isolation

- Every check that spawns a process passes that process an explicit environment, never the developer's live one.
- Every test and sandbox run carries the test-run marker, `VGS_TEST_RUN=1`: `scripts/validate` exports it for every row, `scripts/vgsh-rows.sh` sets it in the environment every bin/vgsh suite hands vgsh, with `TMPDIR` set to the suite's scratch directory, and `scripts/smoke/harness.sh` sets it in the sandbox environment. Under it the theme judge runs a reload hook only when the target's directory, the hook's command and every `PATH` directory lie inside the scratch root, `TMPDIR`, and no variable names a live session's server: the suites' environment unsets `TMUX`, `DBUS_SESSION_BUS_ADDRESS`, `HYPRLAND_INSTANCE_SIGNATURE` and `WAYLAND_DISPLAY` and points `XDG_RUNTIME_DIR` and `TMUX_TMPDIR` into the scratch directory. Any other hook, every hook in the nested sandbox included, is refused as `reload-refused` and never starts ([theme-reload.md](theme-reload.md)). A shipped target's hook therefore never detects and signals the host's live applications from a test, whatever tree the test copied. `scripts/test-validate.sh` proves the export, and `scripts/test-vgsh-reload.sh` the refusal.
- A budget in a script names the machine and date it was measured on. Each latency reading in the smoke carries its poll interval: 10 ms for the first bar, one `qs ipc` round trip for the build records. How the first-bar budget is derived: [validation-latency.md](validation-latency.md).
