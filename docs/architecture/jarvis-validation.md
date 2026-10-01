# Jarvis validation

Covers: scripts/test-jarvis-protocol.js, scripts/test-jarvis-session.js, scripts/test-jarvis-session-runner.js, scripts/test-jarvis-daemon.js, scripts/fixtures/jarvis/, scripts/smoke/rows/jarvis.sh, scripts/smoke/rows/read-only-prefix.sh

The [Jarvis contract](jarvis.md) defines the service and reducer. [Audio evidence](jarvis-audio.md#evidence) defines its process and buffer checks.

## Evidence

- `scripts/test-jarvis-protocol.js` pins shape, direction, unknown-type and UTF-8 line-bound refusals with per-rule controls.
- `scripts/test-jarvis-session.js` tests transitions, ordered event pairs and state-shape refusals. The matrix retains seed-owner callbacks and discovers effects produced by the first event for live second callbacks. It covers capture, collection, brain, playback, tool and approval callbacks, including every deadline owner. Each created pair pins a transition or effect. Independent controls omit each callback family or deadline pair, or change created identities into stale seed identities. Separate mutations break hold replacement, approval retirement, retained brain ownership, identity, muted capture and the other lifetime rules.
- `scripts/test-jarvis-session-runner.js` uses in-memory ports and an injectable clock. Its stand-in brain connection stays open after done until the close port releases it. It proves lease, stop and setting teardown after completed responses, callback identity, synchronous callback ordering, deadline replacement, eventual tool outcomes and timer release. These pure suites start no child or socket.
- `scripts/test-jarvis-daemon.js` runs the real daemon and lease controls through the [J09 test world](validation-jarvis.md). Its fixture parameters enter as arguments. No caller environment reaches the world. It also runs startup task observation and the `task-stop` intent on a launcher group the test starts ([task control](jarvis-task-control.md#evidence)).
- `scripts/smoke/rows/jarvis.sh` proves zero-retry hello, Session detail delivery, disable cleanup and bounded recovery. Removing state publication breaks the real consumer assertion. Recovery checks name their retry count. Its suppressed first reply retains the timeout log and fails the ordinary startup assertion once. Its six-retry copy breaks the five-retry assertion.
- Its gated real daemon proves startup lock forwarding beside the test-only lock holder. That holder locks and unlocks through the core without authentication. Removing the startup resend forces recovery rather than accepting the current lock snapshot. The row also proves Node-floor exit 78 does not retry.
- Every IPC JSON reader in that row follows the shared [smoke reader rule](validation-smoke-harness.md). State words and empty replies do not enter a direct JSON parse.
- `scripts/smoke/rows/read-only-prefix.sh` adds the shared observer to its disposable installed tree. It requires zero-retry hello from the non-writable prefix and checks that startup changes no installed file. `scripts/smoke/rows/start-order.sh` uses the same fresh-start read for the default set.
- Smoke instruments only disposable service copies to launch the child through the real J09 helper. `scripts/fixtures/jarvis/prepare.js` keeps that instrumentation in one place. Its `--task-requests` option gives the [task row](jarvis-task-control.md#evidence) a gated daemon copy that sends task TUI requests. The helper itself owns worktree-local scratch allocation. A fixture launcher carries the stdin pipe through a descriptor, because Bash replaces stdin with `/dev/null` for the helper's asynchronous namespace supervisor. It restores stdin inside the namespace before executing the real daemon.

The Jarvis row also reads stable microphone and speaker offers from the service's status. Removing the service's offer publication fails that real consumer assertion. The installed-prefix row reads the same offers before it compares its tree snapshots. Both run the production audio discovery owner against stand-ins.

## Omarchy comparison

The read-only Omarchy shell reference's `plugins/agents/Main.qml` separates display from external collectors. VGS keeps that separation, with the daemon as the worker and the service as its health publisher. Omarchy's collectors do not own a continuously leased child.

The read-only omarchy-voice reference's `share/omarchy-voice.service` uses a graphical-session systemd unit with restart limiting. VGS keeps bounded restart but ties the daemon to the enabled service's stdin instead. A unit can outlive the shell and its future capture indicator. The audio owner enforces child lifetime. The mapped-indicator owner must still land before production capture can start.

omarchy-voice's `session.py` forwards local control commands through a socket; its `playback.py` owns the playback queue. VGS keeps effect ownership separate from state transitions. One pure reducer must judge overlapping capture, playback, tools and approvals without sharing mutable flags between adapter callbacks.
