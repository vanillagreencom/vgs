# Attribution

VGS is a forked and heavily reworked shell runtime. The current product is VGS
and all runtime/configuration surfaces are VGS-named, but upstream lineage is
preserved here for license and provenance clarity.

## Upstream Shell Lineage

- Upstream project: DankMaterialShell
- Repository: https://github.com/AvengeMedia/DankMaterialShell
- Upstream branch used: `master`
- Seed commit: `0509694d78c99e3065ab3b09c73bf05df460abb7`
- Snapshot date: 2026-07-03
- Preserved license files: `quickshell/vshell/LICENSE` and
  `quickshell/vshell/LICENSE_CHANGE_12_11_2025.md`

The backend Go daemon (`backend/`) is separately adapted from the upstream Go
core at commit `1cc9218ff6192477d52b025f5fbbc286df0f50ef`; see
`backend/ATTRIBUTION.md` for its boundary and exclusions.

The fork is no longer wired to the upstream DMS runtime or greeter. VGS owns its
CLI, Quickshell runtime, greeter sync path, clipboard history, wallpaper/theme
generation, settings UI, bundled plugins, and generated app-theme outputs.

## Theme Engine Lineage

Earlier VGS theme work was informed by Aether/matugen-style palette controls
and by upstream shell app-theme toggles. The current implementation lives in
`bin/vshell-helper`, `themes/`, and `themes/targets/`; it does not call Aether,
download upstream assets, or write generated output to non-VGS paths.

## Naming Boundary

Historical names belong in this attribution file and preserved license lineage
only. Runtime files, default settings, generated outputs, service names, docs,
and bundled plugins should use VGS/vshell naming.
