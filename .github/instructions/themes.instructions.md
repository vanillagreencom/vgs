---
applyTo: "themes/**"
---

# Theme packages

Curated data, not code to normalize. Palettes marked `source: curated` pass
through the engine untouched — only generated palettes get contrast
enforcement, so "this color fails contrast" is not a finding against a curated
palette.

Per-theme files under `themes/<name>/apps/` are intentionally parallel across
themes; near-identical structure is the design, not duplication to refactor.
Generated app-theme targets must write to VGS-named output paths — flag any
target writing to a legacy upstream path.
