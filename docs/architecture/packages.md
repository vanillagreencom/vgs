# Packages

Covers: shell/Core/PackageManagers.js, bin/vgsh-pkg, scripts/test-vgsh-pkg.js

VGS knows a system's package managers through one table, `shell/Core/PackageManagers.js`. Every flow that installs, removes, upgrades or checks a package reads that table: [D034](../decisions/D034-one-package-manager-table.md). `bin/vgsh-pkg` loads it under node through `bin/lib/qml-library.js`, and `vgsh pkg` is its command. Its header states each verb's output and refusals.

## The table

One row per manager: `pacman`, `aur`, `apt`, `dnf`, `xbps`, `emerge`, `nix`, `flatpak` and `mise`. The file's header defines every field.

- A primary serves a system when its family holds the os-release `ID`, or one `ID_LIKE` token, and its binary is on PATH. The identifiers are taken in order, `ID` first, and the first one a row serves decides. A binary alone makes no primary.
- An overlay or a source is present when its binary is on PATH. `aur` is present only beside the `pacman` primary. Its binary is `paru`, else `yay`; `dnf`'s is `dnf5`, else `dnf`.
- The table names no elevation command. A row's `elevate` says whether its steps need root. `aur` does not: the helper asks for root itself. The command that supplies root is chosen where the steps run, never in the table.
- `nix` has no steps and no check: a NixOS system changes through its own configuration.

## Steps

`vgsh pkg plan` prints a plan: each step's argv, in order. It runs nothing.

- Install and remove take one package name or more; upgrade takes none.
- A package name is printable ASCII with no space and never starts with `-`, so no manager reads it as an option.
- A pacman-family step that refreshes the databases also upgrades: `-Syu`, never `-Sy` alone, which is a partial upgrade.
- The steps take no `--noconfirm` or `-y`: the manager asks its own questions in the terminal where the steps run.

## Checks

A row's `check` is the unprivileged update query: its argv, the meaning of each exit status and the parser that reads its output. An exit status the row does not list is a failure. A status marked `rows` means the parser's rows are the updates, and none when it reads none.

The exit statuses that carry a meaning come from each tool's own source:

- `checkupdates`: 0 updates, 2 none, checkupdates(8).
- `paru -Qua` and `yay -Qua`: 0 updates, 1 none, paru `src/query.rs` `print_upgrade_list` and yay `print.go` `printUpdateList`. yay also exits 1 on an error.
- `dnf5 check-update` and `dnf check-update`: 0 none, 100 updates, dnf5 check-upgrade(8). dnf5's `compatibility.conf` declares `check-update` an alias of `check-upgrade`.

## Boundary

The shell never elevates for a package. The table names no elevation command, `vgsh pkg` changes no package, and a package change runs only in a terminal where the user answers the manager's prompt. The one elevation a shell process performs is the Chromium policy writer's `sudo -n`, [D029](../decisions/D029-chromium-policy-writer.md), which changes no package.

## Invariants

1. The table names no elevation command, and no pacman-family step refreshes without upgrading. Enforced by `scripts/test-vgsh-pkg.js`, which judges the shipped table, with a copy planting `-Sy` and a copy planting `sudo` as its controls.
2. Each manager's plan is the argv its row states. Enforced by the same suite's plan rows, one per manager and action.
3. Detection takes the first os-release identifier a present primary serves. Enforced by the same suite's detection rows and, for the command, a fixture os-release bound over `/etc/os-release` under `unshare -rm`.
