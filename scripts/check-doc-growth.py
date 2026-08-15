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

docs/decisions/*.md are deliberately NOT watched: decision records are where
content dieted out of AGENTS.md goes to live (VGS-105, VGS-107), so a ceiling
there would penalize exactly the move the diet depends on. They are read on
demand, not loaded ambiently.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

# Ceilings in bytes. Adoption rule (VGS-108): size measured on post-diet main
# plus ~10% headroom, rounded up to the next 100 bytes; each comment records
# the measured size so the headroom stays auditable. Raising a ceiling happens
# HERE, in the same PR that grows the file, with a rationale comment — the
# rationale is for the reviewer, so a raise without one is review feedback,
# not something this script can enforce.
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
    # issue set rather than a size plus headroom: the file is 4,489 B, so there
    # is almost none, and that is the point. The next addition displaces
    # something or moves to a per-area surface — the thing both diets had to do
    # by hand.
    "AGENTS.md": 4_500,
    # Adopted at 3,289 B. 2026-08-10: owner-approved risk-class +
    # regression-test policy sections plus the PR #120 review rounds
    # (coverage gaps, property-defined privileged class) earned the bytes;
    # 7,200 keeps ~10% headroom at the final 6,490 B size, superseding the
    # 6,500 figure measured mid-review at 5,865 B.
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
    # last auto-loaded warning, so it moved here; 5,700 keeps ~10% headroom at
    # the resulting 5,158 B.
    "project-skills/vshell-dev/SKILL.md": 5_700,
    # Adopted at 403 B. VGS-124: the diet's own rewrap un-exempted a sanctioned
    # direct-launch mention in check-validation-safety.sh (line-scoped spans),
    # and that check does not run in the `docs` area an AGENTS.md edit reaches
    # for. Naming both exact-string couplings, and the commands that actually
    # cover them, where an AGENTS.md edit is reviewed earned the bytes; 1,100
    # keeps ~10% headroom at the resulting 994 B.
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
    # VGS-144 bought the last raise: the validate area list became a machine-read
    # contract delimited by HTML comment markers, and a review found it
    # unnameable — three documents carried bare markers, and this one, the only
    # place that explains them, could not show the literal opener without
    # tripping the guard's own anchored-exactly-once refusal. The parser now
    # ignores fenced blocks and the contract is quoted here verbatim, which is
    # what the bytes bought; 6,500 keeps ~10% headroom at the resulting 5,845 B.
    ".github/instructions/validation-scripts.instructions.md": 6_500,
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
    "docs/architecture/idle-lock-screensaver.md": 20_300,  # adopted at 18,453 B
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

# Every file matching these must carry a CEILINGS entry. Shallow on purpose:
# the patterns match today's layout exactly, so a new nesting level appearing
# is a conscious decision about whether it is an instruction surface — and a
# glob that stops matching anything fails below rather than going quietly
# inert.
WATCHED_GLOBS = (
    ".github/instructions/*.md",
    "docs/architecture/*.md",
    "project-skills/*/SKILL.md",
)

# Surfaces whose ceiling is a BUDGET, not a measured size plus headroom. The
# generic remedy below — "raise the ceiling, here, with a rationale" — is right
# for every other entry, and exactly wrong for these: raising the number is the
# outcome the budget exists to refuse. They get a remedy that says to displace
# or relocate instead. Keep an entry here only while its comment above says the
# same thing; a budget nobody chose is just a tight ceiling.
HARD_BUDGETS = frozenset({"AGENTS.md"})


def main() -> int:
    problems: list[str] = []

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

    for pattern in WATCHED_GLOBS:
        matched = False
        for path in sorted(REPO_ROOT.glob(pattern)):
            matched = True
            rel = path.relative_to(REPO_ROOT).as_posix()
            if rel not in CEILINGS:
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

    if problems:
        print("check-doc-growth: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(f"check-doc-growth: ok ({len(CEILINGS)} surfaces within their ceilings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
