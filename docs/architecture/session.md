# Session: idle, lock, screensaver and greeter

Covers: quickshell/vshell/Modules/Lock/, quickshell/vshell/Modules/Greetd/

Idle activity drives a ladder of independent tiers — lock, blank, monitor power, suspend — and the lock surface is the only thing that may draw while the session is locked. The greeter is the same runtime started from a copied tree under a different flag.

## Boundaries

- `Services/IdleService.qml` is the single owner of idle orchestration and display power. The backend may report session and sleep signals but never turns a display on or off.
- Every tier is gated on the idle inhibitor, so a top-bar inhibit, a compositor inhibit or a media inhibit suppresses the whole flow and holds a systemd sleep-inhibitor lock with it.
- The desktop screensaver is a separate tier for the unlocked idle case. Rendering it over the lock needs a native in-shell renderer, because only the lock surface draws while locked.

## Invariants

1. `Lock {}` is a direct child of the Quickshell root, not something a `Loader` instantiates. Reload propagation visits only children that are themselves reloadable and a `Loader` is not, so out of reach a reload builds a fresh session-lock object and destroys the previous one while it still holds the ext-session-lock — which leaves the session locked and aborts the shell on the next lock request. Enforced by `scripts/check-lock-reload-order.py`.
2. Child order is load-bearing at three levels of the tree, because reload matches children by index and never by id. The persistent-properties object precedes the session lock in `Modules/Lock/Lock.qml` specifically, since it restores the lock request the reload branches on; pinning these at the front of each parent is what makes adding anything later safe. Enforced by `scripts/check-lock-reload-order.py`, which runs in continuous integration because the nested smoke never locks.
3. Because the lock object is always built, including in the greeter and in a shell about to be refused as a duplicate, its activity gate is a property rather than a structure — so every path that can arm the session lock applies it: the lock call, the adoption of a logind-reported lock, and the configured external locker. The logind handlers must not set the lock request themselves, or a greeter would take a lock without anything asking, and a failed acquisition is an uncatchable abort.
4. Clearing lock state is always safe and stays ungated, and a request that arrives while the gate is shut is dropped rather than queued: activation re-reads the session state, which is the path that puts the lock UI back over a session a dead shell left locked.
5. The recovery path tears down what was waiting on the lock, not only the lock state. The fade-to-lock overlay is opaque with exclusive keyboard focus and dismisses itself only when the lock clears, and pending secure-off and blackout intents latch a wake block first — so a lock that never arrives would otherwise leave a session that cannot wake itself.
6. Idle state crosses a reload in persistent properties, because the service is a singleton rebuilt per engine generation. Its start-up recovery functions return early on a reload, or they would force monitors back on over a locked session and ramp brightness back while the blackout overlay lifts.
7. Those snapshots are written by explicit calls, never by bindings: restoring a persistent property assigns it, which breaks a binding permanently and would leave the next reload restoring a stale value. The restore runs under a flag that suppresses snapshotting, or it eats its own input.
8. A lock request goes through the service's `requestLock(source)`, never through an optional call on the lock component. That component is null during start-up and stays null in a greeter or a refused duplicate, so the optional form turns a request to lock the machine into a silent no-op; the service retries across the start-up window, then logs an error naming every distinct source that asked. Enforced by `scripts/test-idle-lock-request.js`.
9. The manual blackout is a latch, not a tier: seat activity cannot lift it, only a second toggle. The dimmed levels are journalled to the runtime directory so a shell restart mid-blackout restores brightness instead of stranding the panels dimmed.
10. The screensaver refuses rather than covering every monitor with an empty terminal. Art resolves most specific first — generated art while a picture is set, else the logo shipped in the package, else a generated card — and a settings file that cannot be read answers that a picture is set, preserving the precedence rather than discarding art. The launcher's non-zero exit clears the active flag, so the shell never reports a saver that is not on screen.
11. The greeter's configured primary monitor is an intent: an absent connector falls back to the first connected screen, so login is never stranded on a disconnected display. This policy begins when greetd starts the VGS compositor; firmware, bootloader and disk-unlock prompts happen earlier and VGS cannot route them.
12. Auto-login and keyring auto-unlock are mutually exclusive by construction, because unlocking the login keyring needs the password typed at the greeter and auto-login types none. The safe default leaves the keyring alone; converting it to an empty password is an explicit, opt-in action that backs the keyring up first, and ordinary greeter sync refuses to replace an existing keyring.

A stray second shell is the usual cause of a lock that is secure while its surface draws black, because each instance builds its own fade-to-lock overlay and races for the session lock. The guard that prevents it is `shell.md` § Invariants, and the recovery is to terminate the stray by process id and then reset the lock state.

## Decisions

[D001](../decisions/D001-quickshell-0-3-0-upstream-defects.md) records the three Quickshell 0.3.0 session-lock defects as reported upstream rather than vendored or patched: a failed lock acquisition aborts the process from inside the library, a process-global permanently poisons locking for any client once a lock manager is destroyed while holding the lock, and reload matching cannot look a child up by id. Invariants 1, 2 and 3 are the shapes that live with them.
