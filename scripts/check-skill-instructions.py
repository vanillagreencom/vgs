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

FENCE = re.compile(r"^```(?:bash|sh)?\n(.*?)^```", re.M | re.S)
# A jq invocation with a single-quoted program, which is how every runbook here
# writes one. Deliberately not a general shell parser: a program spelled some
# other way is not silently skipped, it is simply not one of these, and arm 1
# still covers the bytes.
JQ_PROGRAM = re.compile(r"\bjq\b[^\n']*'([^']*)'")
CONTINUATION = re.compile(r"(?<!\\)\\$", re.M)


def blocks(text: str) -> dict[str, str]:
    """The `[skill-instructions]` values tomllib produces, non-empty ones only."""
    parsed = tomllib.loads(text)
    return {k: v for k, v in parsed.get(TABLE, {}).items() if isinstance(v, str) and v.strip()}


TABLE_HEADER = re.compile(r"\s*\[([^\[\]]+)\]\s*$")
ASSIGNMENT = re.compile(r"([A-Za-z0-9_-]+)\s*=\s*('''|\"\"\"|'|\")")
LITERAL_DELIMITERS = frozenset({"'''", "'"})


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
            while cursor < len(lines) and delimiter not in lines[cursor]:
                body.append(lines[cursor])
                cursor += 1
            # A closing delimiter may trail content on its own line; keep that
            # content, or the span would be short and arm 2 would fire falsely.
            if cursor < len(lines):
                prefix = lines[cursor].split(delimiter, 1)[0]
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


def jq_available() -> bool:
    return shutil.which("jq") is not None


def audit(text: str, *, source: str, jq_timeout: float = JQ_TIMEOUT_SECONDS) -> list[str]:
    """Every problem in one `[skill-instructions]` table. Empty means clean."""
    problems: list[str] = []
    try:
        table = blocks(text)
    except tomllib.TOMLDecodeError as exc:
        return [f"{source} is not valid TOML: {exc}"]

    written = assignments(text)

    for key, value in sorted(table.items()):
        delimiter, raw = written.get(key, ("", ""))
        if not delimiter:
            problems.append(
                f"{source} [{TABLE}] {key}: tomllib sees this key but the source scanner "
                f"does not, so neither the delimiter nor the identity arm can judge it. "
                f"Fix the scanner — an arm that cannot read an entry passes it."
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
        for fenced in FENCE.findall(value):
            for program in JQ_PROGRAM.findall(fenced):
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


def self_test() -> list[str]:
    """The arms must be able to fail. Runs on every invocation, never optional."""
    failures: list[str] = []

    broken = audit(BROKEN_FIXTURE, source="<fixture: pre-fix basic string>")
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

    fixed = audit(FIXED_FIXTURE, source="<fixture: literal string>")
    if fixed:
        failures.append(
            "the post-fix literal-string fixture FAILED, so the check rejects the very "
            f"form it prescribes: {fixed}"
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
    collapsed = audit(COLLAPSE_ONLY_FIXTURE, source="<fixture: backslash collapse only>")
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
    collapse_fixed = audit(COLLAPSE_ONLY_FIXED, source="<fixture: same bytes, literal>")
    if collapse_fixed:
        failures.append(
            "the same bytes written as a literal string were rejected, so those arms "
            f"fire on content rather than on the delimiter: {collapse_fixed}"
        )

    # `jq -n` RUNS what it compiles, so the bound is what stops a pathological
    # program from wedging this check and the CI job. Reaching the handler is the
    # assertion: a non-terminating program outlives any bound, so this cannot be
    # flaky in the direction that matters.
    hanging = audit(
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

    problems = audit(CONFIG.read_text(encoding="utf-8"), source="vstack.toml")
    if problems:
        print("check-skill-instructions: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    count = len(blocks(CONFIG.read_text(encoding="utf-8")))
    print(
        f"check-skill-instructions: ok ({count} [{TABLE}] block(s) are literal strings "
        f"rendering verbatim; self-test proved all four arms fail on the pre-fix form, "
        f"that backslash-collapse-only damage is caught, and that a non-terminating jq "
        f"program is reported rather than hanging the check)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
