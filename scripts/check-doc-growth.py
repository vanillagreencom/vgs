#!/usr/bin/env python3
"""Ratchet byte growth on instruction surfaces and architecture docs.

Nothing braked instruction-surface growth before this existed: AGENTS.md grew
3.3x in fourteen days and had to be dieted back down (VGS-107). The repo
already ratchets its check inventory (scripts/check-validation-inventory.py);
this is the same idiom pointed at context surfaces — the files agents load
every session (AGENTS.md, review-bots.md, the Copilot instruction set, the
project skill) and the per-area references under docs/architecture/. Growth
itself is not the defect; UNEXAMINED growth is. So the ceiling is enforced,
and raising it takes a one-line edit in the same PR as the growth, where a
reviewer sees the trade stated explicitly.

Three failure shapes:

1. **A surface outgrew its ceiling.** Cut it back below the ceiling, or raise
   the ceiling here in the SAME PR with a rationale comment saying what earned
   the bytes.

2. **A file appeared in a watched glob with no ceiling entry.** New files do
   not get to skip the ratchet by being new — silence would grandfather every
   future doc in at whatever size it first merges. Add an entry at current
   size plus ~10% headroom. A glob that matches nothing at all fails the same
   way: a renamed directory must update WATCHED_GLOBS in the same PR, or the
   new-file ratchet is silently disabled for that surface class.

3. **A ceilings entry names a file that does not exist.** A rename or removal
   updates or drops the entry in the same PR — a stale entry is coverage that
   does not exist.

4. **A ceilings comment records a size the file no longer has.** Growth UNDER a
   ceiling is deliberately free, so nothing used to force these figures to be
   refreshed — and they went stale five times across VGS-124's review, three of
   its fix rounds spent re-deriving them by hand. The rationales lean on the
   numbers ("~10% headroom", "almost none"), so a wrong one is the audit trail
   failing quietly. Update the figure; do not loosen the parser. An entry that
   records no size at all is fine, and `adopted at N B` IS the recorded size for
   the many entries that only state that.

docs/decisions/*.md are deliberately NOT watched: decision records are where
content dieted out of AGENTS.md goes to live (VGS-105, VGS-107), so a ceiling
there would penalize exactly the move the diet depends on. They are read on
demand, not loaded ambiently.
"""

from __future__ import annotations

import math
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SELF = Path(__file__).resolve()

