# D073: Jarvis releases labelled content to one recipient set

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: [Jarvis plan § Release gate](../plans/v2-jarvis-plan.md#38-release-gate-what-leaves-the-machine)
**Refines**: [D046](D046-slack-tokens-per-workspace-and-one-card-per-message.md)

**Context**: A brain's answer can reach a speech provider. Checking only the first destination can release file or screen content to a second provider without consent. A custom endpoint or redirect can also deliver a stored key to the wrong origin.

**Decision**: `Policy.release` judges each labelled item against the whole immutable brain and speech set. Summaries retain all contributing labels. Grants reference that exact set. `net.js` is the daemon adapters' outbound door. It attaches a key only to its exact stored HTTP origin and refuses redirects. WebSocket credentials use their HTTP handshake origin. An offline set permits only selected loopback origins.

**Rationale**:
- Provider selection covers speech and desktop content, not every source the assistant reads.
- The whole recipient set reflects the brain-to-speech flow. A separate grant per transfer destination would miss that flow.
- Immutable set identity prevents grants from crossing provider, account, policy or conversation changes. The session still owns teardown and context removal.
- HTTP and WebSocket requests use the same origin judge and credential header owner. Adapters cannot pass an unbound credential as metadata.
- Node's global fetch and WebSocket avoid an npm dependency or a second WebSocket implementation.
- Omarchy separates its usage display from API collectors. VGS takes that separation. It rejects their credential-file reads and automatic redirects because Jarvis sends conversation content to selectable providers.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Consent per immediate destination | Speech can receive information first released to the brain. |
| A summary labelled only as speech | It would lose the consent requirements of its contributing sources. |
| Grants keyed only by provider text | An account, policy or new conversation could reuse an old grant. |
| Follow same-origin redirects | No current adapter needs redirects. Refusing all redirects keeps credentials and payloads on the explicitly selected endpoint. |
| A transport or credential formatter in each adapter | It would duplicate origin and consent rules. |

**Boundaries**: J11 ends conversations and clears context. J19 issues user grants. J21 records releases before transfer. J24 supplies origin-bound in-memory keys. Adapters encode safe markers into their wire formats and use the network door. Harness programs own their sockets and need their separate release handoff. None of those siblings is implemented by this interface.

**Revisit When**: A supported provider requires redirects, a new credential placement, or a transport the door cannot mediate.

**Verification**: `scripts/test-jarvis-release.js` and `scripts/test-jarvis-net.js` run through the private Jarvis namespace world. Their disposable mutants remove independent rules. Selection and install-tree controls run through `scripts/validate`.

**References**: [Jarvis release](../architecture/jarvis-release.md), [action policy](../architecture/jarvis-policy.md), [validation world](../architecture/validation-jarvis.md), [review dispositions](../plans/v2-jarvis-plan-review.md).
