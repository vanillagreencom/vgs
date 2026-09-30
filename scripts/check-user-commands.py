#!/usr/bin/env python3
"""Enforce the no-manual-commands rule of D061 on the text a user reads.

A setup step is automatic or one click; a command the user could run by
hand is only a secondary "Show command" disclosure beside that click. This
check fails where user-facing text tells the user to run a command:
  instruction   a clause that opens with an imperative verb of VERBS and
                names a command: inline code whose first word is a command
                head, or, outside Markdown, a command head as the verb's
                object; or a clause whose subject is inline code naming a
                command, followed by a verb of SUBJECT_VERBS, as in
                "`vgsh plugin enable x` brings it back". A clause opens at
                the start of the text, after `.`, `!`, `?`, `:` or `;`,
                after a comma, and after `or` or `then`. A first word that
                is a path names the command its last part does, so
                `bin/vgsh` is `vgsh`.
  shell-block   a fenced code block of Markdown, untagged or tagged with a
                shell of SHELL_FENCES, whose first command word is a command
                head.
  code-command  a command inside a string literal of shipped QML or
                JavaScript bound to a property of DRAWN, the text a page, a
                notice, a toast or a CodeLine draws: inline code whose first
                word is a command head, or a literal that opens with a head
                and an argument, as "vgsh plugin enable x" does. A command
                there is copied off a label, where the one route is a
                CommandDisclosure. A log line is read by `instruction`
                alone. A binding reaches back over the lines its statement
                wraps across, so `text: ready` then `? "..."` on the next
                line is bound to `text`.
  drawn-command-line  a property of DRAWN bound, on its line, to an
                expression naming COMMAND_LINE, the name a judge gives a
                value that holds a whole command a reader could run, such
                as PluginLogic.noticeView's `commandLine`: that value
                reaches the screen only as a CommandDisclosure's `command`,
                which DRAWN does not hold.
A string literal is a quoted one or a template literal, whose `${...}`
parts read as the argument $ARG.
The text read is every Markdown file and every manifest.json of each plugin
directory under the root's plugins/, the user-facing strings of each
manifest (FIELDS, each key the judge admits named there or in EXEMPT), and
every string literal of every `.qml` and `.js` file
under the root, comments blanked through scripts/qml_source.py. A
`<details>` block of Markdown whose `<summary>` reads "Show command" is the
disclosure and is not read; a manifest's status `command` is the
disclosure the Settings page draws, and PluginLogic.statusError refuses one
without its action.

A command head is a command VGS knows a user could be told to run: a file
name in bin/, a requirement `command` of any plugin manifest under the root
or the repository's shell/ and of config/requirements.json, a binary of every manager in
shell/Core/PackageManagers.js and each of its elevators. The heads are read
from those artifacts, never listed here; fewer than HEADS_FLOOR, or a set
missing a REQUIRED_HEADS member, means an extractor broke, and the run ends
unreadable rather than certifying a tree against too few heads.

Usage: check-user-commands.py [ROOT | --plugin DIR]
ROOT is the repository's shell/ by default. `--plugin DIR` reads one plugin
directory alone, as `vgs-plugin check` passes it. The pass is
`check-user-commands: ok files=<n> strings=<n> heads=<n>`. Each finding is
one line `<rule> <file>:<line> <excerpt>`. Exit 0 when clean, 1 on any
finding, 2 when a file cannot be read or the heads are incomplete, printed
as `check-user-commands: unreadable: <what>: <why>`.
"""
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
from qml_source import Unreadable, blank_comments, source_texts

REPO = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

VERBS = ("run", "type", "paste", "execute", "enter", "use", "call", r"install\s+with")
# What inline code does as the subject of a clause that tells the reader
# to run it, as in "`x` brings it back". A verb that as often says what a
# command does on its own, such as "starts" in "`vgsh run` starts the shell
# again", is not one.
SUBJECT_VERBS = ("brings", "fixes", "installs", "enables", "restores", "repairs", "sets", "turns", "adds", "connects", "stores")
SHELL_FENCES = ("", "bash", "sh", "shell", "console", "zsh", "fish")
HEADS_FLOOR = 20
# Members the head extractors must yield: the core's own command and an
# elevator. A set without them came from a broken extractor.
REQUIRED_HEADS = ("vgsh", "sudo")