# Ceilings in bytes. Adoption rule (VGS-108): size measured on post-diet main
# plus ~10% headroom, rounded up to the next 100 bytes; each comment records
# the measured size so the headroom stays auditable. Raising a ceiling happens
# HERE, in the same PR that grows the file, with a rationale comment — the
# rationale is for the reviewer, so a raise without one is review feedback,
# not something this script can enforce.
#
# Growth UNDER a ceiling is deliberately free, so nothing forces a recorded
# size to be refreshed and three VGS-124 rounds found stale ones by hand. To
# re-derive them all, compare each entry against a fresh stat:
#   python3 -c 'import re,os;[print(f"{f} {os.path.getsize(f):,}") for f in
#     re.findall(r"^    \"([^\"]+)\":", open("scripts/check-doc-growth.py").read(), re.M)]'
CEILINGS: dict[str, int] = {
    # HARD BUDGET, not measured-plus-headroom — see HARD_BUDGETS below.
    #
    # The VGS-124 second diet cut this file to invariants only. RELOCATED to
    # the surface that owns each: § Project skills (project-skills/README.md),
    # § Documentation resources and § Layout's path/purpose table (the
    # vshell-dev skill's "## Repo layout" tree, which predates the diet and
    # gained that table's three missing entries in the same PR), § Review gate
    # (review-gate-writer.yml's header and vstack.settings.toml), the Linear
    # mirroring runbook (vstack.toml, D002) and § Live workstation wiring (the
    # untracked AGENTS.local.md). DROPPED outright, with no successor:
    # § Architecture docs' per-file "when to read" routing, replaced by a
    # pointer at docs/architecture/. Neither deleted table was STALE at
    # removal — every path resolved and all 13 architecture docs were listed;
    # they went because they duplicated a per-area surface and § Layout named
    # only 4 of bin/'s 15 entries, so it read as complete while it was not.
    #
    # Those registers are what regrew after VGS-107, so 4,500 is a budget the
    # issue set rather than a size plus headroom: the file is 4,498 B, so there
    # is almost none, and that is the point. The next addition displaces
    # something or moves to a per-area surface — the thing both diets had to do
    # by hand.
    "AGENTS.md": 4_500,
    # Adopted at 3,289 B. 2026-08-10: owner-approved risk-class +
    # regression-test policy sections plus the PR #120 review rounds
    # (coverage gaps, property-defined privileged class) earned the bytes;
    # 7,200 keeps ~10% headroom at the final 6,490 B size, superseding the
    # 6,500 figure measured mid-review at 5,865 B. Now 6,569 B (~9.6% left):
    # drift predating VGS-124, recorded here when that PR re-derived every size.
    "review-bots.md": 7_200,
    # Adopted at 2,909 B. 2026-08-14: the PR #132 review found the doc-surface
    # and vendored-tree rules were telling reviewers to suppress valid drift
    # findings on the three VGS-authored files inside vendored trees
    # (colorschemes/ATTRIBUTION.md and the two third_party/ READMEs);
    # correcting that needs the enumerated product-facing set plus the
    # carve-out, which earned the bytes. The two rules were merged into one to
    # hold the growth down. 3,850 at the final 3,554 B size: deliberately
    # TIGHTER than the 4,000 the adoption formula rounds to, because the
    # rounding above is an adoption convention and a raise is only required to
    # carry a rationale — so the tighter line wins over the rounder number.
    # Now 3,660 B: VGS-124 added AGENTS.local.md to the doc-surface set. The
    # deliberately tight 3,850 still holds, with ~190 B left.
    ".github/copilot-instructions.md": 3_850,
    # Adopted at 4,497 B. VGS-124: "a green CI run does not prove the shell
    # starts — run the qml area, which forces --require-nested" left AGENTS.md
    # with the rest of the validation runbook, and its only remaining home was
    # validation-scripts.instructions.md, scoped to `scripts/**` — invisible to
    # a QML agent, which loads this skill. That is the VGS-69 class losing its
    # last auto-loaded warning, so it moved here. A later round also completed the
    # "## Repo layout" tree with the three entries AGENTS.md § Layout had that
    # it lacked. 5,700 is deliberately NOT re-raised at the resulting 5,359 B:
    # that is ~6% headroom, not the adoption default's ~10%, and the tighter
    # line wins over the rounder number.
    "project-skills/vshell-dev/SKILL.md": 5_700,
    # Adopted at 403 B. VGS-124: the diet's own rewrap un-exempted a sanctioned
    # direct-launch mention in check-validation-safety.sh (line-scoped spans),
    # and that check does not run in the `docs` area an AGENTS.md edit reaches
    # for. Naming both exact-string couplings, and the commands that actually
    # cover them, where an AGENTS.md edit is reviewed earned the bytes; 1,100
    # keeps ~10% headroom at the resulting 999 B.
    ".github/instructions/agents-md.instructions.md": 1_100,
    ".github/instructions/architecture-docs.instructions.md": 500,  # adopted at 393 B
    ".github/instructions/backend-go.instructions.md": 800,  # adopted at 671 B
    # Adopted at 962 B. VGS-123 moved AGENTS.md § "What CI covers, and what it
    # cannot" out of the always-loaded surface; the required-checks and
    # whitespace-range halves landed here and the local-only/reached-indirectly
    # tables went to validation-scripts.instructions.md, whose `scripts/**`
    # scope is where judging a check actually happens. That 3,500 kept ~10%
    # headroom at the resulting 3,116 B. VGS-124 then repointed the deleted
    # AGENTS.md § Review gate citation here and added the rule it was the only
    # home for — a gate-repair PR cannot open its own gate, so it merges via
    # the ruleset bypass actor. At the resulting 3,448 B, 3,500 left 52 B and
    # a comment still promising ~10%: 3,800 restores it.
    ".github/instructions/ci.instructions.md": 3_800,
    ".github/instructions/harness-config.instructions.md": 900,  # adopted at 760 B
    ".github/instructions/helper-cli.instructions.md": 600,  # adopted at 517 B
    ".github/instructions/quickshell-qml.instructions.md": 1_700,  # adopted at 1,459 B
    ".github/instructions/themes.instructions.md": 700,  # adopted at 577 B
    # Adopted at 844 B. VGS-123 moved the "What CI covers, and what it cannot"
    # tables here from AGENTS.md: their audience is whoever is judging a check,
    # which is `scripts/**` work landing on PRs that touch no workflow file, so
    # a workflow-scoped home never auto-attached for them. The next review round
    # added the runner's four-valued exit status (77 is not a pass) here, where
    # whoever judges a check reads it; 5,500 keeps ~10% headroom at the
    # resulting 4,977 B, superseding the 4,900 figure measured at 4,388 B.
    # VGS-144 bought the next raise: the validate area list became a machine-read
    # contract delimited by HTML comment markers, and a review found it
    # unnameable — three documents carried bare markers, and this one, the only
    # place that explains them, could not show the literal opener without
    # tripping the guard's own anchored-exactly-once refusal. The parser now
    # ignores fenced blocks and the contract is quoted here verbatim, which is
    # what those bytes bought. That raise recorded 5,845 B and landed on a file
    # already at 6,500 — exactly its own new ceiling, zero headroom — which is
    # the stale-figure drift arm 4 below now refuses; re-derived rather than
    # carried. VGS-124 then added the rule that a collection-based check must
    # assert it collected something, after three checks in one night reported
    # clean while asserting nothing: it belongs on the surface that already
    # tells reviewers to reject an unreachable failure path. 7,600 keeps ~10%
    # headroom at the resulting 6,873 B.
    ".github/instructions/validation-scripts.instructions.md": 7_600,
    ".github/instructions/vendored-engine.instructions.md": 1_000,  # adopted at 854 B
    ".github/instructions/vendored-go.instructions.md": 500,  # adopted at 367 B
    # Adopted at 302 B. 2026-08-14: ATTRIBUTION.md carve-out (PR #132) — the
    # blanket "never patch in-repo, skip style findings" rule covered a
    # VGS-authored file. 600 is the adoption rule applied at the final 490 B
    # size: plus ~10% is 539, rounded up to the next 100.
    ".github/instructions/vendored-nvim.instructions.md": 600,
    "docs/architecture/backend-daemon.md": 7_800,  # adopted at 7,087 B
    "docs/architecture/cloud-sync.md": 15_400,  # adopted at 13,975 B
    "docs/architecture/design-language.md": 19_700,  # adopted at 17,886 B
    "docs/architecture/display-brightness.md": 7_600,  # adopted at 6,852 B
    "docs/architecture/greeter-auto-login-keyring.md": 3_500,  # adopted at 3,151 B
    "docs/architecture/idle-lock-screensaver.md": 20_300,  # adopted at 18,453 B; 18,569 after VGS-124
    "docs/architecture/notification-ownership.md": 19_300,  # adopted at 17,530 B
    "docs/architecture/overlay-and-dependencies.md": 21_300,  # adopted at 19,354 B
    "docs/architecture/remote-desktop.md": 21_700,  # adopted at 19,653 B
    "docs/architecture/scratchpads.md": 24_500,  # adopted at 22,271 B
    # Adopted at 20,248 B. 2026-08-15 (VGS-134): now 23,174 B, and the raise
    # absorbs two things, not one. VGS-121 and VGS-118 had already grown the
    # file 2,005 B under the old ceiling, to 22,253 B with 47 B of headroom
    # left; this PR's 921 B — the launcher hover-selection latch, a rule an
    # agent rewiring the vgsMenu delegates has to meet before it edits them,
    # sitting next to the pill-hover rule it mirrors — is what breached it.
    # 24,400 is measured + ~5%, DELIBERATELY tighter than the +10% adoption
    # default: this file is one of the per-area references agents load by name
    # and it has taken 2,926 B since adoption, so the next growth should be
    # argued for rather than absorbed.
    "docs/architecture/shell-architecture.md": 24_400,
    "docs/architecture/theme-architecture.md": 31_800,  # adopted at 28,861 B
    "docs/architecture/wallpaper-upscaling.md": 4_000,  # adopted at 3,625 B
}

