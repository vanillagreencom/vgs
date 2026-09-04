# VGS architecture

VanillaGreen Shell is a desktop shell for Hyprland and Niri: a Quickshell 0.3.0 QML runtime, a Go daemon for system integration, and a single-file Python helper that owns parsing, generation and privileged writes. Hyprland is the reference compositor and Niri support is additive. One session runs exactly one shell.

## The one idea

QML draws and orchestrates; it does not parse formats, render templates, or write anything privileged. Every other job leaves the runtime through one of two seams — the `vshell` CLI for generation and privileged work, or the backend socket for live system state — and each resource behind those seams has exactly one owner. A second watcher, poller or daemon for something already owned is the defect this shape exists to prevent, because two owners disagree and the disagreement reaches the user as a surface that is wrong rather than absent.

## Vocabulary

`vshell`: the runtime name, the CLI name, and the Quickshell config name. `vgs` is the product name and never a command, because it collides with the LVM tool of that name.

Theme package: a directory under `themes/<name>/` holding palette, wallpapers and optional curated per-app files. Not a single JSON file.

Target: one app VGS generates a theme file for, defined by `themes/targets/<id>/`.

Capability: a named group of backend methods the daemon advertises at connect time. QML tests for the name, never for a version number.

Bundled plugin: VGS product UI packaged as a plugin under `config/vshell/plugins/`, loaded read-only from the repo and always available. A user plugin under `~/.config/vshell/plugins/` is the overlay, and may claim a bundled id only by declaring the claim.

Pad: one scratchpad — an application parked out of sight that a keybind reveals and hides.

## Boundaries

- `quickshell/vshell/`: UI and orchestration. May call the helper through `Paths.vshellCli` and the backend through `Services/VGSBackendService.qml`. May never parse TOML or JSON formats the helper owns, render templates, or write outside the user's own config. Enforced by review and by `.github/workflows/ci.yml`'s QML steps.
- `bin/`: the helper CLI. Owns theme generation, compositor config fragments, privileged writes and every subsystem the runtime shells out for. Deliberately one large file; splitting it is its own work, not a review finding.
- `backend/`: the Go daemon and the runner that supervises it. Owns live system state — network, logind, BlueZ, CUPS, clipboard, gamma, printers, updates, cloud sync. Owns no theme code and no display power.
- `themes/`: theme packages and target templates. Palette and per-app data only, never shell or compositor geometry.
- `config/vshell/`: shipped defaults, the dependency manifest and bundled plugins. Mutable user state lives under `~/.config/vshell/` and is never written here.
- `scripts/`: this repository's test suite. There is no test framework; a check whose failure path cannot be reached is a vacuous test.
- `~/dotfiles`: wiring and machine-specific overlays only. Portable and default behaviour belongs in VGS.

## Invariants

1. The CLI is `vshell`, and no VGS runtime path calls `vgs`. Enforced by `scripts/check-naming.sh`.
2. Every backend method a caller names maps to a capability declared in `backend/methods.json`, and QML gates on advertised `capabilities` or `methods` rather than on `apiVersion` ordinals. Enforced by `scripts/check-backend-inventory.py`.
3. One session owns one shell: a second full instance competes for `WlSessionLock`, the fade-to-lock overlay and the idle tiers, and strands full-screen layer surfaces. Enforced by the `vshell instances guard` call in `quickshell/vshell/shell.qml` and by `scripts/check-validation-safety.sh`, which refuses tracked guidance that instructs a direct launch.
4. Not knowing is a state of its own, never rendered as a negative answer. A probe that could not run, a query that did not answer and a reply that could not be parsed each produce an explicit unknown carrying its reason; the previous answer is not left standing. Enforced per subsystem by `scripts/test-remote-desktop-state.js`, `scripts/check-notification-takeover.js` and `scripts/test-brightness-scan-ordering.js`.
5. An empty result is not a clean result. A check that filters, globs or collects asserts it collected something before evaluating the collection. Enforced by `scripts/lib/collected.py`, whose call-site registry names every collection point.
6. External tools are executed as argv arrays, never as a shell string built from user data, and secrets, Wi-Fi keys, clipboard contents and raw frame payloads are never logged. Enforced by `scripts/check-vshell-helper.py` and `scripts/check-paste-injection.py`.
7. `scripts/validate` reports four statuses and 77 is not a pass: it means something did not run, and it is reported as passed with the skips named. Enforced by `scripts/test-validate.sh`.
8. Every section pointer in tracked text names a heading that exists, and every relative link and decision identifier resolves. Enforced by `scripts/check-section-pointers.py` and the growth-guards `md-refs` lane.
9. A generated output path is product API: consumers depend on it, so it is renamed only behind a compatibility shim. Enforced by review against the target list in `themes/targets/`.

## Decisions

The ledger is [../decisions/INDEX.md](../decisions/INDEX.md), written through the `decider` skill; topic files cite the records that bind them and never restate one.

Three shape the whole system rather than one subsystem. [D001](../decisions/D001-quickshell-0-3-0-upstream-defects.md) records the Quickshell 0.3.0 session-lock defects as reported upstream rather than vendored or patched, which is why lock code works around them instead of fixing them. [D005](../decisions/D005-dependency-version-constraints.md) makes `config/vshell/dependencies.json` declare presence only, leaving version questions to capability probes. [D007](../decisions/D007-ci-single-job-economics.md) keeps continuous integration to one suite job, which is why there are no lanes, no nightly run and no caching.

## Topics

- [shell.md](shell.md): read before changing the QML runtime's structure, a service's ownership of a resource, or anything under `Modules/`.
- [design-language.md](design-language.md): read before changing a shared widget, a colour or spacing token, or a popout's surface geometry.
- [session.md](session.md): read before touching the lock, the idle tiers, the screensaver or the greeter — the child order in that tree is load-bearing.
- [notifications.md](notifications.md): read before changing how VGS claims the notification bus name or reverses that claim.
- [plugins.md](plugins.md): read before changing plugin loading, a bundled plugin's manifest, or the dependency manifest and what shipped code may probe for.
- [theme.md](theme.md): read before changing palette derivation, a generated target, the theme package format or the download catalog.
- [helper.md](helper.md): read before changing the helper CLI — its privileged writes, terminal resolution, scratchpads, brightness or the remote-desktop host.
- [backend.md](backend.md): read before adding a backend method, a watcher or a subprocess in the Go daemon.
- [cloud-sync.md](cloud-sync.md): read before changing sync modes, the rclone supervisor or anything that can destroy a user's files.
