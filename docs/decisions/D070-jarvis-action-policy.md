# D070: Jarvis actions use one typed policy gate

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: [Jarvis plan](../plans/v2-jarvis-plan.md), [research comparison](../plans/v2-jarvis-plan-research.md#25-omarchy-voice-v030-mit)
**Refines**: [D010](D010-facade-scope-not-sandbox.md)
**Refined by**: [D074](D074-jarvis-kernel-sandbox.md): kernel confinement consumes the same protected paths.
**Refined by**: [D082](D082-jarvis-approval-bound-to-the-action.md): serial immutable calls and reducer-owned confirmation.

**Context**: A model can select a desktop action from untrusted file, page, screen or agent content. A prose description does not establish the action's authority.

**Decision**: `Policy.decide` is the one action judge. It uses typed tool schemas and argument refinement. `Denied` judges real filesystem paths. Turn taint raises changing actions to confirmation without reducing physical destructive approval. The installed skeleton offers no tool until its router and executor owners land.

**Rationale**:
- A closed schema prevents the model from choosing its own effect, target authority or vendor flags.
- Resolved paths include aliases and absent write targets. Logical path prefixes alone cannot protect credentials or VGS state.
- One profile table keeps executors from applying different permission rules.
- Omarchy's shell agents separate display from workers. VGS keeps that separation and adds the voice-action boundary Omarchy does not have.
- omarchy-voice checks prose against deny and confirmation regexes. Its security document states that this is not a sandbox or complete authorization system. VGS rejects that mechanism for program authority.

**Boundaries**: J18 judges only. J19 owns serial routing, action-bound approvals and user grants. J21 owns the pre-action audit. J22 owns outbound release. J23 owns kernel confinement and proof across executors. A shell regex cannot enforce those kernel rules. J47 owns fresh input targets and layout-resolved effective chords. J27 supplies additional account roots without opening credentials.

**Revisit When**: A new executor cannot supply typed arguments or trusted target facts, or kernel confinement cannot mediate an operation. Refuse that operation or make it an explicit user handoff.

**Verification**: `scripts/test-jarvis-policy.js`, `scripts/test-jarvis-tools.js` and `scripts/test-jarvis-denied.js` through `scripts/validate`. Their controls remove each independent rule's behavior on disposable copies.

**References**: [Jarvis action policy](../architecture/jarvis-policy.md), [Jarvis](../architecture/jarvis.md), [review dispositions](../plans/v2-jarvis-plan-review.md).
