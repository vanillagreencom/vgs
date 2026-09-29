# Theme catalog

Covers: themes/catalog/**

The catalog holds the first-party theme packages VGS offers beside the shipped ones. It lives in this repository under `themes/catalog/`, and offline validation judges every entry as the installed package it becomes, so a catalog package passes the judge a shipped package passes before it reaches the repository. [D038](../decisions/D038-judged-theme-catalog.md) records the choice.

## Layout

| Path | Required | Holds |
|---|---|---|
| `themes/catalog/index.json` | yes | `{ "schemaVersion": 1, "entries": [ ... ] }`, one entry per package. |
| `themes/catalog/<name>/theme.json` | yes | The package's shell document: [themes.md § Package shape](themes.md#package-shape). |
| `themes/catalog/<name>/terminal.json` | no | The package's terminal slots. |
| `themes/catalog/<name>/targets/<destination>` | no | A curated file for a target whose files run no code: [§ Trust](#trust). |

A themes directory's walk skips `catalog/` as it skips `targets/`, and no package of any source takes either name: `ThemeLogic.RESERVED_DIRECTORIES`. Only an index entry reaches a package directory.

## Index entry

| Key | Holds |
|---|---|
| `name` | The package name: one `ThemeLogic.isPackageName` accepts, unique in the index, and not `vgs`, `targets` or `catalog`. The entry's directory has this name, and its `theme.json` carries it as `name`. |
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

## Invariants

1. The index judge refuses a breach of every rule in [§ Index entry](#index-entry), and the shipped index and every package it names pass it and `acceptCatalogEntry`. Enforced by `scripts/test-theme-logic.js`, with a judge copy per rule as its controls.
2. `bin/vgsh-theme-judge catalog-check themes` accepts the shipped catalog, selected by `scripts/validate` for `themes/catalog/*` changes. The check refuses a curated file on a `runsCode` target, one no target writes, one of a shape apply would not take, a symlink, an absent package, `theme.json` or thumbnail, a package the judge refuses, a refused index and a refused target. Enforced by `scripts/test-vgsh-theme-judge.js`, with a judge copy per rule as its controls.
3. The package walk skips `catalog/`, and add and update refuse the name `catalog`. Enforced by `scripts/test-vgsh-theme-judge.js` and `scripts/test-vgsh.sh`, each with a judge copy that reserves `targets` alone as its control, and by `scripts/test-theme-logic.js` for `acceptPackage`.
