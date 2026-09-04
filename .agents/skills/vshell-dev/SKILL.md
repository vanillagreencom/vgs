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

Read the root `AGENTS.md` for validation and live-session safety. Read `docs/architecture/overview.md` to select the subsystem topic, then the nested `AGENTS.md` beside the changed files.

For Quickshell API questions, use the CTX7 source `/websites/quickshell_v0_3_0`.

Theme validation beyond the scoped suite uses `vshell theme list --json` and a theme apply in an isolated test configuration.
