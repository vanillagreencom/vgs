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
    # 18,528 B after VGS-123 moved the 56-command validation manifest into
    # scripts/validate and the "What CI covers" tables into the instruction
    # files. The 25,000 ceiling that survived the VGS-107 diet would leave 6.5 KB
    # of unexamined regrowth headroom here, which is the thing this ratchet
    # exists to deny. 19,500 is measured + ~5%, DELIBERATELY tighter than the
    # +10% adoption default: this file is loaded every session and has just been
    # cut, so the next growth should be argued for rather than absorbed.
    "AGENTS.md": 19_500,
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
    ".github/copilot-instructions.md": 3_850,
    "project-skills/vshell-dev/SKILL.md": 5_000,  # adopted at 4,497 B
    ".github/instructions/agents-md.instructions.md": 500,  # adopted at 403 B
    ".github/instructions/architecture-docs.instructions.md": 500,  # adopted at 393 B
    ".github/instructions/backend-go.instructions.md": 800,  # adopted at 671 B
    # Adopted at 962 B. VGS-123 moved AGENTS.md § "What CI covers, and what it
    # cannot" out of the always-loaded surface; the required-checks and
    # whitespace-range halves landed here and the local-only/reached-indirectly
    # tables went to validation-scripts.instructions.md, whose `scripts/**`
    # scope is where judging a check actually happens. 3,500 keeps ~10% headroom
    # at the resulting 3,116 B.
    ".github/instructions/ci.instructions.md": 3_500,
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
    ".github/instructions/validation-scripts.instructions.md": 5_500,
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
    "docs/architecture/shell-architecture.md": 22_300,  # adopted at 20,248 B
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


def main() -> int:
    problems: list[str] = []

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
