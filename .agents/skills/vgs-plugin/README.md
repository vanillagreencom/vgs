# vgs-plugin

A skill for writing plugins for the v2 shell, for any agent harness kendex links it into.

## Install

`kendex refresh` from a plain terminal in the checkout links it for Claude Code, Codex and Pi. Claude Code reads it through the `.claude/skills/vgs-plugin` symlink into `.agents/skills/vgs-plugin`.

## Features

- A scaffold command that runs the repository's manifest judge, writes a plugin directory from templates and checks it.
- A check command that runs the manifest judge and the boundary check on one plugin.
- Templates for a bar widget, a bar, a panel and a service.
- A reference of every property, token, capability, import and IPC call a plugin may use.

## How it works

- An agent loads the skill, runs `scripts/vgs-plugin new <id> --kinds <kinds>`, and fills the entry points.
- The check calls the repository's own scripts.
- The reference tables are the core's contract.
