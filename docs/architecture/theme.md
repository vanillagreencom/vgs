# Theme engine

Covers: themes/, bin/, quickshell/vshell/Services/, quickshell/vshell/Modules/Settings/

The helper derives palette roles and renders app targets. Theme packages own colour and wallpaper data; shell geometry remains a VGS setting.

## Invariants

- User theme files overlay built-in files individually. Curated palettes bypass generated-palette contrast enforcement. See theme composition and palette derivation in `bin/vshell-helper`.
- Curated app files take precedence over generated output. Restyle adjustments leave the stored base palette intact. See app-target rendering and restyle handling in `bin/vshell-helper`.
- Generated target paths are VGS-named and are declared in each target's configuration. Review path changes against the consumers; no checker proves compatibility for all consumers.
- Syntax roles (`SYNTAX_ROLE_BASES` in `bin/vshell-helper`) carry a hue-preserving lift to 4.5:1 on the background, because Codex paints code and diffs on the terminal's own background and ignores a theme's. The ANSI roles they derive from stay verbatim for the targets that do their own contrast work. Codex reads the rendered theme only once `[tui] theme` names it, which the `codex-theme` hook sets in `~/.codex/config.toml` without touching another key. `test_codex_theme_paints_every_bundled_theme_readably` and `test_codex_theme_selection_changes_only_the_tui_theme_key` in `scripts/check-vshell-helper.py` check both.
- Enabling per-monitor wallpaper mode preserves each screen's current image and disables retained cycling. `scripts/test-switcher-scope.js` checks the transition.
- Theme applies carry distinct request ids and failed reads retain an explicitly identified displayed result. `scripts/test-theme-requests.js` checks request handling.
- A theme downloads as one archive from its `themes-vN` release, accepted only at the catalogued size and sha256, then unpacked member by member under the manifest path rule. `_catalog_fetch_verified` and `_catalog_unpack` in `bin/vshell-helper` own acceptance; `scripts/gen-theme-catalog.py` checks the generated catalog and the release pin.
- The archive streams into `~/.cache/vshell/theme-assets/` in fixed chunks, hashed as it is written, so the verified bytes are the bytes the unpack step reads back and no install holds a whole archive in memory. It is deleted once the install finishes, so the cache holds in-flight downloads only. An installed theme is composed from local directories alone, so applying it makes no network call.
- Each lock entry binds its archive to the definition files it packed. `scripts/gen-theme-catalog.py --check` refuses a catalog whose committed definitions differ from the pinned archive, and `--check-assets-published`, which CI runs, refuses a pin whose archive is not an asset of a release that exists.
- An uninstalled theme paints from `themes/thumbnails/<name>.jpg`, which ships with the package that every install carries. `theme_shipped_preview` in the helper is the one answer to what can be painted without rendering. Both callers, the catalog browser through `catalog_entries` and `theme list --json`, pass the package's own `preview.png` when it has one, and both resolve the thumbnail through `theme_thumbnail_path`.
- Reading the current theme never applies one. With no `theme.json` the helper answers with the file an apply of the default theme would write, rendered from the `vgs-shell` target without writing it, and `theme init`, which `VGSThemeService` runs at startup, is the explicit first-run apply. `test_current_theme_reads_without_applying` and `test_theme_init_applies_only_without_state` in `scripts/check-vshell-helper.py` check both; `scripts/test-theme-startup.js` checks that startup runs `theme init` before its first reads.
- Download publication holds the mutation lock only around the directory swap. Removal requires matching download identity. See `catalog_download_theme` and `catalog_owns` in the helper.

## Decisions

[D010](../decisions/D010-single-screen-wallpaper-apply.md), [D015](../decisions/D015-theme-imagery-release-assets.md).
