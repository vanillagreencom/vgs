#!/usr/bin/env python3
"""Assert the `[skill-instructions]` runbooks survive TOML parsing intact.

WHAT BROKE. `vstack.toml`'s `[skill-instructions] linear` block ships the
GitHub-intake mirroring runbook — shell plus a `jq` program — and it was a TOML
BASIC string (`\"\"\"`). TOML processes escapes inside those, so the bytes that
reached the rendered skill were not the bytes in the file: `\\\\s` arrived as
`\\s`, which jq refuses to compile ("Invalid escape", exit 3); `\\n` became a
real newline mid-string; and the trailing `\\` line continuations swallowed
their newlines, joining commands. The distributed runbook did not run, and
nothing said so — the file looked right, the skill rendered, and the failure
only appeared when someone pasted the command.

The fix is a LITERAL string (`'''`), which passes bytes through untouched. This
check pins it, because a later edit back to `\"\"\"` would look harmless in
review and ship the broken runbook again with CI green.

FOUR ARMS. The first states the rule; the rest are independent signals that the
rule is doing its job.

1. DELIMITER. A block carrying content must be written as a LITERAL string
   (`'''` or `'`), never a basic one (`\"\"\"` or `\"`). This is the invariant
   itself — these blocks ship shell and jq verbatim — so it cannot be satisfied
   by accident. Empty values are exempt: `dev = \"\"` ships nothing, and `\"\"` is
   the ordinary way to write empty.
2. IDENTITY. The parsed value must equal that key's OWN raw span, byte for byte.
   Kept as a second signal, and scoped to the key rather than searched for
   anywhere in the file: a whole-file substring test is a PROXY, and a value
   mangled only by backslash collapsing can still be found somewhere in its own
   raw source (`\\\\s` contains `\\s` from its second backslash). The self-test
   pins that exact case.
3. JQ COMPILES. Every `jq` program in a fenced block must compile. Judged on
   jq's COMPILE status (3) alone: running a filter with no input exits 5, and
   treating that as a break would make the arm fail on correct programs. Bounded
   by a timeout, because `jq -n` runs what it compiles.
4. CONTINUATIONS SURVIVE. A block's parsed text must carry as many trailing-`\\`
   continuation lines as its raw text. That was the second thing basic strings
   ate, and unlike the jq breakage it produces valid shell — `bash -n` is happy
   with the joined command — so nothing else would notice.

The must-fail fixtures run on EVERY invocation rather than behind a --self-test
flag: this file exists because a silent degradation shipped, and a control that
can be skipped is the same defect one level up. Each fixture states which arm it
proves, and the pre-fix basic-string form is exercised in full, so the arms are
shown able to FAIL and not merely to pass.

COLLECTION POINTS. This file implements the invariant stated in
`.github/instructions/validation-scripts.instructions.md` — a collection step
must assert it collected what it expected; a matcher that comes back empty is a
failure of the check, never a clean result — through `scripts/lib/collected.py`.
Four steps here collect something, and each has its own must-fail control. Add a
new one the same way, or it becomes the fifth instance:

1. the `[skill-instructions]` table          `blocks()`      + pinned members
2. the fenced blocks inside a value          `FENCE`         + a pinned block's
                                                               fences must exist
3. the jq occurrences inside a fence         `jq_programs()` partitioned, and the
                                                               parts are counted
                                                               against the whole
4. a key's raw span between its delimiters   `assignments()` unresolved is a
                                                               named failure

Offline and dependency-light: python3 (tomllib, 3.11+) and jq, both already
required by this repo's other checks.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from collected import members_missing, nothing_collected, unaccounted  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]
CONFIG = REPO_ROOT / "vstack.toml"
TABLE = "skill-instructions"

JQ_COMPILE_ERROR = 3

# `jq -n PROGRAM` is the only way to reach the compiler, and it RUNS the program
# once it compiles. A syntactically valid filter can loop forever (`while(true;
# .)`), so an unbounded call would wedge this check, the `docs` area, and the CI
# job it is wired into — on hostile content in the very file it exists to police.
# Bounded instead, and a program that outlives the bound is a FAILURE, never a
# pass. Five seconds is enormous for a runbook one-liner (these compile and run
# in milliseconds) and short enough that a stall cannot matter; the fixture that
# proves the path uses a far shorter bound, since a non-terminating program
# trips any bound and there is no reason to spend five seconds proving it.
JQ_TIMEOUT_SECONDS = 5.0
JQ_FIXTURE_TIMEOUT_SECONDS = 0.5

# EVERY fenced block, whatever its info string. Enumerating language tags is the
# same trap one level down: the pattern used to accept `bash`, `sh` and bare, so
# a block fenced ```shell yielded ZERO spans, arm 3 never ran on it, and an
# invalid filter inside it audited clean. Collect them all and filter afterwards
# — a spelling nobody predicted then shows up instead of disappearing.
FENCE = re.compile(r"^```[^\n]*\n(.*?)^```", re.M | re.S)
FENCE_OPENING = re.compile(r"^```", re.M)
CONTINUATION = re.compile(r"(?<!\\)\\$", re.M)

# Shell line continuations are JOINED before any jq invocation is looked for.
# The previous pattern was anchored to a single line, so `jq -r \` + newline +
# `'…'` collected NOTHING, the compile loop never ran, and arm 3 passed on an
# invalid filter — the check written to prove a runbook renders, defeated by the
# very continuations TOML basic strings ate. Normalising first removes the class
# rather than widening one regex against it.
CONTINUATION_JOIN = re.compile(r"\\\n\s*")
JQ_TOKEN = re.compile(r"\bjq\b")
# `"$VAR"`, `$VAR`, `"${VAR}"` — a program held in a shell variable, and the ONE
# spelling that genuinely cannot be checked from the text: its value is not here.
SHELL_VARIABLE = re.compile(r"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$")
# An UNESCAPED expansion. `\$` inside double quotes is a literal dollar the shell
# hands straight to jq, so treating it as an expansion would refuse a filter that
# is perfectly readable.
EXPANSION = re.compile(r"(?<!\\)[$`]")
# What the shell strips from a "..."-quoted word: a backslash is special there
# only before these. Everything else keeps its backslash, which matters because
# jq's own regex escapes (`\\s`) travel through untouched.
DOUBLE_QUOTE_ESCAPE = re.compile(r"\\([$`\"\\])")


def closing_quote(text: str, start: int, quote: str) -> int:
    """Index of the quote that closes a shell-quoted run, or -1.

    The two quotes differ, and the difference is the whole point. Inside DOUBLE
    quotes a backslash escapes the next character, so a naive search for the next
    `"` stops at the first `\\"` and truncates the filter — which compiled the
    wrong text and REJECTED a valid runbook. Inside SINGLE quotes POSIX defines
    no escape at all: a single quote cannot appear in a single-quoted string by
    any spelling, so the first one genuinely is the close and that path stays a
    plain search.
    """
    if quote == "'":
        return text.find(quote, start)
    index = start
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == quote:
            return index
        index += 1
    return -1


def as_jq_receives_it(program: str, quote: str) -> str:
    """The program text the shell actually hands jq.

    Only double quotes transform anything. Compiling the raw span instead was
    the second half of the same false positive: `sub(\\"x\\"; \\"y\\")` does not
    compile with its backslashes intact, but the shell removes them before jq
    ever sees it, so the check must too or it fails valid content.
    """
    if quote != '"':
        return program
    return DOUBLE_QUOTE_ESCAPE.sub(r"\1", program)


def jq_programs(fenced: str) -> tuple[list[str], list[str], list[str]]:
    """(programs, invocations this cannot read, exempt invocations) from a block.

    ALL THREE literal spellings are compiled — single-quoted, double-quoted and
    unquoted. The reader used to take single-quoted only, so `jq -r .title` (which
    this repo's own runbook writes) added neither a program nor a complaint: the
    arm asserted nothing while the check still claimed every jq program compiles.
    Mutating that filter to `.[` left the audit clean.

    NOTHING IS DROPPED, and the third list is what makes that structural rather
    than careful. Every `jq` token lands in exactly one of the three, so the
    caller can assert programs + unreadable + exempt == tokens seen; a future
    branch that forgets to record an occurrence fails that accounting instead of
    going quiet. Reporting is the default and `exempt` is the one sanctioned
    silence: a program held in a shell variable, whose text is not in the file to
    compile. A double-quoted program carrying an expansion among OTHER text is
    reported instead, since it is visibly a filter this cannot resolve.

    Option parsing is deliberately shallow: leading `-`-prefixed tokens are
    skipped and the next token is the filter. A value-taking option (`--arg x y`)
    would make the value look like the filter — none is used here, and the result
    would be a LOUD false failure rather than a silent miss, which is the right
    direction to be wrong in.
    """
    programs: list[str] = []
    unreadable: list[str] = []
    exempt: list[str] = []
    joined = CONTINUATION_JOIN.sub(" ", fenced)
    position = 0
    while token := JQ_TOKEN.search(joined, position):
        command_end = joined.find("\n", token.end())
        if command_end == -1:
            command_end = len(joined)
        cursor = token.end()

        # Skip this invocation's options to reach its filter.
        while cursor < command_end:
            while cursor < command_end and joined[cursor].isspace():
                cursor += 1
            if cursor < command_end and joined[cursor] == "-":
                while cursor < command_end and not joined[cursor].isspace():
                    cursor += 1
                continue
            break

        if cursor >= command_end:
            unreadable.append(joined[token.start() : command_end].strip())
            position = command_end + 1
            continue

        quote = joined[cursor]
        quoting = quote
        if quote in "'\"":
            # A quoted body may span real newlines — a shell quoted string keeps
            # them, and a TOML-mangled block is where they turn up — so the close
            # is searched past `command_end`.
            closing = closing_quote(joined, cursor + 1, quote)
            if closing == -1:
                unreadable.append(joined[token.start() : command_end].strip())
                break
            program = joined[cursor + 1 : closing]
            position = closing + 1
            if quote == '"' and EXPANSION.search(program):
                occurrence = joined[token.start() : command_end].strip()
                if SHELL_VARIABLE.match(program):
                    exempt.append(occurrence)
                else:
                    unreadable.append(occurrence)
                continue
        else:
            end = cursor
            while end < command_end and not joined[end].isspace():
                end += 1
            program = joined[cursor:end]
            position = end
            if EXPANSION.search(program):
                occurrence = joined[token.start() : command_end].strip()
                if SHELL_VARIABLE.match(program):
                    exempt.append(occurrence)
                else:
                    unreadable.append(occurrence)
                continue
            quoting = "unquoted"
        # Compile what jq RECEIVES, not the bytes between the quotes: inside
        # double quotes the shell strips the escapes first, and handing jq the
        # raw span rejected valid filters.
        programs.append(as_jq_receives_it(program, quoting))
    return programs, unreadable, exempt


def blocks(text: str) -> dict[str, str]:
    """The `[skill-instructions]` values tomllib produces, non-empty ones only."""
    parsed = tomllib.loads(text)
    return {k: v for k, v in parsed.get(TABLE, {}).items() if isinstance(v, str) and v.strip()}


TABLE_HEADER = re.compile(r"\s*\[([^\[\]]+)\]\s*$")
ASSIGNMENT = re.compile(r"([A-Za-z0-9_-]+)\s*=\s*('''|\"\"\"|'|\")")
LITERAL_DELIMITERS = frozenset({"'''", "'"})


def close_offset(line: str, delimiter: str) -> int:
    """Where `delimiter` closes the value on this line, or -1.

    A LITERAL string has no escapes, so its first occurrence is genuinely the
    close. A BASIC string may carry an escaped `\\\"\"\"` that TOML does NOT treat
    as the end, and taking it would truncate the span — producing a false
    identity failure, or hiding a continuation loss, on the one string kind where
    those arms have work to do. Counting the preceding backslashes is four lines
    and keeps every arm live on basic strings; skipping the comparison there
    instead would have made both arms unreachable, since a literal string never
    mangles and so can never fail them.
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


def assignments(text: str) -> dict[str, tuple[str, str]]:
    """Every `[skill-instructions]` key mapped to its (delimiter, raw span).

    A line scanner rather than a regex over the whole file, for two reasons the
    review asked about. It tracks the CURRENT TABLE, so a key of the same name
    under a different table cannot be picked up; and it skips over a multi-line
    string's body, so a line inside a runbook that looks like `[a-header]` cannot
    be mistaken for one. The raw span is sliced between the delimiters, with
    TOML's rule that a newline immediately after an opening `'''`/`\"\"\"` is not
    part of the value — which is what lets arm 2 compare it to the parsed value
    byte for byte.
    """
    found: dict[str, tuple[str, str]] = {}
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
        rest = line[match.end():]
        if delimiter in ("'''", '"""'):
            body: list[str] = []
            cursor = index + 1
            while cursor < len(lines) and not closes_here(lines[cursor], delimiter):
                body.append(lines[cursor])
                cursor += 1
            # A closing delimiter may trail content on its own line; keep that
            # content, or the span would be short and arm 2 would fire falsely.
            if cursor < len(lines):
                prefix = lines[cursor][: close_offset(lines[cursor], delimiter)]
                if prefix:
                    body.append(prefix)
                    raw = "\n".join(body)
                else:
                    raw = "".join(f"{one}\n" for one in body)
            else:
                raw = "\n".join(body)
            if rest:  # content on the opening line, which TOML keeps
                raw = f"{rest}\n{raw}"
            index = cursor + 1
        else:
            end = rest.find(delimiter)
            raw = rest[:end] if end != -1 else rest
            index += 1
        if table == TABLE:
            found[key] = (delimiter, raw)
    return found


# Blocks that must exist AND carry content. Small on purpose — each entry is a
# runbook whose silent removal this check could not otherwise distinguish from a
# clean table:
#   linear — the GitHub-intake mirroring runbook, the block whose TOML mangling
#            this whole check was written for.
REQUIRED_BLOCKS = frozenset({"linear"})


def jq_available() -> bool:
    return shutil.which("jq") is not None


def audit(
    text: str,
    *,
    source: str,
    jq_timeout: float = JQ_TIMEOUT_SECONDS,
    required: frozenset[str] = REQUIRED_BLOCKS,
) -> list[str]:
    """Every problem in one `[skill-instructions]` table. Empty means clean."""
    problems: list[str] = []
    try:
        table = blocks(text)
    except tomllib.TOMLDecodeError as exc:
        return [f"{source} is not valid TOML: {exc}"]

    # COLLECTION POINT 1 — the table itself. Every arm below runs inside a loop
    # over it, so an empty one made all four assert nothing while the check
    # printed "ok (0 blocks)".
    absent = nothing_collected(
        table,
        what=f"non-empty [{TABLE}] block",
        selector=f"the [{TABLE}] table in {source}",
        cause="the table is absent, renamed, or every value is empty",
    )
    if absent:
        return [absent]
    # ...and the partial half: the table being non-empty says nothing about the
    # block that actually ships the runbook still being there.
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

    for key, value in sorted(table.items()):
        delimiter, raw = written.get(key, ("", ""))
        # COLLECTION POINT 4 — this key's raw span. tomllib sees the key, so the
        # source scanner must too; an unresolved span means neither the delimiter
        # nor the identity arm can judge the block, which is DID NOT RUN for it.
        if not delimiter:
            problems.append(
                nothing_collected(
                    [],
                    what="raw span",
                    selector=f"{source} [{TABLE}] {key} in the source scanner",
                    cause="tomllib sees this key but the scanner does not, so the "
                    "delimiter and identity arms cannot judge it — fix the scanner",
                )
            )
            continue

        # --- arm 1: the invariant, asserted directly ------------------------
        # Not inferred from damage: a basic string that happens to carry no
        # escapes today is one backslash away from silently mangling a runbook,
        # and the whole point of this check is that the mangling is invisible.
        # Empty values are exempt because `""` ships nothing and is the ordinary
        # way to write empty; `blocks()` filters them out before this loop.
        if delimiter not in LITERAL_DELIMITERS:
            problems.append(
                f"{source} [{TABLE}] {key} is written as a BASIC string ({delimiter}), "
                f"which makes TOML process escapes inside it: `\\\\s` reaches the reader "
                f"as `\\s`, `\\n` becomes a real newline, and a trailing `\\` swallows its "
                f"own line. These blocks ship shell and jq verbatim, so use a LITERAL "
                f"string (''' or ') instead."
            )

        # --- arm 2: identity against THIS key's own raw span ----------------
        if value != raw:
            problems.append(
                f"{source} [{TABLE}] {key}: the parsed value is not byte-identical to the "
                f"source between its delimiters, so the parser transformed it on the way "
                f"through. Whatever a reader runs is not what this file shows."
            )

        # --- arm 4: shell line continuations --------------------------------
        raw_continuations = len(CONTINUATION.findall(raw))
        parsed_continuations = len(CONTINUATION.findall(value))
        if raw_continuations > parsed_continuations:
            problems.append(
                f"{source} [{TABLE}] {key}: {raw_continuations} shell line continuation(s) "
                f"in the source, {parsed_continuations} in the parsed value — TOML ate the "
                f"newline after a trailing backslash and joined the commands. The result is "
                f"still valid shell, so no syntax check would catch it."
            )

        # --- arm 3: every jq program compiles -------------------------------
        #
        # COLLECTION POINT 2 — the fenced blocks. The tag-enumerating pattern
        # returned no spans for a ```shell block, so this whole arm skipped it.
        # Every fence is collected now, and the count is checked against the
        # opening fences in the value: a value with fences that yields no spans
        # means the pattern stopped matching, not that there is nothing to check.
        fences = FENCE.findall(value)
        openings = len(FENCE_OPENING.findall(value)) // 2
        if openings:
            unmatched = unaccounted(
                openings,
                {"collected": fences},
                what="fenced block(s)",
                selector=f"the fence pattern in {source} [{TABLE}] {key}",
            )
            if unmatched:
                problems.append(unmatched)
        elif key in required:
            # ...and a pinned block with NO fences at all. `linear` ships a
            # runbook, so a value that has lost its fences is DID NOT RUN, not
            # nothing-to-do. Scoped to the pinned blocks on purpose:
            # project-management and reviewer are prose and legitimately carry
            # none, so requiring fences of every block would fail them.
            problems.append(
                nothing_collected(
                    fences,
                    what="fenced block",
                    selector=f"{source} [{TABLE}] {key}",
                    cause="a pinned block ships a runbook, so losing its fences means "
                    "the jq arm has nothing to examine rather than nothing to find",
                )
            )
        for fenced in fences:
            # COLLECTION POINT 3 — the jq occurrences inside one fence, PARTITIONED
            # rather than filtered: every token lands in exactly one of the three,
            # and counting the parts against the whole is what makes a dropped
            # occurrence impossible instead of merely unlikely.
            programs, unreadable, exempt = jq_programs(fenced)
            dropped = unaccounted(
                len(JQ_TOKEN.findall(CONTINUATION_JOIN.sub(" ", fenced))),
                {"compiled": programs, "unreadable": unreadable, "exempt": exempt},
                what="jq occurrence(s)",
                selector=f"a fenced block in {source} [{TABLE}] {key}",
            )
            if dropped:
                problems.append(dropped)
            for line in unreadable:
                problems.append(
                    f"{source} [{TABLE}] {key}: this jq invocation carries a quoted "
                    f"program that could not be extracted, so nothing was compiled for "
                    f"it and the arm asserted nothing about it. Fix the reader in "
                    f"jq_programs() rather than leaving the occurrence unchecked. "
                    f"Line: {line}"
                )
            for program in programs:
                try:
                    completed = subprocess.run(
                        ["jq", "-n", program],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE,
                        text=True,
                        timeout=jq_timeout,
                    )
                except subprocess.TimeoutExpired:
                    problems.append(
                        f"{source} [{TABLE}] {key}: a jq program did not terminate within "
                        f"{jq_timeout:g}s and was killed. It compiles, so this is not a "
                        f"syntax break — the program itself does not finish, which would "
                        f"hang anyone who ran this runbook and would hang this check. "
                        f"Program: {program}"
                    )
                    continue
                if completed.returncode == JQ_COMPILE_ERROR:
                    detail = completed.stderr.strip().splitlines()
                    first = detail[0] if detail else "(no diagnostic)"
                    problems.append(
                        f"{source} [{TABLE}] {key}: a jq program does not compile — {first}. "
                        f"Program: {program}"
                    )
    return problems


# Two fixtures, each naming the arm it proves. The broken one is the literal
# pre-fix shape of the linear block, reduced to the three things that broke.
BROKEN_FIXTURE = '''[skill-instructions]
demo = """
```bash
gh issue view 1 --json title,body,url > "$f"
jq -r '(.body | sub("\\\\s+$"; "")) + "\\n\\nprovenance"' "$f" > "$b"
tool create --title "x" \\
  --description-file "$b"
```
"""
'''

FIXED_FIXTURE = BROKEN_FIXTURE.replace('demo = """', "demo = '''").replace('"""\n', "'''\n", 1)

# A block that is correct in every other respect — literal string, no
# continuations to lose — carrying a jq program that COMPILES and then never
# finishes. Isolated deliberately: if this fixture also tripped another arm, the
# control could pass without the timeout path ever running.
HANGING_FIXTURE = """[skill-instructions]
demo = '''
```bash
jq -n 'while(true; .)'
```
'''
"""


def literal_block(command: str) -> str:
    """A correct block — literal string, one fenced command — around `command`.

    So a control isolates the arm it is for: nothing else in the fixture can trip
    a different arm and let it pass for the wrong reason.
    """
    return f"[skill-instructions]\ndemo = '''\n```bash\n{command}\n```\n'''\n"


# One per literal spelling, each carrying the SAME invalid filter, so a spelling
# the reader stops handling shows up as that spelling going quiet. The unquoted
# one is the shape this repo's own runbook writes — `jq -r .title "$f"` inside a
# command substitution — which is exactly the occurrence the reader used to drop.
INVALID_FILTER_FIXTURES = (
    ("unquoted", 'tool create --title "$(jq -r .[ "$gh_json")"'),
    ("double-quoted", 'jq -r ".[" "$f"'),
    ("single-quoted", "jq -r '.[' \"$f\""),
)

# An escaped `\"""` inside a BASIC string. TOML does not end the value there, so
# a scanner that stops at the first delimiter substring truncates the span — and
# then reports a difference it manufactured rather than the one TOML made.
ESCAPED_DELIMITER_FIXTURE = '[skill-instructions]\ndemo = """\nsays \\""" inside\n"""\n'
ESCAPED_DELIMITER_SPAN = 'says \\""" inside\n'

# The case a whole-file substring test cannot see. Its ONLY escape damage is
# backslash collapsing, and the parsed value (`\\s`) really is a substring of its
# own raw source (`\\\\s`, from the second backslash on) — so the proxy reports
# clean while the block is mangled. This is why arm 1 asserts the delimiter and
# arm 2 compares against the key's own span. Deliberately carries no jq
# invocation and no continuation, so only those two arms can catch it.
COLLAPSE_ONLY_FIXTURE = '[skill-instructions]\ndemo = """\n\\\\s\n"""\n'

# The same bytes written correctly, so the fixture above is shown to be about the
# delimiter rather than about its content.
COLLAPSE_ONLY_FIXED = COLLAPSE_ONLY_FIXTURE.replace('"""', "'''")

# What tomllib makes of the mangled fixture, computed once so the self-test can
# state the premise (`value in raw_file`) rather than assume it.
COLLAPSE_ONLY_VALUE = tomllib.loads(COLLAPSE_ONLY_FIXTURE)[TABLE]["demo"]

# A CORRECT block — literal string, continuations intact — whose jq invocation is
# split across a shell line continuation and whose filter does not compile. The
# line-anchored reader collected nothing here, so the compile loop never ran and
# this fixture PASSED: a check that proves runbooks render, silently broken by
# the same continuations the runbook fix was about. Nothing else can catch it,
# which is what makes it the control for arm 3's reader rather than for jq.
MULTILINE_JQ_FIXTURE = (
    "[skill-instructions]\n"
    "demo = '''\n"
    "```bash\n"
    "jq -r \\\n"
    "  'sub(\"\\s\"; \"\")' \"$f\"\n"
    "```\n"
    "'''\n"
)


def fixture_audit(text: str, **kwargs) -> list[str]:
    """`audit` with the pinned-block requirement waived.

    Fixtures carry one `demo` key, so requiring `linear` would make every control
    fail for a reason that has nothing to do with the arm it is proving. The
    requirement itself gets its own controls below, driven through `audit`.
    """
    kwargs.setdefault("required", frozenset())
    return audit(text, **kwargs)


def self_test() -> list[str]:
    """The arms must be able to fail. Runs on every invocation, never optional."""
    failures: list[str] = []

    # THE RULE THIS FILE PUBLISHES, APPLIED TO ITSELF. Each of these returned
    # clean before: the table renamed away, every value emptied, and the pinned
    # block emptied while the rest of the table stayed fine.
    for case, fixture in (
        ("the table renamed away", "[other-table]\nx = 1\n"),
        ("every value empty", f"[{TABLE}]\nlinear = \"\"\ndev = \"\"\n"),
        (
            "the pinned block emptied",
            f"[{TABLE}]\nlinear = \"\"\nother = '''\ncontent\n'''\n",
        ),
    ):
        if not audit(fixture, source=f"<fixture: {case}>"):
            failures.append(
                f"a [{TABLE}] table with {case} was reported CLEAN. Every arm lives in "
                f"a loop over that table, so an empty one asserts nothing — DID NOT RUN, "
                f"never clean, which is the rule this check publishes."
            )

    # COLLECTION POINT 1 in ISOLATION. The three cases above are all caught by
    # the pinned-set guard as well, so on their own they cannot prove the
    # emptiness guard is live. With the pin waived, only that guard is left.
    if not fixture_audit("[other-table]\nx = 1\n", source="<fixture: empty, pin waived>"):
        failures.append(
            f"an absent [{TABLE}] table was reported CLEAN with the pinned-block "
            f"requirement waived, so the emptiness guard itself is not doing anything — "
            f"only the pin was, and a table with different keys would pass unexamined."
        )

    broken = fixture_audit(BROKEN_FIXTURE, source="<fixture: pre-fix basic string>")
    if not broken:
        failures.append(
            "the pre-fix basic-string fixture PASSED. Every arm is vacuous: the shape "
            "this check exists to catch is not being caught."
        )
    else:
        for arm, needle in (
            ("delimiter", "written as a BASIC string"),
            ("identity", "not byte-identical"),
            ("jq compiles", "does not compile"),
            ("continuations", "line continuation"),
        ):
            if not any(needle in problem for problem in broken):
                failures.append(
                    f"the pre-fix fixture did not trip the `{arm}` arm, so that arm is "
                    f"not shown able to fail (looked for {needle!r})."
                )

    fixed = fixture_audit(FIXED_FIXTURE, source="<fixture: literal string>")
    if fixed:
        failures.append(
            "the post-fix literal-string fixture FAILED, so the check rejects the very "
            f"form it prescribes: {fixed}"
        )

    # COLLECTION POINT 2's control — a fence whose info string nobody enumerated.
    # Under the tag-matching pattern each of these yielded zero spans, so the jq
    # arm skipped the block entirely and an invalid filter audited clean.
    for tag in ("shell", "zsh", "console"):
        other_fence = literal_block("jq -r '.[' \"$f\"").replace("```bash", f"```{tag}", 1)
        if not any(
            "does not compile" in problem
            for problem in fixture_audit(other_fence, source=f"<fixture: ```{tag} fence>")
        ):
            failures.append(
                f"a block fenced ```{tag} was not examined by the jq arm, so an "
                f"unenumerated fence spelling removes a block from this check silently."
            )

    # COLLECTION POINT 2's second control — a PINNED block that has lost its
    # fences. Zero fences is did-not-run for a block that ships a runbook, and it
    # audited clean until this was added.
    fenceless = f"[{TABLE}]\nlinear = '''\nprose only\n'''\n"
    if not any(
        "no fenced block matched" in problem
        for problem in audit(fenceless, source="<fixture: pinned block, no fences>")
    ):
        failures.append(
            "a pinned block with no fenced block at all was accepted, so a runbook "
            "value that lost its fences is indistinguishable from one with nothing "
            "to check."
        )
    # ...and the same shape must NOT fire on the prose blocks that legitimately
    # carry no fences, or the check fails the real file.
    prose = f"[{TABLE}]\nlinear = '''\n```bash\njq -r .a f\n```\n'''\nreviewer = '''\nprose\n'''\n"
    if any(
        "no fenced block matched" in problem
        for problem in audit(prose, source="<fixture: unpinned prose block>")
    ):
        failures.append(
            "an unpinned prose block was required to carry fences, which would fail "
            "project-management and reviewer in the real file."
        )

    # ESCAPED QUOTES, BOTH DIRECTIONS. This is the one defect class on this file
    # that pointed the other way: every other was a silent skip, but truncating a
    # double-quoted filter at its first `\"` REJECTED valid content, which is
    # worse in a check that gates CI. So the pair matters — widening alone would
    # trade a false positive for a silent miss.
    escaped_ok = 'jq -r "sub(\\"x\\"; \\"y\\")" f.json'
    reported = fixture_audit(literal_block(escaped_ok), source="<fixture: escaped quotes, valid>")
    if reported:
        failures.append(
            f"a valid double-quoted jq filter containing escaped quotes was rejected — "
            f"the closing-quote scan or the unescaping is truncating it: {reported}"
        )
    # ...and it must have been COMPILED, not quietly skipped: a blanket skip of
    # the double-quoted case would also make the line above pass.
    compiled, _, _ = jq_programs(escaped_ok + "\n")
    if compiled != ['sub("x"; "y")']:
        failures.append(
            f"the escaped-quote filter was not handed to jq as the shell would hand "
            f"it: got {compiled!r}, expected the unescaped ['sub(\"x\"; \"y\")']. "
            f"Passing it clean by skipping it is not the fix."
        )
    escaped_bad = 'jq -r "sub(\\"x\\"; \\"y\\"" f.json'
    if not any(
        "does not compile" in problem
        for problem in fixture_audit(
            literal_block(escaped_bad), source="<fixture: escaped quotes, invalid>"
        )
    ):
        failures.append(
            "an INVALID double-quoted jq filter containing escaped quotes was not "
            "caught, so honouring the escapes turned a false positive into a miss."
        )

    # COLLECTION POINT 3's control — every jq occurrence lands in exactly one of
    # the three lists. Driven on the reader itself, since that accounting is what
    # makes a forgotten branch impossible rather than merely unlikely.
    accounting_fence = "jq -r '.a' f\njq -r \"$PROGRAM\" f\njq -r 'unterminated\n"
    got_programs, got_unreadable, got_exempt = jq_programs(accounting_fence)
    tokens = len(JQ_TOKEN.findall(CONTINUATION_JOIN.sub(" ", accounting_fence)))
    if tokens != len(got_programs) + len(got_unreadable) + len(got_exempt):
        failures.append(
            f"jq_programs dropped an occurrence: {tokens} jq token(s) in, "
            f"{len(got_programs)} program(s) + {len(got_unreadable)} unreadable + "
            f"{len(got_exempt)} exempt out. Every occurrence must be accounted for."
        )

    # THE PROXY'S BLIND SPOT, pinned. First the premise — the old whole-file
    # substring test really would have called this clean — then that both
    # value-level arms catch it anyway.
    if COLLAPSE_ONLY_VALUE not in COLLAPSE_ONLY_FIXTURE:
        failures.append(
            "the backslash-collapse fixture no longer demonstrates the gap it exists "
            "for: its parsed value is not a substring of its raw source, so it would "
            "have failed the old proxy too and proves nothing about the new arms."
        )
    collapsed = fixture_audit(COLLAPSE_ONLY_FIXTURE, source="<fixture: backslash collapse only>")
    for arm, needle in (
        ("delimiter", "written as a BASIC string"),
        ("identity", "not byte-identical"),
    ):
        if not any(needle in problem for problem in collapsed):
            failures.append(
                f"a block mangled ONLY by backslash collapsing was not caught by the "
                f"`{arm}` arm, which is the exact case a whole-file substring test "
                f"misses (looked for {needle!r}): {collapsed}"
            )
    collapse_fixed = fixture_audit(COLLAPSE_ONLY_FIXED, source="<fixture: same bytes, literal>")
    if collapse_fixed:
        failures.append(
            "the same bytes written as a literal string were rejected, so those arms "
            f"fire on content rather than on the delimiter: {collapse_fixed}"
        )

    # EVERY LITERAL SPELLING IS COMPILED. A spelling the reader stops handling
    # adds no program and no complaint, so the arm goes quiet on it while the
    # check still claims every jq program compiles — which is how `jq -r .title`
    # went unchecked in this repo's own runbook.
    for spelling, command in INVALID_FILTER_FIXTURES:
        reported = fixture_audit(
            literal_block(command), source=f"<fixture: {spelling} invalid filter>"
        )
        if not any("does not compile" in problem for problem in reported):
            failures.append(
                f"an invalid {spelling} jq filter was not compiled, so arm 3 asserts "
                f"nothing about that spelling: {reported}"
            )

    # A program held in a shell variable is the ONE silent exemption, so it must
    # stay silent — otherwise every runbook using one fails for being unreadable.
    variable_form = fixture_audit(
        literal_block('jq -r "$PROGRAM" "$f"'), source="<fixture: shell variable>"
    )
    if variable_form:
        failures.append(
            f"a jq program held in a shell variable was reported, but its text is not "
            f"in the file to compile: {variable_form}"
        )

    # THE SPAN MUST REACH TOML'S OWN CLOSE. An escaped delimiter inside a basic
    # string does not end the value; stopping there manufactures a difference.
    escaped = assignments(ESCAPED_DELIMITER_FIXTURE).get("demo", ("", ""))
    if escaped[1] != ESCAPED_DELIMITER_SPAN:
        failures.append(
            f"an escaped delimiter inside a basic string truncated the raw span: read "
            f"{escaped[1]!r}, expected {ESCAPED_DELIMITER_SPAN!r}. Arms 2 and 4 would "
            f"then compare against a span this scanner invented."
        )
    escaped_problems = fixture_audit(ESCAPED_DELIMITER_FIXTURE, source="<fixture: escaped delimiter>")
    if not any("written as a BASIC string" in problem for problem in escaped_problems):
        failures.append(
            f"a basic string containing an escaped delimiter was not reported as a "
            f"delimiter violation: {escaped_problems}"
        )

    # ARM 3'S READER, not jq. A continued invocation must actually be collected:
    # while it was not, this fixture passed with an invalid filter.
    multiline = fixture_audit(MULTILINE_JQ_FIXTURE, source="<fixture: continued jq invocation>")
    if not any("does not compile" in problem for problem in multiline):
        failures.append(
            "a jq invocation split across a shell line continuation was not compiled, "
            "so arm 3 collected nothing and asserted nothing — the empty-collection-"
            f"reads-as-clean shape, in the check that exists to catch it: {multiline}"
        )

    # `jq -n` RUNS what it compiles, so the bound is what stops a pathological
    # program from wedging this check and the CI job. Reaching the handler is the
    # assertion: a non-terminating program outlives any bound, so this cannot be
    # flaky in the direction that matters.
    hanging = fixture_audit(
        HANGING_FIXTURE,
        source="<fixture: non-terminating jq>",
        jq_timeout=JQ_FIXTURE_TIMEOUT_SECONDS,
    )
    if not any("did not terminate" in problem for problem in hanging):
        failures.append(
            "a jq program that never finishes was not reported as a timeout, so the "
            f"bound on the compile arm is not proven and a pathological runbook could "
            f"hang this check: {hanging}"
        )
    return failures


def main() -> int:
    if not jq_available():
        print(
            "check-skill-instructions: FAIL: jq is not installed, so the compile arm "
            "cannot run. This is a failure, not a skip: a runbook shipping an "
            "uncompilable jq program is exactly what goes unnoticed.",
            file=sys.stderr,
        )
        return 1

    problems = self_test()
    if problems:
        print("check-skill-instructions: FAIL (self-test)", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    problems = fixture_audit(CONFIG.read_text(encoding="utf-8"), source="vstack.toml")
    if problems:
        print("check-skill-instructions: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    count = len(blocks(CONFIG.read_text(encoding="utf-8")))
    print(
        f"check-skill-instructions: ok ({count} [{TABLE}] block(s) are literal strings "
        f"rendering verbatim; self-test proved all four arms fail on the pre-fix form, "
        f"that every literal jq spelling is compiled, that backslash-collapse and "
        f"escaped-delimiter damage are caught, and that a non-terminating jq program is "
        f"reported rather than hanging the check)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
