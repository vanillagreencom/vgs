# Jarvis test environment

Covers: scripts/lib/jarvis-env.sh, scripts/test-jarvis-env.js, scripts/fixtures/jarvis-env/

The shared test world implements the isolation boundary in [the Jarvis plan § Testing strategy](../plans/v2-jarvis-plan.md#9-testing-strategy). It contains no installed runtime code. The [Jarvis service](jarvis.md) and its tests consume this owner. [Validation](validation.md) owns row selection.

## Ownership

- `scripts/lib/jarvis-env.sh::jarvis_env_run` owns one scratch world per invocation. Its header defines the caller contract. A suite starts its fixture servers, daemon and children inside that invocation, so they share the same loopback network.
- The CLI PID owns its cleanup. The sourced API uses a subshell around that same owner to preserve the caller's traps, options, directories, environment and umask.
- The launcher enters user, network, PID and mount namespaces before it starts a service or command. Only loopback comes up. When the command ends, the PID namespace ends its remaining children. The launcher removes the scratch files after the namespace ends.
- Cancellation kills and reaps the owned namespace supervisor before removing scratch files. `unshare --fork` ignores TERM and INT while waiting, so the owner uses KILL with `--kill-child`. The suite's outer namespace supervisor uses that same forced signal for its timeout.
- Namespace creation and host-tool lookup can return 77. That result means the case is not verified. A command's own exit status passes through unchanged.

## Environment

- The launcher supplies an empty-based environment and private HOME, XDG and temporary directories. It passes no caller settings, credentials, account roots or live-session identifiers. Fixture parameters enter as arguments or scratch files.
- The command's PATH holds copied stand-ins and the helper's explicit host-tool allow-list. Host tools come from fixed system directories, not login-shell functions or a user's tool-manager shim. A missing stand-in has no host fallback. A stand-in cannot replace an allow-listed or bootstrap tool.
- Both D-Bus addresses name private buses with no service directories or included configuration. They cannot activate host services. The tmux wrapper selects a private socket and an empty configuration. Its global-option judge follows [tmux's getopt syntax](https://github.com/tmux/tmux/blob/3.7c/tmux.c) with Bash `getopts`, including clusters, attached values and value-taking options. It refuses socket/configuration overrides and unknown or incomplete global options before starting tmux.
- PipeWire and PulseAudio addresses name absent endpoints under the private runtime directory. Audio tools are not host tools on PATH. Private null-sink PipeWire belongs to the plan's playback and echo-cancellation issues, not this environment.
- This boundary isolates processes, networking, command lookup and session endpoints. It is not a filesystem sandbox. Fixtures can read the repository. A consumer that deliberately runs an absolute host executable still owns proof that it touches no live service or device.

## Evidence

- `scripts/test-jarvis-env.js` uses Node's strict assertion library. It exercises the real helper, services and child processes. It tests stand-in removal, environment scrubbing, private directories, host-tool selection, loopback traffic, outbound refusal, both buses, disabled service activation, private tmux, absent audio endpoints, child teardown and exit status propagation.
- Every mutation runs on a temporary code copy inside a separate outer namespace. The outer network holds only loopback and a synthetic test address. Removing the inner network namespace reaches that test listener, never a real network. Removing the PID namespace leaves a child holding a scratch file lock, which the same teardown assertion detects.
- Cancellation cases signal the exact CLI PID while a descendant holds a lock and an output pipe. They read back lock release, removed scratch files and pipe closure. Timeout cases use both the synchronous CLI caller and the outer supervisor with live descendants. A fixture's natural-expiration marker detects cancellation that merely waits for the fixture to finish. Tmux cases first prove the vendor accepts each bypass form against private scratch sockets/configuration, then prove the wrapper refuses it.
- The synthetic OS probes in `scripts/fixtures/jarvis-env/probe.py` identify their source and date. They carry no vendor protocol or recording, so no provider schema or version applies. Protocol fixtures added by adapter suites must name their schema and version, or their sanitized opt-in recording, and date. Their owning suite validates them against the schema where one exists.
- Omarchy's `test/acceptance` uses a live session inside its VM. omarchy-voice's `tests/test_realtime_wire.py` uses a loopback server and starts muted. VGS uses scratch namespaces because these shared tests must also prevent an unexpected child from reaching the host network or a live desktop service.
