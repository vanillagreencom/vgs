#!/usr/bin/env python3
"""Compare the validation manifest with executable scripts, CI and area lists.

Executable checks must appear in the manifest and CI, or have an exclusion
with a reason. Documented commands must be executable as written.
The runner owns the manifest; this file owns CI exceptions.
"""

from __future__ import annotations

import os
import shlex
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from validation_manifest import (  # noqa: E402
    ManifestError,
    ci_run_commands,
    ci_runs,
    manifest_rows,
    prose_areas,
    grammar,
    token_participates,
    runner_usage_arguments,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
AGENTS = REPO_ROOT / "AGENTS.md"
RUNNER = REPO_ROOT / "scripts" / "validate"
CI = REPO_ROOT / ".github" / "workflows" / "ci.yml"
SCRIPTS = REPO_ROOT / "scripts"

# Executable scripts outside the suite need a reason for exclusion.
NOT_A_SUITE_CHECK = {
    "validate": "the suite runner itself: it invokes the checks below rather than being one",
    "build-release.sh": "release tooling, driven by .github/workflows/release.yml",
    "build-assets.sh": "release tooling: builds the extras bundle, driven by .github/workflows/release.yml",
    "check-release.sh": "release preflight, driven by the release path and packaging/README.md",
    "check-vshell-niri.py": "the Niri half of the helper suite; invoked by scripts/check-vshell-helper.py",
    "publish-aur.sh": "release tooling: pushes packaging/arch to the AUR, driven by the release path",
    "publish-gentoo.sh": "release tooling: pushes packaging/gentoo to the overlay, driven by the release path",
    "gen-theme-catalog.py": "theme-catalog generator; its --check mode is invoked by scripts/check-package-assets.sh and its --check-release-pin by scripts/check-release.sh",
}

# Checks the suite runs but CI cannot, with the reason CI cannot run them.
LOCAL_ONLY = {
    "smoke-surfaces.sh": "needs a live Hyprland VGS session and reads `hyprctl layers`",
    "check-label-taxonomy.py": "reads live Linear label inventory; CI has no Linear credentials and no local cache",
}

# Checks CI runs through another entry rather than by name. Naming the caller
# keeps "CI does not mention it" from reading as "CI does not run it".
INDIRECT_IN_CI = {
    "qml-smoke.sh": "scripts/check-validation-safety.sh",
}

# Documents required to enumerate the runner areas.
AREA_ENUMERATING_DOCS = (AGENTS,)

# Syntax checks require their interpreter prefix.
SYNTAX_CHECK_FLAGS = {"--check", "-n", "py_compile"}


def executable_checks() -> list[str]:
    """Executable files directly under scripts/ (scripts/lib/ is libraries)."""
    return sorted(
        path.name
        for path in SCRIPTS.iterdir()
        if path.is_file() and os.access(path, os.X_OK)
    )


def report(problems: list[str], documented_count: int) -> int:
    """Print collected problems and return an exit status.

    Use the supplied manifest count so reporting does not parse the manifest again.
    """
    if problems:
        print("check-validation-inventory: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(
        f"check-validation-inventory: ok ({len(executable_checks())} executable checks, "
        f"{documented_count} documented commands)"
    )
    return 0


def main() -> int:
    problems: list[str] = []

    if not RUNNER.is_file():
        raise SystemExit("check-validation-inventory: scripts/validate does not exist")
    if not os.access(RUNNER, os.X_OK):
        raise SystemExit(
            "check-validation-inventory: scripts/validate is not executable, but every "
            "documented invocation runs it bare "
            "(git update-index --chmod=+x scripts/validate)"
        )

    # Read grammar through the runner, which owns its parser. Check it before
    # derived rows so a grammar failure reports its cause.
    try:
        rules = grammar(RUNNER)
    except ManifestError as error:
        return report([str(error)], 0)
    except Exception as error:  # noqa: BLE001 - a reader defect must still read as one
        return report(
            [f"the grammar could not be read: {type(error).__name__}: {error}"], 0
        )

    # Compare declared arguments with the help output users receive.
    try:
        offered = runner_usage_arguments(RUNNER)
    except ManifestError as error:
        offered = None
        problems.append(str(error))
    if offered is not None and offered != rules.arguments:
        problems.append(
            f"scripts/validate offers areas {sorted(offered)} but the grammar declares "
            f"{sorted(rules.arguments)} — the runner's derivation and the definition "
            f"have drifted"
        )

    # Keep declaration findings when manifest parsing also fails.
    rows: list[tuple[str, str]] | None = None
    try:
        rows = manifest_rows(RUNNER)
    except ManifestError as error:
        problems.append(str(error))
    commands = [command for _, command in rows] if rows is not None else []
    documented = "\n".join(commands)

    # Probe whether each tag changes row selection or exit handling. Source-text
    # matches cannot distinguish a tag from an incidental runner variable.
    # Collect parser, filesystem and decoding failures without losing other findings.
    with tempfile.TemporaryDirectory() as workdir:
        for tag in sorted(rules.row_tags - rules.areas):
            try:
                participates, why = token_participates(
                    RUNNER, rules, tag, Path(workdir)
                )
            except (ManifestError, OSError, UnicodeDecodeError) as error:
                problems.append(
                    f"whether scripts/validate acts on token `{tag}` was NOT "
                    f"determined: {error}"
                )
                continue
            if not participates:
                problems.append(
                    f"the grammar declares token `{tag}` but scripts/validate does not "
                    f"act on it: {why}. Wire it into the selection or run loop, or drop "
                    f"it from the grammar."
                )

    if rows is None:
        problems.append(
            "the per-area and CI-coverage arms did NOT run: they need the manifest "
            "rows, and the manifest could not be parsed (above)"
        )
    for area in sorted(rules.areas) if rows is not None else []:
        # Always-run rows do not prove that an area selects any checks of its own.
        if not any(area in tags.split(",") for tags, _ in rows):
            problems.append(
                f"scripts/validate accepts area `{area}` but no manifest row is tagged "
                f"with it, so `scripts/validate {area}` would run only the `always` rows"
            )

    # A missing CI parser prevents CI comparison; independent checks can still run.
    ci_text: str | None = None
    try:
        ci_text = ci_run_commands(CI)
    except ManifestError as error:
        problems.append(f"CI coverage was NOT checked: {error}")

    for doc in AREA_ENUMERATING_DOCS:
        # Fixture copies can live outside the repository.
        rel = doc.name
        if doc.is_relative_to(REPO_ROOT):
            rel = doc.relative_to(REPO_ROOT).as_posix()
        try:
            stated = prose_areas(doc, rules)
        except ManifestError as exc:
            problems.append(str(exc))
            continue
        for name in sorted(rules.arguments - stated):
            problems.append(
                f"{rel} enumerates the validate areas but omits `{name}`, which "
                f"scripts/validate accepts"
            )
        for name in sorted(stated - rules.arguments):
            problems.append(
                f"{rel} lists `{name}` as a validate area, but scripts/validate does "
                f"not accept it"
            )

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
        if head in {"node", "bash", "sh", "python3"} and len(argv) > 1:
            if SYNTAX_CHECK_FLAGS.intersection(argv[1:]):
                continue
            # Libraries remain non-executable and run self-tests through their interpreter.
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
            continue
        path = REPO_ROOT / head
        if not path.is_file():
            problems.append(f"scripts/validate runs `{head}`, which does not exist")
        elif not os.access(path, os.X_OK):
            problems.append(
                f"scripts/validate runs `{head}` bare, but it is not executable "
                f"(git update-index --chmod=+x {head})"
            )
        # Rows outside scripts/ need CI comparison by their full command path.
        elif (ci_text is not None and not head.startswith("scripts/")
              and not ci_runs(ci_text, head)):
            problems.append(
                f"scripts/validate runs `{head}`, which .github/workflows/ci.yml does not. "
                f"Add the step, or drop the manifest row — an entry CI never runs "
                f"is coverage that does not exist."
            )

    # Manifest coverage can still be checked when CI text is unavailable.
    for name in executable_checks() if rows is not None else []:
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
            if ci_text is not None and ci_runs(ci_text, rel):
                problems.append(
                    f"{rel} is recorded as local-only ({LOCAL_ONLY[name]}) but ci.yml runs it anyway"
                )
            continue
        if name in INDIRECT_IN_CI:
            caller = INDIRECT_IN_CI[name]
            if ci_text is not None and not ci_runs(ci_text, caller):
                problems.append(
                    f"{rel} is recorded as reached through {caller}, but ci.yml does not run {caller}"
                )
            continue
        if ci_text is not None and not ci_runs(ci_text, rel):
            problems.append(
                f"{rel} is in the scripts/validate manifest but not in "
                f".github/workflows/ci.yml. "
                f"Add it to the workflow, record it in LOCAL_ONLY with the reason CI cannot run it, "
                f"or in INDIRECT_IN_CI naming the entry that reaches it."
            )

    for name in sorted(set(NOT_A_SUITE_CHECK) | set(LOCAL_ONLY) | set(INDIRECT_IN_CI)):
        if not (SCRIPTS / name).is_file():
            problems.append(f"scripts/{name} is excluded here but no longer exists; drop the entry")

    return report(problems, len(commands))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ManifestError as error:
        print(f"check-validation-inventory: {error}", file=sys.stderr)
        sys.exit(1)
