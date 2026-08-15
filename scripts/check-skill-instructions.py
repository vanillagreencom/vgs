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

WHY THIS FILE HAD A LONG REVIEW TAIL, recorded because the rule outlives the
fix. It hand-parsed TOML with regexes, so every legal spelling the patterns did
not anticipate was a miss — an indented key, a value closing on its assignment
line, an inline comment on the header, a quoted table name, a quoted key — and
each round fixed one while the next found another. The enumeration had no end,
the same unbounded-matcher problem as #133's argv guard and #135's grammar
shapes. It stopped when `tomllib` became the authority: the parser decides what
exists and what a value contains, and the source is read for ONE fact only —
the delimiter — because that is the single thing the parser discards (`a = '''x'''`
and `b = \"\"\"x\"\"\"` both decode to `x`). TOML's key grammar is finite, so matching
it closes; shell and jq spellings are not, which is why that apparatus went to
VGS-156. Answer any future "the check missed spelling X" by asking whether the
PARSER can decide it, not by adding a pattern.

THE LOCATOR IS SUBORDINATE TO THE PARSER, in both directions and as one rule:
every key tomllib reports must be bound to the raw span belonging to THAT KEY'S
TABLE — never skipped, and never satisfied by a same-named key somewhere else.
Anything it cannot bind unambiguously is a loud failure naming the key and its
table. Half a rule was not enough: binding by name alone let another table's
literal delimiter stand in for a BASIC value here, which passed silently while
technically "finding" something. So any spelling tomllib understands is either
bound to its own table and checked, or a clear error — which is why no further
spelling can pass in silence, whatever it turns out to be.

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
from collections.abc import Collection
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from collected import members_missing, nothing_collected  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]
CONFIG = REPO_ROOT / "vstack.toml"
TABLE = "skill-instructions"

# TOML's KEY GRAMMAR, which is finite: a key is bare, basic-quoted or
# literal-quoted, optionally dotted, with whitespace allowed around all of it.
# Matching bare tokens only meant `"linear" = '''x'''` — which tomllib decodes to
# `linear` — could not be located, and a valid literal value failed CI. This is
# an enumeration that CLOSES, unlike the shell and jq spellings that produced
# this file's earlier tail.
BARE_KEY = r"[A-Za-z0-9_-]+"
BASIC_KEY = r'"(?:[^"\\]|\\.)*"'
LITERAL_KEY = r"'[^']*'"
KEY_PART = f"(?:{BARE_KEY}|{BASIC_KEY}|{LITERAL_KEY})"
SINGLE_KEY = re.compile(f"{KEY_PART}$")
ONE_PART = re.compile(KEY_PART)
DOT_SEPARATOR = re.compile(r"\s*\.\s*")
KEY_PATH = rf"{KEY_PART}(?:\s*\.\s*{KEY_PART})*"
# Any line that opens a bracket is a table header or a defect — never ignorable,
# because a header this cannot read makes every later binding go to the wrong
# table. `[[array]]` lands here too and is reported rather than assumed.
OPENS_BRACKET = re.compile(r"\s*\[")
TABLE_HEADER_LINE = re.compile(rf"\s*\[\s*(?P<path>{KEY_PATH})\s*\]\s*(?:#.*)?$")
# An inline table's entries are single-line by definition, so they are readable
# and therefore must be read: an unreachable key is a loud failure, but a
# reachable one should simply be checked.
INLINE_TABLE = re.compile(rf"\s*(?P<key>{KEY_PATH})\s*=\s*\{{(?P<body>.*)\}}\s*(?:#.*)?$")
ASSIGNMENT_ANYWHERE = re.compile(
    rf"(?P<key>{KEY_PATH})\s*=\s*(?P<delim>'''|\"\"\"|'|\")"
)
ASSIGNMENT = re.compile(
    rf"\s*(?P<key>{KEY_PART}(?:\s*\.\s*{KEY_PART})*)\s*=\s*(?P<delim>'''|\"\"\"|'|\")"
)
LITERAL_MULTILINE = "'''"
LITERAL_DELIMITERS = frozenset({LITERAL_MULTILINE, "'"})

# Blocks that must exist AND carry content. Small on purpose — each entry is a
# runbook whose silent removal this check could not otherwise distinguish from a
# clean table:
#   linear — the GitHub-intake mirroring runbook, the block whose TOML mangling
#            this check was written for.
REQUIRED_BLOCKS = frozenset({"linear"})


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


