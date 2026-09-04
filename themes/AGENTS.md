# themes/

Built-in theme packages and the per-app target templates. Composition rules and invariants: [../docs/architecture/theme.md](../docs/architecture/theme.md).

- A package under `themes/<name>/` is overlaid file by file from `~/.config/vshell/themes/<name>/`, user winning. Machine-local overlays live outside the repository under `~/.config/vshell-local/`.
- A palette marked `source: curated` passes through the engine untouched, so a contrast finding against one is not a defect. Only generated palettes get contrast enforcement.
- Per-theme files under `themes/<name>/apps/` are intentionally parallel across themes. Near-identical structure is the design, not duplication to refactor.
- A generated target writes to a VGS-named output path. A target writing to a legacy upstream path is a defect.
- Add a target by adding `themes/targets/<id>/` with its config and templates, and add token support in the helper before a template uses a new token form.
- Theme packages carry no shell or compositor geometry: radius, border size and spacing are VGS settings.
