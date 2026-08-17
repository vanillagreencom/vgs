#!/usr/bin/env python3
"""End-to-end controls: scripts/check-section-pointers.py run as a PROGRAM.

Its sibling `scripts/test-section-pointers.py` drives each arm as a function.
That leaves the wiring between them — `audit`, `main`, and the four
`problems.extend` calls that assemble a verdict — guarded by nothing, and eight
mutants of exactly that shape survived with both the suite and the guard green.
The worst was `if problems:` -> `if False:`, which makes the CI step permanently
green while the suite still prints "all reporting". Only a real exit status can
see that one, so this file builds throwaway git repos and runs the guard against
them.

The mutation set is recorded in `scripts/test-section-pointers.py`; run all
four scripts against each, or a mutant survives in the one nobody drove.

Split from the unit controls because it is a different kind of test, not a
longer one: it writes trees, creates symlinks, runs `git init`, and reads
process statuses. Same peer-script shape as the three `test-vendor-drift-*.sh`.

ONE TREE PER ARM the guard assembles, each isolating that arm, because a dropped
`problems.extend` is invisible when some other arm reports anyway. And two trees
for the rule underneath them all — that the guard judges TRACKED BLOBS, never
the working tree — one via a symlink pointing out of the repo, one via a file
that is clean in the index and dead on disk.
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from section_pointers import SECTION_MARK  # noqa: E402

_SPEC = importlib.util.spec_from_file_location(
    "check_section_pointers", HERE / "check-section-pointers.py"
)
check = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(check)


# A tree the guard must pass end to end: every SWEEP_ANCHOR present with
# headings, every GRAMMAR_SPELLINGS arm exercised, and the HISTORICAL_SECTIONS
# citer carrying the pointers those entries exempt. Built from the check's own
# tables, not from a second copy of them, so adding an anchor or a spelling
# fails here until this tree covers it.
DECISION = "docs/decisions/D001-fixture-record.md"


def clean_tree(*, with_pointers: bool = True) -> dict[str, bytes | str]:
    """A tree the guard must pass, derived from the check's OWN tables.

    Every SWEEP_ANCHOR and TARGET_ANCHOR present with headings, every
    GRAMMAR_SPELLINGS arm exercised, and the HISTORICAL_SECTIONS citer carrying
    the pointers those entries exempt. Derived rather than copied, so adding an
    anchor or a spelling fails here until this tree covers it.
    """
    anchor = check.SWEEP_ANCHORS[0]
    documents = (*check.SWEEP_ANCHORS, *check.TARGET_ANCHORS, DECISION)
    tree: dict[str, bytes | str] = {
        rel: f"# {rel}\n\n## Live section\n" for rel in documents
    }
    if with_pointers:
        basename = check.SWEEP_ANCHORS[1].rsplit("/", 1)[-1]
        reached = "".join(
            f"and `{target}` {SECTION_MARK} Live section, by path\n\n"
            for target in check.TARGET_ANCHORS
        )
        tree["docs/upstream/note.md"] = (
            f"# Note\n\n## Own section\n\n"
            f"see [a](../../{anchor}) {SECTION_MARK} Live section — citer-relative\n\n"
            f"and `{anchor}` ({SECTION_MARK} Live section, {SECTION_MARK} Live section)\n\n"
            f"and see {SECTION_MARK} Own section, intra-document\n\n"
            f"and `{basename}` {SECTION_MARK} Live section, by basename\n\n"
            f"and D001 {SECTION_MARK} Live section, by decision id\n\n"
            f"{reached}"
        )
    for (citer, target, name), _reason in check.HISTORICAL_SECTIONS.items():
        tree.setdefault(citer, "")
        tree[citer] = f'{tree[citer]}# recorded: `{target}` {SECTION_MARK} "{name}" gone\n'
    for rel in check.FIXTURE_FILES:
        tree.setdefault(rel, "")
    return tree


def end_to_end_controls() -> list[str]:
    """The wiring that assembles the arms into a verdict, which no arm observes.

    Every other control drives one function. That left `audit`, `main` and the
    four `problems.extend` calls between them unguarded, and eight wiring
    mutants survived with both the suite and the guard green — worst among them
    `if problems:` -> `if False:`, which makes the CI step permanently green
    while this file still prints "all reporting". Only a real exit status sees
    that one, so the guard is also run as a process against a throwaway repo.
    """
    failures: list[str] = []
    clean = clean_tree()
    dirty = dict(clean, **{"citer.md": f"# C\n\n`AGENTS.md` {SECTION_MARK} Gone.\n"})

    if check.audit(clean).problems:
        failures.append(
            f"audit() reported problems on a tree built to satisfy every arm: "
            f"{check.audit(clean).problems}"
        )
    if not any("has no such heading" in problem for problem in check.audit(dirty).problems):
        failures.append(
            "audit() did not report a dead pointer, so an arm's findings are being "
            "dropped between the arm and the caller"
        )

    # ONE TREE PER ARM main() ASSEMBLES, each isolating that arm: a dropped
    # `problems.extend` is otherwise invisible, since every other arm stays
    # silent and the exit status is the only thing that can see the omission.
    fixture_untracked = {
        rel: text for rel, text in clean.items() if rel not in check.FIXTURE_FILES
    }
    for case, tree, want in (
        ("clean", clean, 0),
        ("with a dead pointer", dirty, 1),
        ("with a grammar spelling unexercised", clean_tree(with_pointers=False), 1),
        ("with its fixture-file exclusion untracked", fixture_untracked, 1),
        ("with a markdown blob that is not text", dict(clean, **{"x.md": b"# \xff\n"}), 1),
        ("with a binary blob that is not markdown", dict(clean, **{"x.png": b"\x89\xff"}), 0),
    ):
        status, output = run_guard(tree)
        if status != want:
            failures.append(
                f"the guard exited {status} on a throwaway repo {case}, expected {want} "
                f"— the verdict does not follow the findings: {output}"
            )

    # THE GUARD JUDGES TRACKED BLOBS, NOT THE WORKING TREE, and each half of
    # that has its own fixture. Both are paired against `dirty` above — the same
    # dead pointer, tracked, asserted rc=1 — so neither can pass by being inert.
    dead = f"# Outside\n\n`AGENTS.md` {SECTION_MARK} Gone section.\n"
    for case, kwargs in (
        (
            # A symlink's blob is its target path, which holds no mark. Reading
            # the path instead would pull in a file the repo does not contain —
            # a host file, or an endless device such as /dev/zero.
            "followed a tracked symlink out of the repo",
            {"symlinks": {"link.md": "../outside.md"}, "outside": dead},
        ),
        (
            # Tracked and clean in the index, dead on disk. Reading the working
            # tree judges bytes no reviewer approved and no PR contains; it is
            # also what silently swallowed a file absent from the checkout.
            "judged the working tree instead of the tracked blob",
            {"after_add": {"AGENTS.md": dead}},
        ),
    ):
        status, output = run_guard(clean, **kwargs)
        if status != 0:
            failures.append(f"the guard {case}: {output}")

    # SKIP_ROOTS FILTERS CITERS, NOT TARGETS. A vendored doc is not ours to
    # EDIT, which says nothing about whether it can be NAMED — and blaming a
    # correct pointer at one on its citer ("not a tracked markdown file. Repoint
    # it") is wrong in every clause. Both halves are asserted: naming a vendored
    # heading passes, and a dead pointer INSIDE that tree is not read at all.
    vendored = check.SKIP_ROOTS[0]
    anchor = check.SWEEP_ANCHORS[0]
    for case, tree, want in (
        (
            "a pointer AT a vendored document",
            dict(clean, **{
                f"{vendored}vendor.md": "# Vendor\n\n## Upstream section\n",
                "citer.md": f"# C\n\n`{vendored}vendor.md` {SECTION_MARK} Upstream section.\n",
            }),
            0,
        ),
        (
            "a dead pointer INSIDE a vendored tree",
            dict(clean, **{
                f"{vendored}vendor.md": f"# Vendor\n\n`{anchor}` {SECTION_MARK} Gone section.\n",
            }),
            0,
        ),
        (
            "a pointer at a vendored document that does NOT carry the section",
            dict(clean, **{
                f"{vendored}vendor.md": "# Vendor\n\n## Upstream section\n",
                "citer.md": f"# C\n\n`{vendored}vendor.md` {SECTION_MARK} Gone section.\n",
            }),
            1,
        ),
    ):
        status, output = run_guard(tree)
        if status != want:
            failures.append(
                f"{case} exited {status}, expected {want}: SKIP_ROOTS is the citer "
                f"filter, and using it as a target filter blames correct pointers on "
                f"the wrong file — {output}"
            )
    return failures


def run_guard(
    tree: dict[str, bytes | str],
    symlinks: dict[str, str] | None = None,
    outside: str | None = None,
    after_add: dict[str, str] | None = None,
) -> tuple[int, str]:
    """Run the real check as a PROCESS over a throwaway repo, returning (rc, output).

    The scripts are copied in so the check's `REPO_ROOT`, derived from its own
    location, lands on the fixture repo rather than on this one. `symlinks` are
    tracked links; `outside` writes a file BESIDE the repo for one to point at.
    """
    with tempfile.TemporaryDirectory() as workdir:
        root = Path(workdir) / "repo"
        root.mkdir()
        if outside is not None:
            (Path(workdir) / "outside.md").write_text(outside, encoding="utf-8")
        for rel, target in (symlinks or {}).items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).symlink_to(target)
        for rel, text in tree.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            if isinstance(text, bytes):
                (root / rel).write_bytes(text)
            else:
                (root / rel).write_text(text, encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        for rel, text in (after_add or {}).items():
            (root / rel).write_text(text, encoding="utf-8")
        # The scripts land AFTER the add, so they stay UNTRACKED and the guard
        # does not sweep its own source: these files carry real pointers into
        # this repo's docs, none of which exist in a fixture tree.
        shutil.copytree(HERE, root / "scripts", dirs_exist_ok=True)
        done = subprocess.run(
            [sys.executable, str(root / "scripts" / "check-section-pointers.py")],
            capture_output=True,
            text=True,
            check=False,
        )
        return done.returncode, (done.stdout + done.stderr).strip()



def main() -> int:
    failures = end_to_end_controls()
    if failures:
        print("test-section-pointers-e2e: FAIL", file=sys.stderr)
        for problem in failures:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print("test-section-pointers-e2e: ok (the guard reports, and its verdict follows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
