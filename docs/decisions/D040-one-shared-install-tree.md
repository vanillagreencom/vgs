# D040: Every channel installs one shared VGS tree

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: [docs/plans/v2-platform-roadmap.md](../plans/v2-platform-roadmap.md), VGS-531 packaging research

**Context**: VGS needs AUR packages, a Nix flake and a curl installer to install the same runtime files. The shell must also prove that startup and theme apply do not write into a system prefix.

**Decision**:

- Every channel calls `packaging/install-system.sh` with `DESTDIR` and `PREFIX`.
- A packaged install uses `/usr/share/vgs` for the runtime tree. The tree contains `bin`, `shell`, `config`, `themes` and `VERSION`.
- `$PREFIX/bin/vgsh` is a symlink to `../share/vgs/bin/vgsh`.
- The installer drops `AGENTS.md`, `CLAUDE.md` and `README.md` under `shell/`, and installs the root `README.md` and `LICENSE` under doc and licence paths.
- `scripts/check-install-tree.sh` compares the installed tree with `packaging/install-tree.manifest`, and has a `--write` mode for intentional file-list updates.
- Publishing runs from local scripts. VGS adds no GitHub workflow for releases or package publication.
- VGS uses the MIT licence. Package metadata uses `MIT AND OFL-1.1 AND ISC` because bundled fonts and icons carry their own licences.

**Rationale**:

- One installer gives every channel the same file set and makes package recipes thin.
- `/usr/share/vgs` matches a script and data payload. `/usr/lib/vgs` fits architecture-specific binaries better than this tree.
- `/etc/xdg/quickshell` is configuration, not the product root. VGS must start through `vgsh` so the instance lock, version read and root resolution stay in one place.
- Local publishing scripts match the repository rule that VGS has no CI workflows or branch gates.
- MIT matches v1 and the owner's selected licence.

## Omarchy comparison

At `basecamp/omarchy` `main`, read from `/home/method/dev/vgs/tmp/omarchy-ref`, Omarchy's user Hyprland file loads `(os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua"`. Omarchy uses one distribution tree with defaults, migrations, packages, helper commands and themes. Development overrides set `OMARCHY_PATH`.

VGS takes the single-tree property, but not the distribution ownership. VGS installs one shell beside a user's own Hyprland configuration. User state stays in XDG directories.

## Verification

`scripts/test-install-tree.sh` proves the installer and manifest checker. `scripts/qml-smoke.sh` runs `scripts/smoke/rows/read-only-prefix.sh`, which starts from a non-writable installed prefix and applies the default theme.

**Revisit When**: VGS ships architecture-specific binaries, package publication moves to a workflow, or a channel needs a different runtime tree.

**References**: [distribution.md](../architecture/distribution.md), [validation.md](../architecture/validation.md), [D001](D001-hyprland-only.md), [D009](D009-one-manifest-judge-under-node.md)
