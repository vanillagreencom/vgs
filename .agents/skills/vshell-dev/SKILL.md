---
name: vshell-dev
description: >
  Work on VanillaGreen Shell (VGS / vshell), a Hyprland and Niri Quickshell 0.3.0 runtime.
  Use for shell modules, services, bundled plugins, theme engine targets, wallpaper/palette
  flows, IPC, settings UI, or removing stale legacy upstream assumptions.
compatibility: Designed for Claude Code, Pi, Codex, and similar agents
metadata:
  author: VanillaGreen
  version: "1.1"
  domain: qml-desktop-development
  framework: Quickshell
  languages: qml, javascript, python, bash
allowed-tools: Bash Read Write Edit
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# VGS development

## Always know

Naming, the conventions and the hard prohibitions are canonical in `AGENTS.md` (§ Conventions, § Do not) — this skill assumes them rather than restating them. Each tree carries its own local rules in its own `AGENTS.md`, loaded when you work there.

## Where to read before changing something

`docs/architecture/overview.md` names the one idea, the layer boundaries and the repository-wide invariants, and indexes one topic file per subsystem with the trigger for reading it. Go there first; do not read a topic file speculatively.

## Docs source

Use the CTX7 CLI for Quickshell API questions rather than guessing:

| Topic | ctx7 ID | Notes |
|-------|---------|-------|
| Quickshell 0.3.0 | `/websites/quickshell_v0_3_0` | `Process`, `Quickshell`, IPC, QML services, singleton behaviour |

## Validation

The suite is `scripts/validate [AREA]`, <!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas --> — run the area for what you touched. Keep the markers: the inventory guard reads between them, and the contract is `scripts/AGENTS.md`. No command list is restated here, because a partial copy reads as complete.

Its exit status is four-valued: `0` ran and passed, `77` passed but something did not run — report it as passed with each skip named, never as a bare pass — `1` failed, `2` a broken invocation that ran nothing.

**A green continuous-integration run does not prove the shell starts**, because only the static half of the QML smoke runs there. Run `scripts/validate qml` locally before finishing QML work: that area forces the nested mode, so a sandbox it cannot build fails instead of quietly downgrading to a parse check.

For theme changes, which the areas above do not cover end to end (see § Always know for where the rules live):

```bash
vshell theme list --json
vshell theme apply tokyo-night --json
```

## Red flags

- A `vgs` command in a VGS runtime path.
- A personal command required for a default widget to start.
- A bare `vshell` command inside QML instead of `Paths.vshellCli`.
- A virtual-filesystem URL used as a process command.
- QML parsing a TOML or JSON format the helper owns, or rendering a template.
- A generated theme target writing to a legacy upstream path.
