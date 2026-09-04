# VGS

VanillaGreen Shell is a desktop shell for Hyprland and Niri using Quickshell 0.3.0. Hyprland is the reference implementation; Niri support is additive. This checkout drives the live desktop session.

The runtime and CLI are named `vshell`; `vgs` conflicts with the LVM command.

## Never launch a second shell into the live session

Never run `qs -c vshell` or `qs -p quickshell/vshell`: a second instance can leave the desktop black by competing for session resources. Never run `pkill quickshell`: other Quickshell applications share the seat. Use `scripts/validate qml` for isolated runtime validation. Recovery from stranded lock surfaces is `vshell ipc call lock forceReset`.

## Validation

`scripts/validate [AREA]` owns the validation manifest: <!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->. Run the area you change; QML work requires the local runtime checks.

Exit `0` means all selected checks passed; `77` means some checks did not run and must be named; `1` means a check failed; `2` means an invalid invocation. Exit `77` is not a pass.

## Conventions

- Branch names use `vgs-<n>-<slug>` to attach pull requests to Linear issues.
- Releases use `.agents/skills/vgs-release/SKILL.md`.
- The session handoff is `docs/handoff/HANDOFF.md`, untracked and overwritten in place. Read or write it only on request.
- Portable defaults belong in VGS; `~/dotfiles` holds personal wiring and overlays.
- Rollback means reinstalling another shell. VGS keeps no disabled rollback service.

## Do not

- Do not restart `vshell.service` unless asked.
- Do not suspend the machine or destructively test network joins or device pairing and removal.
- Do not depend on legacy upstream runtime services or external theme engines. Keep upstream names only for attribution and licence lineage.

## Read next

- [docs/architecture/overview.md](docs/architecture/overview.md): subsystem boundaries and the topic index.
- [docs/decisions/INDEX.md](docs/decisions/INDEX.md): before changing a recorded architecture choice.
- The nested `AGENTS.md` beside the files you change: local conventions and subsystem pointers.
- [review-bots.md](review-bots.md): repository policy for pull-request reviewers.
- `kendex.settings.toml`: configured tool policy and its rationale. `AGENTS.local.md`, when present, holds machine-local wiring.
