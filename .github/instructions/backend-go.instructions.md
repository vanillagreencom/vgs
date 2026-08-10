---
applyTo: "backend/**/*.go"
---

# Backend daemon

Canonical rules: `AGENTS.md` § Backend rules. The ones that bite in review:
every registered backend method must map to a documented capability in
`docs/architecture/backend-methods.json` — `scripts/check-backend-inventory.py`
enforces it on both the Go and QML sides, so a new method with no manifest
entry is a hard build failure, not a nit, and that coupling is invisible in the
diff. QML gates features on advertised `capabilities`/`methods`, never on raw
`apiVersion` ordinals, and keeps a working fallback when a capability is
absent. Unix socket paths stay short (`sun_path` limit). One owner per
resource.
