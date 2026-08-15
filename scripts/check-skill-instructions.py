#!/usr/bin/env python3
"""Assert the `[skill-instructions]` runbooks still decode to text that RUNS.

WHAT BROKE. `vstack.toml`'s `[skill-instructions] linear` block ships the
GitHub-intake mirroring runbook — shell plus a `jq` program — and it was a TOML
BASIC string (`\"\"\"`). TOML processes escapes inside those, so the bytes that
reached the rendered skill were not the bytes in the file: `\\\\s` arrived as
`\\s`, which jq refuses to compile; `\\n` became a real newline mid-string; and
the trailing `\\` line continuations swallowed their newlines, joining commands.
The distributed runbook did not run, and nothing said so — the file looked right,
the skill rendered, and the failure only appeared when someone pasted it.

WHY THIS CHECK ASSERTS THE VALUE AND NOT THE DELIMITER, which is the lesson
worth more than the fix. It used to assert that the block was written as a
LITERAL string. That is a PROXY for "the value came out right", and the proxy
could only be checked by regex over raw TOML, because `tomllib` yields values but
not source spans — the same unsoundness as regex over JS on #133. One assertion,
roughly ten review findings, one of them a genuine SILENT MISS: a same-named key
in another table bound the wrong delimiter, so a basic value passed on a literal
delimiter that was never its own.

`tomllib` hands over the DECODED value, so the check now asserts the property
itself: the shipped runbook still carries the escapes and continuations it needs
to run. No spans, no locator, no tokenizer — that whole finding family is gone
rather than narrowed. The operative rule, when a check keeps producing findings:
ask whether it is asserting a PROXY for the property you care about, and assert
the property instead.

COVERAGE TRADE, known and accepted rather than hidden. This covers the blocks
that ship COMMANDS — `REQUIRED_BLOCKS` — not every block generically.
`project-management` and `reviewer` are prose and are no longer policed for
delimiter style. That is deliberate: generic coverage of prose is what bought ten
findings and a silent miss, and prose has no escapes to lose.

WHAT THE ASSERTIONS ARE DERIVED FROM — what the runbook needs to RUN, not a
byte-for-byte snapshot of its prose, so ordinary edits do not trip them:

  * a regex escape handed to jq must be DOUBLE-backslashed. `sub("\\\\s+$"; "")`
    reaches jq as `\\s` only if the file carries `\\\\s`; a basic string collapses
    it and jq exits 3 on "Invalid escape".
  * `\\n` must still be a two-character ESCAPE. The provenance line is built
    inside a jq string, so a real newline there breaks the program apart.
  * a shell line continuation must still end a line. The `issues create`
    invocation is written across two lines, and a basic string ate the newline
    after the backslash, joining them.

Measured on the two revisions, which is why these three and not others — decoded
`linear` at c40835b7 versus now: doubled `\\\\s` 0 vs 1, bare `\\s` 1 vs 0,
two-character `\\n` 0 vs 4, continuation lines 0 vs 2. The decoded value alone
distinguishes the regression.

COLLECTION POINTS. This file implements the invariant stated in
`.github/instructions/validation-scripts.instructions.md` — a collection step
must assert it collected what it expected; a matcher that comes back empty is a
failure of the check, never a clean result — through `scripts/lib/collected.py`.
One step here collects, and it has its own must-fail control:

1. the `[skill-instructions]` table   `blocks()`   absent, renamed, all-empty or
                                                   not a table is a failure, and
                                                   `linear` is pinned so losing
                                                   just the runbook block cannot
                                                   pass either

The must-fail fixtures run on EVERY invocation rather than behind a flag: this
file exists because a silent degradation shipped, and a control that can be
skipped is the same defect one level up.

Offline and dependency-light: python3 (tomllib, 3.11+) only.
"""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from collected import members_missing, nothing_collected  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]
CONFIG = REPO_ROOT / "vstack.toml"
TABLE = "skill-instructions"

# Blocks that ship COMMANDS, and are therefore checked for escapes surviving.
# Small on purpose — each entry is a runbook whose silent mangling this check
# exists for, and whose absence it could not otherwise distinguish from a clean
# table:
#   linear — the GitHub-intake mirroring runbook.
REQUIRED_BLOCKS = frozenset({"linear"})

