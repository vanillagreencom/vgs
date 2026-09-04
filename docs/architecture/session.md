# Session: idle, lock, screensaver and greeter

Covers: quickshell/vshell/Modules/Lock/, quickshell/vshell/Modules/Greetd/, quickshell/vshell/Services/

The idle service owns display power and lock orchestration. A locked session draws through the lock surface; the unlocked screensaver is a separate tier.

## Invariants

- `Lock` stays a direct child of the Quickshell root. Persistent lock properties precede the session-lock object. `scripts/check-lock-reload-order.py` checks the reload-sensitive child order.
- Every path that arms the lock applies the activity gate. Clearing state stays ungated. See `Modules/Lock/Lock.qml` and `Services/SessionService.qml`.
- Lock recovery also clears waiting overlays and pending blackout intents. See the force-reset path in `Modules/Lock/Lock.qml` and `Services/IdleService.qml`.
- Idle snapshots use explicit writes and suppress writes while restoring. `scripts/test-idle-reload-snapshot.js` checks reload preservation.
- Callers request locking through `IdleService.requestLock(source)`. `scripts/test-idle-lock-request.js` checks startup retries and reported failure.
- Manual blackout remains latched until explicitly toggled. See the blackout state and recovery journal in `Services/IdleService.qml`.
- A missing greeter monitor falls back to a connected screen. Keyring conversion requires an explicit request and preserves a backup. See the greeter and keyring tests in `scripts/check-vshell-helper.py`.

## Decisions

[D001](../decisions/D001-quickshell-0-3-0-upstream-defects.md), [D008](../decisions/D008-nested-sandbox-state-seeding.md).
