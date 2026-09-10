# D014: A row names what provides its command, and VGS may remove a distribution package to resolve a duplicate

[← Decision Index](INDEX.md)

**Date**: 2026-09-09 **Status**: Active **Research**: — **Refines**: [D011](D011-mise-owns-agent-harnesses.md), [D013](D013-dev-tools-beyond-cli-harnesses.md)

**Context**: [D011](D011-mise-owns-agent-harnesses.md) made mise the owner of harnesses and toolchains, and kept the rule that a stub never replaces a file VGS did not write. That rule protects the owner's install but says nothing about it afterwards, so the Developer tab reported "your own install" for four different situations that need four different answers. Two of them are traps. A mise install that no config declares answers on PATH and is invisible to `mise outdated`, so it never reaches an update count and never moves again; on the machine this landed from, `daytona` had been in that state since it was installed. A command a distribution package owns cannot be installed through mise without leaving two copies on PATH, where the distribution's wins wherever its directory comes first and an update through mise moves a binary nothing runs.

**Decision**: Every catalog row reports one of five origins — `mise`, `untracked`, `system`, `external`, `absent` — and offers the single action that resolves it. `untracked` offers Track updates, which runs `mise use -g` against the package mise already holds. `system` offers Replace with mise, which removes the owning distribution package and then installs through mise. `external` and `absent` offer nothing, because neither is VGS's to change.

Removing a distribution package is therefore a privileged operation VGS performs, under three constraints. It is a separate action the owner asks for, never a step inside an install. It refuses unless a package manager names an owner for the path. It stops without installing when the removal fails, so a machine is never left with neither copy. It runs in a terminal, where the package manager asks for a password itself; VGS neither collects nor holds one.

**Rationale**:

- The stub writer's refusal is the right default and the wrong ending. It correctly declines to shadow a command it did not install, and then leaves the owner with a row that says a problem exists and no way to act on it.
- `untracked` cannot be inferred from the version alone. `mise ls --json` reports the install either way; only the presence of a `source` on one of its rows says a config asked for it, which is what `mise outdated` reads.
- The removal is not new privilege. `vshell app uninstall` already removes a distribution package in a terminal, and `vshell_apps` already owns the per-distribution owner query and remover, so this asks it rather than spelling a second copy.
- Two copies of one command is the failure D011 exists to avoid, arriving by a different route. Leaving it in place would make an update silently move a binary the owner never runs.

**Revisit When**: a distribution ships a catalog tool in a way that co-exists with a user-level install, such as a versioned binary or an alternatives system, so the duplicate is no longer a conflict to resolve; or mise reports declaration without a config file, which would move the `untracked` test off the `source` field.

**Verification**: `test_install_origin_names_what_provides_a_command` and `test_mise_installs_reads_declaration_and_active_version` in `scripts/check-dev-tools.py` cover the classifier and the raw `mise ls --json` parse behind it. `test_row_actions_run_and_refuse` runs both actions against stubbed owner, remover and mise calls, including the refusals and a failed removal, which must stop before the install. Each rule fails when its behaviour is removed: marking every raw install declared, dropping the active-row preference, installing after a failed removal, and dropping the track guard.

**References**: [D011](D011-mise-owns-agent-harnesses.md) (the ownership rule this works within), [D013](D013-dev-tools-beyond-cli-harnesses.md) (the catalog groups these rows draw), PR #260.
