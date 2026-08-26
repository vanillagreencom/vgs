#!/usr/bin/env python3
"""End-to-end controls: scripts/check-section-pointers.py run as a PROGRAM.

Its sibling `scripts/test-section-pointers.py` drives each arm as a function,
which leaves the wiring between them — `audit`, `main`, and the `problems.extend`
calls that assemble a verdict — guarded by nothing: eight mutants of that shape
once survived with both the suite and the guard green. The worst,
`if problems:` -> `if False:`, makes the CI step permanently green while the
suite still prints "all reporting". Only a real exit status sees it, so this
file builds throwaway git repos and runs the guard against them. That is a
different kind of test rather than a longer one — it writes trees, creates
symlinks, runs `git init` and reads process statuses — which is why it is a peer
script.

ONE TREE PER ARM, each isolating its arm AND asserting the diagnostic it
expects, because a dropped `problems.extend` is invisible when another arm
reports anyway. The arms are enumerated by the trees below rather than counted
here; that count went stale twice. Two further trees pin the rule underneath
them all — the guard judges TRACKED BLOBS, never the working tree — one through
a symlink out of the repo, one through a file clean in the index and dead on
disk. The mutation set is recorded in `scripts/test-section-pointers.py`.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import tracked_blobs  # noqa: E402
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
    # One document under each anchor ROOT, derived rather than named: the roots
    # exist precisely because no filename under them survives VGS-125, so a
    # fixture that named one would carry the defect this closed.
    under_roots = tuple(f"{root}anchored.md" for root in check.ANCHOR_ROOTS)
    documents = (*check.SWEEP_ANCHORS, *check.TARGET_ANCHORS, *under_roots, DECISION)
    tree: dict[str, bytes | str] = {
        rel: f"# {rel}\n\n## Live section\n" for rel in documents
    }
    if with_pointers:
        basename = under_roots[0].rsplit("/", 1)[-1]
        reached = "".join(
            f"and `{target}` {SECTION_MARK} Live section, by path\n\n"
            for target in (*check.TARGET_ANCHORS, *under_roots)
        )
        tree["docs/upstream/note.md"] = (
            f"# Note\n\n## Own section\n\n"
            f"see [a](../../{anchor}) {SECTION_MARK} Live section — citer-relative\n\n"
            # No parenthesis: a qualifier around these would be CROSSED, and the
            # second mark would take its target that way rather than by
            # inheriting, leaving that spelling unexercised.
            f"and `{anchor}` {SECTION_MARK} Live section, {SECTION_MARK} Live section\n\n"
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
    `problems.extend` calls between them unguarded, and eight wiring
    mutants survived with both the suite and the guard green — worst among them
    `if problems:` -> `if False:`, which makes the CI step permanently green
    while this file still prints "all reporting". Only a real exit status sees
    that one, so the guard is also run as a process against a throwaway repo.
    """
    failures: list[str] = []
    clean = clean_tree()
    dirty = dict(clean, **{"citer.md": f"# C\n\n`AGENTS.md` {SECTION_MARK} Gone.\n"})

    on_clean = check.audit(clean).problems
    if on_clean:
        failures.append(
            f"audit() reported problems on a tree built to satisfy every arm: {on_clean}"
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
    # One tree per `audit` arm. The exemption tree leaves each
    # HISTORICAL_SECTIONS citer citing nothing; the heading tree makes headless
    # the one SWEEP_ANCHOR clean_tree does not cite — a CITED anchor does not
    # isolate, since the pointer arm answers first with "has no such heading".
    exemption_unused = dict(clean)
    for citer, _target, _name in check.HISTORICAL_SECTIONS:
        exemption_unused[citer] = "# nothing is cited here\n"
    # The anchor no pointer in clean_tree names, by PATH OR BASENAME — the first
    # attempt matched on path alone and picked one cited by basename, so the
    # pointer arm answered first and the tree stayed rc=1 under both mutants.
    documents = {*check.SWEEP_ANCHORS, *check.TARGET_ANCHORS, DECISION}
    prose = "".join(
        text
        for rel, text in clean.items()
        if isinstance(text, str) and rel not in documents
    )
    uncited = next(
        rel
        for rel in check.SWEEP_ANCHORS
        if rel not in prose and rel.rsplit("/", 1)[-1] not in prose
    )
    heading_gone = dict(clean, **{uncited: "no heading in this file\n"})
    # EACH ROW NAMES THE FINDING IT EXPECTS, not just an exit status: rc alone
    # let a tree tripping a DIFFERENT arm pass as if it had proved its own.
    for case, tree, want, expect in (
        ("clean", clean, 0, ""),
        ("with a dead pointer", dirty, 1, "has no such heading"),
        (
            "with a grammar spelling unexercised",
            clean_tree(with_pointers=False), 1, "grammar spellings still exercised",
        ),
        (
            "with its fixture-file exclusion untracked",
            fixture_untracked, 1, "is exempted here",
        ),
        (
            "with a markdown blob that is not text",
            dict(clean, **{"x.md": b"# \xff\n"}), 1, "none of its headings could be parsed",
        ),
        ("with a binary blob that is not markdown", dict(clean, **{"x.png": b"\x89\xff"}), 0, ""),
        (
            "with a HISTORICAL_SECTIONS entry no pointer needs",
            exemption_unused, 1, "no pointer there needs it",
        ),
        (
            "with an uncited anchor that yields no heading",
            heading_gone, 1, "expected member(s) are absent",
        ),
        (
            # The ambiguity check asked only the PARSED documents, so a duplicate
            # basename whose twin is a symlink was invisible to it and the
            # readable one answered for the name. Only the guard's own
            # construction of the target set can be seen from out here.
            "with a duplicate basename whose twin is a tracked symlink",
            dict(clean, **{
                "a/dup.md": "# A\n\n## Live section\n",
                "citer.md": f"# C\n\n`dup.md` {SECTION_MARK} Live section.\n",
            }),
            1,
            "tracked documents share",
        ),
        (
            # Without the cause map a pointer at a tracked symlinked .md gets
            # "not a tracked markdown file", which is false — it IS tracked. The
            # other symlink fixture cannot see this: nothing in it CITES a link.
            "with a citer naming a tracked markdown symlink",
            dict(clean, **{
                "citer.md": f"# C\n\n`link.md` {SECTION_MARK} Live section.\n",
            }),
            1,
            "tracked as a symlink",
        ),
        (
            # FIRST-PARTY: the repo owns it, so a broken fence is a finding —
            # and such a document is always a citer, so that arm owns the message.
            "with a first-party document whose fence never closes",
            dict(clean, **{
                "docs/architecture/owned.md": "# O\n\n```\n## Upstream section\n",
                "citer.md": f"# C\n\n`docs/architecture/owned.md` "
                            f"{SECTION_MARK} Upstream section.\n",
            }),
            1,
            "its heading list is short too",
        ),
        (
            # VENDORED: not ours to repair, so the fence is a CAUSE when someone
            # points at it rather than a failure on its own.
            "with a citer naming a vendored document whose fence never closes",
            dict(clean, **{
                f"{check.SKIP_ROOTS[0]}vendor.md": "# V\n\n```\n## Upstream section\n",
                "citer.md": f"# C\n\n`{check.SKIP_ROOTS[0]}vendor.md` "
                            f"{SECTION_MARK} Upstream section.\n",
            }),
            1,
            "so this pointer cannot be judged",
        ),
        (
            "with a vendored broken fence nobody cites",
            dict(clean, **{
                f"{check.SKIP_ROOTS[0]}vendor.md": "# V\n\n```\n## Upstream section\n",
            }),
            0,
            "",
        ),
    ):
        links = None
        if "duplicate basename" in case:
            links = {"b/dup.md": "../a/dup.md"}
        elif "symlink" in case:
            links = {"link.md": "AGENTS.md"}
        status, output = run_guard(tree, symlinks=links)
        if status != want:
            failures.append(
                f"the guard exited {status} on a throwaway repo {case}, expected {want} "
                f"— the verdict does not follow the findings: {output}"
            )
        elif expect and expect not in output:
            failures.append(
                f"the tree {case} exited 1 without reporting {expect!r}, so it tripped "
                f"some other arm and proves nothing about the one it names: {output}"
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

    # THE FIXTURE STAYS INSIDE ITS TEMPDIR. An absolute GIT_INDEX_FILE in the
    # environment redirects `git -C <fixture> add -A` into whatever repository it
    # names — this rewrote THIS worktree's index during review, staging 21,050
    # deletions while the suite exited 0. The victim's index is read before and
    # after and must be byte-identical.
    with tempfile.TemporaryDirectory() as workdir:
        victim = Path(workdir) / "victim"
        victim.mkdir()
        (victim / "kept.md").write_text("# Kept\n\n## Live section\n", encoding="utf-8")
        env = tracked_blobs.git_env(hermetic=True)
        subprocess.run(["git", "-C", str(victim), "init", "-q"], check=True, env=env)
        subprocess.run(["git", "-C", str(victim), "add", "-A"], check=True, env=env)
        index = victim / ".git" / "index"
        before = index.read_bytes()
        prior = os.environ.get("GIT_INDEX_FILE")
        os.environ["GIT_INDEX_FILE"] = str(index)
        try:
            status, output = run_guard(clean)
        finally:
            # RESTORED, not deleted: the ambient value is the exact condition
            # this control exists for, and dropping it would leave every later
            # control in this process running without it.
            if prior is None:
                os.environ.pop("GIT_INDEX_FILE", None)
            else:
                os.environ["GIT_INDEX_FILE"] = prior
        # The status is BOUND, because run_guard exits early without running the
        # guard when a fixture never staged — and an index is trivially unchanged
        # by a run that never happened.
        if status != 0:
            failures.append(f"the containment fixture never ran the guard: {output}")
        if index.read_bytes() != before:
            failures.append(
                "an absolute GIT_INDEX_FILE in the environment reached the fixture's "
                "git calls, so running these controls rewrites an unrelated "
                "repository's index while reporting ok"
            )

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
        links = {"link.md": "AGENTS.md"} if "symlink" in case else None
        status, output = run_guard(tree, symlinks=links)
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

    EVERY SUBPROCESS GETS A SCRUBBED ENVIRONMENT, the guard included, because it
    shells out to git itself. Inherited, an ABSOLUTE `GIT_DIR` or
    `GIT_INDEX_FILE` makes `git -C <fixture> add -A` write the fixture's paths
    into whatever repository the variable names, leaving that one's index
    referencing blobs it does not have — this happened to this worktree during
    review. `tracked_blobs.git_env` is the one definition of what to remove; the
    hermetic form also silences user and system config, so `git add -A` cannot
    inherit a `core.excludesFile` that declines to add a fixture.
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
        env = tracked_blobs.git_env(hermetic=True)
        subprocess.run(["git", "-C", str(root), "init", "-q"], check=True, env=env)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, env=env)
        # THE FIXTURE SET IS A COLLECTION TOO, and it was the one never asserted:
        # `git add -A` can decline a path, so a control could pass on a tree that
        # never held its fixture at all.
        staged = set(
            subprocess.run(
                ["git", "-C", str(root), "ls-files"],
                capture_output=True, text=True, check=True, env=env,
            ).stdout.split()
        )
        missing = sorted((set(tree) | set(symlinks or {})) - staged)
        if missing:
            return -1, f"fixture paths never entered the index: {', '.join(missing)}"
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
            env=env,
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
