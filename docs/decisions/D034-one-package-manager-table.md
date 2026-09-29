# D034: One package-manager table in the core, and the shell never elevates for a package

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: [v2-platform-roadmap.md](../plans/v2-platform-roadmap.md) § 2, VGS-516

**Context**: Updates, Dev Tools, a plugin's external requirements and the installer's hints all need to know the system's package managers. VGS v1 had two collectors that disagreed: `bin/vshell_devtools.py` held one install argv per family and `bin/vshell_apps.py` held the owner queries, while `backend/internal/services/sysupdate/sysupdate.go` knew pacman, paru, flatpak and mise alone. VGS runs on any distribution that carries Quickshell 0.3.1 and Hyprland, so it cannot assume Arch.

**Decision**: The core owns one package-manager table, `shell/Core/PackageManagers.js`, a pure `.pragma library` file. Each row holds a manager's id, role (one primary per system, overlays and user-level sources), the os-release family it serves, its binaries in preference order, whether its steps need root, its unprivileged check with the meaning of each exit status and its parser's name, its install, remove and upgrade steps as argv templates, and its owner query. `bin/vgsh-pkg` loads the table under node through `bin/lib/qml-library.js` and answers `vgsh pkg detect`, `present` and `plan`; a judge that needs manager ids imports the same file. The table names no elevation command, and the shell process never elevates for a package: a package change runs only in a terminal where the user answers the manager's prompt. `vgsh pkg run` is that path. It refuses without a terminal and in a process the shell started, and puts `sudo`, `doas` or `run0` before a step that needs root, `shell.json`'s `packages.elevate` choosing among them.

**Rationale**:

- One owner per concern: every package flow reads one table, so no two flows disagree on a manager's argv.
- The table is data a judge can import, so a manifest that names a manager is judged against the ids the command runs ([D009](D009-one-manifest-judge-under-node.md)'s one-judge rule).
- A password prompt the user sees and answers in a terminal is the only privilege path. A shell process that elevated would hold root with no one watching.

## Where VGS differs from Omarchy

Omarchy (`basecamp/omarchy`, `main`) is pacman plus yay only: `omarchy-pkg-add`, `omarchy-pkg-drop`, `omarchy-pkg-aur-add`, `omarchy-update-system-pkgs` and `omarchy-update-aur-pkgs`.

| Omarchy | VGS | Why |
|---|---|---|
| `pacman -S --needed --`, `pacman -Rns`, `yay -S --needed --`, `yay -Sua`, and a full `-Syu`. | The same argv for the `pacman` and `aur` rows. | Omarchy's argv is right for Arch; VGS takes it. |
| AUR updates run after the system upgrade. | The `aur` row is an overlay on the `pacman` primary, and an upgrade across managers runs the primary first. | The same order: the repositories first. |
| Arch only, because Omarchy is the distribution. | One primary per family (`pacman`, `apt`, `dnf`, `xbps`, `emerge`, `nix`), chosen from os-release `ID` and `ID_LIKE`, as v1's family table did. | VGS is not the distribution and runs wherever its runtime floor is met. |
| `yay` is the AUR helper. | `paru`, else `yay`. | Either serves; the owner's machine has `paru`. |
| Installs pass `--noconfirm`. | No step passes `--noconfirm` or `-y`. | The manager asks its own questions in the terminal the user watches. |
| The scripts call `sudo` themselves. | The table names no elevation command; the row says whether root is needed, and `vgsh pkg run` adds `sudo`, `doas` or `run0`. | The command that supplies root is chosen where the steps run, not in shared data, and a system without sudo still works. |

DankMaterialShell's system updater picks one primary backend plus overlays, the same shape.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Per-plugin scripts, each plugin knowing its own managers | v1's two collectors disagreed; every plugin would repeat the family table. |
| PackageKit | Absent on Arch by default, and it has no AUR, Flatpak or mise. |
| One plugin owns packages | The core needs the table itself for a plugin's requirements, and a core feature would hang on a plugin toggle ([D003](D003-everything-is-a-plugin.md)). |

**Revisit When**: A supported distribution's manager cannot be expressed as argv steps, or the shell must change a package with no terminal open.

**Verification**: `scripts/test-vgsh-pkg.js` judges the shipped table (no elevation command, no `-Sy` alone), pins each manager's plan and the detection over os-release texts and stub PATHs, and runs `vgsh pkg` with a fixture os-release bound over `/etc/os-release`. `scripts/test-vgsh-pkg-run.sh` runs `vgsh pkg run` and the pickers against stub elevation commands and managers, with controls that run without a terminal and elevate inside the shell.

**References**: [D003](D003-everything-is-a-plugin.md), [D009](D009-one-manifest-judge-under-node.md), [D029](D029-chromium-policy-writer.md), [packages.md](../architecture/packages.md)
