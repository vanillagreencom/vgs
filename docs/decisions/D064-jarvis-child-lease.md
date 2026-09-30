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
