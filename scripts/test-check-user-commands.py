#!/usr/bin/env python3
"""One planted violation per rule of check-user-commands.py, the text each
rule must pass, the "Show command" disclosure's reach, the unreadable trees,
and the repository's own shell/ against a coverage floor. Each row builds a
throwaway shell/ holding one plugin, runs the check on it and asserts the
rule key, the location and the exit status. The controls at the end run a
copy of the check with one rule removed, and the rows must fail on it."""
import importlib.machinery
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import types

# A check loaded to read its lists compiles no bytecode into the tree.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.realpath(os.path.join(HERE, ".."))
CHECK = os.path.join(HERE, "check-user-commands.py")
ENV = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}

MANIFEST = '{ "schemaVersion": 1, "id": "acme.setup", "name": "Setup", "version": "1", "author": "a", "description": "Shows a token", "kinds": ["service"], "entryPoints": { "service": "Service.qml" } }\n'
SERVICE = 'import QtQuick\nItem {\n    property string note: "Checks the token"\n}\n'
FENCE = "```"


def manifest(**extra):
    text = MANIFEST.rstrip().rstrip("}")
    for key, value in extra.items():
        text += ', "' + key + '": ' + value
    return text + " }\n"


def qml(line):
    return "import QtQuick\nItem {\n" + line + "\n}\n"


