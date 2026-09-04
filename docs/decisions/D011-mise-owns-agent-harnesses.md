# D011: mise owns coding-agent harnesses and language toolchains; the distribution owns the system

[← Decision Index](INDEX.md)

**Date**: 2026-09-01 **Status**: Active **Research**: VGS-238

**Context**: Coding-agent CLIs (Claude Code, Codex, OpenCode, DeepSeek Harness, T3 Code, ...) release weekly or faster. AUR repackagings lag and need a maintainer per tool; a distro package needs sudo for a user-level program. Language toolchains have the same shape. Omarchy solved both with mise stubs in `~/.local/bin` and a separate `mise up` step in its update pipeline.

**Decision**: Harnesses and toolchains are user-level mise installs driven by one catalog (`config/vshell/dev-tools.json`). Stubs install lazily on first run. `vshell update run tools` is a separate step after system, AUR and Flatpak, and the bar widget counts it alongside them. VGS ships no version pins: every tool is `latest`, with mise's release-age cooldown disabled.

Two departures from omarchy: the catalog is one file rather than a list repeated across scripts, and a stub never replaces a file VGS did not write (the owner's own wrapper wins and is reported as foreign).

Also decided here: `vshell update run` is the only implementation of "how to upgrade". The Go `sysupdate` service used to assemble its own pacman/paru command that no UI called; it now supervises the CLI in a terminal and re-counts when it exits, and the widget uses that path whenever its button is on the default command.

**Alternatives rejected**:

- AUR packages for agents: sudo for user programs, one maintainer per tool, and the lag this decision exists to remove.
- Pinning versions in the catalog: VGS would become the thing that lags.
- Keeping the Go upgrade command: two spellings of the same sequence, one of them dead.

**Revisit when**: a harness needs an interpreter pin mise cannot express through `mise use` (omarchy's Hermes case), or a distribution VGS packages for ships no mise and the feature has to degrade to something else.
