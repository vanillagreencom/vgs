# v2

A desktop shell for Hyprland on Quickshell. The core is small and fixed. Everything a user sees or a service does is a plugin, and every plugin carries the check that keeps it fast and stable.

## Install

Not yet. The first release comes with its install command.

## How it works

- The core starts one shell per session, holds the instance lock and opens the Hyprland connection.
- The core loads each plugin from its manifest and gives it the shared theme tokens and the compositor events.
- A plugin draws inside a core-owned window or runs as a service. It never opens its own compositor surface.
- Validation runs the shell in a nested compositor and holds each plugin to its latency and memory budget.

## Settings

Settings live in the plugin that reads them. The core reads none of its own.
