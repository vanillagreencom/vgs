# Theme conversion

Covers: tools/convert-v1-themes, scripts/check-theme-contrast.js, scripts/test-check-theme-contrast.js, scripts/test-convert-v1-themes.js, scripts/fixtures/convert-v1-themes/**

The v1 converter turns v1 theme packages into judged catalog packages. The readability judge rejects catalog and shipped themes whose resting text does not meet the contrast floor. The catalog shape and install rules are [theme-catalog.md](theme-catalog.md).

## Conversion

`tools/convert-v1-themes` reads one v1 worktree. It reads `themes/catalog.json`, `themes/asset-lock.json`, and for each selected theme `themes/<name>/colors.toml`, `themes/<name>/theme.json`, and optional `themes/<name>/terminal-colors.toml`. The v1 tree is read only.

The converter writes `themes/catalog/<name>/theme.json`, `themes/catalog/<name>/terminal.json`, `themes/catalog/thumbnails/<name>.jpg`, and a merged `themes/catalog/index.json`. It replaces entries for converted names, keeps other entries, and sorts the index by name with a code-unit comparison, so locale settings cannot change the order. It writes JSON with a fixed key order, two spaces and a trailing newline.

| v2 value | v1 source |
|---|---|
| `scheme.mode` | `theme.json` `mode`. |
| `palette.background` | `colors.toml` `background`. |
| `palette.foreground` | `colors.toml` `foreground`. |
| `palette.accent` | `colors.toml` `accent`. |
| `palette.success` | `colors.toml` `color2`. |
| `palette.warning` | `colors.toml` `color3`. |
| `palette.danger` | `colors.toml` `color1`. |
| `palette.info` | `colors.toml` `color4`. |
| `terminal.json` `color0` to `color15` | `colors.toml` `color0` to `color15`, overlaid by the same key in `terminal-colors.toml`. |
| `imagery` | Matching pins in `catalog.json` and `asset-lock.json`. |

The converter does not carry `apps/`. Catalog packages may not carry curated files for targets that run code, and v1 app files include such targets. It does not carry `ui-roles.toml`, because this issue adds no v2 token mapping for those derived tones. It does not carry `preview.jpg`, because the v2 thumbnail comes from the first wallpaper. It does not carry `contrastShortfalls`, because the v2 readability judge recomputes contrast from the resolved token tree and writes v2 token overrides.

The converter refuses a color line it cannot parse, a missing mapped key, a bad mode, a missing pin, and a pin disagreement between `catalog.json` and `asset-lock.json`. It judges the merged index with `ThemeLogic.acceptCatalogIndex`, and judges each converted package with `ThemeLogic.acceptCatalogEntry`, before it writes the catalog output.

The thumbnail step downloads each pinned archive through `bin/lib/theme-download.js`, the fetch `vgsh theme wallpapers` runs ([theme-wallpapers.md](theme-wallpapers.md)), and keeps it in the content-addressed cache `${XDG_CACHE_HOME:-$HOME/.cache}/vgs/theme-assets/<sha256>.tar.gz`, unless `--asset-cache` names another directory. It checks the archive size and SHA-256 before reading it. Tests can pass `--asset-base file://... --allow-file-base`; normal use accepts HTTPS only, and every redirect must stay HTTPS.

The thumbnail source is the first direct regular image entry under `backgrounds/` in the archive, using `bin/lib/theme-backgrounds.js` for the same image-name rule that `vgsh theme background list` uses. The archive reader is the one [theme-wallpapers.md § Fetch and read](theme-wallpapers.md#fetch-and-read) describes. The converter's own member rule skips nested files and every member outside `backgrounds/`, and refuses symbolic links, hard links and unsupported member types under `backgrounds/`. ImageMagick writes a 480 px wide JPEG with metadata stripped, fixed sampling and fixed quality.

The per-thumbnail budget is 120000 bytes. The 81-theme budget is 9720000 bytes. `tools/convert-v1-themes /home/method/dev/.worktrees/vgs/v1 --asset-cache tmp/theme-assets` on 2026-09-28 converted 80 themes, held back 1 theme, and produced 1395940 thumbnail bytes.

The same run wrote readability overrides to 67 themes: 28 themes changed `palette.accent`, 3 themes changed `color.textMuted`, 56 themes changed `color.textFaint`, 23 changed `color.success`, 14 changed `color.warning`, 45 changed `color.danger`, and 26 changed `color.info`. The largest accent mix amount was 0.50. The largest status mix amount was 0.49. The largest fade reduction was 0.15 for `color.textMuted` and 0.30 for `color.textFaint`.

Reruns are deterministic. The converter replaces the same package files and index entry with the same bytes, and `scripts/test-convert-v1-themes.js` runs the fixture conversion twice and compares the catalog digest.

Omarchy ships theme directories with backgrounds and a preview image, and it has no v1-to-v2 converter. VGS differs because its first-party catalog is judged offline and its thumbnail must match the first wallpaper the browser later shows.

## Readability

`ThemeLogic.readabilityShortfalls` checks the text roles drawn at rest on the resting surfaces. The roles are `color.text`, `color.textHeading`, `color.textMuted`, `color.textFaint`, `color.accent`, `color.success`, `color.warning`, `color.danger` and `color.info`. `color.accent` is in the table because text roles, checked button text and badge text draw it directly. The surfaces are `color.background`, `color.surface`, `color.surfaceRaised` and `color.surfaceSunken`. The floor is 4.5:1, the WCAG 2.2 SC 1.4.3 AA threshold for normal-size text. `color.surfaceHover` is excluded because hover is transient. `color.textDisabled` is excluded because inactive controls are exempt.

The converter fixes only the roles that have one v2 override family. It reads the default expressions for `color.textMuted` and `color.textFaint` from `Tokens.TOKENS` and requires the shape `mix({palette.foreground}, {palette.background}, t)`. That ties the override family to the token table instead of to a copied number. `color.textFaint` searches below its default amount in 0.01 steps and takes the largest passing value. `color.textMuted` searches the same family, but its cap is the chosen faint amount, or the faint default when faint needed no override, multiplied by the ratio of the muted default to the faint default and rounded down to two decimals. That keeps muted text stronger than faint text. `color.accent` is fixed at the palette level, not as a `color.accent` expression, because plugin-owned appearances, Hyprland borders, focus, selection and derived accent roles read `palette.accent` or values that derive from it. The converter probes `mix(<v1 accent>, contrast({palette.background}), t)` through `ThemeLogic.accept`, then writes the resolved opaque colour as the package `palette.accent`. A catalog entry's `palette.accent` can therefore differ from the v1 colour. Each status role searches `mix({palette.<role>}, contrast({palette.background}), t)` from `t = 0.01` up to `1.00` and takes the smallest passing value. Each candidate is resolved through `ThemeLogic.accept`, so 8-bit colour rounding is part of the decision.

A theme is held back when `color.text` or `color.textHeading` fails, or when no value in an override family makes its role pass. A stopped fade-family shape is a converter refusal, not a held-back theme, because the converter can no longer prove that a smaller amount means less fade. Held-back themes are removed from `themes/catalog/index.json`, and stale package and thumbnail files for that theme are removed from the catalog.

| Theme | Failing pair | Ratio |
|---|---|---|
| `moon-orbit` | `color.text` on `color.surfaceRaised` | 4.33 |

## Invariants

1. The v1 converter maps the required v1 fields, preserves unselected catalog entries, overlays terminal-only ANSI slots, refuses malformed pins, unsafe archive names, bad archive headers, unsafe archive member types and non-HTTPS redirects, reads pax path and GNU long-name background members, skips nested background files, chooses the first direct background image, enforces the thumbnail byte budget, writes deterministic output, writes readability overrides only when the resolved theme fails, refuses a changed fade-family token shape, fixes accent at the palette level with the smallest passing mix, takes the largest passing faint-text and muted-text mix under their hierarchy, takes the smallest passing status mix, and holds back unreadable themes while removing stale output. Enforced by `scripts/test-convert-v1-themes.js`, with refused fixture rows for each guard and converter-copy controls for the preservation, overlay, first-image, nested-background, index-order, override, fixed index palette, fade-shape, search, hierarchy and hold-back rules.
2. Every shipped package and catalog entry keeps resting text readable on resting surfaces. Enforced by `scripts/check-theme-contrast.js` and `scripts/test-check-theme-contrast.js`, with failing package, catalog, accent, translucent, refused and unreadable controls. The shared readability table is enforced by `scripts/test-theme-logic.js`, with judge-copy controls for the table, accent role, floor, ratio and translucent rules.
