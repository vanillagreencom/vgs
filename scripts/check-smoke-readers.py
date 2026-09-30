#!/usr/bin/env python3
"""Enforce the smoke reader rule docs/architecture/validation-smoke-harness.md
states.

A smoke row reads the shell through the probe or the compositor and parses
the answer with an inline Python program. The probe answers a state word,
such as `absent` or `ipc-failed`, in place of JSON, and an empty reply can
still come from a failed command; `json.load` raises on both, and a poll that retries past the failed read
leaves the traceback in the log behind a passing check. `py_reply` in
scripts/smoke/harness.sh answers the word itself and parses only JSON, so a
program in a row that parses JSON from its stdin is `py_reply`'s program:
  inline-reader   the read's command is python3, not py_reply.
  unowned-reader  the read is not inside the literal that opens py_reply's
                  program, `py_reply '...'` or `py_reply "$VAR"'...'`, or
                  no command precedes it.
A read is `json.load(sys.stdin` or `json.loads(sys.stdin`, or any
`sys.stdin` in a program literal that also parses JSON with `json.load`,
`json.loads` or `raw_decode`. Its command is the nearest `py_reply` or
`python3` word before it, and a program literal holds no single quote, so
the read sits in the command's program exactly when the text between the
two is the program's opening. A `sys.stdin` outside a literal, such as in
a heredoc, is a read only in the direct form. A `sys.stdin` on a line whose
text before it is a `#` comment is no read.

Usage: check-smoke-readers.py [DIR]
DIR defaults to the repository's scripts/smoke/rows. Every finding is one
line: `<rule> <file>:<line> <detail>`. The pass is
`check-smoke-readers: ok files=<n> readers=<n>`. Exit 0 when clean, 1 on any
finding, 2 when the directory or a file cannot be read, printed as
`check-smoke-readers: unreadable: <path>: <strerror>`. A directory holding
no row is unreadable too: an empty walk certifies nothing.
"""
import os
import re
import sys

ROWS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "smoke", "rows")
STDIN = re.compile(r"\bsys\.stdin\b")
DIRECT = re.compile(r"json\.loads?\(\s*$")
PARSES_JSON = re.compile(r"\bjson\.loads?\(|\braw_decode\(")
COMMAND = re.compile(r"\b(py_reply|python3)\b")
# The text between a command and a stdin use inside the literal that opens
# its program: python3's `-c`, an optional quoted variable the literal
# extends, then the literal's opening quote and no closing one.
PROGRAM_OPENING = {
    "py_reply": re.compile(r"[ \t]+(?:\"\$[A-Za-z_][A-Za-z0-9_]*\")?'([^']*)"),
    "python3": re.compile(r"[ \t]+-c[ \t]+(?:\"\$[A-Za-z_][A-Za-z0-9_]*\")?'([^']*)"),
}


class Unreadable(Exception):
    def __init__(self, path, strerror):
        super().__init__(path, strerror)
        self.path = path
        self.strerror = strerror


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def check_file(path, findings):
    try:
        with open(path, encoding="utf-8") as source:
            text = source.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise Unreadable(path, getattr(exc, "strerror", None) or str(exc)) from exc
    readers = 0
    for read in STDIN.finditer(text):
        line_start = text.rfind("\n", 0, read.start()) + 1
        if text[line_start:read.start()].lstrip().startswith("#"):
            continue
        direct = DIRECT.search(text, line_start, read.start()) is not None
        command = None
        for command in COMMAND.finditer(text, 0, read.start()):
            pass
        opening = command and PROGRAM_OPENING[command.group(1)].fullmatch(text, command.end(), read.start())
        if opening:
            close = text.find("'", read.end())
            program = text[opening.start(1):len(text) if close < 0 else close]
            if not (direct or PARSES_JSON.search(program)):
                continue
        elif not direct:
            continue
        readers += 1
        number = line_of(text, read.start())
        if command is None:
            findings.append(f"unowned-reader {path}:{number} no py_reply before the read")
        elif command.group(1) == "python3":
            findings.append(f"inline-reader {path}:{number} python3 on line {line_of(text, command.start())} parses JSON from stdin; read it through py_reply")
        elif not opening:
            findings.append(f"unowned-reader {path}:{number} the read is outside the program py_reply on line {line_of(text, command.start())} opens")
    return readers


def main(argv):
    if len(argv) > 2:
        print(f"check-smoke-readers: refused: argument={argv[2]}")
        return 2
    root = os.path.abspath(argv[1] if len(argv) == 2 else ROWS)
    findings = []
    readers = 0
    try:
        try:
            names = sorted(n for n in os.listdir(root) if n.endswith(".sh"))
        except OSError as exc:
            raise Unreadable(root, exc.strerror) from exc
        if not names:
            raise Unreadable(root, "no row found")
        for name in names:
            readers += check_file(os.path.join(root, name), findings)
    except Unreadable as exc:
        print(f"check-smoke-readers: unreadable: {exc.path}: {exc.strerror}")
        return 2
    for line in findings:
        print(line)
    if findings:
        print(f"check-smoke-readers: findings={len(findings)}")
        return 1
    print(f"check-smoke-readers: ok files={len(names)} readers={readers}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
