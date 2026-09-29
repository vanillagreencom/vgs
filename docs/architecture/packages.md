# Packages

Covers: shell/Core/PackageManagers.js, bin/vgsh-pkg, scripts/test-vgsh-pkg.js, scripts/fixtures/pkg

VGS knows a system's package managers through one table, `shell/Core/PackageManagers.js`. Every flow that installs, removes, upgrades or checks a package reads that table: [D034](../decisions/D034-one-package-manager-table.md). `bin/vgsh-pkg` loads it under node through `bin/lib/qml-library.js`, and `vgsh pkg` is its command. Its header states each verb's output and refusals.

## The table

One row per manager: `pacman`, `aur`, `apt`, `dnf`, `xbps`, `emerge`, `nix`, `flatpak` and `mise`. The file's header defines every field.

- A primary serves a system when its family holds the os-release `ID`, or one `ID_LIKE` token, and its binary is on PATH. The identifiers are taken in order, `ID` first, and the first one a row serves decides. A binary alone makes no primary.
- An overlay or a source is present when its binary is on PATH. `aur` is present only beside the `pacman` primary. Its binary is `paru`, else `yay`; `dnf`'s is `dnf5`, else `dnf`.
- The table names no elevation command. A row's `elevate` says whether its steps need root. `aur` does not: the helper asks for root itself. The command that supplies root is chosen where the steps run, never in the table.
- `nix` has no steps and no check: a NixOS system changes through its own configuration.
- `packageFor` picks the package that provides a requirement on the detected system: the primary's entry, then an overlay's, then a source's, else none. `PluginLogic.js` imports the table's manager ids and package-name grammar to judge a manifest's `requirements`: [requirements.md](requirements.md).

## Steps

`vgsh pkg plan` prints a plan: each step's argv, in order. It runs nothing.

- Install and remove take one package name or more; upgrade takes none.
- A package name is printable ASCII with no space and never starts with `-`, so no manager reads it as an option.
- A pacman-family step that refreshes the databases also upgrades: `-Syu`, never `-Sy` alone, which is a partial upgrade.
- The steps take no `--noconfirm` or `-y`: the manager asks its own questions in the terminal where the steps run.

## Checks

`vgsh pkg check` counts the updates each detected manager offers, without root and without a partial upgrade. The `bin/vgsh-pkg` header states its output and its error values.

A row's `check` lists its unprivileged update queries. The first whose `binary` is null or names the row's binary runs. Each query holds its argv, the meaning of each exit status, the parser that reads its output, its timeout and whether it runs only on demand. An exit status the query does not list is a failure, whatever the output holds. A status marked `rows` means the parser's rows are the updates, and none when it reads none. A parser refuses a line its format does not define, so a changed format fails the check instead of miscounting it.

Each query, what its exit statuses mean and where that comes from:

- pacman, `checkupdates`: 0 updates, 2 none, checkupdates(8); 1 is its "Cannot fetch updates". It drops the packages pacman ignores.
- aur, `paru -Qua` or `yay -Qua`: 0 updates, 1 none, paru `src/query.rs` `print_upgrade_list` and yay `print.go` `printUpdateList`. paru marks an ignored package ` [ignored]` and the parser leaves it out. yay also exits 1 on an error, so a failed yay query reads as no update.
- apt, `apt list --upgradable`: 0, `apt-private/private-list.cc`. It lists what the package lists held at the last `apt update`, which needs root, so the count is only as current as that run.
- dnf with dnf5, `dnf5 check-upgrade --json`: 0 for updates and none alike, `dnf5/commands/check-upgrade/check-upgrade.cpp`. The JSON output needs dnf5 5.4.0 or later; an earlier dnf5 refuses `--json` and the check fails with `exit=2`.
- dnf with dnf 4, `dnf -q check-update`: 0 none, 100 updates, `dnf/cli/commands/__init__.py`. dnf5's `compatibility.conf` makes `check-update` an alias of `check-upgrade`, but the dnf5 binary is preferred whenever present.
- xbps, `xbps-install -Mun`: 0 for updates and none alike, `bin/xbps-install/transaction.c` `dist_upgrade`. `-M` fetches the repository index into memory, so no root is needed. Only `update` entries count.
- emerge, `emerge --pretend --update --deep --newuse --color=n --ask=n @world`: 0, runs only when named by `--source emerge`, because it resolves the whole dependency graph. `--ask=n` overrides an `--ask` in `EMERGE_DEFAULT_OPTS`. `U` in a merge's flags marks a new version, `lib/_emerge/resolver/output_helpers.py`.
- flatpak, `flatpak remote-ls --updates --columns=application,branch`: 0. It prints no version, so the branch stands for the new one.
- mise, `mise outdated --json`: 0, with `MISE_MINIMUM_RELEASE_AGE=0`, so it counts what `mise upgrade` installs.
- nix has no query: a NixOS system changes through its own configuration. Its result is `skipped=no-check`.

dnf, xbps and flatpak print no installed version, so those packages carry `old` null.

The queries run at once, from `$HOME` with `LC_ALL=C`, so every format reads in English and mise reads no project's `mise.toml`. A query past its timeout has its process group ended, so a helper it started does not outlive it. A check stopped by SIGINT, SIGTERM or SIGHUP ends every query's group the same way and exits only after the last one ends, with 128 plus the signal's number. The timeouts bound a hung query; they are not a speed budget. On a CachyOS machine on 2026-09-28, timed with `date` around each command, `checkupdates` took 1.1 s, `paru -Qua` 1.4 s and `mise outdated --json` 0.01 s, against a 120 s timeout. emerge's 900 s is not measured.

One check runs at a time: each holds `flock` on `$XDG_RUNTIME_DIR/vgs/pkg-check.lock` until it exits, and a second waits for the first. A stopped check releases the lock with no query left running. `checkupdates` syncs its own copy of the databases on every run. A check passes `-n` and compares against that copy when VGS's last successful synced check is under ten minutes old and the copy still holds a database, since `-n` against no database reports no update. A check right after a short upgrade is one such check; one after an upgrade longer than ten minutes syncs again.

Omarchy's `omarchy-update-available` filters `checkupdates` for the Omarchy package alone. VGS counts every source, because the Updates badge covers the whole system.

## Boundary

The shell never elevates for a package. The table names no elevation command, `vgsh pkg` changes no package, and a package change runs only in a terminal where the user answers the manager's prompt. The one elevation a shell process performs is the Chromium policy writer's `sudo -n`, [D029](../decisions/D029-chromium-policy-writer.md), which changes no package.

## Invariants

1. The table names no elevation command, and no pacman-family step refreshes without upgrading. Enforced by `scripts/test-vgsh-pkg.js`, which judges the shipped table, with a copy planting `-Sy` and a copy planting `sudo` as its controls.
2. Each manager's plan is the argv its row states. Enforced by the same suite's plan rows, one per manager and action.
3. Detection takes the first os-release identifier a present primary serves. Enforced by the same suite's detection rows and, for the command, a fixture os-release bound over `/etc/os-release` under `unshare -rm`.
4. An exit status a query does not list fails the check, and each parser reads its manager's output into the packages written by hand beside it. Enforced by the same suite's outcome and parser rows over the canned outputs in `scripts/fixtures/pkg/`, with a copy that reads an unlisted status as output and one copy per parser as controls.
5. A check holds the lock, a query past its timeout ends with its process group, and a check stopped by a signal ends every query's group, SIGKILL included for one that ignores SIGTERM, and holds the lock until the last has ended. Enforced by the same suite's `check` rows against stub commands, with copies that signal only the query's leader, send no SIGKILL, install no signal handler or exit when the first query ends as controls.
