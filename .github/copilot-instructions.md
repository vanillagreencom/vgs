# Copilot instructions — VGS (VanillaGreen Shell)

Repository-wide guidance for GitHub Copilot, including Copilot code review.
Path-scoped rules live in `.github/instructions/*.instructions.md`; each has an
`applyTo` glob, and a file without one is ignored by code review.

`AGENTS.md` at the repository root is also read by Copilot. It is the source of
truth for how this repo is built and validated — this file does not restate it,
and where the two ever disagree, `AGENTS.md` wins.

## What this project is

A Hyprland/Niri desktop shell: a **Quickshell 0.3.0** QML runtime
(`quickshell/vshell/`), a **Go** backend daemon (`backend/`), and a single-file
**Python** helper CLI (`bin/vshell-helper`) that owns parsing, generation, and
privileged writes. The CLI is named `vshell`, never `vgs` — `vgs` collides with
the LVM command of that name, and `scripts/check-naming.sh` fails the build over
it.

## Reviewing here

Be terse and technical. State the defect, the input that triggers it, and the
consequence. Skip praise, diff restatements, and summaries of what the code
already says. If you cannot verify a finding, say which part you could not
verify rather than dressing it up — a confident wrong finding costs more than a
hedged one.

## Rules that apply everywhere

**Never suggest launching a second shell to test a change.** `qs -c vshell` and
`qs -p quickshell/vshell` each start a full second VGS instance in the live
session, where it fights the session shell for `WlSessionLock` and the
fade-to-lock overlay and strands orphaned full-screen layer surfaces — a
blacked-out desktop recoverable only with `vshell ipc call lock forceReset`.
The sandboxed `scripts/qml-smoke.sh --nested` is the only supported runtime
smoke. Never suggest `pkill quickshell` either: other Quickshell applications on
the seat are legitimate, so signal by pid or process group.

**Vendored trees are byte-exact.** `backend/vendor/**` and
`config/vshell/nvim/colorschemes/**` are carried verbatim from upstream. Read
them and report real defects, but never propose an in-repo patch, refactor, or
style fix — frame any genuine finding as an upstream issue to file, and say so.

**Doc surfaces are distinct and deliberately non-overlapping.** `README.md` and
`quickshell/vshell/README.md` are product/user-facing. `docs/architecture/**`
are agent reference docs. `AGENTS.md` is agent process instruction. Do not ask
for content to be mirrored between them or for changelog entries.

**Secrets live in one place.** `.env.local` is gitignored and holds every
credential; `.env.local.example` carries the key names with empty values;
`vstack.settings.toml` is public by design and committed deliberately. Do not
report values in the committed files as leaked secrets.

**One owner per resource.** Reject a second watcher, poller, or daemon for
something the helper or QML already owns.
