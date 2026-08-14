"""Parsers for the VGS validation manifest and the docs that restate it.

Imported by scripts/check-validation-inventory.py, which owns the RULES — which
checks are excluded, which are local-only, what CI must contain. This module
owns only the READING: what the runner says its manifest, areas and tag
attributes are, and what the prose surfaces claim about them.

Every function takes the path it reads rather than resolving one, so a caller
can point them at a fixture. scripts/test-validate.sh does exactly that: it
drives the guard against mutated copies of the runner, which is why a
module-level RUNNER constant would be the wrong shape here.

Library, not a check: no shebang, no `__main__`, never executed directly.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:
    # Fails rather than degrading: without a YAML parse, CI coverage is NOT
    # checked, and a check that silently skips its own subject is the exact
    # false green the importing guard exists to prevent.
    print(
        "check-validation-inventory: FAIL: PyYAML is not installed, so ci.yml could not\n"
        "be parsed and CI coverage was NOT checked (pacman -S python-yaml).",
        file=sys.stderr,
    )
    raise SystemExit(1) from None


def manifest_rows(runner: Path) -> list[tuple[str, str]]:
    """`(area tags, command)` pairs from the scripts/validate manifest heredoc.

    Parsed statically, not via `scripts/validate --list`: this check must report
    a manifest the runner cannot even parse.
    """
    text = runner.read_text(encoding="utf-8")
    block = re.search(r"<<'MANIFEST_EOF'\n(.*?)\nMANIFEST_EOF\n", text, re.DOTALL)
    if not block:
        raise SystemExit(
            "check-validation-inventory: scripts/validate has no MANIFEST_EOF heredoc; "
            "this check parses that block, so moving it silently empties the inventory"
        )
    rows: list[tuple[str, str]] = []
    for line in block.group(1).splitlines():
        if not line.strip():
            continue
        if "|" not in line:
            raise SystemExit(
                f"check-validation-inventory: scripts/validate manifest row has no "
                f"`AREAS | COMMAND` separator: {line!r}"
            )
        tags, command = line.split("|", 1)
        command = command.strip()
        if not command:
            # A truncated hand-edit leaves the tag and drops the command. Both
            # this parser and the runner's loop used to skip such a row, deleting
            # a check from every area while both halves of the guard stayed green.
            raise SystemExit(
                f"check-validation-inventory: scripts/validate manifest row has an "
                f"empty command: {line!r}"
            )
        rows.append(("".join(tags.split()), command))
    if not rows:
        raise SystemExit("check-validation-inventory: scripts/validate manifest is empty")
    return rows


def runner_areas(runner: Path) -> set[str]:
    """The area names scripts/validate accepts, minus the `all` pseudo-area."""
    match = re.search(r"^AREAS=\(([^)]*)\)", runner.read_text(encoding="utf-8"), re.MULTILINE)
    if not match:
        raise SystemExit("check-validation-inventory: scripts/validate has no AREAS=( ... ) list")
    return set(match.group(1).split()) - {"all"}


def runner_tag_attributes(runner: Path) -> set[str]:
    """Manifest tag tokens that are attributes rather than area selectors.

    Read from the runner, not hardcoded: adding one there needs no edit here,
    and REMOVING one immediately reports every row still carrying it.
    """
    match = re.search(
        r"^TAG_ATTRIBUTES=\(([^)]*)\)", runner.read_text(encoding="utf-8"), re.MULTILINE
    )
    if not match:
        raise SystemExit(
            "check-validation-inventory: scripts/validate has no TAG_ATTRIBUTES=( ... ) list"
        )
    return set(match.group(1).split())


def runner_body_without_declaration(runner: Path) -> str:
    """The runner's executable shell, minus comments and the attribute array.

    Proves an attribute token is WIRED, not merely declared: a token named only
    in the header prose behaves exactly like an undeclared one at run time.
    """
    lines = []
    for line in runner.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("#") or stripped.startswith("TAG_ATTRIBUTES=("):
            continue
        lines.append(line)
    return "\n".join(lines)


def prose_areas(path: Path) -> set[str] | None:
    """Backticked area names from a prose surface's `areas ...` enumeration.

    None when the file states none, which is allowed: a doc pointing at
    `scripts/validate --list` instead has nothing to drift.
    """
    match = re.search(
        r"areas\s+((?:`[a-z-]+`(?:,\s*|\s+and\s+|\s*)?)+)",
        path.read_text(encoding="utf-8"),
    )
    if not match:
        return None
    return set(re.findall(r"`([a-z-]+)`", match.group(1)))


def ci_run_commands(ci: Path) -> str:
    """Only the shell inside ci.yml's `run:` blocks, never the whole file.

    A raw substring test over ci.yml counts COMMENTS as invocations: deleting a
    check from its `run:` block while leaving the comment above it kept this
    guard green, the exact false green it exists to prevent. It cuts the other
    way too — a comment naming a local-only script would report a failure that
    is not real. A YAML parse is the honest form.
    """
    workflow = yaml.safe_load(ci.read_text(encoding="utf-8"))
    runs: list[str] = []

    def walk(node) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "run" and isinstance(value, str):
                    runs.append(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(workflow)
    if not runs:
        raise SystemExit("check-validation-inventory: ci.yml has no `run:` blocks at all")
    # Strip shell comments too: a `#` line inside a run block is still prose.
    lines = []
    for block in runs:
        for line in block.splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                lines.append(line)
    return "\n".join(lines)


def documented_table(doc: Path, lead_in: str) -> set[str]:
    """Script basenames named in the first column of the table after `lead_in`."""
    text = doc.read_text(encoding="utf-8")
    start = text.find(lead_in)
    if start == -1:
        raise SystemExit(
            f"check-validation-inventory: validation-scripts.instructions.md "
            f"has no table introduced by {lead_in!r}"
        )
    names: set[str] = set()
    seen_rows = False
    for line in text[start + len(lead_in):].splitlines():
        stripped = line.strip()
        if not stripped:
            if seen_rows:
                break
            continue
        if not stripped.startswith("|"):
            break
        cells = stripped.split("|")
        if len(cells) < 2:
            continue
        first = cells[1].strip()
        if set(first) <= {"-", ":", " "}:  # the header underline
            continue
        match = re.search(r"`scripts/([A-Za-z0-9._-]+)`", first)
        if match:
            names.add(match.group(1))
            seen_rows = True
    return names
