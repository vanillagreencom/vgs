# Copilot review context — VGS

Context for GitHub Copilot code review. It is not working instructions for an agent session: the rules live in `AGENTS.md` at the repository root and in the nested `AGENTS.md` beside each tree, both of which Copilot also reads, and where any of them disagrees with this file, they win. Fleet reviewer guidance — review economics, accepted residual classes, do-not-re-raise rules — is in the root `review-bots.md`; read it before reviewing and follow it.

## What this project is

A desktop shell for Hyprland and Niri: a Quickshell 0.3.0 QML runtime under `quickshell/vshell/`, a Go daemon under `backend/`, and a single-file Python helper CLI at `bin/vshell-helper` that owns parsing, generation and privileged writes. The CLI is named `vshell` and never `vgs`, which collides with the LVM command of that name; `scripts/check-naming.sh` fails the build over it.

## Reviewing here

Be terse and technical. State the defect, the input that triggers it, and the consequence. Skip praise, diff restatements and summaries of what the code already says. Where you cannot verify a finding, say which part you could not verify rather than dressing it up — a confident wrong finding costs more than a hedged one.

Never suggest launching a second shell to test a change: `qs -c vshell` and `qs -p quickshell/vshell` each start a full second VGS instance in the live session, and the sandboxed nested smoke is the only supported runtime check. Never suggest killing Quickshell by name either — other Quickshell applications on the seat are legitimate, so signal by process id or process group.

## Scope

**The harness render is out of review scope.** `.agents/**`, `.claude/**`, `.codex/**`, `.opencode/**`, `.cursor/**`, `.pi/**` and `opencode.json` are `kendex refresh` output. Do not review them and do not report findings on them; defects go upstream with `kendex report`, and a local edit is erased by the next render. This is stronger than the vendored-tree rule below, which asks for upstream issues: on the render, do not flag at all. The exception is this repository's own skills, which `kendex.toml` declares `source = "in-place"` and nothing renders over — <!-- in-place-skills -->`.agents/skills/vgs-distro-publish/**`, `.agents/skills/vgs-release/**` and `.agents/skills/vshell-dev/**`<!-- /in-place-skills --> — which are reviewed like any project file.

**Vendored trees are byte-exact, but not uniformly.** Carried verbatim: `backend/vendor/**`, the plugin directories under `config/vshell/nvim/colorschemes/`, `quickshell/vshell/assets/sounds/plasma/`, and the pinned artifacts under `third_party/`. Report a real defect in those as an issue to file upstream, never as an in-repository patch, refactor or style fix. Three files among them are VGS-authored and maintained here, so drift findings on them are wanted: the colourscheme attribution table, and the two `third_party/` readme files.

**Doc surfaces are distinct and deliberately non-overlapping.** The product-facing set is exactly `README.md`, `packaging/README.md` and `packaging/ubuntu/README.md`. `docs/architecture/**` is agent reference documentation and `AGENTS.md` files are agent process instruction; `AGENTS.local.md` is the machine-local companion, untracked by design, so a pull request never contains it. Do not ask for content to be mirrored between them, and do not ask for changelog entries on them.

**Secrets live in one place.** `.env.local` is gitignored and holds every credential; `.env.local.example` carries the key names with empty values; `kendex.settings.toml` is public by design and committed deliberately. Do not report values in the committed files as leaked secrets, and do not ask for those options to be documented in `README.md`.

**Some configuration is generated.** The agent frontmatter and skill tables in `kendex.toml` are rewritten by `kendex refresh` from upstream defaults, so a finding about a value there belongs upstream — an in-repository edit is overwritten on the next render.
