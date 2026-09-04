#!/usr/bin/env python3
"""Run section-pointer checks as processes over isolated git repositories.

Each tree isolates a check and requires its status and diagnostic. Index and
symlink fixtures distinguish blob reads from working-tree reads.
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
REPO_ROOT = HERE.parent
sys.path.insert(0, str(HERE / "lib"))
import tracked_blobs  # noqa: E402
from section_pointers import SECTION_MARK  # noqa: E402

_SPEC = importlib.util.spec_from_file_location(
    "check_section_pointers", HERE / "check-section-pointers.py"
)
check = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(check)

# Import the same fallback exemption entry used by in-process controls.
_UNIT_SPEC = importlib.util.spec_from_file_location(
    "test_section_pointers", HERE / "test-section-pointers.py"
)
_unit = importlib.util.module_from_spec(_UNIT_SPEC)
_UNIT_SPEC.loader.exec_module(_unit)
FIXTURE_HISTORICAL = _unit.FIXTURE_HISTORICAL
# Require the copied declaration to match before installing the fixture entry.
EMPTY_TABLE = "HISTORICAL_SECTIONS: dict[tuple[str, str, str], str] = {}\n"
# Capture emptiness before installing the fallback in the imported module.
SHIPPED_HISTORICAL = dict(check.HISTORICAL_SECTIONS)
if not SHIPPED_HISTORICAL:
    # end_to_end_controls() calls check.audit() in-process on the same trees the
    # subprocess cases use, so the table this module reads has to be the one
    # those trees were built from, or every clean tree reads as a dead pointer.
    check.HISTORICAL_SECTIONS = dict(FIXTURE_HISTORICAL)


def historical_entries() -> dict[tuple[str, str, str], str]:
    """The entries every tree below is built from: shipped, else the fixture."""
    return dict(check.HISTORICAL_SECTIONS)


DECISION = "docs/decisions/D001-fixture-record.md"


def clean_tree(*, with_pointers: bool = True) -> dict[str, bytes | str]:
    """A tree the guard must pass, derived from the check's OWN tables.

    Every SWEEP_ANCHOR and TARGET_ANCHOR present with headings, every
    GRAMMAR_SPELLINGS arm exercised, and the HISTORICAL_SECTIONS citer carrying
    the pointers those entries exempt. Derived rather than copied, so adding an
    anchor or a spelling fails here until this tree covers it.
    """
    anchor = check.SWEEP_ANCHORS[0]
    # Use root-derived paths so fixture filenames do not constrain document renames.
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
    for (citer, target, name), _reason in historical_entries().items():
        tree.setdefault(citer, "")
        tree[citer] = f'{tree[citer]}# recorded: `{target}` {SECTION_MARK} "{name}" gone\n'
    for rel in check.FIXTURE_FILES:
        tree.setdefault(rel, "")
    for root in check.OWNED_ROOTS:
        tree.setdefault(f"{root}SKILL.md", f"# {root}\n\n## Live section\n")
    return tree


def end_to_end_controls() -> list[str]:
    """Check audit and main failure propagation through process results."""
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

    # Isolate each assembled check so another failure cannot hide an omitted call.
    fixture_untracked = {
        rel: text for rel, text in clean.items() if rel not in check.FIXTURE_FILES
    }
    # One tree per `audit` arm. The exemption tree leaves each
    # HISTORICAL_SECTIONS citer citing nothing; the heading tree makes headless
    # the one SWEEP_ANCHOR clean_tree does not cite — a CITED anchor does not
    # isolate, since the pointer arm answers first with "has no such heading".
    exemption_unused = dict(clean)
    for citer, _target, _name in historical_entries():
        exemption_unused[citer] = "# nothing is cited here\n"
    # Choose an anchor cited by neither path nor basename to isolate heading checks.
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
    # Require the expected diagnostic as well as failure status.
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
        (
            # Unreadable owned-skill documents must use the same scope as the sweep.
            "with an unreadable markdown blob inside an owned skill tree",
            dict(clean, **{f"{check.OWNED_ROOTS[0]}notes.md": b"# \xff\n"})
            if check.OWNED_ROOTS
            else clean,
            1, "none of its headings could be parsed",
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
            # Only process controls exercise the guard construction of unreadable candidates.
            "with a duplicate basename whose twin is a tracked symlink",
            dict(clean, **{
                "a/dup.md": "# A\n\n## Live section\n",
                "citer.md": f"# C\n\n`dup.md` {SECTION_MARK} Live section.\n",
            }),
            1,
            "tracked documents share",
        ),
        (
            # A cited symlink tests its cause map; an uncited symlink does not.
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

    # An absent register must report a prerequisite error, not an empty owned scope.
    status, output = run_guard(clean, register=False)
    if status == 0 or "yielded no" not in output and "could not be read" not in output:
        failures.append(
            f"the guard exited {status} on a repo with no kendex.toml, and without "
            f"naming the unreadable register — with no `source = in-place` rows to "
            f"read it carves nothing out of `.agents/` and sweeps past every owned "
            f"skill tree: {output}"
        )

    # Pair index and working-tree cases with the same dead pointer indexed.
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
            # The working copy differs from the indexed content under test.
            "judged the working tree instead of the tracked blob",
            {"after_add": {"AGENTS.md": dead}},
        ),
    ):
        status, output = run_guard(clean, **kwargs)
        if status != 0:
            failures.append(f"the guard {case}: {output}")

    # An absolute GIT_INDEX_FILE can redirect fixture writes to another repository.
    # Require that repository index to remain byte-identical.
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
            # Restore the ambient value so subsequent controls keep the same environment.
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

    # Skipped citer roots still provide target headings; test both directions.
    vendored = check.SKIP_ROOTS[0]
    anchor = check.SWEEP_ANCHORS[0]
    # An empty owned-root set needs a diagnostic before fixtures index it.
    if not check.OWNED_ROOTS:
        return failures + [
            "OWNED_ROOTS is empty, so no tree under a skipped root is read for "
            "pointers and the rows below cannot run — check kendex.toml's "
            "`source = \"in-place\"` rows"
        ]
    owned = check.OWNED_ROOTS[0]
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
            # THE CARVE-OUT'S OTHER HALF, paired with the row above because a
            # prefix rule that stopped carving would leave that one passing on
            # its own. Both trees sit under the same skip root; only this one is
            # named in OWNED_ROOTS, and it is ours to keep correct.
            "a dead pointer INSIDE an owned tree under a skipped root",
            dict(clean, **{
                f"{owned}note.md": f"# Owned\n\n`{anchor}` {SECTION_MARK} Gone section.\n",
            }),
            1,
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
    register: bool = True,
) -> tuple[int, str]:
    """Run the guard over a temporary repository and return status and output.

    Copy scripts so their root resolves to the fixture. Scrub git redirects for
    every child process, including the guard. Isolate configuration so host
    exclusion rules cannot suppress fixture staging.
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
        # Require every fixture path to be staged; git add can exclude a file.
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
        # Install the fallback exemption only when the copied guard table is empty.
        if not SHIPPED_HISTORICAL:
            copied = root / "scripts" / "check-section-pointers.py"
            source = copied.read_text(encoding="utf-8")
            patched = source.replace(
                EMPTY_TABLE, f"HISTORICAL_SECTIONS = {FIXTURE_HISTORICAL!r}\n", 1
            )
            if patched == source:
                return -1, "the empty HISTORICAL_SECTIONS declaration was not found to patch"
            copied.write_text(patched, encoding="utf-8")
        # Copy the register untracked so its owned roots match the fixture trees.
        # The missing-register control explicitly withholds it.
        if register:
            shutil.copy(REPO_ROOT / "kendex.toml", root / "kendex.toml")
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