# Every file matching these must carry a CEILINGS entry. RECURSIVE, and that is
# a correction: these were shallow, with a comment claiming a new nesting level
# would be a conscious decision. It was not — `docs/architecture/lock/details.md`
# simply never matched, so it got no ceiling and nothing said so. The stale-glob
# guard below could not save it either, since the top-level files still matched
# and kept `matched` true.
#
# If a recursive sweep ever pulls in something that genuinely should not be
# ceilinged, exempt it by name here with a reason. Do NOT narrow the glob back:
# an exemption is visible in review, a shallow glob is not. (Nothing needs one
# today — the sweep found no unceilinged file when it was widened.)
WATCHED_GLOBS = (
    ".github/instructions/**/*.md",
    "docs/architecture/**/*.md",
    "project-skills/**/SKILL.md",
)

# Surfaces whose ceiling is a BUDGET, not a measured size plus headroom. The
# generic remedy below — "raise the ceiling, here, with a rationale" — is right
# for every other entry, and exactly wrong for these: raising the number is the
# outcome the budget exists to refuse. They get a remedy that says to displace
# or relocate instead. Keep an entry here only while its comment above says the
# same thing; a budget nobody chose is just a tight ceiling.
HARD_BUDGETS = frozenset({"AGENTS.md"})

# ─── RECORDED SIZES ─────────────────────────────────────────────────────────
#
# Each entry's comment records what the file measured, and the rationale above
# it reasons from that number. The phrasings below are the ones this file
# actually uses; a figure not introduced by one of them is not a measurement —
# that is what keeps ceilings ("7,200 keeps ~10% headroom"), arithmetic ("plus
# ~10% is 539") and remainders ("~190 B left") out of the comparison.
#
# The LAST match wins, by position. Comments are written chronologically —
# adoption first, revisions appended — so the newest measurement is the current
# one, and the superseded figures a rationale narrates stay readable without
# being mistaken for today's size.
RECORDED_SIZE_PATTERNS = (
    re.compile(r"\badopted at\s+([\d,_]+)\s*B\b", re.I),
    re.compile(r"\bat the resulting\s+([\d,_]+)\s*B\b", re.I),
    re.compile(r"\bat the final\s+([\d,_]+)\s*B\b", re.I),
    re.compile(r"\bnow\s+([\d,_]+)\s*B\b", re.I),
    re.compile(r"\bthe file is\s+([\d,_]+)\s*B\b", re.I),
    # "adopted at 18,453 B; 18,569 after VGS-124" — a revision written as a
    # bare number rather than a phrase.
    re.compile(r";\s*([\d,_]+)\s+after\b", re.I),
)

