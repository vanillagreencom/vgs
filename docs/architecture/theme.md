# Theme engine

Covers: themes/

VGS owns theme state and generates the per-app theme files itself; there is no external theme-engine runtime dependency. A theme is a directory holding metadata, a palette, wallpapers and optional curated per-app files, and applying one derives roles from the palette and renders every enabled target from them.

## Boundaries

- Role derivation and rendering live in `bin/vshell-helper`. QML calls `vshell theme ...` and stays UI and orchestration only.
- A theme package owns colours, wallpapers and per-app theme files. It does not own shell or compositor geometry — corner radius, border size and spacing are VGS settings, not theme fields and not generated app CSS.
- A target is added by adding `themes/targets/<id>/` with its config and templates, and by adding token support in the helper before a template uses a new token form.
- The GTK target deliberately avoids an app-wide radius, so terminal and application interiors stay square unless the app's own styling says otherwise.
- Built-in packages live in `themes/<name>/`; user packages live under `~/.config/vshell/themes/<name>/` and are never written into the repository.

## Invariants

1. The user directory overlays the built-in one file by file, user winning. That is what lets every in-settings colour edit be an ordinary overlay file, keeps built-ins pristine in the repository, and makes reverting a theme a deletion of one directory.
2. A curated palette passes through untouched: no contrast rewriting anywhere in the pipeline, and only missing roles are derived. Only a generated palette gets role normalisation and contrast enforcement, and a lossy mode transform downgrades its result to generated. The linter reports contrast warnings on a curated palette rather than rewriting it.
3. A curated per-app file wins over generation and installs verbatim, with only path tokens rendered. A package may also name a full theme file that replaces the template output at the main destination, in which case the template is skipped for that destination.
4. A restyle is non-destructive. Adjustments are stored as their own object and applied to the base colours at derivation time, so the stored palette is never rewritten and an all-zero adjustment is a byte-exact no-op. Restyling a built-in snapshots its composed metadata into the overlay, which is what keeps mode, pairing and wallpaper working under a file-level overlay — and which masks later repository edits to that metadata until the overlay is dropped.
5. A generated output path is product API. Consumers depend on these paths, so a rename ships with a compatibility shim, every path is VGS-named, and the enumeration lives in each target's own config rather than in prose. A target writing to a legacy upstream path is a defect.
6. The mode toggle never invents a palette. Already being in the target mode is a no-op; a theme with a counterpart in the other mode applies it; otherwise the picker opens filtered to that mode.
7. Enabling per-monitor wallpapers seeds every screen from what it currently shows, on the off-to-on edge and before the flag flips, and forces retained per-screen cycling off at the same edge. Unseeded, the flag alone republishes whatever the last per-monitor session left retained, and every screen holding an entry jumps the instant the mode goes on. Enforced by `scripts/test-switcher-scope.js`.
8. A failed helper read is reported as a failure, never as an empty collection. A list already on screen stays browsable under a notice naming the theme the retained set belongs to, because asserting "you have none" from a failed call is the shape these surfaces exist to avoid.
9. An apply is correlated by a request id minted per call, because one operation name covers many different applies and a completion signal is emitted by many unrelated operations. Applies run uncoalesced, since inferring that a newer request replaced an unlaunched one drops a live token and leaves its failure unreported.
10. The catalog's committed size and checksum are the sole authority for a downloaded file. Two locations are tried in order — the pinned release tag and the moving branch — because the checksums come from the working tree while the tag is fixed at release; a location serving other bytes is rejected rather than trusted, and a file no location can satisfy fails loudly naming every location tried. Enforced by `scripts/gen-theme-catalog.py --check` on every pull request and by its release-pin mode during a release.
11. Catalog fetches are HTTPS only, cover a closed set of file names, and nothing downloaded is ever executed. Ownership for removal is the recorded identity of the download, not the presence of its marker, because duplicating a package copies the marker and a presence test would delete the user's own theme.
12. Downloads run outside the theme mutation lock, which is taken only around the directory swap that publishes a staged theme. Holding the exclusive lock for a catalog-scale transfer would block applies, the light and dark keybinding, wallpaper changes and restyles for hours.
13. Every built-in package ships a committed screenshot, so a fresh install browses a full theme picker without generating anything. The committed shot is skipped once the user has overlaid or restyled that theme, because it stops showing what applying the theme would do.

## Decisions

[D010](../decisions/D010-single-screen-wallpaper-apply.md) makes a single-screen wallpaper apply a verified session-data write rather than a new service method, and records the two product calls behind invariant 7: the settings toggle is seeded like every other route, and enabling per-monitor wallpapers leaves nothing moving or re-cropped on a screen the caller did not name.
