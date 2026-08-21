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

Four failure shapes:

1. **A surface outgrew its ceiling.** Cut it back below the ceiling, or raise
   the ceiling here in the SAME PR with a rationale comment saying what earned
   the bytes.

2. **A file appeared in a watched glob with no ceiling entry.** New files do
   not get to skip the ratchet by being new — silence would grandfather every
   future doc in at whatever size it first merges. Add an entry at current
   size plus ~10% headroom. A glob that matches nothing at all fails the same
   way: a renamed directory must update WATCHED_SURFACES in the same PR, or the
   new-file ratchet is silently disabled for that surface class.

3. **A ceilings entry names a file that does not exist.** A rename or removal
   updates or drops the entry in the same PR — a stale entry is coverage that
   does not exist.

4. **A ceilings comment records a size the file no longer has, or records none
   this parser can find.** Growth UNDER a ceiling is deliberately free, so
   nothing used to force these figures to be refreshed — and they went stale
   five times across VGS-124's review, three of its fix rounds spent re-deriving
   them by hand. The rationales lean on the numbers ("~10% headroom", "almost
   none"), so a wrong one is the audit trail failing quietly.

   EVERY entry records its measured size; `adopted at N B` is that record for
   the many that state only it. An entry whose comment yields no size the parser
   can find is a FAILURE, not an exemption — whether the figure was never
   written or was reworded out of a recognised phrasing, which are
   indistinguishable from outside and both mean the audit trail is broken.
   Restore the figure in a recognised phrasing, or teach the parser the new one.
   Update the figure; do not loosen the parser.

docs/decisions/*.md are deliberately NOT watched: decision records are where
content dieted out of AGENTS.md goes to live (VGS-105, VGS-107), so a ceiling
there would penalize exactly the move the diet depends on. They are read on
demand, not loaded ambiently.

COLLECTION POINTS. This file implements the invariant stated in
`.github/instructions/validation-scripts.instructions.md` — a collection step
must assert it collected what it expected; a matcher that comes back empty is a
failure of the check, never a clean result — through `scripts/lib/collected.py`.
Two steps here collect something, and each has its own must-fail control. Add a
new one the same way, or it becomes the next instance:

1. the surfaces a watched glob finds     `WATCHED_SURFACES`   recursive, and the
                                                              discovered set is
                                                              asserted against
                                                              the ceilinged files
                                                              under each root —
                                                              partial coverage is
                                                              not full coverage
2. the CEILINGS table and each entry's   `ceiling_comments()` both anchors must
   recorded size                                              resolve, and every
                                                              entry must yield a
                                                              SIZE — prose whose
                                                              number the patterns
                                                              cannot find is the
                                                              parser losing it,
                                                              not an entry with
                                                              none

(These are the invariant's only call sites in the tree today. VGS-124 wrote
three more against a `[skill-instructions]` render checker; that checker moved
to VGS-156 whole, so the numbering restarts here rather than leaving a gap
pointing at a file that is not in the repo.)
"""

from __future__ import annotations

import math
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from collected import members_missing, nothing_collected  # noqa: E402

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
    # issue set rather than a size plus headroom: the file is 4,487 B, so there
    # is almost none, and that is the point. The next addition displaces
    # something or moves to a per-area surface — the thing both diets had to do
    # by hand.
    #
    # ALREADY EXERCISED ONCE, on the PR that set it. VGS-144 landed a
    # machine-read marker pair around the validate area list, 47 B the
    # inventory guard requires in THIS file, so relocation was not available
    # and the budget was 36 B short. It was paid by displacement, not a raise:
    # § Where the rest lives' skills pointer dropped the clause explaining why
    # skills sit outside the harness mirrors, which project-skills/README.md
    # opens by explaining at length. The pointer survived; only the duplicate
    # explanation moved. That is the mechanism working, not a near miss.
    #
    # Raising it instead was considered and rejected for two reasons. 4,500 is
    # VGS-124's own acceptance criterion, and a ceiling that moves to fit its
    # overage defines the diet by whatever size the diet reached. And it would
    # contradict a rule this table states a few entries down, where 5,700 was
    # deliberately NOT re-raised at 5,359 B because the tighter line wins over
    # the rounder number. The trim is also the diet's method applied to itself:
    # prose shrinks to a pointer, and the why survives on the surface the
    # pointer already sends the reader to.
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
    # "## Repo layout" tree with the three entries AGENTS.md § "Layout" had that
    # it lacked. 5,700 was deliberately NOT re-raised at the resulting 5,359 B:
    # ~6% headroom rather than the adoption default's ~10%, the tighter line
    # winning over the rounder number. VGS-144 then anchored this file's area
    # list in the same machine-read marker pair as AGENTS.md's and named the
    # contract; now 5,552 B, ~2.7% left. The tighter line is tight enough that
    # the next addition here needs a raise, not a shave.
    "project-skills/skills/vshell-dev/SKILL.md": 5_700,
    # Adopted at 1,906 B; now 1,598 B after the per-channel publish commands
    # moved to vgs-distro-publish, leaving a checklist. Ratcheted down to match.
    "project-skills/skills/vgs-release/SKILL.md": 1_800,
    # Adopted at 5,968 B: per-channel publish commands, split out so the release checklist stays
    # one; Ubuntu's source-tree prep and an every-chroot, non-zero-on-miss verification earn their
    # bulk. VGS-204: now 6,148 B, 148 past the old line, for the two gaps a hand publisher hits when
    # CI is down — publish-aur.sh IS that publisher, wanting AUR commit rights on all three
    # packages, and dput's `incoming` reads owner, then distro, then PPA. 6,200 keeps the round line
    # just above, held since adoption; +10%'s 6,800 would absorb the next addition.
    "project-skills/skills/vgs-distro-publish/SKILL.md": 6_200,
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
    # AGENTS.md § "Review gate" citation here and added the rule it was the only
    # home for — a gate-repair PR cannot open its own gate, so it merges via
    # the ruleset bypass actor. At the resulting 3,448 B, 3,500 left 52 B and
    # a comment still promising ~10%: 3,800 restored it. VGS-204 then added the
    # fifth workflow — the Gentoo publisher and its drift check — and the shared
    # rule both publishers follow: fail rather than skip when the credential is
    # missing. A reader deciding whether external publishing is covered must not
    # be told there are four. Now 3,927 B, after VGS-204 made Gentoo publishing
    # manual and this file had to stop describing a job that no longer exists.
    ".github/instructions/ci.instructions.md": 4_200,
    ".github/instructions/harness-config.instructions.md": 900,  # adopted at 769 B
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
    # headroom at the resulting 6,880 B.
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
    "docs/architecture/design-language.md": 24_900,  # adopted at 17,886 B; 22,565 after VGS-133
    "docs/architecture/display-brightness.md": 7_600,  # adopted at 6,852 B
    "docs/architecture/greeter-auto-login-keyring.md": 3_500,  # adopted at 3,151 B
    "docs/architecture/idle-lock-screensaver.md": 20_300,  # adopted at 18,453 B; 18,569 after VGS-124
    "docs/architecture/notification-ownership.md": 19_300,  # adopted at 17,530 B
    "docs/architecture/overlay-and-dependencies.md": 21_300,  # adopted at 19,354 B
    "docs/architecture/remote-desktop.md": 21_700,  # adopted at 19,653 B
    "docs/architecture/scratchpads.md": 24_500,  # adopted at 22,255 B
    # Adopted at 20,248 B. 2026-08-15 (VGS-134): 23,174 B then, and the raise
    # absorbed two things, not one. VGS-121 and VGS-118 had already grown the
    # file 2,005 B under the old ceiling, to 22,253 B with 47 B of headroom
    # left; this PR's 921 B — the launcher hover-selection latch, a rule an
    # agent rewiring the vgsMenu delegates has to meet before it edits them,
    # sitting next to the pill-hover rule it mirrors — is what breached it.
    # 24,400 is measured + ~5%, DELIBERATELY tighter than the +10% adoption
    # default: this file is one of the per-area references agents load by
    # name, and it has taken 3,338 B since adoption, so the next growth
    # should be argued for rather than absorbed. That figure is VGS-121 and
    # VGS-118's 2,005 B plus VGS-134's 921 B, VGS-124's AGENTS.md repoint
    # (+55 B) and VGS-208's two switcher IPC targets (+357 B); the file is
    # 23,586 B, leaving 814 B of headroom.
    "docs/architecture/shell-architecture.md": 24_400,
    # 31,800 -> 34,000 -> 35,000 -> 36,000: VGS-208's switcher review put the
    # intent-latched seeding rule, the applyInFlight Enter gate, the correlated
    # apply reply, the load-failure and stale-list states and what
    # switcher_check measures. Round 4 added the per-CALL request id, the shared
    # wallpaper stale wording and the three requirements switcher_check enforces
    # on a new switcher (+1,017 B); round 5 swapped its supersession text for the
    # uncoalesced-apply rule and the request-keyed wallpaper slot, paying for
    # both by cutting prose. The +828 B after that is the carousel the switchers
    # actually draw — the slice geometry, the two decode budgets and why the
    # rail carries no border — which replaced a one-image preview area and is
    # the part a reader has to have to touch it. The last +1,133 B buys the
    # three ways INTO a switcher (keybind, the Settings Browse buttons through
    # the ModalManager registry, and the per-page shortcut row) plus the wheel's
    # carried remainder: entry points are what a reader looks for first and were
    # documented nowhere. The last +685 B is review correcting three claims this
    # file made and the code did not keep — no compositor binds ship, Esc clears
    # a filter before it cancels, and sliver residency is a band rather than
    # every entry ever paged past. Adopted at 28,861 B; the file is 37,612 B.
    "docs/architecture/theme-architecture.md": 37_900,
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
# EACH ROOT IS DECLARED, NEVER DERIVED FROM ITS PATTERN, and that separation is
# the whole point of the pair. The partial-coverage guard below asks "does this
# glob still reach every ceilinged file under its root?", so where the root
# comes from decides whether the question can be answered. It used to be
# `pattern.split("*", 1)[0]` — read off the pattern under test — which made the
# guard derive its expectation from its own subject: narrowing
# `docs/architecture/**/*.md` to `docs/architecture/shell*.md` also narrowed the
# root to `docs/architecture/shell`, so the expected set shrank to exactly what
# the narrowed glob still found and the check reported CLEAN while 12 ceilinged
# architecture documents fell out of the ratchet. A guard that derives its
# expectation from its subject can only ever agree with itself.
#
# Narrowing the ROOT instead does not work either: UNWATCHED_CEILINGS below is
# the closing half, and a ceilinged file left under no declared root is a named
# failure. So the two must be narrowed together AND the orphaned file exempted
# by name — three edits, all visible in review, which is what "conscious
# decision" is supposed to mean.
WATCHED_SURFACES = (
    (".github/instructions", ".github/instructions/**/*.md"),
    ("docs/architecture", "docs/architecture/**/*.md"),
    ("project-skills", "project-skills/**/SKILL.md"),
)

# Ceilinged files that live under no watched root, each because it is an
# individually named surface rather than a member of a discovered class. This is
# the independent cross-check on WATCHED_SURFACES: every ceilinged file must be
# under some declared root or listed here, so a root cannot quietly stop
# covering something it used to cover.
#
# PAIRS, NOT A DICT LITERAL, and that is load-bearing rather than style: this
# file parses ITSELF for the CEILINGS table and finds its end by the first
# "\n}\n", so a second mapping closing with a bare `}` at column 0 gives the
# closing-anchor drift arm a decoy to land on — written as a dict, it made that
# arm stop reporting drift and report a bogus size instead. Same self-referential
# hazard the CEILINGS_OPEN comment names, one anchor over.
UNWATCHED_CEILINGS = (
    ("AGENTS.md", "the always-loaded brief itself, ceilinged by name (a budget)"),
    ("review-bots.md", "the review-bot brief, ceilinged by name"),
    (".github/copilot-instructions.md", "the Copilot entry point, ceilinged by name"),
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
    # COLLECTION POINT 3, the second half. The span parse is guarded by the
    # anchors above; this guards the PER-ENTRY parse — and it guards the SIZE,
    # not merely the presence of a comment.
    #
    # Returning None from recorded_size() used to skip the comparison, so an
    # entry whose measurement was reworded out of RECORDED_SIZE_PATTERNS passed
    # unexamined — the parser losing its grip on the number, wearing the same
    # face as an entry that had none to lose. Both are now failures, and
    # deliberately the same failure: the adoption rule at the top of this file
    # says every entry records its measured size, so "this entry records none"
    # is not a legitimate state to exempt. All 29 record one; an exemption would
    # be a hole in the rule rather than a case it allows.
    sized = {rel for rel in sizes if recorded_size(comments.get(rel, "")) is not None}
    silent = members_missing(
        sized,
        sizes,
        what="CEILINGS recorded sizes",
        selector="the per-entry comment parse",
        cause="the comment yields no size this parser can find — either it records "
        "none, which the adoption rule forbids, or its measurement was reworded "
        "outside RECORDED_SIZE_PATTERNS and the parser lost the number. Restore the "
        "figure in a recognised phrasing, or teach the parser the new one",
    )
    if silent:
        return [silent]
    problems = []
    for rel, size in sizes.items():
        stated = recorded_size(comments[rel])
        if stated != size:
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


def watched_glob_problems(
    root: Path,
    ceilinged: set[str],
    surfaces: tuple[tuple[str, str], ...] = WATCHED_SURFACES,
    exempt: tuple[tuple[str, str], ...] = UNWATCHED_CEILINGS,
) -> list[str]:
    """Watched surfaces under `root` with no ceiling, plus any stale glob.

    Takes its root as an argument so the recursion can be proven against a
    throwaway tree: asserting it against the repo alone would only show that
    today's files still match, which the shallow globs did too.

    Takes `surfaces` and `exempt` for the same reason one level up: the controls
    below narrow a real glob and must watch THIS function refuse it. A control
    that could only mutate the module constant would be asserting against a
    global it had just rewritten.
    """
    problems: list[str] = []

    # THE INDEPENDENT HALF, and it runs before any glob does. Every ceilinged
    # file must sit under a DECLARED root or be exempted by name; without this,
    # narrowing a root alongside its pattern would restore the self-agreement
    # the declared root exists to break.
    exempt_names = {rel for rel, _ in exempt}
    orphans = sorted(
        rel
        for rel in ceilinged
        if rel not in exempt_names
        and not any(rel.startswith(f"{base}/") for base, _ in surfaces)
    )
    if orphans:
        problems.append(
            f"{len(orphans)} ceilinged file(s) are under no watched root and are "
            f"not exempted by name ({', '.join(orphans)}) — a root in "
            f"WATCHED_SURFACES stopped covering them, so nothing rediscovers "
            f"them and the partial-coverage guard has nothing to compare "
            f"against. Restore the root, or add each file to UNWATCHED_CEILINGS "
            f"with the reason it is named rather than discovered"
        )

    for base, pattern in surfaces:
        discovered = {
            path.relative_to(root).as_posix() for path in sorted(root.glob(pattern))
        }
        # COLLECTION POINT 2, the PARTIAL half. "Did it match anything?" was
        # satisfied by the top-level files while a nested surface was invisible,
        # so the expected set is named instead: every ceilinged file living under
        # this surface's DECLARED root must be rediscovered by its pattern.
        expected = {rel for rel in ceilinged if rel.startswith(f"{base}/")}
        shortfall = members_missing(
            discovered,
            expected,
            what="watched surfaces",
            selector=f"the glob `{pattern}`",
            cause="the pattern no longer reaches files that carry a ceiling, so "
            "they are no longer ratcheted",
        )
        if shortfall:
            problems.append(shortfall)
        for path in sorted(root.glob(pattern)):
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
        empty = nothing_collected(
            discovered,
            what="watched surfaces",
            selector=f"the glob `{pattern}`",
            cause="the glob is stale — update WATCHED_SURFACES in the same PR as "
            "the rename or removal that emptied it, or drop it if that surface "
            "class is genuinely gone",
        )
        if empty:
            problems.append(empty)
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

    # COLLECTION POINT 2's control, PARTIAL half. A root that still matches some
    # files keeps the "did it match anything?" guard satisfied, which is exactly
    # how a nested surface stayed invisible. Ceilinged files that the glob no
    # longer reaches must be named.
    partial = watched_glob_problems(REPO_ROOT, set(CEILINGS) | {"docs/architecture/ghost.md"})
    if not any("ghost.md" in problem for problem in partial):
        failures.append(
            "a ceilinged surface the globs do not reach was not reported, so partial "
            f"coverage still reads as full coverage: {partial}"
        )

    # THE INDEPENDENCE CONTROLS, both directions, and they are the reason the
    # root is declared rather than read off the pattern. Codex found this on
    # PR #139: `expected` came from `pattern.split("*", 1)[0]`, so narrowing a
    # glob narrowed the detector with it and the check reported CLEAN while
    # dropping 12 ceilinged architecture documents. A guard that derives its
    # expectation from its subject can only ever agree with itself, so the fix
    # had to be an independent source, not another assertion layered on the
    # derived one — and these controls are what prove the source is independent.
    #
    # 1. NARROW THE PATTERN, leave the root. The old shape passed this.
    # ONE VARIABLE. The real surfaces, with only the architecture PATTERN
    # narrowed — passing the single narrowed surface alone would also orphan the
    # other two roots, and the orphan message would satisfy an assertion meant to
    # be about partial coverage.
    narrowed = watched_glob_problems(
        REPO_ROOT,
        set(CEILINGS),
        surfaces=tuple(
            (base, "docs/architecture/shell*.md" if base == "docs/architecture" else pat)
            for base, pat in WATCHED_SURFACES
        ),
    )
    dropped = [
        rel
        for rel in CEILINGS
        if rel.startswith("docs/architecture/")
        and not Path(rel).name.startswith("shell")
    ]
    if not any(
        all(rel in problem for rel in dropped) for problem in narrowed
    ):
        failures.append(
            f"narrowing a watched glob to docs/architecture/shell*.md did not report "
            f"the {len(dropped)} ceilinged documents it stops reaching, so the "
            f"expected set is still derived from the pattern under test and the "
            f"guard vouches for itself: {narrowed}"
        )

    # 2. NARROW THE ROOT TOO, which is the only way to silence control 1 — and
    # it must then trip the orphan arm instead. Without this half, an editor
    # could restore self-agreement by moving both in one edit.
    both = watched_glob_problems(
        REPO_ROOT,
        set(CEILINGS),
        surfaces=tuple(
            ("docs/architecture/shell", "docs/architecture/shell*.md")
            if base == "docs/architecture"
            else (base, pat)
            for base, pat in WATCHED_SURFACES
        ),
    )
    if not any("under no watched root" in problem for problem in both):
        failures.append(
            f"narrowing a root alongside its pattern was accepted, so the ceilinged "
            f"files it abandons are covered by nothing and reported by nothing — the "
            f"self-agreement the declared root exists to break: {both}"
        )

    # ...and the orphan arm must not fire on the real table, or it would satisfy
    # both controls above without distinguishing anything.
    if any(
        "under no watched root" in problem
        for problem in watched_glob_problems(REPO_ROOT, set(CEILINGS))
    ):
        failures.append(
            "the real WATCHED_SURFACES/UNWATCHED_CEILINGS pair reports an orphan, so "
            "the two controls above prove nothing about narrowing."
        )

    # COLLECTION POINT 3's controls — an entry that yields NO SIZE must fail,
    # whichever way it got there. The middle case is the one that used to slip:
    # a comment full of prose whose measurement was reworded out of pattern range
    # returned None, and None skipped the comparison.
    for case, entry in (
        ("no comment at all", '    "fixture.md": 900,\n'),
        (
            "a measurement reworded out of pattern range",
            '    "fixture.md": 900,  # sized 800 bytes when adopted\n',
        ),
        ("prose that records no number", '    "fixture.md": 900,  # earned its bytes\n'),
    ):
        source = "CEILINGS: dict[str, int] = {\n" + entry + "}\n"
        if not any(
            "recorded sizes" in problem
            for problem in recorded_size_problems(source, {"fixture.md": 800})
        ):
            failures.append(
                f"a CEILINGS entry with {case} was accepted, so an entry this parser "
                f"cannot read a size from passes unexamined — indistinguishable from "
                f"one whose recorded size is correct."
            )
    # ...and the arm must still COMPARE when it can read one, or the guard above
    # would satisfy every case by itself.
    readable = 'CEILINGS: dict[str, int] = {\n    "fixture.md": 900,  # adopted at 800 B\n}\n'
    if not any(
        "records 800 bytes but the file is 850" in problem
        for problem in recorded_size_problems(readable, {"fixture.md": 850})
    ):
        failures.append(
            "an entry whose recorded size is readable but WRONG was not reported, so "
            "the arm now only checks that a number exists, not that it is right."
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
