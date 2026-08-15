#!/usr/bin/env python3
"""Assert `[skill-instructions]` runbooks are written as LITERAL TOML strings.

WHAT BROKE. `vstack.toml`'s `[skill-instructions] linear` block ships the
GitHub-intake mirroring runbook — shell plus a `jq` program — and it was a TOML
BASIC string (`\"\"\"`). TOML processes escapes inside those, so the bytes that
reached the rendered skill were not the bytes in the file: `\\\\s` arrived as
`\\s`, which jq refuses to compile; `\\n` became a real newline mid-string; and
the trailing `\\` line continuations swallowed their newlines, joining commands.
The distributed runbook did not run, and nothing said so — the file looked right,
the skill rendered, and the failure only appeared when someone pasted it.

THE ASSERTION. A `[skill-instructions]` key that carries content must be written
as a LITERAL string (`'''` or `'`), never a basic one (`\"\"\"` or `\"`). That is
the invariant itself rather than a symptom of it: a literal string has no escape
processing at all, so the bytes reach the reader exactly as the file shows them,
and no payload can satisfy the rule by accident. Empty values are exempt —
`dev = \"\"` ships nothing, and `\"\"` is the ordinary way to write empty.

SCOPE (VGS-124 → VGS-156). This check also grew fence parsing, jq extraction and
jq compilation, to catch the SYMPTOMS of the mangling. That machinery produced a
P1-class finding on each of five review rounds — all in the fence/jq reader,
none here — so it is split out to VGS-156 to be designed properly, with those
five instances as its acceptance cases. What stays is the piece that pins the
regression and is provable in a few lines: the delimiter assertion alone still
exits 1 on `vstack.toml` at c40835b7, which is what the must-fail control below
asserts.

The byte-identity arm went with it, deliberately: a TOML literal string is
verbatim by specification, so it cannot fire on a value this check accepts —
probed across every literal shape TOML allows, and none of them differ. It was
guarding this file's own span scanner rather than the config, and with the
comparison gone the scanner no longer captures a span to guard.

COLLECTION POINTS. This file implements the invariant stated in
`.github/instructions/validation-scripts.instructions.md` — a collection step
must assert it collected what it expected; a matcher that comes back empty is a
failure of the check, never a clean result — through `scripts/lib/collected.py`.
Two steps here collect something, and each has its own must-fail control:

1. the `[skill-instructions]` table   `blocks()`      absent, renamed or
                                                      all-empty is a failure,
                                                      and `linear` is pinned so
                                                      losing just the runbook
                                                      block cannot pass either
2. each key's delimiter               `assignments()` a key tomllib can see that
                                                      the scanner cannot is a
                                                      failure, not a skip

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

TABLE_HEADER = re.compile(r"\s*\[([^\[\]]+)\]\s*$")
# Leading whitespace allowed: TOML permits an indented key, and anchoring at
# column 0 left a reindented file unjudged.
ASSIGNMENT = re.compile(r"\s*([A-Za-z0-9_-]+)\s*=\s*('''|\"\"\"|'|\")")
LITERAL_DELIMITERS = frozenset({"'''", "'"})

# Blocks that must exist AND carry content. Small on purpose — each entry is a
# runbook whose silent removal this check could not otherwise distinguish from a
# clean table:
#   linear — the GitHub-intake mirroring runbook, the block whose TOML mangling
#            this check was written for.
REQUIRED_BLOCKS = frozenset({"linear"})


def blocks(text: str) -> dict[str, str]:
    """The `[skill-instructions]` values tomllib produces, non-empty ones only."""
    parsed = tomllib.loads(text)
    return {k: v for k, v in parsed.get(TABLE, {}).items() if isinstance(v, str) and v.strip()}


def close_offset(line: str, delimiter: str) -> int:
    """Where `delimiter` closes the value on this line, or -1.

    A LITERAL string has no escapes, so its first occurrence is genuinely the
    close. A BASIC string may carry an escaped `\\\"\"\"` that TOML does NOT treat
    as the end; stopping there would resume scanning inside the value and could
    take a line of runbook text for the next key. Counting the preceding
    backslashes keeps the scan honest on the string kind this check rejects —
    the rejection still has to name the right key.
    """
    at = line.find(delimiter)
    if delimiter != '"""':
        return at
    while at != -1:
        backslashes = 0
        probe = at - 1
        while probe >= 0 and line[probe] == "\\":
            backslashes += 1
            probe -= 1
        if backslashes % 2 == 0:
            return at
        at = line.find(delimiter, at + 1)
    return -1


def closes_here(line: str, delimiter: str) -> bool:
    return close_offset(line, delimiter) != -1


