# Backend daemon

Covers: backend/

A same-user local daemon providing the system-integration layer QML is a poor fit for: network, logind, D-Bus signals, Bluetooth, printing, default-application routing, gamma, outputs, caps lock, clipboard, brightness bridging, wallpaper scheduling, mesh networking, system updates, freedesktop settings and location. `backend/methods.json` is the method and capability inventory; upstream lineage is `ATTRIBUTION.md` beside the code.

## Boundaries

- The Go runner is the parent process: it binds and owns the socket, spawns the daemon on the inherited listener and then spawns Quickshell, supervises the daemon, and tears the socket down on every exit path. A shell script that executes Quickshell in its own place cannot reap the daemon or unlink the socket afterwards.
- The backend owns no theme code. Palette derivation, wallpaper application, theme packages and app-target generation stay in the helper and the theme service; the backend owns only the rotation scheduler.
- The backend never turns a display on or off. It may report session and sleep signals; the idle service is the single owner of display power.
- The native lock screen and the calendar socket are not this daemon.
- No upstream command name, socket name, PID file, config file, desktop id or environment variable is exposed.

## Invariants

1. Every registered method maps to a capability declared in `methods.json`, or to an excluded prefix carrying a removal action. Enforced by `scripts/check-backend-inventory.py`, on both the Go and the QML side, so a new method with no inventory entry is a build failure rather than a review note — a coupling the diff does not show.
2. QML gates features on advertised `capabilities` or `methods` and keeps a working fallback where one is absent. A raw version-number comparison is refused: the version is kept truthful and never bumped past what is implemented, which makes it useless as a feature test.
3. The subscribe handler tolerates unknown service names, so a client's full subscription list works while services land incrementally.
4. The daemon fails closed without a runtime directory rather than falling back to a world-writable location, which would expose generic bus access, account writes and printer actions to any local user. The socket is created private and rejects a peer whose credentials are not the same user.
5. Least privilege over generic power: typed routes rather than a generic call surface. The D-Bus capability is subscribe-only and hard-restricted to the sleep signal; no generic call or property-set method is registered at all.
6. One owner per resource. The daemon owns the single clipboard watcher, its state file and its image store; it owns the single watcher on the mesh-networking daemon's event bus. QML re-asks the backend and never runs a second watcher or poller for either.
7. A panic in a service kills only the daemon child, never the shell. Both children carry a parent-death signal so an uncleanly dying runner cannot leak either process under service restart, and the runner keeps the listener open across a restart so connects queue in the accept backlog and the socket path never disappears.
8. Supervision is bounded: capped backoff plus a crash-loop breaker that tears the socket down and lets the shell run degraded. A dead backend degrades the UI to unavailable and never strands displays.
9. A context-bounded one-shot command is built with the `execbound` package, whose wait delay keeps a descendant holding the child's pipes from wedging the request past its deadline. `execbound` owns the terminal classification, so no call site reads the context error itself: an exit status the child reached on its own outranks an expired deadline, and only a child killed by signal classifies as a timeout. Enforced by `scripts/check-execbound-adoption.py`, which fails a direct output read on a raw command builder; a raw builder passes only when named in the allowlist with a lifecycle reason, and that allowlist is the review surface for backend-owned watchers and supervisors rather than a general lifecycle verifier.
10. Long-lived watchers own their own lifecycle, and jobs do not survive a daemon restart: a generation counter is carried so a job started against a dying daemon cannot be matched to an unrelated job on the next one.
11. A capability is advertised once at registration and cannot be withdrawn, so a capability that only says the daemon watches something is paired with a liveness field in the state it broadcasts. The capability says the backend reports watcher health; the field says whether a watcher is alive.
12. The open command classifies and validates its target — scheme, path, media type, category, desktop id — and launches only a desktop entry or an explicitly selected command through the same sanitised path, never a string concatenated into a shell.
13. Privileged operations use the platform mechanism the service already requires, never a hidden passwordless escalation. Rejected calls and privilege failures are logged; credentials, network keys, clipboard contents and file payloads are not.

## Decisions

[D009](../decisions/D009-manifest-second-reader.md) keeps the inventory's second reader: an inventory taken from the audited party's own report is not a cross-check.