ENTRY_LINE = re.compile(r'^    "([^"]+)":\s*[\d_]+,(?:\s*#\s*(.*))?$')

# This file parses ITSELF to read those comments, so it is pinned to two
# literals in its own source. Named rather than inlined in a split, so a
# reformat produces a sentence naming the anchor that moved.
#
# SELF-REFERENTIAL HAZARD, and it is the trap that made this subtle: the source
# being parsed CONTAINS these constants, so the opening literal occurs three
# times here — the real declaration, the assignment just below, and the
# self-test's fixture. A plain `find` matched the second one and then blamed the
# CLOSING anchor for a drifted declaration, sending the operator to a constant
# that was correct. The lookup is therefore anchored to column 0, which only the
# declaration satisfies: the other two are an assignment value and an indented
# string literal.
CEILINGS_OPEN = "CEILINGS: dict[str, int] = {"
CEILINGS_OPEN_LINE = re.compile(rf"^{re.escape(CEILINGS_OPEN)}", re.M)
CEILINGS_CLOSE = "\n}\n"


def recorded_size(comment: str) -> int | None:
    """The size a comment records, or None when it records none."""
    latest: tuple[int, int] | None = None
    for pattern in RECORDED_SIZE_PATTERNS:
        for match in pattern.finditer(comment):
            value = int(match.group(1).replace(",", "").replace("_", ""))
            if latest is None or match.start() > latest[0]:
                latest = (match.start(), value)
    return None if latest is None else latest[1]