def assignments(text: str) -> dict[str, str]:
    """Every `[skill-instructions]` key mapped to the delimiter it is written with.

    A line scanner rather than a regex over the whole file, for two reasons. It
    tracks the CURRENT TABLE, so a key of the same name under a different table
    cannot be picked up; and it skips over a multi-line string's body, so a line
    inside a runbook that looks like `[a-header]` — or like an assignment —
    cannot be mistaken for one.

    TWO TOML SHAPES IT USED TO MISREAD, both valid and both therefore false
    positives rather than misses — the reconciliation in `audit()` turned each
    into a named failure on correct content, which is the more damaging way for
    a CI check to be wrong:

      * an INDENTED key. TOML allows leading whitespace before a key, and
        matching only at column 0 left a reindented file unjudged.
      * a value that OPENS AND CLOSES on the assignment line
        (`linear = '''x'''`). Scanning forward from the next line consumed the
        following assignments until it met another delimiter, so every key after
        it became unresolvable.
    """
    found: dict[str, str] = {}
    lines = text.split("\n")
    table: str | None = None
    index = 0
    while index < len(lines):
        line = lines[index]
        header = TABLE_HEADER.fullmatch(line)
        if header:
            table = header.group(1)
            index += 1
            continue
        match = ASSIGNMENT.match(line)
        if not match:
            index += 1
            continue
        key, delimiter = match.groups()
        # What follows the OPENING delimiter on this same line. A closer in here
        # ends the value where it sits; only when there is none does the body
        # continue onto the lines below.
        rest = line[match.end() :]
        if delimiter in ("'''", '"""') and close_offset(rest, delimiter) == -1:
            cursor = index + 1
            while cursor < len(lines) and not closes_here(lines[cursor], delimiter):
                cursor += 1
            index = cursor + 1
        else:
            index += 1
        if table == TABLE:
            found[key] = delimiter
    return found


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
    except tomllib.TOMLDecodeError as exc:
        return [f"{source} is not valid TOML: {exc}"]

    # COLLECTION POINT 1 — the table itself. The assertion below runs inside a
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

    written = assignments(text)

    for key in sorted(table):
        # COLLECTION POINT 2 — this key's delimiter. tomllib sees the key, so the
        # scanner must too; without it there is nothing to judge, which is DID
        # NOT RUN for that block rather than a pass.
        delimiter = written.get(key)
        if not delimiter:
            problems.append(
                nothing_collected(
                    [],
                    what="delimiter",
                    selector=f"{source} [{TABLE}] {key} in the source scanner",
                    cause="tomllib sees this key but the scanner does not, so the "
                    "delimiter cannot be judged — fix the scanner",
                )
            )
            continue

        # THE ASSERTION. Not inferred from damage: a basic string that happens to
        # carry no escapes today is one backslash away from silently mangling a
        # runbook, and the whole point is that the mangling is invisible.
        if delimiter not in LITERAL_DELIMITERS:
            problems.append(
                f"{source} [{TABLE}] {key} is written as a BASIC string ({delimiter}), "
                f"which makes TOML process escapes inside it: `\\\\s` reaches the reader "
                f"as `\\s`, `\\n` becomes a real newline, and a trailing `\\` swallows its "
                f"own line. These blocks ship shell and jq verbatim, so use a LITERAL "
                f"string (''' or ') instead."
            )
    return problems


# The pre-fix shape of the linear block, reduced to the delimiter that made it
# mangle. `POST_FIX` is the same bytes written the way this check prescribes, so
# the pair shows the assertion keys on the delimiter and not on the content.
PRE_FIX_FIXTURE = f'[{TABLE}]\nlinear = """\njq -r \'sub("\\\\s+$"; "")\'\n"""\n'
POST_FIX_FIXTURE = PRE_FIX_FIXTURE.replace('"""', "'''")

# A basic string carrying an escaped delimiter, with an assignment-shaped line
# BELOW it, then a real key. TOML does not end the value at `\\"""`, so a scanner
# that stopped there would resume inside the runbook and take `phantom` for a
# key — which is what makes this fixture discriminate rather than merely pass:
# `phantom` is invisible to tomllib, so a scanner that reports it is reading the
# body as source.
ESCAPED_DELIMITER_FIXTURE = (
    f'[{TABLE}]\nlinear = """\nsays \\""" inside\nphantom = "x"\n"""\n'
    "after = '''\ncontent\n'''\n"
)


def fixture_audit(text: str, **kwargs) -> list[str]:
    """`audit` with the pinned-block requirement waived.

    Some fixtures carry keys other than `linear`, so requiring it would make a
    control fail for a reason unrelated to the thing it proves. The requirement
    has its own controls, driven through `audit`.
    """
    kwargs.setdefault("required", frozenset())
    return audit(text, **kwargs)