def decode_key(spelling: str) -> str | None:
    """The key TOML means by one key PART, or None if it will not decode.

    The DECODING is tomllib's too, not another hand-rolled unescape: a quoted key
    is handed back to the parser as a one-line document and the key it produces
    is the answer. Raw text is never compared to raw text — `"linear"` and
    `linear` are the same key, and only the parser is entitled to say so.
    """
    if not SINGLE_KEY.fullmatch(spelling):
        return None
    if not spelling.startswith(('"', "'")):
        return spelling
    try:
        return next(iter(tomllib.loads(f"{spelling} = 0")))
    except tomllib.TOMLDecodeError:
        return None


def decode_key_path(spelling: str) -> list[str] | None:
    """Every part of a possibly-dotted key, each decoded, or None.

    `skill-instructions.linear = '''x'''` needs no header, and tomllib nests it
    into exactly the table a header would produce — so the value is already
    right and only the locator could not span it. Reading part-then-separator
    left to right keeps that spelling checked rather than erroring, and keeps
    EVERY part the parser's business: a quoted half is decoded the same way as a
    whole key, so a dot INSIDE a quoted part is content rather than a separator.
    """
    parts: list[str] = []
    position = 0
    while True:
        part = ONE_PART.match(spelling, position)
        if not part:
            return None
        decoded = decode_key(part.group(0))
        if decoded is None:
            return None
        parts.append(decoded)
        position = part.end()
        if position == len(spelling):
            return parts
        separator = DOT_SEPARATOR.match(spelling, position)
        if not separator:
            return None
        position = separator.end()


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


def assignments(text: str, keys: Collection[str]) -> tuple[dict[str, list[str]], list[str]]:
    """Each of `keys` mapped to the delimiters of assignments IN ITS OWN TABLE.

    THE SCAN DOES NOT DECIDE WHAT EXISTS. `keys` is tomllib's own key set, so this
    function's whole job is to locate an assignment tomllib has already reported
    and read the delimiter token after its `=` — the one fact the parser discards.

    BINDING IS BY FULL PATH, and that is the half this file learned last. Matching
    a bare key name anywhere let `[other]`'s `linear` supply the delimiter for the
    checked table's `linear`, so a BASIC value passed on a literal delimiter that
    was never its own. Every assignment's path is therefore built as
    <enclosing table> + <key path> and must equal this table's, so a same-named
    key elsewhere cannot satisfy anything.

    That means the enclosing table has to be tracked again — but under the same
    discipline as everything else here: a line that opens a bracket and does NOT
    parse as a table header is REPORTED, never ignored, because from then on
    every binding would be against the wrong table. Header spellings are read
    with the same finite grammar and the same tomllib decoding as keys, so an
    inline comment, a quoted name and unusual spacing all still pass.

    Inline tables are scanned too (`skill-instructions = { linear = '''x''' }`),
    since their entries are single-line by definition and are otherwise
    unreachable — an unreachable key is a loud failure, but a readable one should
    simply be read.

    Returns (delimiters per key, problems). A LIST per key because the same key
    can legitimately appear twice only if the file says so; two sightings inside
    one table is ambiguity the caller reports rather than resolving.
    """
    found: dict[str, list[str]] = {}
    problems: list[str] = []
    wanted = set(keys)
    lines = text.split("\n")
    table_path: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if OPENS_BRACKET.match(line):
            header = TABLE_HEADER_LINE.match(line)
            decoded = decode_key_path(header.group("path")) if header else None
            if decoded is None:
                problems.append(
                    f"this line opens a table but does not parse as a header, so every "
                    f"key after it would be bound to the wrong table: {line.strip()!r}"
                )
                return found, problems
            table_path = decoded
            index += 1
            continue
        match = ASSIGNMENT.match(line)
        if not match:
            inline = INLINE_TABLE.match(line)
            if inline:
                owner = decode_key_path(inline.group("key"))
                if owner is not None:
                    for entry in ASSIGNMENT_ANYWHERE.finditer(inline.group("body")):
                        entry_path = decode_key_path(entry.group("key"))
                        if entry_path is None:
                            continue
                        full = table_path + owner + entry_path
                        if full[:-1] == [TABLE] and full[-1] in wanted:
                            found.setdefault(full[-1], []).append(entry.group("delim"))
            index += 1
            continue
        path = decode_key_path(match.group("key"))
        delimiter = match.group("delim")
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
        if path is None:
            continue
        full = table_path + path
        if full[:-1] == [TABLE] and full[-1] in wanted:
            found.setdefault(full[-1], []).append(delimiter)
    return found, problems


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

    # OUT OF CONTRACT, decided by the parser rather than by pattern. `blocks()`
    # drops anything that is not a string — silently, until now. This is about
    # the VALUE's shape, not how its key was spelled: a dotted key naming this
    # table is checked like any other, but a value that is a sub-table, a number
    # or a list has no delimiter to judge and must say so rather than vanish.
    for key, value in sorted(parsed.items()):
        if not isinstance(value, str):
            problems.append(
                f"{source} [{TABLE}] {key} is a {type(value).__name__}, not a string — "
                f"this check's contract is one string value per block, and a value of "
                f"that shape has no delimiter to judge. It would otherwise pass "
                f"unexamined."
            )

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

    # The scan is handed tomllib's key set rather than discovering keys itself,
    # so a table header this file cannot parse is no longer a thing that exists.
    written, locator_problems = assignments(text, table)
    # A header the locator cannot read is reported here, not swallowed: every
    # binding after it would be against the wrong table.
    problems.extend(f"{source}: {one}" for one in locator_problems)

    for key in sorted(table):
        # COLLECTION POINT 2 — this key's delimiter. tomllib sees the key, so the
        # scanner must too; without it there is nothing to judge, which is DID
        # NOT RUN for that block rather than a pass.
        seen = written.get(key, [])
        if not seen:
            problems.append(
                nothing_collected(
                    seen,
                    what="delimiter",
                    selector=f"{source} [{TABLE}] {key} in the source scanner",
                    cause="tomllib sees this key but the scanner cannot locate its "
                    "assignment, so the delimiter cannot be judged — fix the scanner",
                )
            )
            continue
        # There was an ambiguity branch here, for a key matched more than once.
        # Binding by full path removed the only way to reach it: two sightings
        # would mean two assignments to the SAME path, which is a duplicate key
        # and a TOMLDecodeError this function has already returned on. A branch
        # whose failure path cannot be reached is what this repo rejects, so it
        # went rather than staying as decoration.
        delimiter = seen[0]

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

