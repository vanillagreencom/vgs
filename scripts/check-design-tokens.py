#!/usr/bin/env python3
"""Enforce the design token rules docs/architecture/design-system.md states.

Token rule, on every QML and JS file under shell/, the vgs-plugin skill
templates and the smoke fixtures:
  token-unknown      a `Theme.<path>` names no token, no group and no
                     read-only property or function Theme.qml declares; the
                     paths come from Tokens.js through scripts/qml-library.js,
                     never from a second list
  group-unpublished  a top-level group of Tokens.js has no read-only property
                     in Theme.qml, so no file could read its tokens
Literal rules, on shipped QML (shell/Ui, shell/Hosts, shell/plugins) and the
skill templates; shell/Commons and shell/Core draw nothing, and a fixture's
fixed geometry is what a placement row measures:
  literal-color      a hex colour string, a named colour other than "transparent"
                     assigned to a colour property, or a Qt.rgba, Qt.hsla,
                     Qt.hsva, Qt.lighter, Qt.darker or Qt.tint call
  literal-font       a literal assigned to font.family, font.pixelSize,
                     font.pointSize, font.weight, font.bold or font.letterSpacing,
                     dotted or inside a font group
  literal-radius     a radius that reads no token: any value other than one
                     naming `Theme.` or one plain property path such as
                     `parent.radius`, since a corner shape is a visual choice,
                     never layout arithmetic
  literal-metric     one non-zero numeric literal assigned to a width, height,
                     implicit size, spacing, padding, margin, border.width or
                     strokeWidth
  literal-opacity    a numeric literal other than 0 and 1 assigned to opacity
  literal-duration   a numeric literal assigned to a duration
A value that is more than one literal, such as `2 * inset`, is layout and
passes. Comments are blanked and strings kept, through scripts/qml_source.py.

Usage: check-design-tokens.py [--repo DIR] [PLUGIN_DIR...]
With no plugin directories, the repository's own trees are checked. With them,
each directory is checked alone: token-unknown is a finding and a literal rule
prints a `notice` line, since a plugin author may choose a literal.

Every finding is one line: `<rule> <file>:<line> <detail>`. Exit 0 when clean,
1 on any finding, 2 when the token table cannot be read or any directory or
source file cannot be read, printed as
`check-design-tokens: unreadable: <path>: <strerror>`. A tree the walk found no
source file in is unreadable too: an empty walk certifies nothing.
"""
import argparse
import json
import os
import re
import subprocess
import sys

# A check writes nothing into the tree it reads, so the shared module leaves
# no bytecode cache beside it.
sys.dont_write_bytecode = True
from qml_source import Unreadable, source_lines

# node runs under this environment and nothing inherited beyond it.
NODE_ENV = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}
# The table and the judge, loaded the way every offline reader loads a
# shell library; the judge lists the groups, the tokens and the leaves.
TOKEN_PATHS = (
    "const { load } = require(process.argv[1]);"
    "const table = load(process.argv[2]).TOKENS;"
    "const judge = load(process.argv[3]);"
    "process.stdout.write(JSON.stringify({ paths: judge.paths(table), leaves: judge.leaves(table).map(l => l.path) }));"
)

THEME_REFERENCE = re.compile(r"(?<![\w.$])Theme\.((?:[A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*)")
THEME_MEMBER = re.compile(r"^\s*readonly property \w+ (\w+)\s*:", re.MULTILINE)
THEME_FUNCTION = re.compile(r"^\s*function (\w+)\s*\(", re.MULTILINE)
THEME_FIRST_MEMBER = re.compile(r"^\s*readonly property ", re.MULTILINE)

