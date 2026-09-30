# Jarvis

Covers: shell/Core/SessionLock.qml, scripts/smoke/fixtures/plugins/acme.session/, scripts/smoke/rows/session.sh

The [Jarvis plan](../plans/v2-jarvis-plan.md) defines the voice assistant's scope. This document records its implemented core boundary. No Jarvis service or daemon ships yet.

## Session observation

A privacy-sensitive service declares capability `session` and binds to `shell.session.locked`. The [capability contract](capabilities.md) defines that state and its tests. It grants no lock authority and introduces no dependency on a lock plugin: [D056](../decisions/D056-read-only-session-state.md).

The service must treat a missing lock state as unknown, not unlocked. The future daemon's initial lock-state message and its capture shutdown belong to the plan's process model. The core capability does not enforce capture or action policy.
