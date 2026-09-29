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
- The installer refuses an existing non-empty runtime tree. A package upgrade installs into a fresh staging root, or removes the old runtime tree first.
- `vgsh self` knows four install methods: a git checkout, the `vgs` or `vgs-git` package, a curl install and a Nix tree. `vgsh self status` names the method and whether the channel offers something newer. `vgsh self update` fast-forwards a checkout and replaces a curl install with the newest release. It refuses a package or a Nix tree and names what updates it.
- A curl install keeps each release's runtime tree in `${XDG_DATA_HOME:-~/.local/share}/vgs/X.Y.Z`, with a relative `current` link replaced by rename and `~/.local/bin/vgsh` linked to `current/bin/vgsh`. Every writer of that directory holds `vgs/.self.lock`.
- Publishing runs from local scripts. VGS adds no GitHub workflow for releases or package publication.
- VGS uses the MIT licence. Package metadata uses `MIT AND OFL-1.1 AND ISC` because bundled fonts and icons carry their own licences.
- Fedora gets `vgs` and `vgs-git` from one COPR, `vanillagreen/vgs`, from 0.1.x. Its runtime comes from the third-party COPRs `errornointernet/quickshell` and `sdegler/hyprland`, held to the preflight floor by versioned `Requires`. A Fedora release joins the project only after a clean container install passes.

**Rationale**:

- One installer gives every channel the same file set and makes package recipes thin.
- `/usr/share/vgs` matches a script and data payload. `/usr/lib/vgs` fits architecture-specific binaries better than this tree.
- `/etc/xdg/quickshell` is configuration, not the product root. VGS must start through `vgsh` so the instance lock, version read and root resolution stay in one place.
- Local publishing scripts match the repository rule that VGS has no CI workflows or branch gates.
- MIT matches v1 and the owner's selected licence.
- The install method decides who may change the tree. VGS updates only the trees it laid out itself, a checkout and a curl install. A package manager or a Nix flake owns every other tree.
- A versioned directory with a `current` link lets an update land beside the running tree. The running shell keeps its files until it restarts, and a failed update leaves `current` unchanged.
- Fedora ships Quickshell below the floor and no Hyprland, so a Fedora package needs third-party repositories. v1 co-hosted its own `quickshell` in COPR and let it go stale at 0.3.0, below v1's floor; depending on the maintained COPRs, with the floor in `Requires`, fails loudly instead.

## Omarchy comparison

At `basecamp/omarchy` `main`, read from `/home/method/dev/vgs/tmp/omarchy-ref`, Omarchy's user Hyprland file loads `(os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua"`. Omarchy uses one distribution tree with defaults, migrations, packages, helper commands and themes. Development overrides set `OMARCHY_PATH`.

VGS takes the single-tree property, but not the distribution ownership. VGS installs one shell beside a user's own Hyprland configuration. User state stays in XDG directories.

Omarchy's development channel is a git checkout that `omarchy-update-dev` fast-forwards with `git pull --ff-only`. VGS supports that checkout flow and three more forms: the `vgs` and `vgs-git` packages, a curl install and a Nix tree.

## Verification

`scripts/test-install-tree.sh` proves the installer and manifest checker. `scripts/test-vgsh-self.sh` proves the method detection, the status and the update for each method. `scripts/qml-smoke.sh` runs `scripts/smoke/rows/read-only-prefix.sh`, which starts from a non-writable installed prefix, uses the sandbox target set, checks the installed shell log and applies the default theme. `scripts/check-fedora-specs.py` holds both Fedora specs to the requirement data and the preflight floor, and `scripts/fedora-container.sh` builds and installs them in a clean Fedora container.

**Revisit When**: VGS ships architecture-specific binaries, package publication moves to a workflow, a channel needs a different runtime tree, or Fedora ships Quickshell and Hyprland at the floor, or a third-party COPR falls behind it.

**References**: [distribution.md](../architecture/distribution.md) § Install methods, [validation.md](../architecture/validation.md), [D001](D001-hyprland-only.md), [D009](D009-one-manifest-judge-under-node.md)
