# Theme catalog

Covers: themes/catalog/**, bin/lib/theme-catalog.js, scripts/test-theme-catalog.js, scripts/test-vgsh-catalog.sh

The catalog holds the first-party theme packages VGS offers beside the shipped ones. It lives in this repository under `themes/catalog/`, and offline validation judges every entry as the installed package it becomes, so a catalog package passes the judge a shipped package passes before it reaches the repository. [D038](../decisions/D038-judged-theme-catalog.md) records the choice.

## Layout

| Path | Required | Holds |
|---|---|---|
| `themes/catalog/index.json` | yes | `{ "schemaVersion": 1, "entries": [ ... ] }`, one entry per package. |
| `themes/catalog/<name>/theme.json` | yes | The package's shell document: [themes.md § Package shape](themes.md#package-shape). |
| `themes/catalog/<name>/terminal.json` | no | The package's terminal slots. |
| `themes/catalog/<name>/targets/<destination>` | no | A curated file for a target whose files run no code: [§ Trust](#trust). |
| `themes/catalog/thumbnails/<name>.jpg` | no | A generated catalog thumbnail from the theme archive's first background image. |
| `themes/catalog/BACKGROUNDS-ATTRIBUTION.md` | yes | Wallpaper provenance and the thumbnail source image for each converted theme. |
| `themes/catalog/THEMES-ATTRIBUTION.md` | yes | Upstream theme repository and license provenance for converted palettes. |

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

## Install

A catalog package installs with no network into `${XDG_CONFIG_HOME:-~/.config}/vgs/themes/<name>/`, as an ordinary installed package that carries the catalog marker. The git verbs, the lock and the origin rule are [theme-install.md](theme-install.md).

- **List.** `vgsh theme catalog [--json]` prints every index entry in index order, each as `acceptCatalogIndex` answers it, palette colours in `#rrggbbaa` form, with four keys after it. `installed` is true when `themes/<name>` is a catalog install. `definitionUpdate` is true when the catalog package's digest is not the one the marker records. `imageryInstalled` is true when the marker records an unpacked wallpaper archive. `imageryUpdate` is true when the index pins an archive with another `sha256`. Each key is false when nothing is installed. `--json` prints `{ "entries": [ ... ] }` as one line; the text form prints `theme=<name> mode=<mode> installed=<bool> definitionUpdate=<bool> imageryInstalled=<bool> imageryUpdate=<bool>`. It takes no lock and never contacts the shell.
- **Install.** `vgsh theme install <name>` holds the theme lock. It copies the package's `theme.json`, `terminal.json` and each regular file directly under `targets/` into a staging directory beside `themes/`. It then writes the marker and judges the staged package with the judge add runs, `accept` under the entry's name. Last, it renames the package into `themes/<name>`: `ok installed=<name> path=<dir>[ shadows=<shipped dir>]`. `--json` prints `{ state, theme, path, shadows, reason }` as one line, a refusal's included. It refuses a name the index lacks as `not-in-catalog`, a catalog install of that name as `installed`, anything else at that path as `exists`, and a package the judge refuses with the judge's `reason`. A refusal leaves nothing behind.
- **Marker.** `.vgs-catalog.json` is `{ "source": "catalog", "digest": <sha256>, "imagery": <pin|null> }`. `digest` is the package digest `applied.json` records for the same content ([theme-follow.md](theme-follow.md)): `theme.json`, `terminal.json` and `targets/*`, and never backgrounds or the marker. `imagery` is null until a wallpaper download records the [§ Index entry](#index-entry) pin of the archive it unpacked. `bin/lib/theme-catalog.js` judges it; a marker that is a symlink or that the judge refuses is refused `marker`.
- **Update.** `vgsh theme update <name>` on a catalog install asks nothing: the catalog changes only with VGS itself, and a catalog package runs no code at apply ([§ Trust](#trust)). It refuses an install whose content digest is not the marker's as `modified`, a hand edit that an update would lose, and a name the index dropped as `not-in-catalog`. When the catalog package's digest is the marker's, it prints `ok up-to-date=<name>`. Otherwise it stages and judges the catalog package as install does, keeping the marker's `imagery`. It then renames the installed package to its backup, `.vgsh-theme-backup-<name>` beside `themes/`. It renames the staged package into place and moves in every entry of the backup that is not `theme.json`, `terminal.json`, `targets/` or the marker, such as `backgrounds/`. Last, it removes the backup: `ok updated=<name> from=<digest> to=<digest>`, 12 digits each. It then follows as a git update does ([theme-install.md](theme-install.md)).
- **Recovery.** The installed package is never inside the staging directory, which is removed on exit. While an update swaps, the package is in its backup, and the backup's presence records the unfinished swap. Add, install, update and remove run the judge's `recover` under the theme lock before they change anything. A backup with no `themes/<name>` is renamed back, because the new package never landed. A backup beside `themes/<name>` moves every entry it still keeps into it and is removed, because the new definition landed. Each prints `vgsh: recovered: theme=<name> state=restored|completed path=<dir>` on stderr. An entry the installed package already holds is refused `recover-conflict`, with the backup kept.
- **Outdated.** `vgsh theme outdated` gives a catalog install the row of [manager.md § Outdated](manager.md#outdated), with `head` the marker's digest, `upstream` the catalog package's and `behind` 1 when they differ, else 0. A refusal update would print is its `error`.
- **Remove.** `vgsh theme remove <name>` deletes a catalog install as it deletes any installed package, whatever its marker holds.
- **Omarchy.** `omarchy-theme-install` (basecamp/omarchy, e332dc9, read 2026-09-28) clones a git URL and removes any theme of that name first. VGS installs from the judged catalog with no network, and refuses an occupied name so that no install deletes a package or its edits.

## Wallpapers

`vgsh theme wallpapers <name> [--update]` lands the images of the archive an entry's `imagery` pins in the catalog install's `backgrounds/`, which that download owns, and records the pin in the marker: [theme-wallpapers.md](theme-wallpapers.md).

## Trust

An installed package's curated file on a `runsCode` target is dropped at apply ([D031](../decisions/D031-installed-themes-render-code-targets.md)), and a catalog package installs as an installed package. The catalog therefore carries no such file: `catalog-check` refuses a curated file on a `runsCode` target as `curated-code`. It refuses a file no target writes as `curated-unknown`, since the judge cannot tell whether it runs code, a file apply would not take in place of the render as `curated-shape`, through the renderer's own `curatedTaken`, anything but a regular file as `curated-file`, and a symlink anywhere in an entry as `symlink`. A target the renderer refuses leaves a curated file unclassified, so it refuses the check. A catalog install needs no trust exception, and apply drops or passes over no curated file of a catalog package.

## Conversion and readability

The v1 converter, the contrast check, the conversion metrics and the readability override rules are [theme-conversion.md](theme-conversion.md). A held-back theme is not listed in `themes/catalog/index.json`, has no package directory and has no thumbnail. No v1 theme is held back in the current catalog.

## Invariants

1. The index judge refuses a breach of every rule in [§ Index entry](#index-entry), and the shipped index and every package it names pass it and `acceptCatalogEntry`. Enforced by `scripts/test-theme-logic.js`, with a judge copy per rule as its controls.
2. `bin/vgsh-theme-judge catalog-check themes` accepts the shipped catalog, selected by `scripts/validate` for `themes/catalog/*` changes. The check refuses a curated file on a `runsCode` target, one no target writes, one of a shape apply would not take, a symlink, an absent package, `theme.json` or thumbnail, a package the judge refuses, a refused index and a refused target. Enforced by `scripts/test-vgsh-theme-judge.js`, with a judge copy per rule as its controls.
3. The package walk skips `catalog/` and `thumbnails/`, and add and update refuse both names. Enforced by `scripts/test-vgsh-theme-judge.js` and `scripts/test-vgsh.sh`, each with a judge copy that reserves `targets` alone as its control, and by `scripts/test-theme-logic.js` for `acceptPackage`.
4. Install copies the package byte for byte with its marker and leaves no staging directory. It refuses a reinstall, a package the judge refuses, a name the index lacks and an occupied name, and is refused busy while the theme lock is held. `--json` prints each as its line. Update replaces a changed definition, keeps `backgrounds/` and the marker's `imagery`, and follows the applied, unedited package. It refuses a hand edit and a version the judge refuses. An update ended after either of its renames leaves the package in its backup, and the next install, update or remove restores it or completes the swap byte for byte. `catalog` and `outdated` report the install's state, and remove deletes it. Enforced by `scripts/test-vgsh-catalog.sh`, with judge copies that skip the judge, write no marker, keep no background, ignore a hand edit, drop the imagery pin, keep the backup in the staging directory and install without the recovery, and `bin/vgsh` copies whose install takes no lock and whose remove skips the recovery, as its controls.
5. The marker judge refuses every defect of [§ Install](#install)'s marker shape, and the install state follows the marker and the index. Enforced by `scripts/test-theme-catalog.js`, with a library copy per rule as its controls.
