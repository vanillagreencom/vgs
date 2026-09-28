# Themes

Covers: themes/**, bin/vgsh-theme-judge, scripts/test-vgsh-theme-judge.js, shell/Core/ThemeRunner.qml

A theme package is one directory. It holds the shell document and the application files that later apply steps copy or render. The package judge is pure; callers read files and pass their text to `ThemeLogic.acceptPackage`, and `bin/vgsh-theme-judge` owns the shipped-package directory walk.

## Package shape

| File | Required | Holds |
|---|---|---|
| `theme.json` | yes | The shell document from [design-system.md § The shell document](design-system.md#the-shell-document). |
| `terminal.json` | no | `{ "schemaVersion": 1, "slots": { "color0": "#...", ... "color15": "#..." } }`. |
| Application target files | no | Curated files a target later writes verbatim for its application. |

The directory name is the package name and must equal `theme.json`'s `name`. The name `vgs` is reserved for the shipped defaults, so an installed package cannot hide the revert package. A package without `terminal.json` is valid; a later renderer falls back to the shipped `vgs` terminal slots when it needs them.

## Boundaries

- `ThemeLogic.acceptPackage` takes the token table and file texts. It performs no I/O. It judges `theme.json` through `ThemeLogic.accept`, judges terminal slot names and colours, checks the directory/document name match, and applies the `vgs` reservation.
- `bin/vgsh-theme-judge` lists packages under a directory and reads `theme.json` and `terminal.json`. It uses the same judge as the shell through `scripts/qml-library.js`.
- `shell/Core/ThemeRunner.qml` owns the apply process when the theme capability lands. It starts runner commands and reports their structured result; it does not judge package files itself.
- `shell/plugins/vgs.themes/**` belongs to [plugins.md](plugins.md). This topic covers package and core runner contracts only.

## Trust

Applying a third-party package carries plugin-level trust. A curated target file is written verbatim into a path an application includes, so package application has the same user-privilege impact as enabling a plugin. [D019](../decisions/D019-theme-packages-carry-plugin-trust.md) records the boundary.

## Invariants

1. The shipped `vgs` package is accepted, and an installed package named `vgs`, a directory/document name mismatch, a bad terminal slot name and a bad terminal colour are refused. Enforced by `scripts/test-theme-logic.js`.
2. Every package under `themes/` passes the package judge in offline validation. Enforced by `bin/vgsh-theme-judge packages themes`, selected by `scripts/validate` for `themes/*` changes.
3. The nested smoke sandbox contains the shipped packages beside `shell`, `bin`, `config` and `scripts`. Owned by `scripts/smoke/harness.sh`.