# A regex escape that reached the reader with ONE backslash: `\s` not preceded by
# another backslash. jq needs the doubled form, and a TOML basic string is what
# takes one away. Restricted to regex CLASS letters so a shell `\"` or a path
# separator is not mistaken for one.
COLLAPSED_REGEX_ESCAPE = re.compile(r"(?<!\\)\\[sdwSDWbB]")
TWO_CHARACTER_NEWLINE = re.compile(r"\\n")
CONTINUATION_LINE = re.compile(r"(?<!\\)\\$", re.M)


def table_of(text: str) -> object:
    """Whatever tomllib makes of `[skill-instructions]` — not assumed to be a table.

    `[[skill-instructions]]` is valid TOML and produces a LIST, which used to
    reach `.items()` and raise. A shape this check cannot judge is reported by
    `audit`, never crashed on and never skipped.
    """
    return tomllib.loads(text).get(TABLE, {})


def blocks(text: str) -> dict[str, str]:
    """The `[skill-instructions]` values tomllib produces, non-empty ones only."""
    parsed = table_of(text)
    if not isinstance(parsed, dict):
        return {}
    return {k: v for k, v in parsed.items() if isinstance(v, str) and v.strip()}


def survives_decoding(value: str) -> list[str]:
    """Ways a command-bearing block's decoded text would no longer run."""
    problems: list[str] = []
    collapsed = COLLAPSED_REGEX_ESCAPE.findall(value)
    if collapsed:
        problems.append(
            f"its regex escapes reached the reader single-backslashed "
            f"({', '.join(sorted(set(collapsed)))}) — jq needs the DOUBLED form and "
            f"exits 3 on 'Invalid escape'. A TOML basic string is what takes the "
            f"backslash away; write the block as a literal string (''' or ')"
        )
    if not TWO_CHARACTER_NEWLINE.search(value):
        problems.append(
            "it carries no two-character `\\n` escape — the provenance line is built "
            "inside a jq string, so a real newline there breaks the program apart. A "
            "TOML basic string turns each `\\n` into a real newline"
        )
    if not CONTINUATION_LINE.search(value):
        problems.append(
            "no line ends with a shell continuation — the `issues create` invocation "
            "is written across two lines, and a TOML basic string eats the newline "
            "after the backslash and joins them"
        )
    return problems


def audit(
    text: str,
    *,
    source: str,
    required: frozenset[str] = REQUIRED_BLOCKS,
) -> list[str]:
    """Every problem in one `[skill-instructions]` table. Empty means clean."""
    problems: list[str] = []
    try:
        table = blocks(text)
        parsed = table_of(text)
    except tomllib.TOMLDecodeError as exc:
        return [f"{source} is not valid TOML: {exc}"]

    if not isinstance(parsed, dict):
        return [
            f"{source} [{TABLE}] is a {type(parsed).__name__}, not a table — an array of "
            f"tables has no single set of blocks to judge, so nothing here can be "
            f"checked. That is DID NOT RUN, not a pass."
        ]

    # COLLECTION POINT 1 — the table itself. The assertions below run inside a
    # loop over it, so an empty one asserts nothing while the check reports ok.
    absent = nothing_collected(
        table,
        what=f"non-empty [{TABLE}] block",
        selector=f"the [{TABLE}] table in {source}",
        cause="the table is absent, renamed, or every value is empty",
    )
    if absent:
        return [absent]
    # ...and the partial half: a non-empty table says nothing about the block
    # that actually ships the runbook still being there.
    shortfall = members_missing(
        table,
        required,
        what=f"[{TABLE}] blocks",
        selector=f"the [{TABLE}] table in {source}",
        cause="a pinned block that ships a runbook agents paste and run was "
        "deleted or emptied",
    )
    if shortfall:
        problems.append(shortfall)

    for key in sorted(required & table.keys()):
        for problem in survives_decoding(table[key]):
            problems.append(f"{source} [{TABLE}] {key}: {problem}.")
    return problems


