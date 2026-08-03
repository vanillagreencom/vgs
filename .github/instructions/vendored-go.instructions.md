---
applyTo: "backend/vendor/**"
---

# Vendored Go modules

Byte-exact copies of upstream modules. Read them and report real defects, but
**never** propose an in-repo patch, refactor, or style fix — the tree must match
upstream exactly or vendor verification fails. Frame any genuine finding as an
upstream issue to file against the module, and say so explicitly.
