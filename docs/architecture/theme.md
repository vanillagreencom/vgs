# Theme engine

Covers: themes/, bin/, quickshell/vshell/Services/, quickshell/vshell/Modules/Settings/

The helper derives palette roles and renders app targets. Theme packages own colour and wallpaper data; shell geometry remains a VGS setting.

## Invariants

- User theme files overlay built-in files individually. Curated palettes bypass generated-palette contrast enforcement. See theme composition and palette derivation in `bin/vshell-helper`.
- Curated app files take precedence over generated output. Restyle adjustments leave the stored base palette intact. See app-target rendering and restyle handling in `bin/vshell-helper`.
- Generated target paths are VGS-named and are declared in each target's configuration. Review path changes against the consumers; no checker proves compatibility for all consumers.
- Enabling per-monitor wallpaper mode preserves each screen's current image and disables retained cycling. `scripts/test-switcher-scope.js` checks the transition.
- Theme applies carry distinct request ids and failed reads retain an explicitly identified displayed result. `scripts/test-theme-requests.js` checks request handling.
- A theme downloads as one archive from its `themes-vN` release, accepted only at the catalogued size and sha256, then unpacked member by member under the manifest path rule. `_catalog_fetch_verified` and `_catalog_unpack` in `bin/vshell-helper` own acceptance; `scripts/gen-theme-catalog.py` checks the generated catalog and the release pin.
- The archive is verified in `~/.cache/vshell/theme-assets/` and deleted once the install finishes, so the cache holds in-flight downloads only. An installed theme is composed from local directories alone, so applying it makes no network call.
- An uninstalled theme paints from `themes/thumbnails/<name>.jpg`, which ships in every package. See `catalog_preview_path` in the helper.
- Download publication holds the mutation lock only around the directory swap. Removal requires matching download identity. See `catalog_download_theme` and `catalog_owns` in the helper.

## Decisions

[D010](../decisions/D010-single-screen-wallpaper-apply.md), [D015](../decisions/D015-theme-imagery-release-assets.md).
