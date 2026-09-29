# Packages

Covers: shell/Core/PackageManagers.js, bin/vgsh-pkg, bin/lib/pkg-run.sh, scripts/*vgsh-pkg*, scripts/fixtures/pkg

VGS knows a system's package managers through one table, `shell/Core/PackageManagers.js`. Every flow that installs, removes, upgrades or checks a package reads that table: [D034](../decisions/D034-one-package-manager-table.md). `bin/vgsh-pkg` loads it under node through `bin/lib/qml-library.js`, and `vgsh pkg` is its command. Its header states each verb's output and refusals.

## The table

One row per manager: `pacman`, `aur`, `apt`, `dnf`, `xbps`, `emerge`, `nix`, `flatpak` and `mise`. The file's header defines every field.

- A primary serves a system when its family holds the os-release `ID`, or one `ID_LIKE` token, and its binary is on PATH. The identifiers are taken in order, `ID` first, and the first one a row serves decides. A binary alone makes no primary.
- An overlay or a source is present when its binary is on PATH. `aur` is present only beside the `pacman` primary. Its binary is `paru`, else `yay`; `dnf`'s is `dnf5`, else `dnf`.
- No row names an elevation command. A row's `elevate` says whether its steps need root. `aur`, `flatpak` and `mise` do not: each tool asks for root itself when it needs it. `vgsh pkg run` chooses the command that supplies root: [§ Running a plan](#running-a-plan).
- `nix` has no steps and no check: a NixOS system changes through its own configuration. The sudo grant follows the same rule; [tui-sudo.md](tui-sudo.md) names its configuration-only path.
- `packageFor` picks the package that provides a requirement on the detected system: the primary's entry, then an overlay's, then a source's, else none. `PluginLogic.js` imports the table's manager ids and package-name grammar to judge a manifest's `requirements`: [requirements.md](requirements.md).

## Steps

`vgsh pkg plan` prints a plan: each step's argv, in order. It runs nothing.

- Install and remove take one package name or more; upgrade takes none.
- A package name is printable ASCII with no space and never starts with `-`, so no manager reads it as an option.
- A pacman-family step that refreshes the databases also upgrades: `-Syu`, never `-Sy` alone, which is a partial upgrade.
- The steps take no `--noconfirm` or `-y`: the manager asks its own questions in the terminal where the steps run.

## Running a plan

`vgsh pkg run install|remove|upgrade [--manager <id>] [names...]` runs a plan in the terminal it is typed in. Without `--manager` it takes the detected primary. `vgsh pkg install` and `remove` with names do the same.

- **Where it runs.** Before it reads anything, `run` refuses `caller=shell` when `VGSH_RUNNER_PID` is set, and `<verb>=no-terminal` when `/dev/tty` does not open. `vgsh run` exports that variable to the shell, so every process the shell starts carries it. The shell removes it only from the programs it opens for the user: `shell.run.detached` and a floating TUI's terminal ([tui.md](tui.md)). So a plugin process never elevates, and a terminal the user opened from the shell does not refuse.
- **Elevation.** Each step of a row whose `elevate` is true runs behind one command from the table's `ELEVATORS`: `packages.elevate` in `shell.json` ([configuration.md](configuration.md)) when set, else the first of `sudo`, `doas` and `run0` on PATH. A configured command that is absent, or no command at all, is refused before any step runs. A row whose `elevate` is false runs with no elevation command.
- **The runner.** node decides; bash runs. `bin/vgsh-pkg` hands `bin/lib/pkg-run.sh` the elevation command and each step's argv, each led by its length. The steps never pass through a shell string: a name that holds `$(...)` reaches the manager as one word. The steps run from `$HOME`, as a check's queries do, so a project's `mise.toml` in the caller's directory cannot make `mise upgrade` do other than what the check counted. The runner prints each step in the theme accent, stops at the first step that fails and exits with its status.
- **sudo.** A run through `sudo` holds one `vgs_tui_sudo_session` of `bin/lib/tui.sh` for all its steps: the password is asked once, before the first step, and the credential is dropped when the run ends, also after a failure or a Ctrl-C. A one-step run holds one too, so no run leaves a credential cached behind the window.
- **doas and run0.** Neither has a command that refreshes a credential without running a program as root, so they get no keepalive. Each step asks as the system's rules say: `persist` in `doas.conf`, or polkit's `auth_admin_keep` for `run0`.
- **The ending.** `run` prints no Done or Failed. `vgsh-tui present` prints the ending from the exit status.
- **The rescan.** Once the steps end, however they end, `run` runs `vgsh plugin rescan`, so a running shell reports each requirement the change brought or took away ([requirements.md § Command line](requirements.md#command-line)). A run refused before its steps asks for none, and the exit status stays the steps'.

## Pickers

`vgsh pkg install` and `vgsh pkg remove` with no names open fzf. A row's `picker` names two read-only queries per action: `list` prints the packages, and `preview` prints the details of the package under the cursor.

- The flags, keys and preview layout are Omarchy's `omarchy-pkg-install`, `omarchy-pkg-remove` and `omarchy-pkg-aur-install` (basecamp/omarchy `e332dc97`): `--multi`, the preview in the lower 65 % with `alt-p` to hide it, and `alt-d`, `alt-u`, `alt-j` and `alt-k` to scroll it. The pointer and marker take `VGS_TUI_SUCCESS` for an install and `VGS_TUI_DANGER` for a removal, from the theme's `gum.env`, else fzf's `green` and `red`.
- fzf runs a preview as a shell string. `bin/vgsh-pkg` quotes each preview word and leaves only fzf's `{1}`, which fzf fills and quotes itself. No preview word holds a brace. fzf runs with `SHELL=/bin/sh`, so the quoting holds whatever the user's login shell.
- The picked names go to `run` as argv. Picking nothing exits 0; Esc or Ctrl-C exits 130, so `present` closes the window with no prompt.
- Without `--manager`, install asks first which manager to pick from when an overlay offers a picker beside the primary: the AUR beside pacman. The AUR's steps run through the helper with no elevation command, since the helper asks for root itself.
- pacman, the AUR, apt and dnf have pickers. pacman's remove list is its explicit packages, which include the AUR's, as Omarchy's is. xbps, emerge, nix, flatpak and mise have none: `vgsh pkg install --manager <id> <names>` still runs their steps.
- Omarchy passes `--noconfirm` and joins the picked names through `tr` and `xargs`. VGS lets the manager ask its own questions and hands the names as argv.

## Checks

`vgsh pkg check` counts the updates each detected manager offers, without root and without a partial upgrade.

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

## Queries

A row's `owner` names the package that owns a file, and its `installed` names a package's installed version. Each is an argv and the pattern whose first group reads the answer from the first line the query prints. `vgsh pkg owner <path>` runs the primary manager's two queries and prints `{ manager, package, version }`. Both queries only read the package database. `vgsh self status` asks it which package owns a VGS tree: [distribution-methods.md](distribution-methods.md).

- `installed` answers the upstream version, with no epoch and no packaging revision, so a `vgs-git` version ends in its commit on every manager.
- The table asks no `installed` query of xbps and emerge, which no VGS package serves, so their `version` is null.
- A query that exits non-zero refuses with the query's own stderr after the line. Every owner query exits non-zero for a file no package owns.

The outputs the patterns read come from each tool's own documentation:

- `pacman -Qoq` prints the owner's name, and `pacman -Q <name>` prints `<name> [<epoch>:]<pkgver>-<pkgrel>`, pacman(8).
- `dpkg -S` prints `<package>[:<arch>]: <path>`, and `dpkg-query -W --showformat='${Version}\n'` prints `[<epoch>:]<upstream>[-<revision>]`, dpkg-query(1) and deb-version(7).
- `rpm -qf --queryformat '%{NAME}\n'` and `rpm -q --queryformat '%{VERSION}\n'` print the tag alone, rpm(8).
- `xbps-query -o` prints `<pkgver>: <path>`, with `<pkgver>` the package's name, `-`, its version and `_<revision>`, xbps-query(1) and xbps `bin/xbps-query/ownedby.c`.
- `qfile` prints `<category>/<package> (<path>)`, the Gentoo wiki's Q applets page.

## Boundary

The shell process never elevates for a package. The table names no elevation command, and only `vgsh pkg run`, `install` and `remove` change a package: they refuse in a process the shell started and without a terminal, so a package change runs only where the user answers the prompt. The core opens the pickers as the floating TUIs `core/pkg-install` and `core/pkg-remove` ([tui.md](tui.md)). The one elevation a shell process performs is the Chromium policy writer's `sudo -n`, [D029](../decisions/D029-chromium-policy-writer.md), which changes no package.

## Invariants

1. The table names no elevation command in a step or a picker, no pacman-family step refreshes without upgrading, and no preview word holds a brace. Enforced by the table suite `scripts/test-vgsh-pkg-table.js`, which judges the shipped table, with a copy planting `-Sy`, a copy planting `sudo` in a step and in a picker, and a copy planting `{q}` in a preview as its controls.
2. Each manager's plan is the argv its row states. Enforced by the table suite's plan rows, one per manager and action.
3. Detection takes the first os-release identifier a present primary serves. Enforced by the table suite's detection rows and, for the command, by the CLI suite `scripts/test-vgsh-pkg-cli.js` with a fixture os-release bound over `/etc/os-release` under `unshare -rm`.
4. An exit status a query does not list fails the check, and each parser reads its manager's output into the packages written by hand beside it. Enforced by the table suite's outcome and parser rows over the canned outputs in `scripts/fixtures/pkg/`, with a copy that reads an unlisted status as output and one copy per parser as controls.
5. A check holds the lock, a query past its timeout ends with its process group, and a check stopped by a signal ends every query's group, SIGKILL included for one that ignores SIGTERM, and holds the lock until the last has ended. Enforced by the CLI suite's `check` rows against stub commands, with copies that signal only the query's leader, send no SIGKILL, install no signal handler or exit when the first query ends as controls.
6. Each manager's owner and installed queries are the argv its row states, and each reads its manager's output. Enforced by the table suite's query and answer rows, and for `vgsh pkg owner` by the CLI suite's stub `pacman` and `xbps-query` commands under fixture os-release files. Its controls are a copy whose answer ignores the pattern and a copy of `bin/vgsh-pkg` that asks no installed version.
7. `run` refuses without a terminal and in a process the shell started, before any command runs. Enforced by `scripts/test-vgsh-pkg-run.sh` with stub elevation commands and managers that record their argv, with a copy that skips the terminal test and a copy that ignores `VGSH_RUNNER_PID` as controls.
8. A sudo run asks once and drops the credential at the end, the first failing step ends the run, a step reaches the manager as argv, and a row with `elevate` false runs with no elevation command. Enforced by the same suite, with copies that hold no sudo session, run past a failure, run a step through `bash -c` and always elevate.
9. The elevation command is `packages.elevate`, else the first of `sudo`, `doas` and `run0` on PATH; `PluginLogic.configError` refuses any other value. Enforced by the table suite's elevator rows, the run suite's rows and `scripts/test-plugin-logic.js`, each with its own control.
10. A picker offers the table's list, previews through the table's quoted query, colours from `gum.env` and runs nothing when left. Enforced by the run suite with a stub fzf, with copies that leave the preview unquoted, ignore the colour and run after Esc.
