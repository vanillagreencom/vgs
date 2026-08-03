---
applyTo: "backend/**/*.go"
---

# Backend daemon

Every registered backend method must map to a documented capability in
`docs/architecture/backend-methods.json`. `scripts/check-backend-inventory.py`
enforces this on both the Go and QML sides, so a new method with no manifest
entry is a hard build failure, not a nit — and that coupling is invisible in
the diff.

QML must gate features on advertised `capabilities`/`methods`, never on raw
`apiVersion` ordinals, and must keep a working fallback when a capability is
absent. Unix socket paths must stay short (`sun_path` limit). One owner per
resource.