# The manifest keys a user reads, each a path whose `*` is any key of a
# table or index of a list.
FIELDS = (
    ("name",), ("description",), ("author",),
    ("schema", "*", "label"), ("schema", "*", "description"), ("schema", "*", "group"), ("schema", "*", "options", "*"),
    ("status", "*", "label"), ("status", "*", "group"), ("status", "*", "hint"), ("status", "*", "action", "label"),
    ("requirements", "*", "purpose"),
    ("tui", "*", "title"), ("tui", "*", "entry", "label"), ("tui", "*", "entry", "group"),
    ("secrets", "label"),
)
# The keys the judge admits that the check does not read, and why: an
# identifier, a path or a value no one reads as prose, or the Show command
# disclosure itself.
EXEMPT = (
    ("schemaVersion",), ("id",), ("version",), ("license",), ("icon",), ("kinds",), ("entryPoints",),
    ("capabilities",), ("settings",), ("defaultSection",), ("appearance",),
    ("schema", "*", "type"), ("schema", "*", "optionsFrom"), ("schema", "*", "min"), ("schema", "*", "max"), ("schema", "*", "step"),
    ("status", "*", "type"), ("status", "*", "hidden"), ("status", "*", "command"),
    ("status", "*", "action", "tui"), ("status", "*", "action", "install"),
    ("requirements", "*", "command"), ("requirements", "*", "packages"), ("requirements", "*", "optional"),
    ("tui", "*", "script"), ("tui", "*", "size"), ("tui", "*", "presentation"), ("tui", "*", "entry", "icon"),
    ("secrets", "service"),
    ("hyprland", "binds", "*", "shortcut"), ("hyprland", "binds", "*", "key"), ("hyprland", "binds", "*", "hold"), ("hyprland", "appearance"),
    ("hyprland", "layerRules", "*", "namespace"), ("hyprland", "layerRules", "*", "blur"), ("hyprland", "layerRules", "*", "ignoreAlpha"),
)

# A clause's rest runs to its sentence's end: a `.`, `!`, `?` or `;` that
# ends a word, never one inside inline code or a dotted name.
CLAUSE = re.compile(r"(?:^|[.!?:;]\s+|,\s*|\b(?:or|then)\s+)(" + "|".join(VERBS) + r")\b((?:`[^`\n]*`|[.!?;](?=[^\s`])|[^.!?;`\n])*)", re.I | re.M)
SUBJECT = re.compile(r"(?:^|[.!?:;]\s+|,\s*|\b(?:or|then)\s+)`([^`\n]+)`\s+(" + "|".join(SUBJECT_VERBS) + r")\b", re.I | re.M)
INLINE_CODE = re.compile(r"`([^`\n]+)`")
# In a string literal, code may run past its end into the next literal a
# concatenation adds, as `"`vgsh plugin enable " + id + "`"` does.
LITERAL_CODE = re.compile(r"`([^`\n]+)(?:`|$)")
FENCE = re.compile(r"^([ \t]*)(```+|~~~+)[ \t]*([A-Za-z0-9_+-]*)[^\n]*\n(.*?)^\1\2[ \t]*$", re.M | re.S)
DETAILS = re.compile(r"<details>\s*<summary>\s*Show command\s*</summary>.*?</details>", re.S | re.I)
# The properties whose text a component draws: a Label's and a Button's
# text, a Field's hint and error, a TextField's placeholder, a toast's or a
# notice's title and message, a row's label and description.
DRAWN = ("text", "hint", "error", "description", "placeholderText", "title", "message", "label", "secondary", "body", "summary")
DRAWN_BEFORE = re.compile(r"\b(?:" + "|".join(DRAWN) + r")\s*:")
COMMAND_LINE = "commandLine"
STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'')
# A quoted literal or a template literal, the quoted ones first, so a
# backtick inside a quoted literal opens no template.
LITERAL = re.compile(STRING.pattern + r"|`(?:[^`\\]|\\.)*`", re.S)
TEMPLATE_PART = re.compile(r"\$\{[^{}]*\}")
WORD = re.compile(r"[A-Za-z0-9./~][A-Za-z0-9._+/~-]*")
# A line that carries its statement on from the one before: it opens with
# an operator, or the line before ends with one.
CONTINUES = re.compile(r"[ \t]*(?:[?:+.)]|&&|\|\|)")
CONTINUED = re.compile(r"(?:[?:+(,=]|&&|\|\|)\s*$")


def unreadable(what, why):
    print(f"check-user-commands: unreadable: {what}: {why}")
    sys.exit(2)


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeError) as exc:
        unreadable(path, getattr(exc, "strerror", None) or str(exc))


def plugin_dirs(root):
    base = os.path.join(root, "plugins")
    try:
        names = sorted(os.listdir(base))
    except OSError as exc:
        unreadable(base, exc.strerror)
    return [os.path.join(base, n) for n in names if os.path.isdir(os.path.join(base, n))]


