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
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from validation_manifest import (  # noqa: E402
    ManifestError,
    ci_run_commands,
    documented_table,
    manifest_rows,
    prose_areas,
    grammar,
    token_participates,
    runner_usage_arguments,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
AGENTS = REPO_ROOT / "AGENTS.md"
SKILL_DOC = REPO_ROOT / "project-skills" / "skills" / "vshell-dev" / "SKILL.md"
RUNNER = REPO_ROOT / "scripts" / "validate"
TABLES_DOC = REPO_ROOT / ".github" / "instructions" / "validation-scripts.instructions.md"
CI = REPO_ROOT / ".github" / "workflows" / "ci.yml"
SCRIPTS = REPO_ROOT / "scripts"

# Executable files under scripts/ that are NOT part of the validation suite.
# Each needs a reason: an unexplained entry here is how an orphan comes back.
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
# validation-scripts.instructions.md § "What CI covers, and what it cannot"
# documents these at length; this is the machine-readable half, so the two
# cannot disagree silently.
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


def report(problems: list[str], documented_count: int) -> int:
    """Print every problem found and return the exit status.

    TOTAL BY CONSTRUCTION: it takes the count rather than re-deriving it. The
    success line used to call manifest_rows a second time, which re-ran
    `bash -n` over all 58 commands on every clean run — the expensive half of
    the parse, repeated for a number main() already had — and left a reporting
    function able to fail on a manifest that changed between the two parses.
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

    # --- the GRAMMAR itself, before anything that is built from it ----------
    # ASKED OF THE RUNNER, not parsed here. scripts/lib/validation-grammar.conf
    # has exactly one parser — scripts/validate — and this reads
    # `scripts/validate --dump-grammar`. Two readers of one definition is the
    # same bug as two definitions, one level up, and it produced three
    # divergences before the second parser was deleted.
    #
    # Checked first because everything below is derived from it: a bad grammar
    # makes correctly-written rows fail, and the manifest arm would answer
    # first, blaming the rows.
    #
    # NOTHING BUT A DIAGNOSTIC CROSSES THIS BOUNDARY, and on a grammar the
    # runner refuses that diagnostic is the RUNNER'S OWN, relayed verbatim —
    # never a traceback, never a silent skip.
    try:
        rules = grammar(RUNNER)
    except ManifestError as error:
        return report([str(error)], 0)
    except Exception as error:  # noqa: BLE001 - a reader defect must still read as one
        return report(
            [f"the grammar could not be read: {type(error).__name__}: {error}"], 0
        )

    # The runner must actually OFFER what the grammar declares. Asked by running
    # `scripts/validate -h`, not by matching an array that no longer exists:
    # the runner derives its arguments now, so the question is whether that
    # derivation still agrees with the definition.
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

    # AN UNPARSEABLE MANIFEST IS A PROBLEM TOO, not an abort that discards what
    # the declaration arms already found. A bad name in AREAS makes every row
    # with the CORRECT spelling fail the tag grammar, so raising here reported
    # the rows and swallowed the declaration finding that explains them — the
    # same "answers something other than what it claims" shape as the PyYAML
    # prerequisite, one level over.
    rows: list[tuple[str, str]] | None = None
    try:
        rows = manifest_rows(RUNNER)
    except ManifestError as error:
        problems.append(str(error))
    commands = [command for _, command in rows] if rows is not None else []
    documented = "\n".join(commands)

    # A declared token the runner never acts on is worse than an unknown one:
    # rows carrying it pass every check here and then behave like `-`.
    #
    # ASKED BEHAVIOURALLY, not by matching text. Whole-token matching closed the
    # SUBSTRING hole (`skip` inside `may-skip`) but not the INCIDENTAL one:
    # `status` and `run` match the runner's own variables exactly, so either
    # could be declared a modifier and pass while the tag did nothing. Tag names
    # and identifiers come from the same small pool of words, so that collision
    # recurs. The question the grammar already asks — does this token change
    # what a row SELECTS or how it EXITS — is the one worth answering.
    # A PROBE THAT CANNOT RUN IS A PROBLEM TOO, collected like every other arm's.
    # Unwrapped, the first raise from the probe machinery reached __main__ and
    # discarded everything collected — including the manifest_rows finding above,
    # which usually explains it. Caught per tag, so a tag-specific failure keeps
    # its tag and a shared cause reports once per tag.
    #
    # ALL THREE TYPES THE PROBE PATH PRODUCES, not only the library's own. That
    # path writes files, chmods them and executes the result while capturing in
    # text mode, so it raises OSError (an occupied workdir, an unlaunchable
    # probe) and UnicodeDecodeError (a probe whose output is not UTF-8) beside
    # ManifestError — both verified reachable. Naming only ManifestError left the
    # identical abort through the other two, which is this defect's second door.
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
        # Deliberately ignores `always` rows. Counting them would make this arm
        # dead the moment one exists — every area would look populated — and an
        # area whose only members are the checks EVERY area runs is not an area,
        # it is a name that selects nothing of its own.
        if not any(area in tags.split(",") for tags, _ in rows):
            problems.append(
                f"scripts/validate accepts area `{area}` but no manifest row is tagged "
                f"with it, so `scripts/validate {area}` would run only the `always` rows"
            )

    # A PREREQUISITE IS A PROBLEM, NOT AN ABORT. This raised straight out of
    # main, so on a python3 without PyYAML every OTHER arm — area, prose,
    # tag-wiring, tables — was replaced by the prerequisite message, and the
    # harness that drives fixtures through this function reported ten failures
    # that were not its fixtures' verdicts, including a false claim that the
    # real tree does not pass. Collected here instead: the CI comparison is
    # genuinely impossible, so it FAILS loudly, and every arm that does not
    # need ci_text still reports its own answer.
    ci_text: str | None = None
    try:
        ci_text = ci_run_commands(CI)
    except ManifestError as error:
        problems.append(f"CI coverage was NOT checked: {error}")

    # A per-tag vocabulary loop used to live here. It is gone, not relaxed:
    # manifest_rows now validates the whole tag field against the same grammar
    # scripts/validate applies, and raises before returning a row, so this loop
    # could never have fired. An unreachable check is coverage that does not
    # exist — the thing this file exists to report.
    # --- the prose copies of the area list must match the grammar -----------
    # Both docs enumerate the areas: a second copy of something the runner
    # defines, i.e. the drift axis this check exists to close. So: compared.
    for doc in AREA_ENUMERATING_DOCS:
        # A fixture copy lives outside the tree (test-validation-inventory.sh
        # patches these paths), so name it rather than failing to relativise it.
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
    # The CI half of this arm needs ci_text; without it the manifest half still
    # runs, and the missing comparison is already recorded above.
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
            if ci_text is not None and rel in ci_text:
                problems.append(
                    f"{rel} is recorded as local-only ({LOCAL_ONLY[name]}) but ci.yml runs it anyway"
                )
            continue
        if name in INDIRECT_IN_CI:
            caller = INDIRECT_IN_CI[name]
            if ci_text is not None and caller not in ci_text:
                problems.append(
                    f"{rel} is recorded as reached through {caller}, but ci.yml does not run {caller}"
                )
            continue
        if ci_text is not None and rel not in ci_text:
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

    return report(problems, len(commands))


if __name__ == "__main__":
    # The library raises ManifestError carrying only the parse problem; the name
    # of the failing check belongs to the check, not to a module that may one
    # day have two consumers.
    try:
        sys.exit(main())
    except ManifestError as error:
        print(f"check-validation-inventory: {error}", file=sys.stderr)
        sys.exit(1)
