# VGS

VanillaGreen Shell is a desktop shell for Hyprland and Niri: a Quickshell 0.3.0 QML runtime, a Go daemon for system integration, and a single-file Python helper CLI that owns parsing, generation and privileged writes. Hyprland is the reference compositor and Niri support must be additive. This repository drives the live session on this machine.

The runtime, the CLI and the Quickshell config are all named `vshell`. `vgs` is the product name and never a command, because it collides with the LVM tool of that name.

## Never launch a second shell into the live session

Never run `qs -c vshell` or `qs -p quickshell/vshell`: each starts a full second VGS instance that fights the session shell for session-global resources and strands orphaned layer surfaces, ending the session as cursors over black, recoverable only with `vshell ipc call lock forceReset`. Never `pkill quickshell` either — other Quickshell applications on the seat are legitimate, so signal by process id or process group. `scripts/validate qml` is the sanctioned smoke and shows the same breakage without a second instance.

## Validation

`scripts/validate [AREA]` is the whole suite, and its header is the manifest: <!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->. Scope the run to what you touched.

Its exit status is four-valued and **77 is not a pass**: `0` everything selected ran and passed, `77` what ran passed but something did not run, reported as passed with each skip named, `1` a real failure, `2` a broken invocation where nothing ran.

A green continuous-integration run does not prove the shell starts, because only the static half of the QML smoke runs there. Run `scripts/validate qml` locally before finishing QML work.

## Conventions

- Commit subjects take the conventional form the `commit-msg` guard enforces, with the issue identifier as the scope: `fix(VGS-12): tighten the gate`. An area may ride along in the scope, as in `fix(printers/VGS-189): ...`.
- Branch names are `vgs-<n>-<slug>`, which is what attaches a pull request to its issue.
- Releases follow `.agents/skills/vgs-release/SKILL.md` and verify every maintained install channel. A channel that cannot be verified is named in the release notes, never silently skipped.
- Session handoff is `docs/handoff/HANDOFF.md`, gitignored and overwritten in place. Read or write it on request only.
- `~/dotfiles` is a wiring and overlay layer. Portable and default behaviour belongs in VGS, never moved out to dotfiles.
- Rollback means reinstalling another shell. VGS keeps no disabled rollback service.

## Do not

- Do not restart `vshell.service` unless asked; this repository drives the live session.
- Do not suspend the machine, and do not destructively test network joins or device pairing and removal, to verify a change.
- Do not reintroduce legacy upstream naming into runtime code, configuration, generated paths or documentation, outside attribution and licence lineage.
- Do not depend on legacy upstream runtime services or on an external theme engine.

## Read next

- [docs/architecture/overview.md](docs/architecture/overview.md): before structural work, and to find the topic file for a subsystem.
- [docs/decisions/INDEX.md](docs/decisions/INDEX.md): before re-arguing a path choice; records are cited by identifier and never restated.
- `<dir>/AGENTS.md`: when working under that directory — `quickshell/vshell/`, `backend/`, `bin/`, `themes/`, `config/vshell/`, `scripts/`, `packaging/`, and the vendored trees.
- [review-bots.md](review-bots.md): reviewer context for the pull-request bots. Agent sessions do not load it as working instructions.
- `kendex.settings.toml`: every settings key with its rationale. `AGENTS.local.md` is this machine's wiring, untracked and absent from a fresh clone.