class AnchorError(Exception):
    """A literal this file parses ITSELF by is no longer where it was."""


def ceiling_body(source: str) -> str:
    """The text between the CEILINGS anchors, or a sentence saying which moved.

    Both anchors are checked, and neither is allowed to fail quietly. A missing
    opening one used to raise IndexError out of a split, handing the operator a
    traceback instead of a diagnostic; a missing closing one read to end of file,
    scanning the rest of the module for entries. Reporting nothing is not an
    option either — an unreadable table means the recorded-size arm DID NOT RUN,
    never that it is clean (validation-scripts.instructions.md).
    """
    opening = CEILINGS_OPEN_LINE.search(source)
    if opening is None:
        raise AnchorError(
            f"the CEILINGS opening anchor ({CEILINGS_OPEN!r}) does not start a line in "
            f"scripts/check-doc-growth.py, so no entry's comment can be read and the "
            f"recorded-size arm cannot run. The declaration was reformatted or "
            f"renamed — update CEILINGS_OPEN in this file to match it."
        )
    rest = source[opening.end() :]
    end = rest.find(CEILINGS_CLOSE)
    if end == -1:
        raise AnchorError(
            f"the CEILINGS closing anchor ({CEILINGS_CLOSE!r}) is not in "
            f"scripts/check-doc-growth.py after the opening one, so the table has no "
            f"end and the parser would read the rest of the module as entries. The "
            f"closing brace's whitespace changed — update CEILINGS_CLOSE to match."
        )
    return rest[:end]


def ceiling_comments(source: str) -> dict[str, str]:
    """Each CEILINGS entry mapped to its own comment, from this file's text."""
    body = ceiling_body(source)
    comments: dict[str, str] = {}
    pending: list[str] = []
    for line in body.split("\n"):
        stripped = line.strip()
        if stripped.startswith("#"):
            pending.append(stripped.lstrip("#").strip())
            continue
        match = ENTRY_LINE.match(line)
        if match:
            comments[match.group(1)] = " ".join(filter(None, [*pending, match.group(2) or ""]))
        pending = []
    return comments


def recorded_size_problems(source: str, sizes: dict[str, int]) -> list[str]:
    """Entries whose comment records a size the file no longer has."""
    try:
        comments = ceiling_comments(source)
    except AnchorError as exc:
        return [str(exc)]
    missed = sorted(sizes.keys() - comments.keys())
    if missed:
        return [
            f"the CEILINGS comment parser read {len(comments)} entries and missed "
            f"{len(missed)} that have a measured size to check, so this arm cannot "
            f"report a stale figure for them. First unread: {missed[:3]}. Fix the "
            f"parser rather than the table — an arm that reads nothing passes "
            f"everything."
        ]
    problems = []
    for rel, size in sizes.items():
        stated = recorded_size(comments[rel])
        if stated is not None and stated != size:
            problems.append(
                f"{rel}'s ceiling comment records {stated:,} bytes but the file is "
                f"{size:,}. The rationale reasons from that number, so update it to "
                f"the measured size in this PR — the figure is the audit trail, and a "
                f"wrong one is worse than none."
            )
    return problems


# Fixtures for the arm above, run on every invocation rather than behind a flag:
# it exists because stale figures went unnoticed five times, and a control that
# can be skipped is that same failure one level up. Each shape in real use is
# covered, so no single phrasing can quietly stop being recognised.
RECORDED_SIZE_FIXTURES = (
    ("adopted at 671 B", 671),
    ("Adopted at 962 B. ... That 3,500 kept ~10% headroom at the resulting 3,116 B.", 3_116),
    ("Adopted at 302 B. 600 is the adoption rule applied at the final 490 B size.", 490),
    ("7,200 keeps ~10% headroom at the final 6,490 B size. Now 6,569 B (~9.6% left).", 6_569),
    ("4,500 is a budget the issue set: the file is 4,498 B, so there is almost none.", 4_498),
    ("adopted at 18,453 B; 18,569 after VGS-124", 18_569),
    ("owner-approved risk-class sections earned the bytes", None),
)