# A basic string carrying an escaped delimiter, with an assignment for a REAL key
# inside its body, then that key's actual assignment. TOML does not end the value
# at `\\"""`, so a scanner that stopped there would resume inside the runbook and
# see `after` TWICE. The in-body line wears a real key name deliberately: the scan
# now records only keys tomllib reported, so an invented name would be discarded
# and the fixture would pass either way.
ESCAPED_DELIMITER_FIXTURE = (
    f'[{TABLE}]\nlinear = """\nsays \\""" inside\nafter = "x"\n"""\n'
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
    # Three of these were separate defects before the scan stopped deciding what
    # exists; the last two are here to prove the GENERALISATION rather than three
    # more patterns — neither was ever special-cased, and both work because
    # nothing about the header is read any more.
    shapes = (
        ("an indented key", f"[{TABLE}]\n  linear = '''\nx\n'''\n", {"linear"}),
        ("an indented key closing on its own line", f"[{TABLE}]\n  linear = '''x'''\n", {"linear"}),
        (
            "a value that closes on the assignment line, followed by another key",
            f"[{TABLE}]\nlinear = '''x'''\nreviewer = '''y'''\n",
            {"linear", "reviewer"},
        ),
        ("an inline comment on the header", f"[{TABLE}] # runbooks\nlinear = '''x'''\n", {"linear"}),
        ("a quoted table name", f'["{TABLE}"]\nlinear = \'\'\'x\'\'\'\n', {"linear"}),
        ("tabs around the equals", f"[{TABLE}]\nlinear\t=\t'''x'''\n", {"linear"}),
        ("a basic-quoted key", f'[{TABLE}]\n"linear" = \'\'\'x\'\'\'\n', {"linear"}),
        ("a literal-quoted key", f"[{TABLE}]\n'linear' = '''x'''\n", {"linear"}),
        ("a dotted key and no header", f"{TABLE}.linear = '''x'''\n", {"linear"}),
        ("a dotted key with a quoted part", f'{TABLE}."linear" = \'\'\'x\'\'\'\n', {"linear"}),
    )
    for shape, fixture, expected in shapes:
        reported = fixture_audit(fixture, source=f"<fixture: {shape}>")
        if reported:
            failures.append(
                f"a VALID TOML file with {shape} was rejected — the scanner cannot read "
                f"the shape, so the check fails CI on correct content: {reported}"
            )
        resolved = set(assignments(fixture, blocks(fixture))[0])
        if resolved != expected:
            failures.append(
                f"with {shape} the scanner resolved {sorted(resolved)}, expected "
                f"{sorted(expected)} — a key it cannot see is one it cannot judge."
            )
    # ...and reading a shape must not cost the ability to JUDGE it: the same
    # spellings wearing a BASIC string are still violations.
    for shape, fixture, _ in shapes:
        basic = fixture.replace("'''", '"""')
        if not any(
            "written as a BASIC string" in problem
            for problem in fixture_audit(basic, source=f"<fixture: basic, {shape}>")
        ):
            failures.append(
                f"a BASIC-string key with {shape} was not reported as a delimiter "
                f"violation, so reading the shape was traded for no longer judging it."
            )

    # BINDING BY TABLE, both directions. A same-named key in ANOTHER table must
    # never supply this one's delimiter — that bound a literal delimiter to a
    # BASIC value and let it pass — and the mirror must not fail for the opposite
    # reason. The pair is what proves the fix is binding, not "distrust inline
    # tables".
    inline_basic = f'{TABLE} = {{ linear = """bad""" }}\n[other]\nlinear = ' + "'''good'''\n"
    inline_literal = f"{TABLE} = {{ linear = '''good''' }}\n[other]\nlinear = " + '"""bad"""\n'
    for shape, fixture, want_violation in (
        ("an inline BASIC value beside another table's literal key", inline_basic, True),
        ("an inline LITERAL value beside another table's basic key", inline_literal, False),
    ):
        reported = fixture_audit(fixture, source=f"<fixture: {shape}>")
        violation = any("written as a BASIC string" in problem for problem in reported)
        if violation != want_violation or bool(reported) != want_violation:
            failures.append(
                f"with {shape} the check reported {reported or 'nothing'} — a key must be "
                f"bound to the assignment in ITS OWN table, so the checked value decides "
                f"the verdict and a same-named key elsewhere decides nothing."
            )

    # THE SUBORDINATION INVARIANT: a bracket line the locator cannot read is
    # reported, never ignored — every binding after it would be to the wrong
    # table. `[[other]]` is valid TOML and is exactly that line.
    if not any(
        "does not parse as a header" in problem
        for problem in fixture_audit(
            f"[{TABLE}]\nlinear = '''x'''\n[[other]]\nz = 1\n",
            source="<fixture: unreadable bracket line>",
        )
    ):
        failures.append(
            "a bracket line the locator could not parse was ignored, so every key after "
            "it would be bound to the wrong table without a word. The locator is "
            "subordinate to the parser: it may fail to read something, but never "
            "silently."
        )

    # ...and the table itself may not be a table: `[[skill-instructions]]` is
    # valid TOML, produces a list, and used to raise AttributeError.
    if not any(
        "not a table" in problem
        for problem in fixture_audit(
            f"[[{TABLE}]]\nlinear = '''x'''\n", source="<fixture: array of tables>"
        )
    ):
        failures.append(
            "an array-of-tables spelling of the table was not reported, so a shape with "
            "no single set of blocks either crashes or passes unexamined."
        )

    # Out of contract, and it must SAY so rather than being dropped by the
    # is-it-a-string filter.
    if not any(
        "not a string" in problem
        for problem in fixture_audit(
            f"[{TABLE}]\nlinear = '''x'''\nfoo.bar = '''y'''\n",
            source="<fixture: dotted key>",
        )
    ):
        failures.append(
            "a dotted key under the table was not reported as out of contract, so a "
            "sub-table here passes unexamined — its delimiter is never judged."
        )

    # A same-named key under another table is no longer ambiguous — it simply
    # does not bind — so the checked table's own value decides, and nothing else.
    other_table = f"[other]\nlinear = \"\"\"z\"\"\"\n[{TABLE}]\nlinear = '''x'''\n"
    if fixture_audit(other_table, source="<fixture: same name, other table>"):
        failures.append(
            "a literal value was rejected because another table happens to use the same "
            "key name, so binding is still matching names rather than paths."
        )

    # COLLECTION POINT 2, and the escaped-delimiter scan that serves it.
    escaped = fixture_audit(ESCAPED_DELIMITER_FIXTURE, source="<fixture: escaped delimiter>")
    if not any("linear is written as a BASIC string" in problem for problem in escaped):
        failures.append(
            f"a basic string containing an escaped delimiter was not reported against "
            f"`linear`, so the scan ended early and named the wrong key: {escaped}"
        )
    scanned, _ = assignments(ESCAPED_DELIMITER_FIXTURE, blocks(ESCAPED_DELIMITER_FIXTURE))
    if scanned.get("after") != [LITERAL_MULTILINE]:
        failures.append(
            f"the key after a basic string containing an escaped delimiter resolved to "
            f"{scanned.get('after')}, expected exactly its own literal assignment. More "
            f"than one sighting means the scan ended at the escaped delimiter and read "
            f"the runbook body as source; none means every later key is invisible."
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
