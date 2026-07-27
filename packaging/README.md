# Package recipes

VGS ships recipes for package maintainers. Runtime command remains `vshell`; package name is `vgs-shell`.

| System | Recipe |
|---|---|
| Arch / AUR | `arch/PKGBUILD`, `arch/vgs-shell-git/PKGBUILD` |
| Fedora / openSUSE | `fedora/vgs-shell.spec` |
| Debian / Ubuntu | `debian/` |
| Gentoo | `gentoo/vgs-shell-0.1.0.ebuild` |
| Void | `void/template` |
| Nix | `../flake.nix` |


Recipes install the immutable runtime under `/usr/lib/vshell`, expose `/usr/bin/vshell`, and install the user service. Mutable state stays in `~/.config/vshell`.

Public repository commands belong in the main README only after installation succeeds from that repository. Guix needs a packaged Quickshell dependency before VGS can truthfully publish a channel. Release procedure: `.agents/skills/vgs-release/SKILL.md`.
