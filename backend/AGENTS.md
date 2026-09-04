# backend/

The Go daemon and the runner that supervises it. Boundaries, threat model and invariants: [../docs/architecture/backend.md](../docs/architecture/backend.md).

- Every registered method maps to a documented capability in [methods.json](methods.json); `scripts/check-backend-inventory.py` enforces it on both the Go and the QML side, so a new method with no entry is a build failure rather than a review note, and that coupling is invisible in the diff.
- QML gates on advertised `capabilities` and `methods`, never on raw `apiVersion` ordinals, and keeps a working fallback where a capability is absent.
- One owner per resource: never add a second watcher, daemon or poller for something the helper or QML already owns.
- Execute external tools with argv arrays, and never log credentials, network keys, clipboard contents or raw frame payloads.
- Build a context-bounded one-shot command with `internal/execbound`; `scripts/check-execbound-adoption.py` fails a direct output read on a raw command builder.
- Verify against a scratch daemon — `VGS_BACKEND_SOCKET=/run/user/$UID/test.sock vshell backend serve` — never against the live socket, and keep socket paths short enough for the address limit.
