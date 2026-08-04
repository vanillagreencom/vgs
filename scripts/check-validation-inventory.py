#!/usr/bin/env python3
"""Keep AGENTS.md § Validation, CI and scripts/ from drifting apart.

Two failure shapes, both of which had already happened when this was written:

1. **A check nobody runs.** Four executable checks under `scripts/` were
   committed, maintained, and referenced by nothing — not the documented suite,
   not the CI workflow, not another script (VGS-50). A dead check is worse than
   no check: it implies coverage. Nothing detected them for however long they
   sat there, which is the same reason this file exists rather than a note in a
   review checklist.

2. **A documented command that cannot run.** § Validation lists bare
   invocations; a script without the executable bit fails with "permission
   denied", which reads like a broken check rather than a mode problem
   (VGS-30).

So: every executable check under `scripts/` must be invoked by § Validation and
by the CI workflow, or carry a written exclusion here; and every command in
§ Validation must be runnable exactly as written.
"""

from __future__ import annotations

import os
import re
import shlex
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
AGENTS = REPO_ROOT / "AGENTS.md"
CI = REPO_ROOT / ".github" / "workflows" / "ci.yml"
SCRIPTS = REPO_ROOT / "scripts"

# Executable files under scripts/ that are NOT part of the validation suite.
# Each needs a reason: an unexplained entry here is how an orphan comes back.
NOT_A_SUITE_CHECK = {
    "build-release.sh": "release tooling, driven by .github/workflows/release.yml",
    "check-release.sh": "release preflight, driven by the release path and packaging/README.md",
    "check-vshell-niri.py": "the Niri half of the helper suite; invoked by scripts/check-vshell-helper.py",
}

# Checks the suite runs but CI cannot, with the reason CI cannot run them.
# AGENTS.md § What CI covers documents these at length; this is the machine-
# readable half, so the two cannot disagree silently.
LOCAL_ONLY = {
    "smoke-surfaces.sh": "needs a live Hyprland VGS session and reads `hyprctl layers`",
    "check-label-taxonomy.py": "reads live Linear label inventory; CI has no Linear credentials and no local cache",
    "check-review-gate-vendor.sh": "compares the tracked engine against the vstack-managed copy under .agents/, which CI does not have",
}

# Checks CI runs through another entry rather than by name. Naming the caller
# keeps "CI does not mention it" from reading as "CI does not run it".
INDIRECT_IN_CI = {
    "qml-smoke.sh": "scripts/check-validation-safety.sh",
}

# Interpreter invocations that syntax-CHECK a file rather than run it. These are
# not a mode problem: `node --check`, `bash -n` and `python3 -m py_compile` have
# no bare equivalent, so the prefix is the command, not a workaround for a
# missing executable bit.
SYNTAX_CHECK_FLAGS = {"--check", "-n", "py_compile"}


def validation_commands() -> list[str]:
    """The command lines inside AGENTS.md § Validation's bash fence."""
    text = AGENTS.read_text(encoding="utf-8")
    match = re.search(r"^## Validation$(.*?)^#{2,3} ", text, re.MULTILINE | re.DOTALL)
    if not match:
        raise SystemExit("check-validation-inventory: AGENTS.md has no '## Validation' section")
    fence = re.search(r"```bash\n(.*?)```", match.group(1), re.DOTALL)
    if not fence:
        raise SystemExit("check-validation-inventory: AGENTS.md § Validation has no ```bash block")
    return [line for line in fence.group(1).splitlines() if line.strip()]


def executable_checks() -> list[str]:
    """Executable files directly under scripts/ (scripts/lib/ is libraries)."""
    return sorted(
        path.name
        for path in SCRIPTS.iterdir()
        if path.is_file() and os.access(path, os.X_OK)
    )


def main() -> int:
    problems: list[str] = []
    commands = validation_commands()
    documented = "\n".join(commands)
    ci_text = CI.read_text(encoding="utf-8")

    # --- every documented command runs exactly as written ---------------------
    for line in commands:
        # Subshells and `python3 -m ...` are not a script invocation to mode-check.
        stripped = line.strip()
        if stripped.startswith("("):
            continue
        try:
            argv = shlex.split(stripped)
        except ValueError:
            problems.append(f"§ Validation line is not parseable as a command: {stripped}")
            continue
        if not argv:
            continue
        head = argv[0]
        # A documented interpreter prefix is the defect VGS-30 named: the file
        # should carry its own executable bit and be invoked bare.
        if head in {"node", "bash", "sh", "python3"} and len(argv) > 1:
            if SYNTAX_CHECK_FLAGS.intersection(argv[1:]):
                continue
            target = next((a for a in argv[1:] if not a.startswith("-")), None)
            if target and (REPO_ROOT / target).is_file():
                problems.append(
                    f"§ Validation runs `{stripped}` through `{head}`. "
                    f"Give {target} the executable bit and document it bare, "
                    f"or the doc and the file disagree about how it runs."
                )
            continue
        if "/" not in head:
            continue  # git, and anything else resolved from PATH
        path = REPO_ROOT / head
        if not path.is_file():
            problems.append(f"§ Validation runs `{head}`, which does not exist")
        elif not os.access(path, os.X_OK):
            problems.append(
                f"§ Validation runs `{head}` bare, but it is not executable "
                f"(git update-index --chmod=+x {head})"
            )

    # --- every executable check is invoked, or excluded with a reason ---------
    for name in executable_checks():
        if name in NOT_A_SUITE_CHECK:
            continue
        rel = f"scripts/{name}"
        if rel not in documented:
            problems.append(
                f"{rel} is executable but AGENTS.md § Validation never runs it. "
                f"Wire it into the suite, or add it to NOT_A_SUITE_CHECK with a reason, "
                f"or delete it — a check nothing runs implies coverage that does not exist."
            )
            continue
        if name in LOCAL_ONLY:
            if rel in ci_text:
                problems.append(
                    f"{rel} is recorded as local-only ({LOCAL_ONLY[name]}) but ci.yml runs it anyway"
                )
            continue
        if name in INDIRECT_IN_CI:
            caller = INDIRECT_IN_CI[name]
            if caller not in ci_text:
                problems.append(
                    f"{rel} is recorded as reached through {caller}, but ci.yml does not run {caller}"
                )
            continue
        if rel not in ci_text:
            problems.append(
                f"{rel} is in AGENTS.md § Validation but not in .github/workflows/ci.yml. "
                f"Add it to the workflow, record it in LOCAL_ONLY with the reason CI cannot run it, "
                f"or in INDIRECT_IN_CI naming the entry that reaches it."
            )

    # --- exclusions that no longer name a real file --------------------------
    for name in sorted(set(NOT_A_SUITE_CHECK) | set(LOCAL_ONLY) | set(INDIRECT_IN_CI)):
        if not (SCRIPTS / name).is_file():
            problems.append(f"scripts/{name} is excluded here but no longer exists; drop the entry")

    if problems:
        print("check-validation-inventory: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(
        f"check-validation-inventory: ok ({len(executable_checks())} executable checks, "
        f"{len(commands)} documented commands)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
