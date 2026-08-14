#!/usr/bin/env python3
"""Keep the scripts/validate manifest, CI and scripts/ from drifting apart.

Two failure shapes, both of which had already happened when this was written:

1. **A check nobody runs.** Four executable checks under `scripts/` were
   committed, maintained, and referenced by nothing — not the documented suite,
   not the CI workflow, not another script (VGS-50). A dead check is worse than
   no check: it implies coverage. Nothing detected them for however long they
   sat there, which is the same reason this file exists rather than a note in a
   review checklist.

2. **A documented command that cannot run.** The manifest lists bare
   invocations; a script without the executable bit fails with "permission
   denied", which reads like a broken check rather than a mode problem
   (VGS-30).

So: every executable check under `scripts/` must be invoked by the manifest and
by the CI workflow, or carry a written exclusion here; and every command in the
manifest must be runnable exactly as written.

The manifest used to be AGENTS.md § Validation and moved into `scripts/validate`
(VGS-123), so this parses the runner rather than the doc. The prose tables it
cross-compares against — local-only and reached-indirectly — moved with it, to
`.github/instructions/ci.instructions.md`.
"""

from __future__ import annotations

import os
import re
import shlex
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:
    print(
        "check-validation-inventory: FAIL: PyYAML is not installed, so ci.yml could not\n"
        "be parsed and CI coverage was NOT checked (pacman -S python-yaml).",
        file=sys.stderr,
    )
    raise SystemExit(1)

REPO_ROOT = Path(__file__).resolve().parents[1]
RUNNER = REPO_ROOT / "scripts" / "validate"
CI_DOC = REPO_ROOT / ".github" / "instructions" / "ci.instructions.md"
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
# .github/instructions/ci.instructions.md § What CI covers documents these at
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

# Interpreter invocations that syntax-CHECK a file rather than run it. These are
# not a mode problem: `node --check`, `bash -n` and `python3 -m py_compile` have
# no bare equivalent, so the prefix is the command, not a workaround for a
# missing executable bit.
SYNTAX_CHECK_FLAGS = {"--check", "-n", "py_compile"}


def manifest_rows() -> list[tuple[str, str]]:
    """`(area tags, command)` pairs from the scripts/validate manifest heredoc.

    Parsed statically rather than by running `scripts/validate --list`: this
    check must report a manifest the runner cannot even parse, and a runner that
    refuses to start would otherwise make this check unable to say why.
    """
    text = RUNNER.read_text(encoding="utf-8")
    block = re.search(r"<<'MANIFEST_EOF'\n(.*?)\nMANIFEST_EOF\n", text, re.DOTALL)
    if not block:
        raise SystemExit(
            "check-validation-inventory: scripts/validate has no MANIFEST_EOF heredoc; "
            "this check parses that block, so moving it silently empties the inventory"
        )
    rows: list[tuple[str, str]] = []
    for line in block.group(1).splitlines():
        if not line.strip():
            continue
        if "|" not in line:
            raise SystemExit(
                f"check-validation-inventory: scripts/validate manifest row has no "
                f"`AREAS | COMMAND` separator: {line!r}"
            )
        tags, command = line.split("|", 1)
        rows.append(("".join(tags.split()), command.strip()))
    if not rows:
        raise SystemExit("check-validation-inventory: scripts/validate manifest is empty")
    return rows


def runner_areas() -> set[str]:
    """The area names scripts/validate accepts, minus the `all` pseudo-area."""
    match = re.search(r"^AREAS=\(([^)]*)\)", RUNNER.read_text(encoding="utf-8"), re.MULTILINE)
    if not match:
        raise SystemExit("check-validation-inventory: scripts/validate has no AREAS=( ... ) list")
    return set(match.group(1).split()) - {"all"}


