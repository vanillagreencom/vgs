"""The QML and JavaScript source lines a static check reads.

`check-plugin-boundary.py` and `check-design-tokens.py` walk the same files the
way the shell lists them, through `bin/vgsh-scan`, and read code only: line
comments, block comments and trailing comments are blanked before matching,
with line numbers kept. String literals stay, so a name inside a string handed
to `Qt.createQmlObject` is still a finding.

A directory or file the walk cannot read raises `Unreadable`, and the caller
ends its run: an incomplete traversal never certifies a tree.
"""
import os
import re
import runpy

SCAN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "vgsh-scan")
scan_sources = runpy.run_path(SCAN)["source_files"]

# A `/` after one of these characters, after one of these keywords, or at the
# start of the text, opens a regular expression literal rather than dividing.
REGEX_AFTER = set("(,=:[!&|?{};~+-*%<>^")
REGEX_AFTER_WORDS = {"return", "typeof", "case", "in", "of", "delete", "void", "throw", "new", "else", "do", "yield", "await", "instanceof"}
LAST_WORD = re.compile(r"([A-Za-z_$][\w$]*)\s*$")


class Unreadable(Exception):
    """A directory or file the walk could not read; the run ends with exit 2."""

    def __init__(self, path, strerror):
        super().__init__(f"{path}: {strerror}")
        self.path = path
        self.strerror = strerror


def blank_comments(text):
    """Return `text` with every comment replaced by spaces, newlines kept.

    Strings, template literals and regular expression literals are copied as
    they are, so a `//` inside `"file://"` or `/\\/\\//` opens no comment. A
    single- or double-quoted string ends at its line's end even unterminated,
    so a misread quote cannot hide more than the rest of one line."""
    out = []
    i, n = 0, len(text)
    last = ""

    def after_keyword():
        m = LAST_WORD.search("".join(out[-24:]))
        return m is not None and m.group(1) in REGEX_AFTER_WORDS

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if c == "/" and nxt == "*":
            end = text.find("*/", i + 2)
            end = n if end == -1 else end + 2
            out.append("".join("\n" if ch == "\n" else " " for ch in text[i:end]))
            i = end
            continue
        if c in "\"'`" or (c == "/" and (last == "" or last in REGEX_AFTER or after_keyword())):
            close = c
            out.append(c)
            i += 1
            in_class = False
            while i < n:
                ch = text[i]
                if ch == "\n" and close != "`":
                    break
                out.append(ch)
                i += 1
                if ch == "\\" and i < n and text[i] != "\n":
                    out.append(text[i])
                    i += 1
                elif close == "/" and ch == "[":
                    in_class = True
                elif close == "/" and ch == "]":
                    in_class = False
                elif ch == close and not in_class:
                    break
            last = close
            continue
        out.append(c)
        if not c.isspace():
            last = c
        i += 1
    return "".join(out)


def source_lines(root):
    """Yield (path, line number, code) for every non-blank code line of every
    `.qml` and `.js` file under `root`, comments blanked."""
    try:
        for relative, _executable, data in scan_sources(root):
            if not relative.endswith((".qml", ".js")):
                continue
            path = os.path.join(root, relative)
            try:
                text = data.decode("utf-8-sig")
            except UnicodeError as exc:
                raise Unreadable(path, str(exc)) from exc
            for number, line in enumerate(blank_comments(text).split("\n"), 1):
                if line.strip():
                    yield path, number, line
    except OSError as exc:
        raise Unreadable(exc.filename, exc.strerror) from exc
