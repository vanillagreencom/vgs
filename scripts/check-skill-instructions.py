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

THREE ARMS, on the value tomllib produces — the same bytes a rendered skill
carries, not the raw source:

1. IDENTITY. Every block must appear verbatim in the file's raw text. A basic
   string cannot: escape processing makes the parsed value differ. This is the
   general statement of the bug, so it catches forms 2 and 3 would miss.
2. JQ COMPILES. Every `jq` program in a fenced block must compile. Judged on
   jq's COMPILE status (3) alone: running a filter with no input exits 5, and
   treating that as a break would make the arm fail on correct programs.
3. CONTINUATIONS SURVIVE. A block's parsed text must carry as many trailing-`\\`
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


def raw_source(text: str, key: str) -> str:
    """The bytes between a key's opening and closing string delimiters.

    Sliced exactly rather than by a length guess: the whole point of arm 3 is
    that the parsed value is SHORTER than its source, so any window derived from
    the parsed length is the wrong size in the failing direction.
    """
    match = re.search(rf"^{re.escape(key)}\s*=\s*('''|\"\"\"|'|\")", text, re.M)
    if not match:
        return ""
    delimiter = match.group(1)
    start = match.end()
    end = text.find(delimiter, start)
    return text[start:end] if end != -1 else text[start:]


def jq_available() -> bool:
    return shutil.which("jq") is not None


def audit(text: str, *, source: str) -> list[str]:
    """Every problem in one `[skill-instructions]` table. Empty means clean."""
    problems: list[str] = []
    try:
        table = blocks(text)
    except tomllib.TOMLDecodeError as exc:
        return [f"{source} is not valid TOML: {exc}"]

    for key, value in sorted(table.items()):
        # --- arm 1: identity through the parser -----------------------------
        if value not in text:
            problems.append(
                f"{source} [{TABLE}] {key}: the parsed value differs from the bytes in "
                f"the file, so TOML processed escapes inside it. That is a BASIC string "
                f'(""" or "); this block ships commands and must be a LITERAL string '
                f"(''' or '), which passes bytes through untouched."
            )

        # --- arm 3: shell line continuations --------------------------------
        raw_continuations = len(CONTINUATION.findall(raw_source(text, key)))
        parsed_continuations = len(CONTINUATION.findall(value))
        if raw_continuations > parsed_continuations:
            problems.append(
                f"{source} [{TABLE}] {key}: {raw_continuations} shell line continuation(s) "
                f"in the source, {parsed_continuations} in the parsed value — TOML ate the "
                f"newline after a trailing backslash and joined the commands. The result is "
                f"still valid shell, so no syntax check would catch it."
            )

        # --- arm 2: every jq program compiles -------------------------------
        for fenced in FENCE.findall(value):
            for program in JQ_PROGRAM.findall(fenced):
                completed = subprocess.run(
                    ["jq", "-n", program],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    text=True,
                )
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
            ("identity", "BASIC string"),
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
        f"check-skill-instructions: ok ({count} [{TABLE}] block(s) render verbatim, "
        f"self-test proved all three arms fail on the pre-fix form)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