def watched_glob_problems(root: Path, ceilinged: set[str]) -> list[str]:
    """Watched surfaces under `root` with no ceiling, plus any stale glob.

    Takes its root as an argument so the recursion can be proven against a
    throwaway tree: asserting it against the repo alone would only show that
    today's files still match, which the shallow globs did too.
    """
    problems: list[str] = []
    for pattern in WATCHED_GLOBS:
        matched = False
        for path in sorted(root.glob(pattern)):
            matched = True
            rel = path.relative_to(root).as_posix()
            if rel not in ceilinged:
                size = path.stat().st_size
                suggested = math.ceil(size * 1.10 / 100) * 100
                problems.append(
                    f"{rel} ({size:,} bytes) matches the watched glob `{pattern}` "
                    f"but has no ceiling in scripts/check-doc-growth.py. A new "
                    f"instruction surface needs a conscious ceiling, not a "
                    f"grandfathered size: add an entry at its current size plus "
                    f"~10% headroom rounded up to the next 100 bytes "
                    f"({suggested:,} for this file today), with a comment "
                    f"recording the measured size."
                )
        if not matched:
            problems.append(
                f"the watched glob `{pattern}` matches no files at all, so the "
                f"new-file ratchet is silently disabled for it — the glob is "
                f"stale. Update WATCHED_GLOBS in scripts/check-doc-growth.py in "
                f"the same PR as the rename or removal that emptied it, or drop "
                f"the glob if that surface class is genuinely gone."
            )
    return problems


def self_test() -> list[str]:
    """The arm must be able to fail, and must not fire on correct records."""
    failures = []

    # THE GLOBS REACH DOWN. Proven on a throwaway tree, because the repo's own
    # files sit at the top level and match either way — which is exactly why the
    # shallow globs passed every existing test while a nested surface was
    # invisible.
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)
        for rel in (
            ".github/instructions/nested/deep.md",
            "docs/architecture/lock/details.md",
            "project-skills/thing/nested/SKILL.md",
        ):
            probe = root / rel
            probe.parent.mkdir(parents=True, exist_ok=True)
            probe.write_text("x" * 100, encoding="utf-8")
            reported = watched_glob_problems(root, set())
            if not any(rel in problem for problem in reported):
                failures.append(
                    f"a nested instruction surface ({rel}) was not reported as "
                    f"unceilinged, so the watched globs do not reach it and it would "
                    f"be added with no ceiling and no complaint: {reported}"
                )
    for comment, expected in RECORDED_SIZE_FIXTURES:
        actual = recorded_size(comment)
        if actual != expected:
            failures.append(
                f"recorded_size read {actual!r}, expected {expected!r}, from: {comment!r}"
            )

    # The must-fail control: a wrong figure has to be REPORTED. Driven through
    # the real comparison, not just the parser, so the arm is proven end to end.
    fixture_source = (
        'CEILINGS: dict[str, int] = {\n'
        '    "fixture.md": 900,  # adopted at 800 B\n'
        '}\n'
    )
    if not recorded_size_problems(fixture_source, {"fixture.md": 850}):
        failures.append(
            "a comment recording 800 B for an 850-byte file was accepted, so this arm "
            "is vacuous and every recorded size is unchecked."
        )
    # Reports what it actually got: a broken entry parser reaches here too, and
    # calling that "fires on correct records" would name the wrong cause — the
    # mistake this file's other diagnostics were fixed for twice.
    spurious = recorded_size_problems(fixture_source, {"fixture.md": 800})
    if spurious:
        failures.append(
            f"a comment recording 800 B for an 800-byte file was not accepted: {spurious}"
        )

    # ANCHOR DRIFT MUST BE A SENTENCE naming the RIGHT anchor — not a traceback,
    # not silence, and not the other anchor's remedy.
    #
    # Driven against THIS FILE's own text, not a synthetic fixture, and that is
    # the whole point: the hazard only exists because the parsed source contains
    # the anchor constants, so a fixture with one occurrence cannot see it. The
    # earlier controls were synthetic, passed, and missed a drifted declaration
    # being reported as a drifted closing brace.
    real = SELF.read_text(encoding="utf-8")
    opening = CEILINGS_OPEN_LINE.search(real)
    closing_at = real.find(CEILINGS_CLOSE, opening.end()) if opening else -1
    if opening is None or closing_at == -1:
        failures.append(
            "this file's own CEILINGS anchors could not be located, so the drift "
            "controls below could not be built and prove nothing."
        )
    else:
        drifts = (
            (
                "opening",
                real[: opening.start()] + "CEILINGS = {" + real[opening.end() :],
            ),
            (
                "closing",
                real[:closing_at] + "\n    }\n" + real[closing_at + len(CEILINGS_CLOSE) :],
            ),
        )
        for anchor, drifted in drifts:
            try:
                reported = recorded_size_problems(drifted, {"AGENTS.md": 1})
            except Exception as exc:  # noqa: BLE001 — any escape is the defect
                failures.append(
                    f"a drifted {anchor} CEILINGS anchor raised {type(exc).__name__} out "
                    f"of the arm instead of reporting it: {exc}"
                )
                continue
            if not any(f"{anchor} anchor" in problem for problem in reported):
                failures.append(
                    f"a drifted {anchor} CEILINGS anchor was not reported as {anchor}-"
                    f"anchor drift, so the operator is sent to the wrong constant (or "
                    f"nowhere). An unreadable table means DID NOT RUN, never clean, and "
                    f"the cause has to be the one that actually moved: {reported}"
                )
    return failures