NUMBER = r"-?\d+(?:\.\d+)?"
LITERAL = r"\"[^\"]*\"|'[^']*'|" + NUMBER + r"|true|false|Font\.\w+"
# A property assignment: an optionally dotted name, a colon, and the value up
# to the end of that statement.
ASSIGNMENT = r"(?<![\w.])((?:[A-Za-z_]\w*\.)*(?:{names}))\s*:\s*([^;{{}}]*)"
FONT_NAMES = "family|pixelSize|pointSize|weight|bold|letterSpacing"
METRIC_NAMES = r"\w*(?:[wW]idth|[hH]eight|[pP]adding|[mM]argins?)|spacing|rowSpacing|columnSpacing"

HEX_COLOR = re.compile(r"[\"']#[0-9a-fA-F]{3,8}[\"']")
COLOR_CALL = re.compile(r"\bQt\.(rgba|hsla|hsva|lighter|darker|tint)\s*\(")
COLOR_ASSIGNMENT = re.compile(ASSIGNMENT.format(names=r"\w*[cC]olor"))
FONT_ASSIGNMENT = re.compile(ASSIGNMENT.format(names=FONT_NAMES))
RADIUS_ASSIGNMENT = re.compile(ASSIGNMENT.format(names="radius"))
METRIC_ASSIGNMENT = re.compile(ASSIGNMENT.format(names=METRIC_NAMES))
OPACITY_ASSIGNMENT = re.compile(ASSIGNMENT.format(names="opacity"))
DURATION_ASSIGNMENT = re.compile(ASSIGNMENT.format(names="duration"))
IS_NUMBER = re.compile(r"^" + NUMBER + r"$")
IS_PROPERTY_PATH = re.compile(r"^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*$")
IS_LITERAL = re.compile(r"^(?:" + LITERAL + r")$")
QUOTED = re.compile(r"^[\"']([^\"']*)[\"']$")


def font_property(name):
    """True for a dotted font property and for a bare font-group name."""
    return name.startswith("font.") or "." not in name


def literal_findings(line):
    """Every literal-rule finding on one code line, as (rule, detail)."""
    out = []
    for m in HEX_COLOR.finditer(line):
        out.append(("literal-color", m.group(0)))
    for m in COLOR_CALL.finditer(line):
        out.append(("literal-color", "Qt." + m.group(1)))
    for m in COLOR_ASSIGNMENT.finditer(line):
        quoted = QUOTED.match(m.group(2).strip())
        if quoted and quoted.group(1) != "transparent" and not HEX_COLOR.match(m.group(2).strip()):
            out.append(("literal-color", m.group(1) + ": " + m.group(2).strip()))
    for m in FONT_ASSIGNMENT.finditer(line):
        if font_property(m.group(1)) and IS_LITERAL.match(m.group(2).strip()):
            out.append(("literal-font", m.group(1) + ": " + m.group(2).strip()))
    for m in RADIUS_ASSIGNMENT.finditer(line):
        value = m.group(2).strip()
        if "Theme." not in value and not IS_PROPERTY_PATH.match(value):
            out.append(("literal-radius", m.group(1) + ": " + value))
    for m in METRIC_ASSIGNMENT.finditer(line):
        value = m.group(2).strip()
        if IS_NUMBER.match(value) and float(value) != 0:
            out.append(("literal-metric", m.group(1) + ": " + value))
    for m in OPACITY_ASSIGNMENT.finditer(line):
        value = m.group(2).strip()
        if IS_NUMBER.match(value) and float(value) not in (0, 1):
            out.append(("literal-opacity", m.group(1) + ": " + value))
    for m in DURATION_ASSIGNMENT.finditer(line):
        if IS_NUMBER.match(m.group(2).strip()):
            out.append(("literal-duration", m.group(1) + ": " + m.group(2).strip()))
    return out