def self_test() -> list[str]:
    """The assertion must be able to fail. Runs on every invocation."""
    failures: list[str] = []

    # COLLECTION POINT 1. Each of these returned clean before it existed.
    for case, fixture in (
        ("the table renamed away", "[other-table]\nx = 1\n"),
        ("every value empty", f'[{TABLE}]\nlinear = ""\ndev = ""\n'),
        ("the pinned block emptied", f"[{TABLE}]\nlinear = \"\"\nother = '''\nc\n'''\n"),
    ):
        if not audit(fixture, source=f"<fixture: {case}>"):
            failures.append(
                f"a [{TABLE}] table with {case} was reported CLEAN. The assertion runs "
                f"inside a loop over that table, so an empty one asserts nothing — DID "
                f"NOT RUN, never clean."
            )
    # ...and in ISOLATION: the three above are all caught by the pinned-set guard
    # too, so on their own they cannot show the emptiness guard is live.
    if not fixture_audit("[other-table]\nx = 1\n", source="<fixture: empty, pin waived>"):
        failures.append(
            f"an absent [{TABLE}] table was reported CLEAN with the pinned-block "
            f"requirement waived, so the emptiness guard itself is doing nothing — only "
            f"the pin was, and a table with different keys would pass unexamined."
        )

    # THE ASSERTION, both directions.
    if not any(
        "written as a BASIC string" in problem
        for problem in fixture_audit(PRE_FIX_FIXTURE, source="<fixture: pre-fix basic string>")
    ):
        failures.append(
            "the pre-fix basic-string fixture PASSED, so the delimiter assertion is "
            "vacuous and the shape this check exists to catch is not being caught."
        )
    post_fix = fixture_audit(POST_FIX_FIXTURE, source="<fixture: literal string>")
    if post_fix:
        failures.append(
            "the post-fix literal-string fixture FAILED, so the check rejects the very "
            f"form it prescribes: {post_fix}"
        )

    # TOML SHAPES THE SCANNER MUST READ. These are valid files, so the failure
    # direction here is a FALSE POSITIVE — the reconciliation would report the
    # key as unresolvable and fail CI on correct content. Each valid form must
    # audit clean AND resolve every key, since "clean" would also be the answer
    # if the scanner had stopped seeing the table entirely.
    for shape, fixture, expected in (
        ("an indented key", f"[{TABLE}]\n  linear = '''\nx\n'''\n", {"linear"}),
        ("an indented key closing on its own line", f"[{TABLE}]\n  linear = '''x'''\n", {"linear"}),
        (
            "a value that closes on the assignment line, followed by another key",
            f"[{TABLE}]\nlinear = '''x'''\nreviewer = '''y'''\n",
            {"linear", "reviewer"},
        ),
    ):
        reported = fixture_audit(fixture, source=f"<fixture: {shape}>")
        if reported:
            failures.append(
                f"a VALID TOML file with {shape} was rejected — the scanner cannot read "
                f"the shape, so the check fails CI on correct content: {reported}"
            )
        resolved = set(assignments(fixture))
        if resolved != expected:
            failures.append(
                f"with {shape} the scanner resolved {sorted(resolved)}, expected "
                f"{sorted(expected)} — a key it cannot see is one it cannot judge."
            )
    # ...and the fix must not turn a genuine violation into a pass: the same
    # shapes wearing a BASIC string are still violations.
    if not any(
        "written as a BASIC string" in problem
        for problem in fixture_audit(
            f'[{TABLE}]\n  linear = """x"""\n', source="<fixture: indented basic string>"
        )
    ):
        failures.append(
            "an INDENTED basic-string key was not reported as a delimiter violation, so "
            "reading the shape was traded for no longer judging it."
        )

    # COLLECTION POINT 2, and the escaped-delimiter scan that serves it.
    escaped = fixture_audit(ESCAPED_DELIMITER_FIXTURE, source="<fixture: escaped delimiter>")
    if not any("linear is written as a BASIC string" in problem for problem in escaped):
        failures.append(
            f"a basic string containing an escaped delimiter was not reported against "
            f"`linear`, so the scan ended early and named the wrong key: {escaped}"
        )
    scanned = assignments(ESCAPED_DELIMITER_FIXTURE)
    if "after" not in scanned:
        failures.append(
            "the key after a basic string containing an escaped delimiter was not "
            "found, so the scan resumed inside the value and every later key is "
            "invisible — DID NOT RUN for all of them."
        )
    if "phantom" in scanned:
        failures.append(
            "an assignment-shaped line INSIDE a basic string was taken for a key, so "
            "the scan ended at an escaped delimiter and is reading runbook text as "
            "source — every judgement below it is about the wrong thing."
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

    count = len(blocks(CONFIG.read_text(encoding="utf-8")))
    print(
        f"check-skill-instructions: ok ({count} [{TABLE}] block(s) are literal strings; "
        f"self-test proved the assertion fails on the pre-fix form)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
