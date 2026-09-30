# D056: Plugins read the session's lock state without lock authority

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: [Jarvis plan § Decisions to record](../plans/v2-jarvis-plan.md#10-decisions-to-record), VGS-617

**Refines**: [D012](D012-core-owns-lent-objects.md)

**Context**: A service must stop privacy-sensitive work as soon as the shell requests a lock. Lending `lock` to that reader would grant unlock authority and prevent the lock screen from holding the exclusive capability.

**Decision**: The shared `session` capability exposes only the read-only, bindable boolean `locked`. `shell/Core/SessionLock.qml::sessionProvider` returns a frozen getter over the existing owner's requested and secure state. It stays true until both states are false. The exclusive `lock` capability and its requested-state `locked` member keep their existing contract. Removing either a reader or the lock holder cannot unlock the session.

**Rationale**:

- One existing owner supplies the state, with no polling, subscriber registry or plugin dependency.
- A frozen object rejects replacement, deletion and injected members as well as assignment.
- Omarchy's current `quattro` lock service exposes `readonly locked: lockRequested || sessionLock.locked || sessionLock.secure` in `shell/plugins/lock/Service.qml`. Its lock plugin owns the Wayland lock. Its plugin service APIs use scoped service lookup. VGS instead keeps lock ownership in the core under D012 and lends observation separately. VGS's host binds the Wayland request to the owner's request, so requested and secure state cover that lifetime without a second lock object.

**Revisit When**: A reader needs to observe a lock another process owns, or the compositor supplies an independent session-state API.

**Verification**: `scripts/test-plugin-logic.js` checks manifest admission and shared lending with controls. `scripts/test-session-lock.sh` checks reactive reads, immutable providers and holder teardown with controls. `scripts/smoke/rows/session.sh` reads a real fixture beside the exclusive holder in the nested compositor.

**References**: [Capabilities](../architecture/capabilities.md), [Omarchy lock service](https://github.com/basecamp/omarchy/blob/quattro/shell/plugins/lock/Service.qml), [Omarchy service API](https://github.com/basecamp/omarchy/blob/quattro/shell/services/PluginFirstPartyServiceApi.qml)
