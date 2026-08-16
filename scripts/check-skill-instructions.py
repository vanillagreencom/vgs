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

LIMITS — read these before the arms, because they are what the arms do NOT say.
This check proves the shipped runbook's provenance program COMPILES, and that its
escapes and its continuation survive decoding. It does not prove the runbook is
CORRECT. It says nothing about whether a command reports its failure, whether
cleanup swallows an exit status, whether the sequence is right, or whether any of
it does what the surrounding prose claims.

That is not hypothetical: a fail-open sat in the `issues create` step — an
unconditional `rm -f` after it made the cleanup's status the block's, so a failed
create reported success — and every assertion here passed until a reviewer read
the block. The class is the actionable part: assertions about a script's TEXT
cannot see its RUNTIME BEHAVIOUR.

WHAT THE ASSERTIONS ARE, and each is bound to the CONSTRUCT it protects rather
than to the block — "some `\\n` survives somewhere" was satisfied by an escape in
a different sentence while the one inside the jq string was gone:

  * THE PROVENANCE PROGRAM COMPILES. It is extracted and handed to jq itself.
    Binary and complete: it fails for ANY escape TOML collapsed, not the subset
    someone enumerated, and it tests what the regression actually did — jq
    exiting 3 on "Invalid escape". Judged on the COMPILE status alone, since
    running a filter against no input exits 5 by design.
  * that program contains no REAL newline. Measured, not assumed: jq 1.8.2
    ACCEPTS a literal newline inside a string (`jq -n '\"a<LF>b\"'` exits 0), so
    compiling provably does not catch this and a compile-only check would lose
    it. A real newline here means TOML processed the `\\n` escapes, which is the
    mangling itself.
  * the mirroring invocation still ends a line with a shell continuation. That
    is shell, not jq, so no compile covers it.

jq is a declared hard dependency for arch, debian and fedora
(packaging/optional-packages.json), so there is no fallback path — its absence is
reported as a sentence rather than raised, which is this file's standing rule for
a check that cannot run.

Measured on the two revisions — decoded `linear` at c40835b7 versus now: the
provenance program does not compile vs does, real newlines inside it 1 vs 0,
continuation lines 0 vs 2. The decoded value alone distinguishes the regression.

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