# rows: name, { file in the plugin: text }, rule key or None, location.
ROWS = [
    ("a clean plugin", {}, None, None),
    ("a README step to run a command", {"README.md": "# Setup\n\n1. Run `vsys warden install` once.\n"}, "instruction", "README.md:3"),
    ("an instruction after a comma and or", {"README.md": "Open it from the launcher, or run `vgsh ipc call acme.setup invoke go \"\"`.\n"}, "instruction", "README.md:1"),
    ("an instruction to type at a command's prompt", {"docs.md": "Type the token at `secret-tool`'s prompt.\n"}, "instruction", "docs.md:1"),
    ("an instruction to paste a command", {"README.md": "Paste `sudo pacman -S gum` into a terminal.\n"}, "instruction", "README.md:1"),
    ("an instruction whose code holds a dot", {"README.md": "Then run `vgsh plugin enable acme.setup` again.\n"}, "instruction", "README.md:1"),
    ("an instruction past a dotted name", {"README.md": "Run the acme.setup step with `vgsh plugin enable acme.setup`.\n"}, "instruction", "README.md:1"),
    ("a verb inside a word opens no clause", {"README.md": "Each open runs `vsys --once --summary` once.\n"}, None, None),
    ("an instruction naming code that is no command", {"README.md": "Type a key such as `SUPER+SHIFT+M`.\n"}, None, None),
    ("a command named without an instruction", {"README.md": "The service runs `vgsh doctor --json` at start.\n"}, None, None),
    ("a noun run opens no clause", {"README.md": "A run that fails is logged as `agent-warden: summary=...`.\n"}, None, None),
    ("a shell block of a command", {"README.md": "Store it with:\n\n" + FENCE + "bash\nsecret-tool store service acme account a\n" + FENCE + "\n"}, "shell-block", "README.md:3"),
    ("an untagged block of a command", {"README.md": "Install:\n\n" + FENCE + "\n$ sudo pacman -S gum\n" + FENCE + "\n"}, "shell-block", "README.md:3"),
    ("a block of a script that is no command", {"README.md": "A caller waits:\n\n" + FENCE + "bash\nuntil [[ -s $done ]]; do sleep 0.05; done\n" + FENCE + "\n"}, None, None),
    ("a block of another language", {"README.md": "The layer writes:\n\n" + FENCE + "lua\nvgsh.rule()\n" + FENCE + "\n"}, None, None),
    ("an instruction inside a code block is the block's", {"README.md": FENCE + "text\nRun `gum` now.\n" + FENCE + "\n"}, None, None),
    ("the Show command disclosure", {"README.md": "Settings offers Set up.\n\n<details><summary>Show command</summary>\n\nRun `vsys warden install`.\n\n" + FENCE + "bash\nvsys warden install\n" + FENCE + "\n\n</details>\n"}, None, None),
    ("a disclosure under another summary", {"README.md": "<details><summary>More</summary>\n\n" + FENCE + "bash\nvsys warden install\n" + FENCE + "\n\n</details>\n"}, "shell-block", "README.md:3"),
    ("a manifest hint telling the user to run a command", {"manifest.json": manifest(capabilities='["status"]', status='{ "a": { "type": "text", "label": "A", "hint": "Run loginctl enable-linger once" } }')}, "instruction", "manifest.json:status.a.hint"),
    ("a manifest description telling the user to run code", {"manifest.json": manifest(description='"Shows a token. Run `vgsh doctor` first"')}, "instruction", "manifest.json:description"),
    ("a manifest status command is the disclosure", {"manifest.json": manifest(capabilities='["status"]', status='{ "a": { "type": "text", "label": "A", "command": "loginctl enable-linger" } }')}, None, None),
    ("a drawn QML string naming a command", {"Service.qml": qml('    property string hint: "Off; `vgsh plugin enable " + id + "` brings it back"')}, "code-command", "Service.qml:3"),
    ("a drawn text naming a command", {"Service.qml": qml('    Label { text: "Paste it with `secret-tool store`" }')}, "code-command", "Service.qml:3"),
    ("a log line naming a command", {"Service.qml": qml('    Component.onCompleted: console.warn("acme: refused; start it with `vgsh run`")')}, None, None),
    ("a log line telling the user to run a command", {"Service.qml": qml('    Component.onCompleted: console.warn("acme: refused: run vgsh doctor")')}, "instruction", "Service.qml:3"),
    ("a JavaScript toast telling the user to run a command", {"Logic.js": '.pragma library\nvar TOAST = { title: "Token missing", message: "Run `secret-tool store` to add it" };\n'}, "instruction", "Logic.js:2"),
    ("a command in a comment", {"Service.qml": qml('    // Run `vgsh doctor` to see it.')}, None, None),
    ("a notice body drawing its command line", {"Service.qml": qml('    Label { text: "Install with " + view.commandLine }')}, "drawn-command-line", "Service.qml:3"),
    ("a message bound to a command line", {"Logic.js": '.pragma library\nvar TOAST = { title: "Missing", message: shown.commandLine };\n'}, "drawn-command-line", "Logic.js:2"),
    ("a command line behind Show command", {"Service.qml": qml('    CommandDisclosure { command: view.commandLine }')}, None, None),
    ("a judge naming its command line", {"Logic.js": '.pragma library\nvar VIEW = { commandLine: "vgsh pkg run install a" };\n'}, None, None),
    ("a drawn string that only says commandLine", {"Service.qml": qml('    Label { text: "commandLine" }')}, None, None),
    ("a command named by its path", {"README.md": "Run `bin/vgsh plugin enable acme.setup` once.\n"}, "instruction", "README.md:1"),
    ("a command as the clause's subject", {"README.md": "Turn it off in Settings; `bin/vgsh plugin enable acme.setup` brings it back.\n"}, "instruction", "README.md:1"),
    ("a step that says use", {"README.md": "Use `vgsh doctor` to see what is missing.\n"}, "instruction", "README.md:1"),
    ("a step that says install with", {"README.md": "Install with `paru -S acme-tool` first.\n"}, "instruction", "README.md:1"),
    ("a step that says call", {"Logic.js": '.pragma library\nvar NOTE = "Call vgsh ipc call acme.setup invoke go";\n'}, "instruction", "Logic.js:2"),
    ("a bare command in a drawn string", {"Service.qml": qml('    Label { text: "vgsh plugin enable acme.setup" }')}, "code-command", "Service.qml:3"),
    ("a bare command as a CodeLine's text", {"Service.qml": qml('    CodeLine { text: "vgsh doctor" }')}, "code-command", "Service.qml:3"),
    ("drawn prose that opens with a command's name", {"Service.qml": qml('    Label { text: "vsys sees nothing wrong on this computer." }')}, None, None),
    ("a drawn state that opens with a command's name", {"Service.qml": qml('    Label { text: "loginctl did not answer" }')}, None, None),
    ("a template literal telling the user to run a command", {"Logic.js": '.pragma library\nvar TOAST = { title: "Missing", message: `Run vgsh doctor for ${name}` };\n'}, "instruction", "Logic.js:2"),
    ("a drawn template literal holding a command", {"Service.qml": qml('    Label { text: `vgsh plugin enable ${id}` }')}, "code-command", "Service.qml:3"),
    ("a drawn binding wrapped over lines", {"Service.qml": qml('    Label {\n        text: ready\n            ? "Done"\n            : "`vgsh doctor` shows it"\n    }')}, "code-command", "Service.qml:6"),
    ("a command line bound to a drawn property over lines", {"Service.qml": qml('    Label {\n        text: shown\n            ? shown.commandLine\n            : ""\n    }')}, "drawn-command-line", "Service.qml:5"),
    ("a secrets label telling the user to run a command", {"manifest.json": manifest(capabilities='["secrets"]', secrets='{ "service": "acme", "label": "Run `vgsh doctor` first" }')}, "instruction", "manifest.json:secrets.label"),
]


