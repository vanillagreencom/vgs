# D064: Jarvis is one service with a leased child and one wire judge

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: [Jarvis plan](../plans/v2-jarvis-plan.md)
**Refines**: [D010](D010-facade-scope-not-sandbox.md), [D052](D052-automations-engine.md)

**Context**: Jarvis must stop when its plugin or shell goes away. Its future microphone owner cannot outlive the indicator.

**Decision**: The service owns one Node child. Closed stdin is its lease. `JarvisProtocol.js` judges both directions. The service bounds recovery and publishes daemon health. No systemd unit starts Jarvis.

**Rationale**:
- A pipe closes after a shell crash without relying on QML teardown.
- One wire judge prevents the QML and daemon endpoints from accepting different messages.
- Omarchy's shell agents separate display from collectors. VGS keeps that separation.
- omarchy-voice uses a graphical-session systemd unit. VGS rejects that lifetime because it can outlive the shell's future capture indicator.
- Automations use systemd because their work must survive the shell. Jarvis has the opposite requirement.

**Scope**: J10 establishes the child and wire only. J11 owns region state. J13 owns audio children, forced-death cleanup and capture refusal while locked or lock state is unknown. J16 owns the mapped indicator handshake. No capture exists in this skeleton.

**Revisit When**: Quickshell provides a stronger child lease, or capture moves to a process whose lifetime the shell cannot own.

**Verification**: `scripts/test-jarvis-protocol.js`, `scripts/test-jarvis-daemon.js`, `scripts/smoke/rows/jarvis.sh` and the read-only prefix row.

**References**: [jarvis.md](../architecture/jarvis.md), [Quickshell Process 0.3.1](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/Process/).

## Refined by VGS-626 (2026-09-30)

`Audio.js` owns the capture, playback, echo loader and sidecar audio feed. `Audio.teardown` acknowledges after its children and feeds close. Session remains the admission judge. The daemon installs these production ports but stays unconfigured until the later speech and indicator owners supply their prerequisites.

Every audio child starts through `setpriv --pdeathsig KILL`. An expected-parent check closes the startup race where the parent died before that signal was installed. A daemon-only pipe lease also reaches a private PID namespace's init. Init ends on EOF or command exit; Linux then kills every descendant, including a detached process that closed its pipes. The namespace child also starts the command through setpriv with an expected-parent check.

`unshare --map-current-user --pid --fork --kill-child=KILL` provides that descendant boundary without a systemd capture unit or a PipeWire configuration change. User-namespace refusal faults audio and never falls back to an unowned host process. The network stays unchanged in production. Tests retain their separate no-network namespace.

**Alternatives**:
- Parent-death signal alone: Linux clears it across fork and sends no signal for a parent already dead when it is installed.
- Closed pipes alone: a detached descendant can close them and remain alive.
- A process group: a descendant can create a new group.
- A capture unit: its lifetime can exceed the enabled service and indicator.

The [audio contract](../architecture/jarvis-audio.md) defines the interfaces and sources. `scripts/test-jarvis-audio.js` proves reducer-triggered releases with real stand-in processes. `scripts/test-jarvis-audio-daemon.js` proves EOF, lock and forced daemon death before the outer test world ends.