Offline: python3 (tomllib, 3.11+) and jq, both already required by this repo.
"""

from __future__ import annotations

import re
import subprocess
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

# THE ANCHORS, and the reason they are this small. Every assertion below is bound
# to the CONSTRUCT it protects, because "the block contains a `\n` somewhere" was
# satisfied by an escape in a different sentence: the decoded runbook carries four
# of them, and collapsing the one INSIDE the jq string left three matches and the
# check reported clean. Presence is not provenance — the same shape as the
# delimiter once bound to another table's key, one level in.
#
# Each anchor names what the construct DOES rather than the prose around it, so
# ordinary edits do not trip it, and a construct that cannot be located is a LOUD
# failure: an absent construct is precisely the breakage being guarded against.
# `issues create` alone is NOT an anchor — the block also discusses it in prose —
# so the invocation is identified by the script it invokes.
PROVENANCE_PROGRAM = "sub("
MIRROR_INVOCATION = ("linear.sh", "issues create")

# EXTRACTION, deliberately bounded to ONE shell-quoting form. A POSIX
# single-quoted string cannot contain a single quote by any spelling, so the span
# from the quote after `jq` to the next quote is exact and sound — no parser, no
# escape handling, no ambiguity. Double-quoted, unquoted and variable-held
# programs are NOT handled: that is the unbounded extraction which produced five
# findings and was split to VGS-156, and widening this is how it comes back.
JQ_INVOCATION = re.compile(r"\bjq\b[^'\n]*'")
JQ_COMPILE_ERROR = 3
# jq compiles and RUNS what it is given, so a filter could loop forever; the bound
# keeps a pathological program from wedging CI. Generous — these compile in
# milliseconds.
JQ_TIMEOUT_SECONDS = 5.0


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


def lines_containing(value: str, *anchors: str) -> list[str]:
    """Decoded lines carrying every anchor — the construct, not the block."""
    return [line for line in value.split("\n") if all(one in line for one in anchors)]


def single_quoted_jq_programs(value: str) -> list[str]:
    """Every single-quoted jq program in the decoded text, spans exact.

    Bounded on purpose — see JQ_INVOCATION. The opening quote is the first one
    after `jq` on that line, and the close is the next single quote ANYWHERE,
    because a shell single-quoted string legitimately spans newlines and a
    mangled one is exactly where they turn up.
    """
    programs: list[str] = []
    for opening in JQ_INVOCATION.finditer(value):
        closing = value.find("'", opening.end())
        if closing != -1:
            programs.append(value[opening.end() : closing])
    return programs


def compiles(program: str) -> list[str]:
    """Whether jq accepts `program`, judged on its COMPILE status alone.

    Exit 3 is a compile error; exit 5 is a runtime error, which running a filter
    against no input reaches on purpose and which says nothing about syntax.
    jq is a declared hard dependency for arch, debian and fedora
    (packaging/optional-packages.json), so there is no fallback path — but its
    absence is reported as a sentence rather than raised as a traceback, which is
    this file's standing rule for a check that cannot run.
    """
    try:
        done = subprocess.run(
            ["jq", "-n", program],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=JQ_TIMEOUT_SECONDS,
        )
    except FileNotFoundError:
        return [
            "jq is not installed, so the provenance program could not be compiled — "
            "it is a declared hard dependency, and this is DID NOT RUN, not a pass"
        ]
    except subprocess.TimeoutExpired:
        return [
            f"the provenance jq program did not terminate within {JQ_TIMEOUT_SECONDS:g}s "
            f"and was killed — it compiles, but it does not finish, which would hang "
            f"anyone running this runbook"
        ]
    if done.returncode != JQ_COMPILE_ERROR:
        return []
    detail = done.stderr.strip().splitlines()
    return [
        f"the jq program that builds the mirrored body DOES NOT COMPILE — "
        f"{detail[0] if detail else '(no diagnostic)'}. Restore whatever escape was "
        f"collapsed inside that program; a TOML basic string taking a backslash away "
        f"is the usual cause"
    ]


def survives_decoding(value: str) -> list[str]:
    """Ways a command-bearing block's decoded text would no longer run.

    Every assertion is scoped to the LINE the construct lives on, never to the
    block: an escape or a continuation elsewhere must not satisfy a claim about
    this construct. Each message names the property missing from the DECODED
    value and asks for it back. The delimiter is offered as the likely CAUSE
    only — this check's own self-test proves a mangled runbook fails while
    written as a literal string, so prescribing a delimiter would send the reader
    to change something that cannot fix the failure in front of them.
    """
    problems: list[str] = []

    provenance = [
        program
        for program in single_quoted_jq_programs(value)
        if PROVENANCE_PROGRAM in program
    ]
    if not provenance:
        problems.append(
            f"the provenance jq program (a single-quoted jq filter containing "
            f"`{PROVENANCE_PROGRAM}`) is not in its decoded text at all — the construct "
            f"this check guards is gone, which is the breakage rather than the absence "
            f"of one. Restore it, or retarget PROVENANCE_PROGRAM if the runbook "
            f"genuinely stopped using it"
        )
    for program in provenance:
        # COMPILE IT. Binary and complete: this fails for ANY escape TOML collapsed,
        # not the subset someone thought to enumerate, and it tests the property the
        # regression actually had — jq refusing the program.
        for problem in compiles(program):
            problems.append(problem)
        # ...and separately, no LITERAL newline inside it. Measured rather than
        # assumed: jq 1.8.2 ACCEPTS a real newline in a string (`jq -n '"a<LF>b"'`
        # exits 0), so the compile above provably does not catch this, and a
        # compile-only check would have lost the case it was added for. What a real
        # newline here does mean is that TOML processed the `\n` escapes — the
        # mangling this file exists to catch — so it is asserted directly.
        if "\n" in program:
            problems.append(
                "the jq program that builds the mirrored body contains a REAL newline "
                "where it needs a two-character `\\n` — jq tolerates it, but its "
                "presence means TOML processed the escapes on the way through, which "
                "is the mangling itself. Restore the `\\n` escapes inside that program; "
                "a TOML basic string turning each into a real newline is the usual cause"
            )

    invocation_lines = lines_containing(value, *MIRROR_INVOCATION)
    if not invocation_lines:
        problems.append(
            f"the mirroring invocation ({' … '.join(MIRROR_INVOCATION)}) is not in its "
            f"decoded text at all — the construct this check guards is gone. Restore "
            f"it, or retarget MIRROR_INVOCATION if the runbook genuinely stopped "
            f"calling it"
        )
    elif not any(line.endswith("\\") for line in invocation_lines):
        problems.append(
            "the mirroring invocation does not end its line with a shell continuation "
            "— it is written across two lines, so without one the `--description-file` "
            "argument joins onto it. Restore the trailing backslash on that line; a "
            "TOML basic string eating the newline after it is the usual cause"
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
    'linear.sh issues create --title "$(jq -r .title "$f")" \\\n'
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
        ("collapsed regex escape", "DOES NOT COMPILE"),
        ("newline escape turned real", "REAL newline"),
        ("continuation swallowed", "continuation"),
    ):
        if not any(needle in problem for problem in mangled):
            failures.append(
                f"a runbook whose decoded text lost its {property_lost} was accepted, so "
                f"the check no longer notices the thing that stopped it running "
                f"(looked for {needle!r}): {mangled}"
            )
    # THE DECOY, and the control that proves these assertions are bound to their
    # constructs. The same damage, with a compensating escape, `\n` and
    # continuation added in PROSE elsewhere in the block: a block-scoped check
    # counted those and reported clean. Every failure above must survive it.
    decoyed = audit(
        MANGLED_RUNBOOK.replace(
            "```\n'''", "```\nprose with \\\\s and a \\n escape and a continuation \\\n'''"
        ),
        source="<fixture: mangled runbook + decoy>",
    )
    for property_lost, needle in (
        ("collapsed regex escape", "DOES NOT COMPILE"),
        ("newline escape turned real", "REAL newline"),
        ("continuation swallowed", "does not end its line"),
    ):
        if not any(needle in problem for problem in decoyed):
            failures.append(
                f"a decoy elsewhere in the block rescued the {property_lost} failure, so "
                f"the assertion is satisfied by a token in the WRONG PLACE rather than "
                f"by the construct it protects: {decoyed}"
            )

    # An absent construct is the breakage, not the absence of one.
    for construct, fixture in (
        ("the jq program", INTACT_RUNBOOK.replace("sub(", "trim(", 1)),
        ("the mirroring invocation", INTACT_RUNBOOK.replace("linear.sh", "other.sh", 1)),
    ):
        if not any(
            "is not in its decoded text at all" in problem
            for problem in audit(fixture, source=f"<fixture: {construct} absent>")
        ):
            failures.append(
                f"{construct} being absent from the runbook was accepted, so a check "
                f"bound to a construct passes when the construct is gone — which is the "
                f"breakage rather than the absence of one."
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