def build(tmp, files):
    plugin = os.path.join(tmp, "shell", "plugins", "acme.setup")
    os.makedirs(plugin)
    base = {"manifest.json": MANIFEST, "Service.qml": SERVICE}
    base.update(files)
    for name, text in base.items():
        with open(os.path.join(plugin, name), "w", encoding="utf-8") as fh:
            fh.write(text)
    return os.path.join(tmp, "shell")


def run(check, root):
    return subprocess.run([sys.executable, check, root], capture_output=True, text=True, env=ENV)


def rows_hold(check):
    """The failures of every row against CHECK, as lines."""
    failures = []
    for name, files, rule, where in ROWS:
        with tempfile.TemporaryDirectory() as tmp:
            done = run(check, build(tmp, files))
        lines = done.stdout.splitlines()
        if rule is None:
            if done.returncode != 0 or not lines or not lines[-1].startswith("check-user-commands: ok "):
                failures.append(f"{name}: want a pass, got exit {done.returncode}: {done.stdout.strip()} {done.stderr.strip()}")
            continue
        found = [line for line in lines if line.startswith(rule + " ") and (os.sep + "acme.setup" + os.sep + where) in line]
        if done.returncode != 1 or len(found) != 1:
            failures.append(f"{name}: want one {rule} at {where} and exit 1, got exit {done.returncode}: {done.stdout.strip()} {done.stderr.strip()}")
    return failures


# Where the judge's key lists sit in a manifest: a path, whether a `*`
# key or index comes between it and the keys, and the list. A key whose path
# is here is a table of keys, not a value.
NESTED = {
    ("schema",): (True, "SCHEMA_ENTRY_KEYS"),
    ("status",): (True, "STATUS_ENTRY_KEYS"),
    ("status", "*", "action"): (False, "STATUS_ACTION_KEYS"),
    ("requirements",): (True, "REQUIREMENT_KEYS"),
    ("tui",): (True, "TUI_KEYS"),
    ("tui", "*", "entry"): (False, "TUI_ENTRY_KEYS"),
    ("secrets",): (False, "SECRETS_KEYS"),
    ("hyprland",): (False, "HYPRLAND_KEYS"),
    ("hyprland", "binds"): (True, "HYPRLAND_BIND_KEYS"),
    ("hyprland", "layerRules"): (True, "HYPRLAND_RULE_KEYS"),
}


def admitted_paths():
    """Every leaf path of a manifest PluginLogic admits, from its key lists."""
    names = ["MANIFEST_KEYS"] + sorted({name for _star, name in NESTED.values()})
    script = "const m = require(process.argv[1]).load(process.argv[2]); const out = {}; for (const n of process.argv.slice(3)) out[n] = m[n]; process.stdout.write(JSON.stringify(out));"
    done = subprocess.run(["node", "-e", script, os.path.join(REPO, "bin", "lib", "qml-library.js"), os.path.join(REPO, "shell", "Core", "PluginLogic.js")] + names, capture_output=True, text=True, env=ENV)
    lists = json.loads(done.stdout)
    missing = [n for n in names if not isinstance(lists.get(n), list)]
    if done.returncode != 0 or missing:
        return None, f"the judge's key lists did not load: exit {done.returncode} missing={missing} {done.stderr.strip()}"
    leaves = []

    def expand(path):
        if path in NESTED:
            star, name = NESTED[path]
            for key in lists[name]:
                expand(path + (("*",) if star else ()) + (key,))
        else:
            leaves.append(path)
    for key in lists["MANIFEST_KEYS"]:
        expand((key,))
    return leaves, ""


