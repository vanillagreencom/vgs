"""Parsers for the VGS validation manifest and the docs that restate it.

Its one importer today is scripts/check-validation-inventory.py, which owns the
RULES — which checks are excluded, which are local-only, what CI must contain.
This module owns only the READING.

Every function takes the path it reads rather than resolving one. That is what
makes scripts/test-validation-inventory.sh possible: it drives the guard against
MUTATED COPIES of the runner and of the docs, by patching the guard's own path
constants, which only works because nothing here resolves a path of its own.

Parse problems raise ManifestError rather than SystemExit, and carry no caller
name — the importer prefixes its own. A module that brands its errors with one
consumer's name cannot honestly gain a second.

Library, not a check: no shebang, no `__main__`, never executed directly.
"""

from __future__ import annotations

import re
from pathlib import Path


class ManifestError(Exception):
    """A surface this module reads does not say what it must say."""



def manifest_rows(runner: Path) -> list[tuple[str, str]]:
    """`(area tags, command)` pairs from the scripts/validate manifest heredoc.

    Parsed statically, not via `scripts/validate --list`: this check must report
    a manifest the runner cannot even parse.
    """
    text = runner.read_text(encoding="utf-8")
    block = re.search(r"<<'MANIFEST_EOF'\n(.*?)\nMANIFEST_EOF\n", text, re.DOTALL)
    if not block:
        raise ManifestError(
            "scripts/validate has no MANIFEST_EOF heredoc; "
            "this check parses that block, so moving it silently empties the inventory"
        )
    rows: list[tuple[str, str]] = []
    for line in block.group(1).splitlines():
        if not line.strip():
            continue
        if "|" not in line:
            raise ManifestError(
                f"scripts/validate manifest row has no "
                f"`AREAS | COMMAND` separator: {line!r}"
            )
        tags, command = line.split("|", 1)
        command = command.strip()
        if not command:
            # A truncated hand-edit leaves the tag and drops the command. Both
            # this parser and the runner's loop used to skip such a row, deleting
            # a check from every area while both halves of the guard stayed green.
            raise ManifestError(
                f"scripts/validate manifest row has an "
                f"empty command: {line!r}"
            )
        rows.append(("".join(tags.split()), command))
    if not rows:
        raise ManifestError("scripts/validate manifest is empty")
    return rows


def runner_areas(runner: Path) -> set[str]:
    """The area names scripts/validate accepts, minus the `all` pseudo-area."""
    match = re.search(r"^AREAS=\(([^)]*)\)", runner.read_text(encoding="utf-8"), re.MULTILINE)
    if not match:
        raise ManifestError("scripts/validate has no AREAS=( ... ) list")
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
        raise ManifestError("scripts/validate has no TAG_ATTRIBUTES=( ... ) list")
    return set(match.group(1).split())


def runner_logic(runner: Path) -> str:
    """The runner's executable shell, with everything that is DATA removed.

    Used to ask whether a tag token is acted upon. Three things are stripped,
    and each one had to be:

      comments          a token named only in the header prose behaves exactly
                        like an undeclared one at run time
      the declarations  TAG_ATTRIBUTES and AREAS list the vocabulary; finding a
                        token in its own declaration proves nothing
      the manifest      the heredoc is data. Every attribute in real use appears
                        in a manifest ROW, so leaving it in made the whole test
                        vacuous: deleting the `may-skip` branch outright still
                        looked wired, because `qml,may-skip | ...` was in scope.

    What remains is shell that runs. That is a NECESSARY condition for a token
    being honoured, not a sufficient one — the behavioral proof that each branch
    does its job lives in scripts/test-validate.sh.
    """
    text = runner.read_text(encoding="utf-8")
    manifest = re.search(r"<<'MANIFEST_EOF'\n.*?\nMANIFEST_EOF\n", text, re.DOTALL)
    if manifest:
        text = text.replace(manifest.group(0), "")
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped.startswith("TAG_ATTRIBUTES=(") or stripped.startswith("AREAS=("):
            continue
        lines.append(line)
    return "\n".join(lines)


def prose_areas(path: Path) -> set[str]:
    """Backticked area names from a prose surface's `areas ...` enumeration.

    ABSENCE IS AN ERROR, never an empty answer. This returned None on a phrasing
    miss and the caller skipped that document, so rewording a lead-in — with a
    real, and possibly wrong, list still on the page — turned the comparison off
    while the suite stayed green. "An empty result treated as a clean result" is
    the standing rule this file's own instructions name.

    The wording coupling is the residual weakness: the parser keys on the word
    `areas` followed by backticked names. A delimited anchor in each document
    would remove it, and is the better long-term shape; making absence fatal is
    what stops the coupling from failing OPEN in the meantime.
    """
    match = re.search(
        r"areas\s+((?:`[a-z-]+`(?:,\s*|\s+and\s+|\s*)?)+)",
        path.read_text(encoding="utf-8"),
    )
    if not match:
        raise ManifestError(
            f"{path.name} no longer states the validate area list where this guard can "
            f"read it (the word `areas` followed by backticked names). Restore that "
            f"phrasing, or drop the enumeration entirely and remove the file from "
            f"AREA_ENUMERATING_DOCS as a recorded decision."
        )
    stated = set(re.findall(r"`([a-z-]+)`", match.group(1)))
    if not stated:
        raise ManifestError(f"{path.name} states an empty validate area list")
    return stated


def ci_run_commands(ci: Path) -> str:
    """Only the shell inside ci.yml's `run:` blocks, never the whole file.

    A raw substring test over ci.yml counts COMMENTS as invocations: deleting a
    check from its `run:` block while leaving the comment above it kept this
    guard green, the exact false green it exists to prevent. It cuts the other
    way too — a comment naming a local-only script would report a failure that
    is not real. A YAML parse is the honest form.
    """
    # IMPORTED HERE, not at module scope. At module scope the failure fires
    # during import — before the caller has installed its ManifestError handler
    # — so a python3 without PyYAML got a traceback out of the guard and a
    # cascade of unrelated fixture failures out of the two shell suites, in
    # place of one clear prerequisite line. Deferring also keeps every other
    # parser in this module usable without PyYAML at all.
    try:
        import yaml
    except ModuleNotFoundError as exc:
        # Fails rather than degrading: without a YAML parse, CI coverage is NOT
        # checked, and a check that silently skips its own subject is the exact
        # false green the importing guard exists to prevent.
        raise ManifestError(
            "PyYAML is not installed, so ci.yml could not be parsed and CI "
            "coverage was NOT checked (pacman -S python-yaml)"
        ) from exc

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
        raise ManifestError("ci.yml has no `run:` blocks at all")
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
        raise ManifestError(f"{doc.name} has no table introduced by {lead_in!r}")
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
