#!/usr/bin/env python3
"""Enforce the design token rules docs/architecture/design-system.md states.

Token rule, on every QML and JS file under shell/, the vgs-plugin skill
templates and the smoke fixtures:
  token-unknown      a `Theme.<path>` names no token, no group and no
                     read-only property or function Theme.qml declares; the
                     paths come from Tokens.js through bin/lib/qml-library.js,
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
Appearance rules, on a plugin whose manifest declares `appearance` (each
directory under shell/plugins, or each directory given): the plugin draws
with its own table, `look`, instead of Theme, so
  appearance-refused the declared file throws as it loads, or
                     ThemeLogic.acceptAppearance refuses its TOKENS and LIGHT
                     in dark or in light mode against the shell's defaults;
                     the manifest is read through PluginLogic.validateManifest,
                     and a manifest it refuses or a file bin/lib/qml-library.js
                     refuses (absent, no pragma) is unreadable
  look-unknown       a `look.<path>` names no path of that table
  theme-read         a `Theme.<path>` other than `Theme.appearance`, since
                     every other member carries the global look
  type-floor         a `length` under the table's `text` group, a font size,
                     resolves in either mode below the smallest size of the
                     shell's own text roles, the chrome floor a plugin that
                     owns its look meets too (docs/architecture/design-quality.md
                     § Type); read from Tokens.js, never a second number
The declared file is exempt from the literal rules, since the judge types
each of its values; every other file of the plugin stays under them, with a
radius that names `look.` reading a token.

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

# A plugin's appearance: its manifest judged by the one manifest judge and,
# when it declares `appearance`, the table in that file judged in both modes
# against the shell's defaults, with every path the table holds.
APPEARANCE = (
    "const fs = require('fs'); const path = require('path');"
    "const { load } = require(process.argv[1]);"
    "const plugins = load(process.argv[2]); const judge = load(process.argv[3]);"
    "const shell = judge.defaults(load(process.argv[4]).TOKENS).values;"
    "const dir = process.argv[5];"
    "const out = { error: null, appearance: null, refusals: [], paths: [], small: [] };"
    "const floor = Math.min.apply(null, Object.keys(shell.text).map(role => shell.text[role].size));"
    "let raw; try { raw = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8')); } catch (e) { out.error = e.message; }"
    "const judged = out.error === null ? plugins.validateManifest(raw, dir) : null;"
    "if (judged !== null && !judged.ok) out.error = 'manifest: ' + judged.error;"
    "if (judged !== null && judged.ok && judged.manifest.appearance !== undefined) {"
    "  out.appearance = judged.manifest.appearance;"
    "  let look = null; try { look = load(path.join(dir, out.appearance)); } catch (e) { out.refusals.push('unloadable: ' + e.message); }"
    "  if (look !== null) {"
    "    for (const mode of ['dark', 'light']) {"
    "      const theme = Object.assign({}, shell, { scheme: { mode: mode } });"
    "      const result = judge.acceptAppearance(look.TOKENS, look.LIGHT, theme);"
    "      if (!result.ok) { out.refusals.push('mode=' + mode + ' ' + judge.refusalLine(result).replace(/^theme: refused: /, '')); continue; }"
    "      for (const l of judge.leaves(look.TOKENS).filter(l => l.path.startsWith('text.') && l.leaf.type === 'length')) {"
    "        const size = l.path.split('.').reduce((node, key) => node[key], result.values);"
    "        if (size < floor) out.small.push(l.path + '=' + size + ' mode=' + mode + ' floor=' + floor);"
    "      }"
    "    }"
    "    if (out.refusals.length === 0) out.paths = judge.paths(look.TOKENS);"
    "  }"
    "}"
    "process.stdout.write(JSON.stringify(out));"
)

THEME_REFERENCE = re.compile(r"(?<![\w.$])Theme\.((?:[A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*)")
LOOK_REFERENCE = re.compile(r"(?<![\w$])look\.((?:[A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*)")
# The one member of Theme a plugin with its own appearance reads.
APPEARANCE_MEMBER = "appearance"
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


def literal_findings(line, tokens=("Theme.",)):
    """Every literal-rule finding on one code line, as (rule, detail).
    `tokens` are the prefixes a radius may name to read a token."""
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
        if not any(prefix in value for prefix in tokens) and not IS_PROPERTY_PATH.match(value):
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


def unknown_prefix(dotted, paths, leaves):
    """The shortest prefix of `dotted` that names no path, or None once a
    prefix names a leaf, whose value's own properties are not judged."""
    parts = dotted.split(".")
    for i in range(1, len(parts) + 1):
        prefix = ".".join(parts[:i])
        if prefix in leaves:
            return None
        if prefix not in paths:
            return prefix
    return None