def ci_run_commands() -> str:
    """Only the shell inside ci.yml's `run:` blocks, never the whole file.

    A raw substring test over ci.yml counts COMMENTS as invocations. ci.yml
    mentions several scripts in comments explaining why a step exists, so
    deleting a check from its `run:` block while leaving the comment above it
    kept this guard green — the exact false green it exists to prevent. It also
    cuts the other way: a comment naming a local-only script would report a
    failure that is not real.

    A YAML parse is the honest form. Anything that is not a `run:` scalar is
    prose about the workflow, not the workflow.
    """
    workflow = yaml.safe_load(CI.read_text(encoding="utf-8"))
    runs: list[str] = []

    def walk(node) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "run" and isinstance(value, str):
                    runs.append(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(workflow)
    if not runs:
        raise SystemExit("check-validation-inventory: ci.yml has no `run:` blocks at all")
    # Strip shell comments too: a `#` line inside a run block is still prose.
    lines = []
    for block in runs:
        for line in block.splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                lines.append(line)
    return "\n".join(lines)


# The prose tables in .github/instructions/ci.instructions.md § What CI covers,
# keyed by the bold lead-in above each. Claiming the doc and the code cannot
# disagree is only true if something compares them; before this, nothing did,
# and the table had drifted (it omitted check-review-gate-vendor.sh and listed
# qml-smoke.sh, which is reached indirectly rather than being local-only).
DOC_TABLES = {
    "LOCAL_ONLY": "**Local-only — CI cannot run these at all:**",
    "INDIRECT_IN_CI": "**Reached indirectly — CI runs these through another entry, not by name:**",
}


def documented_table(lead_in: str) -> set[str]:
    """Script basenames named in the first column of the table after `lead_in`."""
    text = CI_DOC.read_text(encoding="utf-8")
    start = text.find(lead_in)
    if start == -1:
        raise SystemExit(
            f"check-validation-inventory: .github/instructions/ci.instructions.md "
            f"has no table introduced by {lead_in!r}"
        )
    names: set[str] = set()
    seen_rows = False
    for line in text[start + len(lead_in):].splitlines():
        stripped = line.strip()
        if not stripped:
            if seen_rows:
                break
            continue
        if not stripped.startswith("|"):
            break
        cells = stripped.split("|")
        if len(cells) < 2:
            continue
        first = cells[1].strip()
        if set(first) <= {"-", ":", " "}:  # the header underline
            continue
        match = re.search(r"`scripts/([A-Za-z0-9._-]+)`", first)
        if match:
            names.add(match.group(1))
            seen_rows = True
    return names


def executable_checks() -> list[str]:
    """Executable files directly under scripts/ (scripts/lib/ is libraries)."""
    return sorted(
        path.name
        for path in SCRIPTS.iterdir()
        if path.is_file() and os.access(path, os.X_OK)
    )


def main() -> int:
    problems: list[str] = []
    rows = manifest_rows()
    commands = [command for _, command in rows]
    documented = "\n".join(commands)
    ci_text = ci_run_commands()

    # --- every manifest area tag is one the runner accepts --------------------
    # A typo'd tag is invisible otherwise: `scripts/validate <area>` would refuse
    # the unknown name, but the row would silently drop out of every real area
    # while still running under `all`, so the scoped run passes over a check it
    # never executed.
    areas = runner_areas()
    for tags, command in rows:
        if tags == "-":
            continue
        for tag in tags.split(","):
            if tag not in areas:
                problems.append(
                    f"scripts/validate manifest tags `{command}` with area `{tag}`, "
                    f"which is not in the runner's AREAS list ({', '.join(sorted(areas))})"
                )
    for area in sorted(areas):
        if not any(area in tags.split(",") for tags, _ in rows):
            problems.append(
                f"scripts/validate accepts area `{area}` but no manifest row is tagged "
                f"with it, so `scripts/validate {area}` would run nothing"
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
        documented_names = documented_table(lead_in)
        for name in sorted(coded - documented_names):
            problems.append(
                f"scripts/{name} is in {map_name} but not in the "
                f".github/instructions/ci.instructions.md table introduced by {lead_in!r}"
            )
        for name in sorted(documented_names - coded):
            problems.append(
                f"scripts/{name} is in that ci.instructions.md table but not in {map_name}"
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
