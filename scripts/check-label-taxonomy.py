#!/usr/bin/env python3
"""Compare cached Linear labels with the taxonomy in kendex.toml.

Every inventory label must be usable or forbidden in the taxonomy. Every
taxonomy label must exist in the inventory. The local Linear cache is required
unless --allow-missing-inventory explicitly accepts an unchecked inventory.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "kendex.toml"
LINEAR_CLI = REPO_ROOT / ".agents" / "skills" / "linear" / "scripts" / "linear.sh"

# The taxonomy names labels in backtick spans inside markdown table rows.
TAXONOMY_START = "## Project issue label taxonomy"
NEVER_USE_HEADING = "### Never-use labels"
# Label names can start with a digit.
LABEL_SPAN = re.compile(r"`([A-Za-z0-9][A-Za-z0-9:._-]*)`")

# Prose inside the taxonomy also uses backticks for non-label text.
NOT_A_LABEL = re.compile(r"^(issues|kendex|linear|docs/|quickshell/|\.github/|\.agents/)")


def taxonomy_sections() -> tuple[set[str], set[str]]:
    """(usable labels, never-use labels) as named in kendex.toml."""
    text = MANIFEST.read_text(encoding="utf-8")
    start = text.find(TAXONOMY_START)
    if start == -1:
        raise SystemExit(f"check-label-taxonomy: kendex.toml has no '{TAXONOMY_START}' section")
    body = text[start:]
    end = body.find('\n"""')
    if end != -1:
        body = body[:end]

    never_at = body.find(NEVER_USE_HEADING)
    if never_at == -1:
        raise SystemExit(f"check-label-taxonomy: kendex.toml has no '{NEVER_USE_HEADING}' section")

    def labels(chunk: str) -> set[str]:
        return {
            name
            for line in chunk.splitlines()
            if line.startswith("|")
            for name in LABEL_SPAN.findall(line.split("|")[1] if line.count("|") > 1 else "")
            if not NOT_A_LABEL.match(name)
        }

    usable = labels(body[:never_at])
    never = labels(body[never_at:])
    # This label is governed in prose outside the table.
    if "`ci-nightly`" in body:
        usable.add("ci-nightly")
    return usable, never


def live_labels() -> list[dict]:
    result = subprocess.run(
        [str(LINEAR_CLI), "cache", "labels", "list", "--format=safe"],
        capture_output=True,
        text=True,
        # The skill reads credentials from its own config; an inherited
        # LINEAR_API_KEY makes the CLI take a different, unauthenticated path.
        env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(Path.home())},
        timeout=120,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"exit {result.returncode}")
    return json.loads(result.stdout)


def main() -> int:
    allow_missing = "--allow-missing-inventory" in sys.argv[1:]

    usable, never = taxonomy_sections()

    if not LINEAR_CLI.is_file():
        message = f"linear CLI not found at {LINEAR_CLI}"
    else:
        message = ""
    if not message:
        try:
            inventory = live_labels()
        except Exception as exc:  # noqa: BLE001 - any failure means no sweep happened
            message = f"could not read the Linear label inventory: {exc}"
    if message:
        if allow_missing:
            print(f"check-label-taxonomy: skipped: {message} — the taxonomy was NOT swept")
            return 0
        print(f"check-label-taxonomy: FAIL: {message}", file=sys.stderr)
        print(
            "This check compares kendex.toml's taxonomy against live Linear and cannot\n"
            "run without that inventory. Pass --allow-missing-inventory only when you\n"
            "accept that the sweep did not happen (CI has no Linear credentials).",
            file=sys.stderr,
        )
        return 1

    documented = usable | never
    live = {label["name"] for label in inventory}

    undocumented = sorted(live - documented)
    stale = sorted(documented - live)

    problems = []
    if undocumented:
        problems.append(
            "live in Linear but in neither the usable tables nor the never-use table:\n"
            + "".join(f"    {name}\n" for name in undocumented)
            + "  Add each to a Domain/Classification/Workflow table, or to the never-use\n"
            "  table with the reason it can never apply."
        )
    if stale:
        problems.append(
            "named by the taxonomy but no longer live in Linear:\n"
            + "".join(f"    {name}\n" for name in stale)
            + "  Remove the row, or restore the label."
        )

    groups = {label["name"] for label in inventory if label.get("is_group")}
    ungoverned_groups = sorted(groups - never)
    if ungoverned_groups:
        problems.append(
            "group/parent labels not in the never-use table: "
            + ", ".join(ungoverned_groups)
            + "\n  A group label must never be assigned; say so explicitly."
        )

    if problems:
        print("check-label-taxonomy: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(
        f"check-label-taxonomy: ok ({len(live)} live labels: "
        f"{len(live & usable)} usable, {len(live & never)} never-use)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