class Look:
    """A plugin's appearance: the declared file and its table's paths, or
    None for a plugin that declares none."""

    def __init__(self, repo, plugin, require_manifest):
        commons = os.path.join(repo, "shell", "Commons")
        command = ["node", "-e", APPEARANCE, os.path.join(repo, "bin", "lib", "qml-library.js"), os.path.join(repo, "shell", "Core", "PluginLogic.js"),
                   os.path.join(commons, "ThemeLogic.js"), os.path.join(commons, "Tokens.js"), plugin]
        try:
            run = subprocess.run(command, capture_output=True, text=True, check=False, env=NODE_ENV)
        except OSError as exc:
            raise Unreadable("appearance", exc.strerror) from exc
        if run.returncode != 0:
            raise Unreadable(plugin, "appearance judge exited " + str(run.returncode) + ": " + run.stderr.strip())
        answer = json.loads(run.stdout)
        manifest = os.path.join(plugin, "manifest.json")
        if answer["error"] is not None:
            if not os.path.exists(manifest):
                self.plugin = require_manifest
                self.file = None
                return
            raise Unreadable(manifest, answer["error"])
        self.plugin = True
        self.file = None if answer["appearance"] is None else os.path.join(plugin, answer["appearance"])
        self.refusals = answer["refusals"]
        self.small = answer["small"]
        self.paths = set(answer["paths"])
        self.leaves = {p for p in self.paths if not any(other.startswith(p + ".") for other in self.paths)}


class Table:
    """The token paths a `Theme.<path>` may name."""

    def __init__(self, repo):
        commons = os.path.join(repo, "shell", "Commons")
        command = ["node", "-e", TOKEN_PATHS, os.path.join(repo, "bin", "lib", "qml-library.js"), os.path.join(commons, "Tokens.js"), os.path.join(commons, "ThemeLogic.js")]
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
        return unknown_prefix(dotted, self.paths, self.leaves)


def plugin_looks(repo, root, plugins):
    """The appearance of every plugin under `root`, keyed by its directory.
    `plugins` is "children" when each directory under `root` is a plugin,
    "self" when `root` is one, and None for a tree the rules skip."""
    if plugins is None:
        return {}
    if plugins == "self":
        dirs = [root]
        require_manifest = True
    else:
        try:
            names = sorted(os.listdir(root))
        except OSError as exc:
            raise Unreadable(root, exc.strerror) from exc
        dirs = [os.path.join(root, name) for name in names if os.path.isdir(os.path.join(root, name))]
        require_manifest = False
    return {d: Look(repo, d, require_manifest) for d in dirs}


def manifestless_plugin_dir(looks, path):
    """The manifestless plugin directory `path` sits in, or None."""
    for directory, look in looks.items():
        if not look.plugin and path.startswith(directory + os.sep):
            return directory
    return None


def look_of(looks, path):
    """The appearance of the plugin `path` sits in, or None."""
    for directory, look in looks.items():
        if path.startswith(directory + os.sep) and look.file is not None:
            return look
    return None


def check_tree(root, table, literal, looks, findings, notices):
    """Check every source file under `root`; answer the file count."""
    files = set()
    for look in looks.values():
        if look.file is not None:
            for refusal in look.refusals:
                findings.append(f"appearance-refused {look.file}:1 {refusal}")
            for small in look.small:
                (findings if literal != "notice" else notices).append(f"type-floor {look.file}:1 {small}")
    for path, number, line in source_lines(root):
        if manifestless_plugin_dir(looks, path) is not None:
            continue
        files.add(path)
        look = look_of(looks, path)
        for m in THEME_REFERENCE.finditer(line):
            unknown = table.unknown(m.group(1))
            if unknown is not None:
                findings.append(f"token-unknown {path}:{number} Theme.{unknown}")
            elif look is not None and m.group(1).split(".")[0] != APPEARANCE_MEMBER:
                findings.append(f"theme-read {path}:{number} Theme.{m.group(1)}")
        if look is not None and not look.refusals:
            for m in LOOK_REFERENCE.finditer(line):
                unknown = unknown_prefix(m.group(1), look.paths, look.leaves)
                if unknown is not None:
                    findings.append(f"look-unknown {path}:{number} look.{unknown}")
        if literal is None or (look is not None and path == look.file):
            continue
        for rule, detail in literal_findings(line, ("Theme.",) if look is None else ("Theme.", "look.")):
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
    # root -> how a literal rule is reported there (a finding, a notice, or
    # not judged) and where its plugins are, for the appearance rules.
    if args.plugin_dirs:
        trees = [(os.path.abspath(d), "notice", "self") for d in args.plugin_dirs]
    else:
        trees = [(os.path.join(shell, "Ui"), "finding", None), (os.path.join(shell, "Hosts"), "finding", None), (os.path.join(shell, "plugins"), "finding", "children"),
                 (templates, "finding", None), (os.path.join(shell, "Commons"), None, None), (os.path.join(shell, "Core"), None, None), (fixtures, None, None)]
    findings = []
    notices = []
    files = 0
    try:
        table = Table(repo)
        for group in table.unpublished:
            findings.append(f"group-unpublished {table.theme}:{table.members_line} {group}")
        for root, literal, plugins in trees:
            files += check_tree(root, table, literal, plugin_looks(repo, root, plugins), findings, notices)
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
