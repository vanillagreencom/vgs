# D082: Jarvis approval belongs to one immutable action

[← Decision Index](INDEX.md)

**Date**: 2026-10-01
**Status**: Active
**Research**: [Jarvis plan § Policy](../plans/v2-jarvis-plan.md#37-policy-authority-effects-approval-audit), [review dispositions](../plans/v2-jarvis-plan-review.md)
**Refines**: [D070](D070-jarvis-action-policy.md)

**Context**: File, page and model output can request synthetic input. A generic confirmation command would let that output approve its own action.

**Decision**: ToolRouter holds one immutable typed call behind a random id and canonical digest. Session owns confirmation identity, drawing time, expiry and retirement. Policy rejudges fresh facts before start. Audit gates that start. The model receives no confirmation API. Production offers no tool until its real executor and required commands exist.

**Rationale**:
- Session already owns the held region, monotonic clock and invalidation events. A router confirmation clock would duplicate that authority.
- A serial slot prevents a held action from starting another tool that could press its own confirmation key.
- Tools owns the typed sentence and argument schema. Model text cannot describe another action while retaining an old digest.
- A generation change clears grants in the leased router. Session remains the only conversation identity owner.
- Fresh policy and durable audit must succeed before a scope becomes usable. A changed target or failed audit cannot issue a grant.
- Omarchy's agents plugin separates display and workers. omarchy-voice serializes pending actions and journals before execution. VGS keeps those boundaries but excludes its model-facing confirm_last approach.

**Alternatives considered**:
- A router-owned confirmation timer would duplicate Session's deadlines and retirement.
- Model-supplied approval prose or a confirmation tool would let untrusted output release the hold.
- Executor-owned policy, grant or audit checks would create different rules for each tool family.

**Boundaries**: J20 owns the bubble, key and final-transcript matcher. J28 owns the bridge. J33 owns the brain turn loop and release consent integration. J45 through J51 own executors and their confinement. The action router supplies no recipient-labelled release grant. Another same-user program can press a real confirmation bind; VGS cannot prove the human source of that press.

**Revisit When**: A new action cannot fit a typed call or needs parallel execution while another action waits for consent.

**Verification**: `scripts/test-jarvis-router.js`, `scripts/test-jarvis-session.js`, `scripts/test-jarvis-session-runner.js`, `scripts/test-jarvis-protocol.js` and `scripts/test-jarvis-daemon.js` through `scripts/validate`. Independent disposable defects must turn the corresponding assertions red.

**References**: [Approval contract](../architecture/jarvis-approval.md), [action policy](../architecture/jarvis-policy.md), [audit](../architecture/jarvis-audit.md)
