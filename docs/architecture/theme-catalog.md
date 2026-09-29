# Theme catalog

Covers: themes/catalog/**, tools/convert-v1-themes, scripts/test-convert-v1-themes.js, scripts/fixtures/convert-v1-themes/**

The catalog holds the first-party theme packages VGS offers beside the shipped ones. It lives in this repository under `themes/catalog/`, and offline validation judges every entry as the installed package it becomes, so a catalog package passes the judge a shipped package passes before it reaches the repository. [D038](../decisions/D038-judged-theme-catalog.md) records the choice.

## Layout

| Path | Required | Holds |
|---|---|---|
| `themes/catalog/index.json` | yes | `{ "schemaVersion": 1, "entries": [ ... ] }`, one entry per package. |
| `themes/catalog/<name>/theme.json` | yes | The package's shell document: [themes.md § Package shape](themes.md#package-shape). |
| `themes/catalog/<name>/terminal.json` | no | The package's terminal slots. |
| `themes/catalog/<name>/targets/<destination>` | no | A curated file for a target whose files run no code: [§ Trust](#trust). |
| `themes/catalog/thumbnails/<name>.jpg` | no | A generated catalog thumbnail from the theme archive's first background image. |

A themes directory's walk skips `catalog/` as it skips `targets/` and `thumbnails/`, and no package of any source takes these names: `ThemeLogic.RESERVED_DIRECTORIES`. Only an index entry reaches a package directory.

## Index entry

| Key | Holds |
|---|---|
| `name` | The package name: one `ThemeLogic.isPackageName` accepts, unique in the index, and not `vgs`, `targets`, `catalog` or `thumbnails`. The entry's directory has this name, and its `theme.json` carries it as `name`. |
| `mode` | One of the `scheme.mode` token's options, equal to the package's resolved `scheme.mode`. |
| `thumbnail` | Null, or a path relative to `themes/catalog/`: `/`-separated segments, each one `isPackageName` accepts, naming a file reached through no symlink. |
| `palette` | Every token of the `palette` group and no other, each a colour the judge reads, equal to the package's resolved palette. A reader draws a palette card from it without reading the package. |
| `imagery` | Null for a theme without wallpapers, or the pin of its wallpaper archive, below. |

| `imagery` key | Holds |
|---|---|
| `repo` | `https://<host>/<path>`, with no credentials, port, query, fragment or trailing slash. |
| `release` | The release tag, one `isPackageName` accepts. |
| `archive` | The archive's file name, one `isPackageName` accepts. |
| `size` | The archive's size in bytes, a positive integer. |
| `sha256` | The archive's SHA-256, 64 lower-case hexadecimal digits. |

## Boundaries

- `ThemeLogic.acceptCatalogIndex(tokens, text)` judges the index text. It performs no I/O. It answers the entries in index order, each palette colour in the resolved `#rrggbbaa` form, or one refusal whose token is `entries.<i>` and the key it names.
- `ThemeLogic.acceptCatalogEntry(tokens, entry, files)` judges one package from the file texts its caller read: `acceptPackage` under the entry's name as an installed package, then the entry's mode and palette against the package's resolved values.
- `bin/vgsh-theme-judge catalog-check [DIR]` reads `DIR/catalog` (default `themes/`), makes every decision above through `ThemeLogic.js`, and reads the targets under `DIR/targets` for § Trust. It prints one line per entry, `ok       catalog/<name>` or `refused  <dir>: <refusal>`, and a refused index as `refused  <index>: <refusal>`. Exit 0 when every entry is accepted, 1 on a refusal, 2 when the index or a file cannot be read.

## Trust

An installed package's curated file on a `runsCode` target is dropped at apply ([D031](../decisions/D031-installed-themes-render-code-targets.md)), and a catalog package installs as an installed package. The catalog therefore carries no such file: `catalog-check` refuses a curated file on a `runsCode` target as `curated-code`. It refuses a file no target writes as `curated-unknown`, since the judge cannot tell whether it runs code, a file apply would not take in place of the render as `curated-shape`, through the renderer's own `curatedTaken`, anything but a regular file as `curated-file`, and a symlink anywhere in an entry as `symlink`. A target the renderer refuses leaves a curated file unclassified, so it refuses the check. A catalog install needs no trust exception, and apply drops or passes over no curated file of a catalog package.

## Conversion

`tools/convert-v1-themes` reads one v1 worktree. It reads `themes/catalog.json`, `themes/asset-lock.json`, and for each selected theme `themes/<name>/colors.toml`, `themes/<name>/theme.json`, and optional `themes/<name>/terminal-colors.toml`. The v1 tree is read only.

The converter writes `themes/catalog/<name>/theme.json`, `themes/catalog/<name>/terminal.json`, `themes/catalog/thumbnails/<name>.jpg`, and a merged `themes/catalog/index.json`. It replaces entries for converted names, keeps other entries, and sorts the index by name. It writes JSON with a fixed key order, two spaces and a trailing newline.

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

The converter does not carry `apps/`. Catalog packages may not carry curated files for targets that run code, and v1 app files include such targets. It does not carry `ui-roles.toml`, because this issue adds no v2 token mapping for those derived tones. It does not carry `preview.jpg`, because the v2 thumbnail comes from the first wallpaper. It does not carry `contrastShortfalls`, because contrast fixes belong to the later catalog conversion issue.

The converter refuses a color line it cannot parse, a missing mapped key, a bad mode, a missing pin, and a pin disagreement between `catalog.json` and `asset-lock.json`. It judges the merged index with `ThemeLogic.acceptCatalogIndex`, and judges each converted package with `ThemeLogic.acceptCatalogEntry`, before it writes the catalog output.

The thumbnail step downloads each pinned archive into the content-addressed cache `${XDG_CACHE_HOME:-$HOME/.cache}/vgs/theme-assets/<sha256>.tar.gz`, unless `--asset-cache` names another directory. It checks the archive size and SHA-256 before reading it. Tests can pass `--asset-base file://... --allow-file-base`; normal use accepts HTTPS only.

The thumbnail source is the first regular image under `backgrounds/` in the archive, using `bin/lib/theme-backgrounds.js` for the same image-name rule that `vgsh theme background list` uses. The archive reader refuses absolute paths, `..` segments and symlinks. ImageMagick writes a 480 px wide JPEG with metadata stripped, fixed sampling and fixed quality.

The per-thumbnail budget is 120000 bytes. The 81-theme budget is 9720000 bytes. `tools/convert-v1-themes /home/method/dev/.worktrees/vgs/v1 --theme nord --asset-cache tmp/theme-assets` on 2026-09-28 produced `themes/catalog/thumbnails/nord.jpg` at 25445 bytes.

Reruns are deterministic. The converter replaces the same package files and index entry with the same bytes, and the nord measurement run changed no output bytes on its second pass.

Omarchy ships theme directories with backgrounds and a preview image, and it has no v1-to-v2 converter. VGS differs because its first-party catalog is judged offline and its thumbnail must match the first wallpaper the browser later shows.

## Invariants

1. The index judge refuses a breach of every rule in [§ Index entry](#index-entry), and the shipped index and every package it names pass it and `acceptCatalogEntry`. Enforced by `scripts/test-theme-logic.js`, with a judge copy per rule as its controls.
2. `bin/vgsh-theme-judge catalog-check themes` accepts the shipped catalog, selected by `scripts/validate` for `themes/catalog/*` changes. The check refuses a curated file on a `runsCode` target, one no target writes, one of a shape apply would not take, a symlink, an absent package, `theme.json` or thumbnail, a package the judge refuses, a refused index and a refused target. Enforced by `scripts/test-vgsh-theme-judge.js`, with a judge copy per rule as its controls.
3. The package walk skips `catalog/` and `thumbnails/`, and add and update refuse both names. Enforced by `scripts/test-vgsh-theme-judge.js` and `scripts/test-vgsh.sh`, each with a judge copy that reserves `targets` alone as its control, and by `scripts/test-theme-logic.js` for `acceptPackage`.
4. The v1 converter maps the required v1 fields, overlays terminal-only ANSI slots, refuses malformed pins and unsafe archives, chooses the first background image, enforces the thumbnail byte budget, and writes deterministic output. Enforced by `scripts/test-convert-v1-themes.js`, with refused fixture rows for each guard and converter-copy controls for the overlay, first-image and index-order rules.
