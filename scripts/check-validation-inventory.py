#!/usr/bin/env python3
"""Keep the scripts/validate manifest, CI and scripts/ from drifting apart.

Two failure shapes, both of which had already happened when this was written:

1. **A check nobody runs.** Four executable checks under `scripts/` were
   committed, maintained, and referenced by nothing (VGS-50). A dead check is
   worse than no check: it implies coverage, and nothing detected them.

2. **A documented command that cannot run.** The manifest lists bare
   invocations; a script without the executable bit fails with "permission
   denied", which reads like a broken check rather than a mode problem (VGS-30).

So: every executable check under `scripts/` must be invoked by the manifest and
by the CI workflow, or carry a written exclusion here; and every command in the
manifest must be runnable exactly as written.

The manifest moved out of AGENTS.md § Validation into `scripts/validate`
(VGS-123), so this parses the runner; the tables it cross-compares against moved
with it, to `.github/instructions/validation-scripts.instructions.md`.
"""

from __future__ import annotations

import os
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from validation_manifest import (  # noqa: E402
    ManifestError,
    ci_run_commands,
    documented_table,
    manifest_rows,
    prose_areas,
    runner_areas,
    runner_logic,
    runner_tag_attributes,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
AGENTS = REPO_ROOT / "AGENTS.md"
SKILL_DOC = REPO_ROOT / "project-skills" / "vshell-dev" / "SKILL.md"
RUNNER = REPO_ROOT / "scripts" / "validate"
TABLES_DOC = REPO_ROOT / ".github" / "instructions" / "validation-scripts.instructions.md"
CI = REPO_ROOT / ".github" / "workflows" / "ci.yml"
SCRIPTS = REPO_ROOT / "scripts"

# Executable files under scripts/ that are NOT part of the validation suite.
# Each needs a reason: an unexplained entry here is how an orphan comes back.
NOT_A_SUITE_CHECK = {
    "validate": "the suite runner itself: it invokes the checks below rather than being one",
    "build-release.sh": "release tooling, driven by .github/workflows/release.yml",
    "check-release.sh": "release preflight, driven by the release path and packaging/README.md",
    "check-vshell-niri.py": "the Niri half of the helper suite; invoked by scripts/check-vshell-helper.py",
    "publish-aur.sh": "release tooling: pushes packaging/arch to the AUR, driven by the release path",
    "gen-theme-catalog.py": "theme-catalog generator; its --check mode is invoked by scripts/check-package-assets.sh and its --check-release-pin by scripts/check-release.sh",
}

# Checks the suite runs but CI cannot, with the reason CI cannot run them.
# validation-scripts.instructions.md § What CI covers documents these at
# length; this is the machine-readable half, so the two cannot disagree
# silently.
LOCAL_ONLY = {
    "smoke-surfaces.sh": "needs a live Hyprland VGS session and reads `hyprctl layers`",
    "check-label-taxonomy.py": "reads live Linear label inventory; CI has no Linear credentials and no local cache",
    "check-review-gate-vendor.sh": "compares the tracked engine against the vstack-managed copy under .agents/, which CI does not have",
    "check-size-ratchet-vendor.sh": "compares the tracked size-ratchet engine against the vstack-managed copy under .agents/, which CI does not have",
}

# Checks CI runs through another entry rather than by name. Naming the caller
# keeps "CI does not mention it" from reading as "CI does not run it".
INDIRECT_IN_CI = {
    "qml-smoke.sh": "scripts/check-validation-safety.sh",
}

# Documents that MUST enumerate the validate areas in prose, checked against the
# runner's own AREAS. Membership is the decision: a doc that should point at
# `scripts/validate --list` instead is removed from this tuple in the same edit,
# which is a recorded choice rather than a regex that quietly stopped matching.
AREA_ENUMERATING_DOCS = (AGENTS, TABLES_DOC, SKILL_DOC)

# Interpreter invocations that syntax-CHECK a file rather than run it. These are
# not a mode problem: `node --check`, `bash -n` and `python3 -m py_compile` have
# no bare equivalent, so the prefix is the command, not a workaround for a
# missing executable bit.
SYNTAX_CHECK_FLAGS = {"--check", "-n", "py_compile"}


# The prose tables in validation-scripts.instructions.md § What CI covers, keyed
# by the bold lead-in above each. Claiming the doc and the code cannot
# disagree is only true if something compares them; before this, nothing did,
# and the table had drifted (it omitted check-review-gate-vendor.sh and listed
# qml-smoke.sh, which is reached indirectly rather than being local-only).
DOC_TABLES = {
    "LOCAL_ONLY": "**Local-only — CI cannot run these at all:**",
    "INDIRECT_IN_CI": "**Reached indirectly — CI runs these through another entry, not by name:**",
}


def executable_checks() -> list[str]:
    """Executable files directly under scripts/ (scripts/lib/ is libraries)."""
    return sorted(
        path.name
        for path in SCRIPTS.iterdir()
        if path.is_file() and os.access(path, os.X_OK)
    )


def main() -> int:
    problems: list[str] = []

    # VGS-30 applied to the entry point: everything below asserts the mode of the
    # checks the manifest names, and the file doing the naming was exempt.
    if not RUNNER.is_file():
        raise SystemExit("check-validation-inventory: scripts/validate does not exist")
    if not os.access(RUNNER, os.X_OK):
        raise SystemExit(
            "check-validation-inventory: scripts/validate is not executable, but every "
            "documented invocation runs it bare "
            "(git update-index --chmod=+x scripts/validate)"
        )

    rows = manifest_rows(RUNNER)
    commands = [command for _, command in rows]
    documented = "\n".join(commands)
    ci_text = ci_run_commands(CI)

    # A per-tag vocabulary loop used to live here. It is gone, not relaxed:
    # manifest_rows now validates the whole tag field against the same grammar
    # scripts/validate applies, and raises before returning a row, so this loop
    # could never have fired. An unreachable check is coverage that does not
    # exist — the thing this file exists to report.
    areas = runner_areas(RUNNER)
    attributes = runner_tag_attributes(RUNNER)
    # An attribute the guard accepts but the runner never acts on is worse than
    # an unknown tag: rows carrying it pass here and then behave like `-`. The
    # REMOVAL direction was already fail-closed; this closes ADDITION.
    runner_body = runner_logic(RUNNER)
    for tag in sorted(attributes - {"-"}):
        if tag not in runner_body:
            problems.append(
                f"scripts/validate declares TAG_ATTRIBUTES token `{tag}` but never acts "
                f"on it outside that array, so every row tagged `{tag}` would silently "
                f"behave like `-`. Wire it into the selection or run loop, or drop it."
            )

    for area in sorted(areas):
        # Deliberately ignores `always` rows. Counting them would make this arm
        # dead the moment one exists — every area would look populated — and an
        # area whose only members are the checks EVERY area runs is not an area,
        # it is a name that selects nothing of its own.
        if not any(area in tags.split(",") for tags, _ in rows):
            problems.append(
                f"scripts/validate accepts area `{area}` but no manifest row is tagged "
                f"with it, so `scripts/validate {area}` would run only the `always` rows"
            )

    # --- the prose copies of the area list must match the runner ------------
    # Both docs enumerate the areas: a second copy of something the runner
    # defines, i.e. the drift axis this check exists to close. So: compared.
    for doc in AREA_ENUMERATING_DOCS:
        # A fixture copy lives outside the tree (test-validation-inventory.sh
        # patches these paths), so name it rather than failing to relativise it.
        rel = doc.name
        if doc.is_relative_to(REPO_ROOT):
            rel = doc.relative_to(REPO_ROOT).as_posix()
        try:
            stated = prose_areas(doc)
        except ManifestError as exc:
            problems.append(str(exc))
            continue
        for name in sorted((areas | {"all"}) - stated):
            problems.append(
                f"{rel} enumerates the validate areas but omits `{name}`, which "
                f"scripts/validate accepts"
            )
        for name in sorted(stated - (areas | {"all"})):
            problems.append(
                f"{rel} lists `{name}` as a validate area, but scripts/validate does "
                f"not accept it"
            )

    # --- every documented command runs exactly as written ---------------------
    for line in commands:
        # Subshells and `python3 -m ...` are not a script invocation to mode-check.
        stripped = line.strip()
        if stripped.startswith("("):
            continue
        try:
            argv = shlex.split(stripped)
        except ValueError:
            problems.append(f"scripts/validate manifest line is not parseable as a command: {stripped}")
            continue
        if not argv:
            continue
        head = argv[0]
        # A documented interpreter prefix is the defect VGS-30 named: the file
        # should carry its own executable bit and be invoked bare.
        if head in {"node", "bash", "sh", "python3"} and len(argv) > 1:
            if SYNTAX_CHECK_FLAGS.intersection(argv[1:]):
                continue
            # scripts/lib/ holds LIBRARIES — imported or sourced, never run as
            # a command. The runner's header says they stay non-executable
            # deliberately, so running a library's built-in self-test through
            # its interpreter is the correct form, not the VGS-30 defect of a
            # manifest that omits a prefix the file actually needs.
            if any(a.startswith("scripts/lib/") for a in argv[1:]):
                continue
            target = next((a for a in argv[1:] if not a.startswith("-")), None)
            if target and (REPO_ROOT / target).is_file():
                problems.append(
                    f"scripts/validate runs `{stripped}` through `{head}`. "
                    f"Give {target} the executable bit and list it bare, "
                    f"or the manifest and the file disagree about how it runs."
                )
            continue
        if "/" not in head:
            continue  # git, and anything else resolved from PATH
        path = REPO_ROOT / head
        if not path.is_file():
            problems.append(f"scripts/validate runs `{head}`, which does not exist")
        elif not os.access(path, os.X_OK):
            problems.append(
                f"scripts/validate runs `{head}` bare, but it is not executable "
                f"(git update-index --chmod=+x {head})"
            )

    # --- every executable check is invoked, or excluded with a reason ---------
    for name in executable_checks():
        if name in NOT_A_SUITE_CHECK:
            continue
        rel = f"scripts/{name}"
        if rel not in documented:
            problems.append(
                f"{rel} is executable but the scripts/validate manifest never runs it. "
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
                f"{rel} is in the scripts/validate manifest but not in "
                f".github/workflows/ci.yml. "
                f"Add it to the workflow, record it in LOCAL_ONLY with the reason CI cannot run it, "
                f"or in INDIRECT_IN_CI naming the entry that reaches it."
            )

    # --- the prose tables and the maps above must agree ----------------------
    for map_name, lead_in in DOC_TABLES.items():
        coded = set(globals()[map_name])
        documented_names = documented_table(TABLES_DOC, lead_in)
        for name in sorted(coded - documented_names):
            problems.append(
                f"scripts/{name} is in {map_name} but not in the "
                f"validation-scripts.instructions.md table introduced by {lead_in!r}"
            )
        for name in sorted(documented_names - coded):
            problems.append(
                f"scripts/{name} is in that instruction-file table but not in {map_name}"
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
    # The library raises ManifestError carrying only the parse problem; the name
    # of the failing check belongs to the check, not to a module that may one
    # day have two consumers.
    try:
        sys.exit(main())
    except ManifestError as error:
        print(f"check-validation-inventory: {error}", file=sys.stderr)
        sys.exit(1)
