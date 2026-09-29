# Install methods

Covers: bin/lib/self.js, scripts/test-vgsh-self.sh

`vgsh self status` names how this tree was installed and whether its channel offers something newer. `vgsh self update` updates the tree where VGS owns it. `bin/lib/self.js` is the one judge of the method and of `behind`; `bin/vgsh` makes every git call and hands it the facts. The command's header in `bin/vgsh` states every output and refusal.

## The four methods

The judge tries each method in this order, on the real path of the tree beside `bin/`:

| Method | The tree is | `current` | `latest` | Behind while |
|---|---|---|---|---|
| `checkout` | the top level of its own git checkout, as `vgsh version` decides | `HEAD` in the describe form | the upstream commit in the describe form, after a fetch | the upstream holds commits `HEAD` lacks |
| `nix` | inside the Nix store: `$NIX_STORE_DIR`, else `/nix/store` | `VERSION` | the newest release | the newest release is newer |
| `curl` | the directory `${XDG_DATA_HOME:-~/.local/share}/vgs/current` resolves to, a directory of `…/vgs` | `VERSION` | the newest release | the newest release is newer |
| `package` | owned, through its `VERSION`, by the primary package manager, as the package `vgs` or `vgs-git` | the package's installed version | `vgs`: the newest release; `vgs-git`: the commit `main` points at | `vgs`: the newest release is newer; `vgs-git`: `main` is not the commit its version names |

- Any other tree is refused as `method=unknown path=<root>`. So is a package other than `vgs` and `vgs-git`, as `package=<name> manager=<id> reason=not-vgs`.
- The owner query is the package layer's: `vgsh pkg owner <path>` runs the primary manager's owner and installed queries from `shell/Core/PackageManagers.js` ([packages.md § Queries](packages.md#queries)). pacman, apt and dnf answer both; xbps and emerge name the owner only.
- A `vgs-git` version ends in the commit it was built from: the AUR form `X.Y.Z.r<N>.g<hash>` and the COPR form `X.Y.Z^<N>.git<hash>`. Any other `vgs-git` version is refused as `reason=not-a-version`.
- A checkout's fetch is `plugin outdated`'s fetch ([manager.md § Outdated](manager.md#outdated)): no hook, no prompt, no askpass, no `FETCH_HEAD`, ended at 10 s. `main`'s commit for `vgs-git` is `git ls-remote https://github.com/vanillagreencom/vgs.git refs/heads/main` under the same rules. The package recipe builds from that URL.
- The newest release is `GET https://api.github.com/repos/vanillagreencom/vgs/releases/latest`, ended at 10 s. Its tag must be `v<X.Y.Z>`. A repository with no release is `release=none`.

## Output

- `vgsh self status --json` prints one line `{ version, method, package, current, latest, behind, error }`. `version` is `VERSION`'s line. `package` is `vgs`, `vgs-git` or null. `behind` is a boolean.
- The text form prints the same fields that are set, as `key=value` words on one line.
- A step that fails does not fail the command. Its keyed refusal line becomes `error`, `latest` and `behind` are null, and the exit status is 0. The fields read before the failure stay: a checkout whose fetch fails still names its `current`.
- The planned consumer is the Updates plugin's check, which reads the JSON form beside the other update sources.

## Update

- A checkout fast-forwards to its upstream, as `plugin update` does, with no diff and no question: VGS is the program the user runs, not third-party code. A modified checkout, a missing upstream and an upstream that rewrote its history are refused with `plugin update`'s keys.
- A curl install is replaced by the newest release under `${XDG_DATA_HOME:-~/.local/share}/vgs/.self.lock`. A second update is refused `self=busy` with exit 75. The steps are the curl installer's: download `vgs-X.Y.Z.tar.gz` and `SHA256SUMS` from the release's assets into a staging directory under `…/vgs`, check the archive's sha256 against its one `SHA256SUMS` line, unpack it, require one top directory `vgs-X.Y.Z` whose `VERSION` is `X.Y.Z`, run its own `packaging/install-system.sh`, move the runtime tree to `…/vgs/X.Y.Z`, and rename a new `current` link over the old one. Three trees stay: the new one, the one the command ran from, and the one the running shell was started from, read from its command line (`qs -p <tree>/shell`). So a shell keeps its files until it restarts, even one whose earlier restart was refused. Every other version directory is removed. A running shell whose command line names no tree refuses the update as `shell=unreadable pid=<pid>`. A failure removes the staging directory and leaves `current` as it was.
- A download is https, at most 128 MiB for the archive, and ended at 120 s. VGS publishes no release signing key yet, so the update checks the sha256 alone.
- A package and a Nix tree are refused, `method=package package=<name> manager=<id>` and `method=nix`. The package manager or the flake owns the tree, and `vgsh self update` changes neither.
- After an update, a running shell restarts from the updated tree's `vgsh`. The restart's status becomes the command's. With no shell running, the last line is `shell=not-running`.
- `VGS_RELEASE_API` replaces the API base only in a test run, and only with `http://127.0.0.1:<port>`. Any other value is refused, so no environment redirects a real update.

## Verification

`scripts/test-vgsh-self.sh` builds one fixture tree per method: a clone of a local bare repository, a curl layout under a fixture `XDG_DATA_HOME`, a package tree owned by a stub `pacman` under a fixture Arch os-release bound under `unshare -rm`, and a tree under a fixture `NIX_STORE_DIR`. The newest release is a local release fixture served on 127.0.0.1, and a stub `qs` whose pid sits in the instance lock stands in for a running shell. Its controls are copies of `self.js` that call every tree a checkout, accept a loopback API outside a test run, skip the checksum comparison, or remove the running shell's tree. `scripts/test-vgsh-pkg-table.js` pins the owner and installed queries.

## Omarchy comparison

- Omarchy's development channel is a git checkout at `$OMARCHY_PATH`. `omarchy-update-available` fetches it with a 10 s timeout and counts the commits behind its upstream, and `omarchy-update-dev` runs `git pull --ff-only`. For a package it filters `checkupdates` for `omarchy` or `omarchy-dev`. VGS takes the checkout flow, and supports three more install forms: the `vgs` and `vgs-git` packages, a curl install and a Nix tree. VGS reads `vgs-git`'s commit itself, because an AUR helper reports a `-git` package behind only when its recipe's version changes. A checkout with no upstream is an error in VGS, where Omarchy skips it, so the Updates plugin never shows a silent "up to date".
