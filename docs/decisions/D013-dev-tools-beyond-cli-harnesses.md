# D013: One mise catalog carries desktop applications and pinned interpreters

[← Decision Index](INDEX.md)

**Date**: 2026-09-08 **Status**: Active **Research**: —

**Context**: [D011](D011-mise-owns-agent-harnesses.md) put coding-agent harnesses and language toolchains in one mise catalog and rejected distribution packages for them. Two kinds of tool the desktop needs did not fit the shape it defined. Applications people run agents inside — herdr, Orca, T3 Code, cmux, Claude Desktop — are neither a harness nor a toolchain, and reached the user through AUR packages that lag upstream or through nothing at all. Hermes declares `Requires-Python >=3.11,<3.14` and pins every dependency exactly; D011 named that case as its own revisit condition, on the belief that `mise use` could not express the pin.

**Decision**: The same catalog carries them, through four fields rather than a second install route.

- `apps` is a section beside `agents`, with the same launcher, installer and removal behind it. One `launchable()` reads both and stamps the group each entry came from, so only the label differs. `kind: gui` starts an application detached, with no terminal around it.
- `buildEnv` holds variables the install needs and the tool must not inherit. `requires` are mise packages the backend itself needs first. `present` is a path under the install proving the build honoured that environment, and the tool is re-forced when it is gone.
- `arch` lists the architectures an entry publishes for. VGS ships an aarch64 tarball, and an entry that builds only x86_64 must not reach a list there.

The launcher builds its tiles from `vshell agent list` and `vshell dev-env list` rather than reading the catalog, so one place decides what a machine can install.

**Rationale**:

- The pin *is* expressible through `mise use`: `UV_PYTHON` exported for the build, dropped again before the exec so it cannot reach the agent's own subprocesses, and a probe because `mise up` rebuilds without it. D011's revisit condition is therefore not met, and its decision stands.
- An application shares everything with a harness except what it is. A second install route would have duplicated the stub writer's foreign-file rule, its removal path and its update counting, and the two would have drifted.
- AUR packages for these carry D011's own objections. The Orca package on the machine this landed from was a release behind mise, and its Claude Desktop package was 22,000 build numbers behind and built from a repository whose own README says the project moved.

**Revisit When**: a tool VGS should offer publishes no release any mise backend can read — Cursor embeds a per-release commit hash in a download URL only its own JSON API knows, and OpenAI ships its desktop app as a `.deb` and a `.rpm`, which mise does not unpack — or an application needs system integration a `~/.local/bin` stub cannot give it, such as a desktop entry or a file-type association.

**Verification**: `scripts/check-dev-tools.py` derives its expectations from the catalog rather than a second list, and runs under a pinned `x86_64` and a pinned `aarch64` host. Its cases fail when the behaviour is removed: dropping `env -u`, the force probe or the uv requirement each breaks the pin case; ignoring `apps` in `launchable()` breaks the launch; removing the architecture filter offers an x86-only entry on ARM. The Hermes stub was run against an empty mise data directory and the result reports Python 3.13.15.

**References**: [D011](D011-mise-owns-agent-harnesses.md) (the decision this works within), PR #253, PR #254.
