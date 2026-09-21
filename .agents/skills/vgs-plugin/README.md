# vgs-plugin

A skill for writing plugins for the v2 shell. It is owned by this repository and declared `source = "in-place"` in `kendex.toml`, so `kendex refresh` links it into every harness.

## Install

Already installed with the repository. `kendex refresh` from a plain terminal in the checkout links it for Claude Code, Codex and Pi.

## Features

- A scaffold command that writes a plugin directory from templates and checks it.
- A check command that runs the manifest judge and the boundary check on one plugin.
- Templates for a bar widget, a bar, a panel and a service.
- A reference of every property, token, capability and IPC call a plugin may use.

## How it works

- An agent loads the skill, runs `scripts/vgs-plugin new <id> --kinds <kinds>`, and fills the entry points.
- The check reuses the repository's own scripts, so the skill and the validation manifest never disagree.
- The reference tables are the core's contract; a value not listed there does not exist for a plugin.