def fields_unclassified(check):
    """Each admitted leaf path CHECK names in neither FIELDS nor EXEMPT, as
    lines; a pattern that runs on past a leaf, as schema.*.options.* does,
    names it."""
    loader = importlib.machinery.SourceFileLoader("check_user_commands_" + str(abs(hash(check))), check)
    module = types.ModuleType(loader.name)
    module.__file__ = check
    sys.path.insert(0, os.path.dirname(check))
    try:
        loader.exec_module(module)
    finally:
        sys.path.pop(0)
    leaves, error = admitted_paths()
    if leaves is None:
        return [error]
    named = list(module.FIELDS) + list(module.EXEMPT)
    return [".".join(leaf) + ": named in neither FIELDS nor EXEMPT" for leaf in leaves if not any(tuple(p[:len(leaf)]) == leaf for p in named)]


failures = rows_hold(CHECK) + fields_unclassified(CHECK)

# The repository's own shell/ passes, over a floor that proves the walk
# read the tree: the plugins' Markdown and manifests and the shipped QML.
done = run(CHECK, os.path.join(REPO, "shell"))
summary = re.match(r"check-user-commands: ok files=(\d+) strings=(\d+) heads=(\d+)$", done.stdout.strip().splitlines()[-1] if done.stdout.strip() else "")
if done.returncode != 0 or summary is None:
    failures.append(f"the repository's shell/: want a pass, got exit {done.returncode}: {done.stdout.strip()}")
elif int(summary.group(1)) < 150 or int(summary.group(2)) < 5000 or int(summary.group(3)) < 20:
    failures.append(f"the repository's shell/: the walk read too little, files={summary.group(1)} strings={summary.group(2)} heads={summary.group(3)}: an extractor is broken")

# Unreadable trees end the run with exit 2 and certify nothing.
with tempfile.TemporaryDirectory() as tmp:
    done = run(CHECK, build(tmp, {"manifest.json": "{ not json"}))
    if done.returncode != 2 or "check-user-commands: unreadable: " not in done.stdout:
        failures.append(f"a manifest that is no JSON: want unreadable and exit 2, got exit {done.returncode}: {done.stdout.strip()}")
with tempfile.TemporaryDirectory() as tmp:
    done = run(CHECK, os.path.join(tmp, "missing"))
    if done.returncode != 2 or "check-user-commands: unreadable: " not in done.stdout:
        failures.append(f"a root without plugins/: want unreadable and exit 2, got exit {done.returncode}: {done.stdout.strip()}")

# One plugin directory alone, as `vgs-plugin check` passes it, is read the
# same way.
with tempfile.TemporaryDirectory() as tmp:
    root = build(tmp, {"README.md": "Run `vsys warden install` once.\n"})
    done = subprocess.run([sys.executable, CHECK, "--plugin", os.path.join(root, "plugins", "acme.setup")], capture_output=True, text=True, env=ENV)
    if done.returncode != 1 or not re.search(r"^instruction \S*/acme\.setup/README\.md:1 ", done.stdout, re.M):
        failures.append(f"--plugin: want the README's instruction and exit 1, got exit {done.returncode}: {done.stdout.strip()}")