# One payload, wrapped two ways. The MANGLED fixture is not hand-written: it is
# the same bytes in a BASIC string, so TOML itself performs the damage — the
# doubled `\\s` collapses, the `\n` escapes become real newlines, and the trailing
# backslash swallows its own line. That keeps the fixture faithful to the
# regression instead of to my idea of it.
RUNBOOK_PAYLOAD = (
    "```bash\n"
    'jq -r \'(.body | sub("\\\\s+$"; "")) + "\\n\\nprovenance"\' "$f" > "$b"\n'
    'tool create --title "x" \\\n'
    '  --description-file "$b"\n'
    "```\n"
)
INTACT_RUNBOOK = f"[{TABLE}]\nlinear = '''\n{RUNBOOK_PAYLOAD}'''\n"
MANGLED_RUNBOOK = f'[{TABLE}]\nlinear = """\n{RUNBOOK_PAYLOAD}"""\n'


def fixture_audit(text: str, **kwargs) -> list[str]:
    """`audit` with the pinned-block requirement waived.

    Some fixtures carry keys other than `linear`, so requiring it would make a
    control fail for a reason unrelated to the thing it proves. The requirement
    has its own controls, driven through `audit`.
    """
    kwargs.setdefault("required", frozenset())
    return audit(text, **kwargs)


def self_test() -> list[str]:
    """The assertions must be able to fail. Runs on every invocation."""
    failures: list[str] = []

    # COLLECTION POINT 1. Each of these returned clean before it existed.
    for case, fixture in (
        ("the table renamed away", "[other-table]\nx = 1\n"),
        ("every value empty", f'[{TABLE}]\nlinear = ""\ndev = ""\n'),
        ("the pinned block emptied", f"[{TABLE}]\nlinear = \"\"\nother = '''\nc\n'''\n"),
        ("an array of tables", f"[[{TABLE}]]\nlinear = '''x'''\n"),
    ):
        if not audit(fixture, source=f"<fixture: {case}>"):
            failures.append(
                f"a [{TABLE}] table with {case} was reported CLEAN. The assertions run "
                f"inside a loop over that table, so an empty one asserts nothing — DID "
                f"NOT RUN, never clean."
            )
    # ...and in ISOLATION: the four above are all caught by the pinned-set guard
    # too, so on their own they cannot show the emptiness guard is live.
    if not fixture_audit("[other-table]\nx = 1\n", source="<fixture: empty, pin waived>"):
        failures.append(
            f"an absent [{TABLE}] table was reported CLEAN with the pinned-block "
            f"requirement waived, so the emptiness guard itself is doing nothing — only "
            f"the pin was, and a table with different keys would pass unexamined."
        )

    # THE REGRESSION, and the point of the rewrite. `MANGLED_RUNBOOK` is written
    # as a LITERAL string, so nothing about its delimiter is wrong — it must fail
    # anyway, on its decoded text, or this check is asserting syntax again. Each
    # lost property is asserted separately so one of them cannot carry the others.
    mangled = audit(MANGLED_RUNBOOK, source="<fixture: mangled runbook>")
    for property_lost, needle in (
        ("collapsed regex escape", "single-backslashed"),
        ("newline escape turned real", "two-character"),
        ("continuation swallowed", "continuation"),
    ):
        if not any(needle in problem for problem in mangled):
            failures.append(
                f"a runbook whose decoded text lost its {property_lost} was accepted, so "
                f"the check no longer notices the thing that stopped it running "
                f"(looked for {needle!r}): {mangled}"
            )
    intact = audit(INTACT_RUNBOOK, source="<fixture: intact runbook>")
    if intact:
        failures.append(
            f"an INTACT runbook was rejected, so the assertions fire on text that runs "
            f"and ordinary edits would trip them: {intact}"
        )
    return failures


def main() -> int:
    problems = self_test()
    if problems:
        print("check-skill-instructions: FAIL (self-test)", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    problems = audit(CONFIG.read_text(encoding="utf-8"), source="vstack.toml")
    if problems:
        print("check-skill-instructions: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    checked = sorted(REQUIRED_BLOCKS & blocks(CONFIG.read_text(encoding="utf-8")).keys())
    print(
        f"check-skill-instructions: ok ({', '.join(checked)} decodes to text that still "
        f"runs; self-test proved a mangled runbook fails even written as a literal string)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