def manager_heads():
    script = ("const m = require(process.argv[1]).load(process.argv[2]);"
              "process.stdout.write(JSON.stringify(m.MANAGERS.reduce((a, r) => a.concat(r.binaries), []).concat(m.ELEVATORS)));")
    try:
        out = subprocess.run(["node", "-e", script, os.path.join(REPO, "bin", "lib", "qml-library.js"),
                              os.path.join(REPO, "shell", "Core", "PackageManagers.js")],
                             capture_output=True, text=True, check=True, env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")})
        heads = json.loads(out.stdout)
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        unreadable("shell/Core/PackageManagers.js", "the managers' binaries did not load: " + str(exc).splitlines()[0])
    if not isinstance(heads, list) or not all(isinstance(h, str) for h in heads):
        unreadable("shell/Core/PackageManagers.js", "the managers' binaries are no list of names")
    return heads


def command_heads(root, manifests):
    heads = set(manager_heads())
    try:
        heads.update(n for n in os.listdir(os.path.join(REPO, "bin")) if os.path.isfile(os.path.join(REPO, "bin", n)))
    except OSError as exc:
        unreadable(os.path.join(REPO, "bin"), exc.strerror)
    core = os.path.join(REPO, "config", "requirements.json")
    shipped = []
    for d in plugin_dirs(os.path.join(REPO, "shell")):
        path = os.path.join(d, "manifest.json")
        if os.path.exists(path):
            try:
                shipped.append((path, json.loads(read(path))))
            except ValueError as exc:
                unreadable(path, "not JSON: " + str(exc))
    for source, doc in [(core, json.loads(read(core)))] + shipped + manifests:
        reqs = doc if source == core else doc.get("requirements", [])
        for req in reqs if isinstance(reqs, list) else []:
            if isinstance(req, dict) and isinstance(req.get("command"), str):
                heads.add(req["command"])
    if len(heads) < HEADS_FLOOR or any(h not in heads for h in REQUIRED_HEADS):
        unreadable("command heads", f"found {len(heads)}, want at least {HEADS_FLOOR} holding {', '.join(REQUIRED_HEADS)}: an extractor is broken")
    return heads


def first_word(code):
    text = code.strip()
    if text.startswith("$ "):
        text = text[2:].lstrip()
    match = WORD.match(text)
    return os.path.basename(match.group(0).rstrip("/")) if match else ""


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def statement_start(code, index):
    """Where the statement holding INDEX of CODE starts: the start of its
    line, moved back over each line it wraps from."""
    start = code.rfind("\n", 0, index) + 1
    while start > 0:
        before = code.rfind("\n", 0, start - 1) + 1
        if not (CONTINUES.match(code, start) or CONTINUED.search(code[before:start - 1])):
            break
        start = before
    return start


def enclosing_type(code, index):
    """The QML type whose `{` block holds INDEX of CODE, or ""."""
    depth = 0
    for at in range(index - 1, -1, -1):
        if code[at] == "}":
            depth += 1
        elif code[at] == "{":
            if depth == 0:
                match = re.search(r"([A-Z][A-Za-z0-9_]*)\s*$", code[:at])
                return match.group(1) if match else ""
            depth -= 1
    return ""


def opens_with_command(value, heads, copied):
    """Whether VALUE reads as a command line: a head, then an argument. A
    CodeLine's text (COPIED) is one whatever its words; drawn prose that
    opens with a command's name, as "vsys sees nothing wrong." does, is
    one only when it ends with no sentence stop and one of its arguments
    reads as a flag, a path, a dotted name, an assignment or a template
    literal's `${...}`, read as $ARG."""
    text = value.strip()
    if text.startswith("$ "):
        text = text[2:].lstrip()
    parts = text.split()
    if len(parts) < 2 or first_word(parts[0]) not in heads or parts[0] != WORD.match(parts[0]).group(0):
        return False
    return copied or (not text.endswith((".", "!", "?")) and any(re.search(r"^-|[./=:$]", word) for word in parts[1:]))


def blank(text, pattern):
    """TEXT with every match of PATTERN replaced by spaces, newlines kept."""
    return pattern.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def instructions(text, heads, bare):
    """(index, excerpt) of each clause of TEXT that tells the reader to run
    a command: inline code naming a head, or with BARE a head as the verb's
    first word."""
    out = []
    for match in CLAUSE.finditer(text):
        rest = match.group(2)
        named = any(first_word(code) in heads for code in INLINE_CODE.findall(rest))
        if not named and bare:
            named = first_word(rest.lstrip("`\"' ")) in heads
        if named:
            out.append((match.start(1), (match.group(1) + match.group(2)).strip()[:120]))
    for match in SUBJECT.finditer(text):
        if first_word(match.group(1)) in heads:
            out.append((match.start(), match.group(0).strip(" ,.;:!?")[:120]))
    return sorted(out)


def check_markdown(path, heads, findings):
    text = blank(read(path), DETAILS)
    for fence in FENCE.finditer(text):
        lang = fence.group(3).lower()
        body = [line for line in fence.group(4).splitlines() if line.strip()]
        if lang in SHELL_FENCES and body and first_word(body[0]) in heads:
            findings.append(("shell-block", path, line_of(text, fence.start()), body[0].strip()[:120]))
    prose = blank(text, FENCE)
    for index, excerpt in instructions(prose, heads, False):
        findings.append(("instruction", path, line_of(prose, index), excerpt))


def resolve(node, pattern, where=()):
    """(where, value) of each value of NODE at PATTERN, a FIELDS path."""
    if not pattern:
        yield ".".join(where), node
        return
    head, rest = pattern[0], pattern[1:]
    if head == "*":
        items = node.items() if isinstance(node, dict) else enumerate(node) if isinstance(node, list) else []
        for key, child in items:
            yield from resolve(child, rest, where + (str(key),))
    elif isinstance(node, dict) and head in node:
        yield from resolve(node[head], rest, where + (head,))


def manifest_strings(doc):
    """(where, text) of every user-facing string of manifest DOC (FIELDS)."""
    return [(where, value) for pattern in FIELDS for where, value in resolve(doc, pattern) if isinstance(value, str)]


def main(argv):
    if len(argv) == 3 and argv[1] == "--plugin":
        root = os.path.realpath(argv[2])
        dirs = [root]
    elif len(argv) <= 2 and (len(argv) == 1 or not argv[1].startswith("-")):
        root = os.path.realpath(argv[1]) if len(argv) == 2 else os.path.join(REPO, "shell")
        dirs = plugin_dirs(root)
    else:
        print("usage: check-user-commands.py [ROOT | --plugin DIR]")
        return 2
    manifests, markdown = [], []
    for d in dirs:
        path = os.path.join(d, "manifest.json")
        if os.path.exists(path):
            try:
                manifests.append((path, json.loads(read(path))))
            except ValueError as exc:
                unreadable(path, "not JSON: " + str(exc))
        for current, subdirs, files in os.walk(d, onerror=lambda e: unreadable(e.filename, e.strerror)):
            subdirs.sort()
            markdown.extend(os.path.join(current, f) for f in sorted(files) if f.endswith(".md"))
    heads = command_heads(root, manifests)
    findings = []
    strings = 0
    for path in markdown:
        check_markdown(path, heads, findings)
    for path, doc in manifests:
        for where, text in manifest_strings(doc):
            strings += 1
            for _index, excerpt in instructions(text, heads, True):
                findings.append(("instruction", path, where, excerpt))
    code_files = 0
    try:
        for path, text in source_texts(root):
            code_files += 1
            code = blank_comments(text)
            masked = blank(code, LITERAL)
            for use in re.finditer(r"\b" + COMMAND_LINE + r"\b(?![ \t]*:)", masked):
                start = statement_start(masked, use.start())
                if DRAWN_BEFORE.search(masked, start, use.start()) is not None:
                    end = masked.find("\n", use.end())
                    findings.append(("drawn-command-line", path, line_of(masked, use.start()), masked[start:end if end != -1 else len(masked)].strip()[:120]))
            for literal in LITERAL.finditer(code):
                strings += 1
                token = literal.group(0)
                value = TEMPLATE_PART.sub("$ARG", token[1:-1]) if token.startswith("`") else token[1:-1]
                line = line_of(code, literal.start())
                for _index, excerpt in instructions(value, heads, True):
                    findings.append(("instruction", path, line, excerpt))
                start = statement_start(masked, literal.start())
                if DRAWN_BEFORE.search(masked, start, literal.start()) is None:
                    continue
                inline_named = not token.startswith("`") and any(first_word(inline) in heads for inline in LITERAL_CODE.findall(value))
                if inline_named or opens_with_command(value, heads, enclosing_type(masked, literal.start()) == "CodeLine"):
                    findings.append(("code-command", path, line, value.strip()[:120]))
    except Unreadable as exc:
        unreadable(exc.path, exc.strerror)
    files = len(markdown) + len(manifests) + code_files
    if files == 0:
        unreadable(root, "no file to read: an empty walk certifies nothing")
    for rule, path, where, excerpt in findings:
        print(f"{rule} {os.path.relpath(path, REPO)}:{where} {excerpt}")
    if findings:
        print(f"check-user-commands: findings={len(findings)}")
        return 1
    print(f"check-user-commands: ok files={files} strings={strings} heads={len(heads)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