def main() -> int:
    broken = self_test()
    if broken:
        print("check-doc-growth: FAIL (self-test)", file=sys.stderr)
        for problem in broken:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    problems: list[str] = []
    sizes: dict[str, int] = {}

    # A budget naming a path with no ceiling would never be consulted, so the
    # entry would look like policy while enforcing nothing.
    for rel in sorted(HARD_BUDGETS - CEILINGS.keys()):
        problems.append(
            f"{rel} is in HARD_BUDGETS but has no CEILINGS entry, so its budget "
            f"is never consulted. Add the ceiling or drop the budget."
        )

    for rel, ceiling in CEILINGS.items():
        path = REPO_ROOT / rel
        if not path.is_file():
            problems.append(
                f"{rel} has a ceiling here but does not exist. If it was renamed or "
                f"removed, update or drop the entry in scripts/check-doc-growth.py "
                f"in the same PR — a stale entry is coverage that does not exist."
            )
            continue
        size = path.stat().st_size
        sizes[rel] = size
        if size > ceiling:
            if rel in HARD_BUDGETS:
                problems.append(
                    f"{rel} is {size:,} bytes, over its {ceiling:,}-byte BUDGET. "
                    f"This one is not a measured size plus headroom, so raising "
                    f"it is not the remedy: displace something already here, or "
                    f"move the addition to the per-area surface that owns it "
                    f"(the comment on its entry in scripts/check-doc-growth.py "
                    f"records where each register went). Changing the number "
                    f"takes an explicit decision to retire the budget, not a "
                    f"rationale comment."
                )
                continue
            suggested = math.ceil(size * 1.10 / 100) * 100
            problems.append(
                f"{rel} is {size:,} bytes, over its {ceiling:,}-byte ceiling. "
                f"Growth must be a conscious trade, not drift: cut the file back "
                f"below the ceiling, or raise its ceiling in "
                f"scripts/check-doc-growth.py in the SAME PR ({suggested:,} "
                f"keeps ~10% headroom at today's size) with a rationale comment "
                f"saying what earned the bytes."
            )

    # Only over entries whose file exists: a missing one is already reported
    # above, and its comment says nothing about a file that is not there.
    problems.extend(recorded_size_problems(SELF.read_text(encoding="utf-8"), sizes))

    problems.extend(watched_glob_problems(REPO_ROOT, set(CEILINGS)))

    if problems:
        print("check-doc-growth: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(f"check-doc-growth: ok ({len(CEILINGS)} surfaces within their ceilings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
