# Jarvis validation rows

Covers: scripts/validate, scripts/test-validate.sh

How `scripts/validate` selects the Jarvis suites. The check selector itself is [validation.md](validation.md); the shared test world is [validation-jarvis.md](validation-jarvis.md).

The [Jarvis Session](jarvis-session.md#session) has pure reducer and effect-owner rows in the `logic` area. The protocol row also selects on the Session state judge it imports. The real daemon and nested service rows use the private Jarvis environment.

The pure Jarvis guidance, speech text and language suites select from their modules, runtime assets and fixtures. Their [voice text contract](jarvis-voice.md) defines the consumer boundary and mutation evidence. The installed consumer runs in the install-tree suite and nested read-only prefix row.

The task record, event-producer and [task runner](jarvis-task-control.md#evidence) rows exercise the [coding-task contract](jarvis-tasks.md) in that environment. Each selects on its owners, the isolation helper and its fixtures.

The [playback rows](jarvis-playback.md#evidence) select on Audio, its child bootstrap, the Session judge and their shared test world. The private PipeWire row also selects on its null-sink configuration. It reads actual monitor PCM after interruption, not bytes sent to the player.

The [Jarvis audit](jarvis-audit.md#evidence) has a redaction row in `logic` and a real-file writer row in `cli`. Both select on the tool schemas, shared fixture and private environment.

The [GPT-Live row](jarvis-live.md#evidence) in `cli` selects on the engine, the Session judge and runner, the shared release, transport, secret and guidance inputs, its pinned scripts and the loopback WebSocket fixture.

The [wire brain rows](jarvis-brain.md#evidence) select both drivers on shared history, release, transport, secret and stream inputs. Each driver's vendor scripts select its own row. The [Messages row](jarvis-anthropic.md#evidence) includes schema-pinned loopback and cancellation controls.

The [Codex harness rows](jarvis-codex.md#evidence) put the app-server judge in `logic`, selected by its excerpt and recording, and the harness in `cli`, selected by the harness, gate, account, bridge and router owners and its stub. The account, engine and audio daemon rows also select on the harness modules they load.

The [Jarvis account suites](jarvis-accounts.md#evidence) select from the account judge, provider declaration, secret owner, terminal and private fixtures. Their CLI rows use the shared isolated world. The nested Jarvis row reads account status and core TUI completion.

The [Claude Code harness row](jarvis-claude.md#evidence) in `cli` selects on the adapter, the bridge, shim, router, Policy and audit it carries a call through, the account judge its Verify cases run, its stand-in program and stream-json excerpt. The account rows and the audio daemon row also select on the adapter, since the account judge loads it.

The [vision row](jarvis-vision.md#evidence) in `cli` selects on the executor, its geometry judge, the seam and the desktop owners it shares, the router, Policy, Audit, the manifest and its fixtures. The desktop executor and desktop tool rows and the audio daemon row also select on the two vision files the seam loads.

The [router](jarvis-approval.md#evidence-and-comparison) shares inputs with the audio daemon; `scripts/test-validate.sh` controls its edges.

The [file tools row](jarvis-files.md#evidence) in `cli` selects on the whole plugin directory, as the daemon row does, because its end-to-end case drives a disposable daemon copy through the desktop driver. It also selects on the core dispatch and launch modules that daemon loads, the shared policy and scripted fixtures, and the private environment.

The [local setup contract](jarvis-setup.md#evidence) adds installer controls in `tools` and a nested Settings/TUI row. The installer doubles run inside J09 and never download or install a real runtime.

The [private browser suites](jarvis-browser.md#evidence-and-comparison) select from the driver owner, typed call and effect judges, stub, setup flow and their isolated fixtures. The executor suite also owns daemon EOF and SIGTERM browser teardown checks. Its row selects the daemon, copied backend, protocol, Session, imported core helpers and audio and desktop fixtures. The selector's controls remove these dependency edges and require the browser consumer to disappear. The nested browser row reads readiness and TUI completion with process doubles.

The shared guidance consumer selects the router and Browser suites on `ComputerHelp` and installed input guidance. The input owner and its help keep their own suite. Browser readiness adds its topic to the existing help offer. The Browser suite checks input help before setup, both topics after setup and one guidance registration. Its controls retain the installed skill files in every disposable backend copy.
