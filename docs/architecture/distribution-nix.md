# Nix

Covers: flake.nix, flake.lock, scripts/test-flake.sh

This file holds the Nix flake: what it exposes, how it builds the install tree and how it sets the runtime `PATH`. [distribution.md](distribution.md) holds the licence, the version and the install tree every channel shares.

- `flake.nix` exposes `packages.<system>.default` and `apps.<system>.default` for `x86_64-linux` and `aarch64-linux`. The app runs `vgsh`. Users run `nix run github:vanillagreencom/vgs/v<VERSION>`, or add the package to their configuration. There is no Home Manager module until autostart is settled.
- nixpkgs carries Quickshell 0.3.1 and Hyprland 0.56.2, which meet the runtime floor. `flake.lock` pins the `nixos-unstable` nixpkgs revision the package builds against.
- The package is a `stdenvNoCC` derivation. Its install phase calls `packaging/install-system.sh` once with `PREFIX=$out` and an empty `DESTDIR`, adds the runtime `PATH` line below, then runs `scripts/check-install-tree.sh` on `$out`. A tree that differs from `packaging/install-tree.manifest` fails the build. `$out/bin/vgsh` stays the installer's plain link.
- The runtime `PATH` is Quickshell plus one package per row of `config/requirements.json`: each row's `packages.nix` names a nixpkgs attribute. A required row without one fails evaluation, and an optional row without one stays off the `PATH`. Hyprland is not on it, because the session supplies `hyprctl`.
- Every bash script under `$out/share/vgs/bin` sets that `PATH` itself. A wrapper around the `$out/bin/vgsh` link would not reach them: `vgsh restart` has Hyprland exec the resolved `vgsh` path, and `vgsh-tui launch` hands its own path to a terminal. Neither process inherits the caller's environment, and a single-instance terminal starts from a process that was already running. The build adds one line marked `# vgs-nix-path` after each script's leading comment block, which the usage text is read from. The line prefixes the runtime path as one unit, only when `PATH` does not already hold it. The build fails when `vgsh` or `vgsh-tui` lacks the line.
- The fixup phase rewrites the runtime tree's `#!/usr/bin/env` and `#!/bin/bash` lines to the store's bash, node and python3.
- `scripts/test-flake.sh` runs `nix flake check`, `nix build` and `nix run .# -- --version` in the `nixos/nix` container, on a read-only copy of the tracked and untracked files. For `vgsh` and `vgsh-tui`, it checks that the `PATH` line alone resolves `qs` and every requirement command, does not resolve `hyprctl`, and adds itself once. It also checks that each script is its source plus only that line, placed after the comment block. Its controls cut the requirements from the runtime `PATH`, strip the line from a built `vgsh-tui`, narrow the build's insertion to `vgsh`, and plant a manifest entry the installer never writes. The container's nix store is a named podman or docker volume, so later runs reuse the downloads. No container runtime, no image and no route to `cache.nixos.org` each exit 77.

## Omarchy comparison

- Omarchy ships no Nix package: at `main` `e332dc9` it has no `flake.nix` and no reference to nixpkgs. The VGS flake follows the nixpkgs conventions for a script package instead.