# Controls: a copy of the check with one rule removed, beside a copy of the
# modules it loads, must fail the rows. The copy reads the heads from this
# repository, as the check does.
CONTROLS = [
    ("the instruction rule", "        findings.append((\"instruction\", path, line_of(prose, index), excerpt))", "        pass"),
    ("the shell-block rule", "if lang in SHELL_FENCES and body and first_word(body[0]) in heads:", "if False:"),
    ("the code-command rule", "                    findings.append((\"code-command\", path, line, value.strip()[:120]))", "                    pass"),
    ("the manifest strings", "            for _index, excerpt in instructions(text, heads, True):\n                findings.append((\"instruction\", path, where, excerpt))", "            pass"),
    ("the disclosure's reach", "text = blank(read(path), DETAILS)", "text = read(path)"),
    ("the drawn-property reach of code-command", "if DRAWN_BEFORE.search(masked, start, literal.start()) is None:", "if False:"),
    ("the drawn-command-line rule", "if DRAWN_BEFORE.search(masked, start, use.start()) is not None:", "if False:"),
    ("a string literal names no command line", "masked = blank(code, LITERAL)", "masked = code"),
    ("a command named by its path", 'return os.path.basename(match.group(0).rstrip("/")) if match else ""', 'return match.group(0) if match else ""'),
    ("a command as the clause's subject", "    for match in SUBJECT.finditer(text):\n", "    for match in []:\n"),
    ("the verbs use, call and install with", ', "use", "call", r"install\\s+with")', ")"),
    ("a bare command in a drawn string", "if inline_named or opens_with_command(", "if inline_named or False and opens_with_command("),
    ("a CodeLine's text is copied", 'enclosing_type(masked, literal.start()) == "CodeLine"', "False"),
    ("drawn prose is no command line", "    return copied or (not text.endswith(", "    return True or (not text.endswith("),
    ("template literals", 'LITERAL = re.compile(STRING.pattern + r"|`(?:[^`\\\\]|\\\\.)*`", re.S)', "LITERAL = re.compile(STRING.pattern, re.S)"),
    ("a literal's binding reaches back over wrapped lines", "                start = statement_start(masked, literal.start())\n", "                start = masked.rfind(\"\\n\", 0, literal.start()) + 1\n"),
    ("a command line's binding reaches back over wrapped lines", "                start = statement_start(masked, use.start())\n", "                start = masked.rfind(\"\\n\", 0, use.start()) + 1\n"),
    ("a user-facing manifest key is read", '    ("secrets", "label"),\n)', ")"),
    ("every admitted manifest key is classified", '("license",), ("icon",), ("kinds",)', '("license",), ("kinds",)'),
    ("a clause after or", "|\\b(?:or|then)\\s+)(", ")("),
    ("inline code past a dot", "[.!?;](?=[^\\s`])|", ""),
    ("the heads floor", "if len(heads) < HEADS_FLOOR or any(h not in heads for h in REQUIRED_HEADS):", "if False:"),
]
source = open(CHECK, encoding="utf-8").read()
with tempfile.TemporaryDirectory() as tmp:
    scripts = os.path.join(tmp, "scripts")
    os.makedirs(scripts)
    os.makedirs(os.path.join(tmp, "bin"))
    shutil.copy(os.path.join(HERE, "qml_source.py"), scripts)
    os.symlink(os.path.join(REPO, "bin", "vgsh-scan"), os.path.join(tmp, "bin", "vgsh-scan"))
    rooted = source.replace('REPO = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))', "REPO = " + repr(REPO))
    if rooted == source:
        failures.append("controls: the check's REPO line was not found to root the copies")
    for label, needle, replacement in CONTROLS:
        if rooted.count(needle) != 1:
            failures.append(f"control {label}: the text to replace occurs {rooted.count(needle)} times, want 1")
            continue
        mutant = os.path.join(scripts, "check-user-commands.py")
        with open(mutant, "w", encoding="utf-8") as fh:
            fh.write(rooted.replace(needle, replacement))
        if label == "the heads floor":
            # A copy that reads no bin/ and no manager must be refused by
            # the floor; without it, the copy passes on too few heads.
            with open(mutant, encoding="utf-8") as fh:
                text = fh.read()
            text = text.replace("heads = set(manager_heads())", "heads = set()").replace('os.listdir(os.path.join(REPO, "bin"))', "[]")
            with open(mutant, "w", encoding="utf-8") as fh:
                fh.write(text)
            with tempfile.TemporaryDirectory() as tree:
                done = run(mutant, build(tree, {}))
            if done.returncode != 0:
                failures.append(f"control {label}: the copy without the floor still refused a tree read against too few heads: {done.stdout.strip()}")
            continue
        if not rows_hold(mutant) and not fields_unclassified(mutant):
            failures.append(f"control {label}: the rows passed on a copy without it")
    # The floor itself: the unmodified check refuses a head set its
    # extractors lost.
    starved = rooted.replace("heads = set(manager_heads())", "heads = set()").replace('os.listdir(os.path.join(REPO, "bin"))', "[]")
    with open(os.path.join(scripts, "check-user-commands.py"), "w", encoding="utf-8") as fh:
        fh.write(starved)
    with tempfile.TemporaryDirectory() as tree:
        done = run(os.path.join(scripts, "check-user-commands.py"), build(tree, {}))
    if done.returncode != 2 or "an extractor is broken" not in done.stdout:
        failures.append(f"the heads floor: want unreadable with exit 2 on a lost extractor, got exit {done.returncode}: {done.stdout.strip()}")

for line in failures:
    print("FAIL " + line)
if failures:
    print(f"test-check-user-commands: failing={len(failures)}")
    sys.exit(1)
print(f"test-check-user-commands: ok rows={len(ROWS)} controls={len(CONTROLS)}")
