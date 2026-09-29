# Install guide

Covers: README.md § Install, § Shipped plugins and § Licence, scripts/check-readme.js, scripts/test-check-readme.js, scripts/preflight-floor.js, scripts/readme-install.sh, scripts/test-readme-install.sh

`README.md` § Install is the install guide users read. This file states what the section must say, where each fact comes from, and the two scripts that hold it to those sources.

## What the section says

| Fact | Source |
|---|---|
| The floor, stated once in the first paragraph: each tool with `<need> or later`, or its name for `present` | the `preflight_floor` table of `bin/vgsh` ([runtime.md § Process](runtime.md#process)) |
| Arch: `yay -S <pkg>` for each package, each in its own fence, because the two conflict | the recipes under `packaging/arch/` |
| The install script: `curl -fsSL <main install.sh> \| bash`, and `bash -s -- <options>` | the option parser of `install.sh`; a `--version` value is `v` plus `VERSION` |
| Nix: `nix run github:vanillagreencom/vgs/v<VERSION> -- <vgsh args>` | `VERSION`, and the usage header of `bin/vgsh` for the command |
| A checkout: `git clone https://github.com/vanillagreencom/vgs`, then `vgs/bin/vgsh <args>` | the usage header of `bin/vgsh` |
| The autostart line, in one `lua` fence | the autostart sentence in [runtime.md § Process](runtime.md#process), and the line `install.sh` prints with `vgsh` for its absolute path |
| The first run adds one line to `hyprland.lua`, and `vgsh hypr unwire` removes it | [hyprland.md](hyprland.md) |
| One Shipped plugins row per plugin directory | the directories `bin/vgsh-scan` lists under `shell/plugins/` |
| The package licence expression | `license` in `packaging/arch/vgs/PKGBUILD` |
| Fedora follows in 0.1.x. Debian, Ubuntu, openSUSE, Gentoo and Void wait until their repositories carry Quickshell 0.3.1 and Hyprland with Lua configuration. | [distribution.md § Fedora](distribution.md#fedora) for Fedora; decision 5 of [the platform roadmap](../plans/v2-platform-roadmap.md#decisions) for the rest |

Every line of a `bash` fence in § Install is one command of one channel. A line that fits no channel above is refused, so a new install path needs a channel in the check first.

## The check

`scripts/check-readme.js` is the offline check, a row in the `cli` area of `scripts/validate`. Its header lists each rule and the finding it prints: `section`, `floor`, `command`, `autostart`, `plugin` and `licence`. It reads the floor through `scripts/preflight-floor.js`, the one reader of the floor table, which `scripts/check-packaging.js` also uses. A floor bump, a `VERSION` bump, an option `install.sh` no longer takes, a new plugin or a changed licence fails the check until the README follows.

`scripts/test-check-readme.js` plants one defect per rule in a scratch copy and pins every output line.

`check-readme.js --commands` prints one JSON line per command: its fence, its README line, its channel, its needs and its `vgsh` arguments. The runner reads these lines, never the README.

## The runner

`scripts/readme-install.sh` runs each command as the README prints it, in clean podman containers:

- The aur, curl and checkout commands run in an `archlinux:latest` image with Quickshell, Hyprland, node, python and git. They run as an unprivileged user with a login session's `HOME` and `XDG_RUNTIME_DIR`.
- The nix command runs in `nixos/nix`.
- Each fence runs top to bottom in one fresh container, so alternatives such as the two AUR packages go in separate fences. Every prompt gets an empty answer, so it takes its default.
- A command runs under `pipefail`, so a `curl ... | bash` whose download fails fails too, though bash exits 0 on an empty script.
- A command passes on exit 0. A command that runs `vgsh run` passes when it exits 78 at the Hyprland floor, because no Hyprland runs in a container.

The curl and checkout commands read `main` on GitHub, so the runner checks what users get, not the working tree. It needs podman and the network, so it runs by hand, not in `scripts/validate`. `scripts/test-readme-install.sh` covers its host side with stubs.

### Needs and unpublished commands

- A curl release install and the nix run need the tag `v<VERSION>`. The runner asks `git ls-remote --tags`.
- An AUR install needs its package in the AUR. The runner asks the AUR RPC info query.
- A command whose need is not published is not measured. The rest of its fence still runs. The runner names each such command and exits 77, which is not a pass.
- A probe that fails is not measured either. It is never read as unpublished.

Before the first release, only the checkout commands and the curl `--git` and `--uninstall` commands run. The release (VGS-562) runs the runner after it publishes the tag, the release assets and the AUR packages. A pass then measures every command and exits 0.
