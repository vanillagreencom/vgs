# v2

This is Kendex's first extensive Copilot consumer workload; report package or workflow failures with `kendex report`, using temporary consumer-side workarounds without editing Kendex-owned files.

A desktop shell for Hyprland, built on Quickshell 0.3.1. A small fixed core starts the shell, talks to Hyprland, hosts surfaces and loads plugins. Everything outside the core is a plugin: one directory with a `manifest.json`, shown on the surfaces the core hosts, landed with the validation row that proves it is built and handed what it asked for. `docs/architecture/overview.md` holds the idea, the vocabulary and the invariants.

## Commands

- `scripts/validate [AREA]`: run only checks affected by changes from the default branch's merge base, including uncommitted files. `--changed BASE` selects a fix round; `--list` previews commands; `--full` opts into the whole area. `unit` needs Qt and no Wayland session; `package` needs rootless podman and the Arch mirrors; `qml` needs the nested sandbox. Exit 77 means a check could not run and is not a pass.
- `scripts/qml-smoke.sh`: the nested sandbox row alone. It needs `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` in the environment.
- `bin/vgsh`: the runner (`run`, `restart`), the plugin manager and the theme commands (`theme list`, `theme apply <name>`, `theme reload`, `theme background next`, `theme add <git url>`, `theme update <name>`, `theme remove <name>`; `theme apply vgs` restores the defaults). Run it with no arguments for the command list.

## Conventions

- Work targets `main`. `v1` is an archived reference, not a development target.
- No branch protection, CI workflows, merge queue, required review or commit/push gates. PRs are optional and may merge immediately; direct pushes are welcome. Do not arm Kendex guards or wait for absent CI.
- Validate the final relevant diff once. After fixes, use `--changed <last-validated-commit>` and reuse results for unchanged inputs; do not repeat a full suite at commit, push or PR submission. Unknown source inputs select the full area rather than silently skipping coverage. Shared workflow gate requirements do not apply here.

- Hyprland is the only compositor. No compositor abstraction and no second compositor: `docs/decisions/D001-hyprland-only.md`.
- Never start a second shell against the live session and never kill Quickshell processes by name. Validation runs in the nested sandbox only.
- A change that adds a surface, a service or a plugin adds its validation row under `scripts/smoke/rows/` in the same PR.
- No manual commands: a user-facing setup step is automatic or one click, a step that asks or elevates runs in a floating TUI or the requirement notice that button starts, a secret goes into a masked field VGS stores in libsecret, and a command shows only behind "Show command". `scripts/check-user-commands.py` enforces the text: `docs/decisions/D058-no-manual-commands.md`.
- Before writing or changing code, load the code-quality skill. Before writing a plugin, load the vgs-plugin skill.
- Before designing a plugin, a theme target or any system integration, check how the latest Omarchy (`basecamp/omarchy`, its default branch) solves the same problem. Take its approach where it is simpler or more robust; where VGS differs, say why in the issue or decision record.

## Read next

- `docs/architecture/overview.md`: before structural work.
- `docs/architecture/plugins.md` and `docs/architecture/plugin-manifest.md`: before writing a plugin or a host.
- `docs/architecture/surfaces.md`: before choosing between an application window and an overlay, or touching the summon host.
- `docs/architecture/manager.md`: before touching enablement, install, update, remove or the manager's panel.
- `docs/architecture/configuration.md`: before touching the configuration files or their judge.
- `docs/architecture/design-system.md`: before touching a token, the theme judge, `Theme`, a component of `qs.Ui`, or any value a surface draws with.
- `docs/architecture/components.md`: before adding or changing a component of `qs.Ui`.
- `docs/architecture/runtime.md`: before touching anything that starts, stops, measures or talks to the shell, and for every Quickshell fact the code rests on.
- `docs/architecture/runtime-hyprland.md`: before touching a dispatch, `Compositor` or `Dispatch.js`, for every Hyprland fact the code rests on.
- `docs/architecture/validation.md`: before touching `scripts/validate` or one of its rows.
- `docs/architecture/validation-smoke.md`: before touching the nested sandbox, its harness or a smoke row's verdict.
- `docs/architecture/validation-smoke-faults.md`: before touching a sandbox fault the smoke excuses, a mode a row holds on the nested output, or the smoke's closing verdict.
- `docs/architecture/validation-latency.md`: before touching a latency the smoke reads or its budget.
- `docs/architecture/runtime-qml.md`: before writing QML, for every Quickshell and Qt fact the QML rests on.
- `docs/architecture/runtime-pointer.md`: before touching a pointer handler, a cursor, a hover reading or a popup, for the Qt and Wayland facts they rest on.
- `shell/AGENTS.md`, `shell/plugins/AGENTS.md`, `scripts/AGENTS.md`: when working under that directory. Claude Code loads each through the `CLAUDE.md` shim beside it. Pi and Codex load only the root-to-cwd chain at launch, so an agent on those harnesses reads the nested file before working under the directory.

## Code Review Rules

<!-- generated by bot-instructions 2.3.0 from kendex.toml, .kendex-generated.json, SKILL.md, schemas/renders.md, AGENTS.md. Edit [bot-instructions] in the effective manifest or the spec copy, then re-render. -->

If you are a review agent reviewing code, read .github/instructions/code-review.md before you comment.