class Table:
    """The token paths a `Theme.<path>` may name."""

    def __init__(self, repo):
        commons = os.path.join(repo, "shell", "Commons")
        command = ["node", "-e", TOKEN_PATHS, os.path.join(repo, "scripts", "qml-library.js"), os.path.join(commons, "Tokens.js"), os.path.join(commons, "ThemeLogic.js")]
        try:
            run = subprocess.run(command, capture_output=True, text=True, check=False, env=NODE_ENV)
        except OSError as exc:
            raise Unreadable("token-table", exc.strerror) from exc
        if run.returncode != 0:
            raise Unreadable("token-table", "node exited " + str(run.returncode) + ": " + run.stderr.strip())
        listed = json.loads(run.stdout)
        self.paths = set(listed["paths"])
        self.leaves = set(listed["leaves"])
        if not self.leaves:
            raise Unreadable("token-table", "the judge listed no token; the table walk is broken")
        self.theme = os.path.join(commons, "Theme.qml")
        try:
            with open(self.theme, encoding="utf-8") as fh:
                text = fh.read()
        except OSError as exc:
            raise Unreadable(self.theme, exc.strerror) from exc
        self.members = set(THEME_MEMBER.findall(text)) | set(THEME_FUNCTION.findall(text))
        first = THEME_FIRST_MEMBER.search(text)
        if first is None:
            raise Unreadable(self.theme, "no read-only property declared; the member scan is broken")
        self.members_line = text.count("\n", 0, first.start()) + 1
        self.unpublished = sorted(group for group in self.paths if "." not in group and group not in self.members)

    def unknown(self, dotted):
        """The shortest prefix of `dotted` that names nothing, or None. A
        member Theme.qml declares that is no group, such as `name`, takes
        any path under it."""
        parts = dotted.split(".")
        if parts[0] in self.members and parts[0] not in self.paths:
            return None
        for i in range(1, len(parts) + 1):
            prefix = ".".join(parts[:i])
            if prefix in self.leaves:
                return None
            if prefix not in self.paths:
                return prefix
        return None


def check_tree(root, table, literal, findings, notices):
    """Check every source file under `root`; answer the file count."""
    files = set()
    for path, number, line in source_lines(root):
        files.add(path)
        for m in THEME_REFERENCE.finditer(line):
            unknown = table.unknown(m.group(1))
            if unknown is not None:
                findings.append(f"token-unknown {path}:{number} Theme.{unknown}")
        if literal is None:
            continue
        for rule, detail in literal_findings(line):
            (findings if literal == "finding" else notices).append(f"{rule} {path}:{number} {detail}")
    if not files:
        raise Unreadable(root, "no source file found")
    return len(files)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    parser.add_argument("plugin_dirs", nargs="*")
    args = parser.parse_args(argv[1:])
    repo = os.path.abspath(args.repo)
    shell = os.path.join(repo, "shell")
    templates = os.path.join(repo, ".agents", "skills", "vgs-plugin", "templates")
    fixtures = os.path.join(repo, "scripts", "smoke", "fixtures", "plugins")
    # root -> how a literal rule is reported there: a finding, a notice, or
    # not judged.
    if args.plugin_dirs:
        trees = [(os.path.abspath(d), "notice") for d in args.plugin_dirs]
    else:
        trees = [(os.path.join(shell, "Ui"), "finding"), (os.path.join(shell, "Hosts"), "finding"), (os.path.join(shell, "plugins"), "finding"), (templates, "finding"),
                 (os.path.join(shell, "Commons"), None), (os.path.join(shell, "Core"), None), (fixtures, None)]
    findings = []
    notices = []
    files = 0
    try:
        table = Table(repo)
        for group in table.unpublished:
            findings.append(f"group-unpublished {table.theme}:{table.members_line} {group}")
        for root, literal in trees:
            files += check_tree(root, table, literal, findings, notices)
    except Unreadable as exc:
        print(f"check-design-tokens: unreadable: {exc.path}: {exc.strerror}")
        return 2
    for line in notices:
        print("notice " + line)
    for line in findings:
        print(line)
    if findings:
        print(f"check-design-tokens: findings={len(findings)}")
        return 1
    print(f"check-design-tokens: ok files={files}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
