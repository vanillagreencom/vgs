#!/usr/bin/env python3
"""One temp tree per row for bin/vgsh-scan. Each listing row plants files
under a throwaway directory, removes permission bits where the row says so,
runs the scanner on the named base with the row's options, and asserts the
JSON elements it prints (the dir, either a text entry or the start of the
error, and the failing path where the row names one) plus the exit status.
The revision rows then read the scanner twice over one tree and compare
revisions, snapshots and pruning. The probe rows run the scanner with a PATH
of one stub directory and read each plugin's `missing` list; their control
runs them against a copy of the scanner that finds every command. The core
rows probe a --core requirements file beside a plugin; their control reads
that file as a manifest. The URL rows publish a snapshot under a root whose
path needs quoting, and run a scan in a child interpreter that reports
whether urllib.request was imported; their controls quote nothing and spell
the URL through pathlib's as_uri. Permission rows need a uid that
permissions bind; under euid 0 the script reports status=not-measured and
exits 77 instead of passing vacuously."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

SCAN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "vgsh-scan")
MANIFEST = '{"id": "acme.widget"}'
ENV = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}

# listing rows: name, files {relative path: text or bytes}, modes {relative path: mode}, base (relative),
# want [(dir, "text" | "error:<prefix>"[, failing path])], options, links {relative path: target}
ROWS = [
    ("absent base is skipped", {}, {}, "plugins", []),
    ("absent base under --require-base is an error", {}, {}, "plugins", [("plugins", "error:cannot list: ", "plugins")], ["--require-base"]),
    ("base that is a file is an error", {"plugins": "x"}, {}, "plugins", [("plugins", "error:cannot list: ")]),
    ("plugin dir without a manifest is skipped", {"plugins/a/Widget.qml": ""}, {}, "plugins", []),
    ("entry that is a file is skipped", {"plugins/README": ""}, {}, "plugins", []),
    ("readable manifest is a text entry", {"plugins/a/manifest.json": MANIFEST}, {}, "plugins", [("plugins/a", "text")]),
    ("plugin dir without its search bit is an error", {"plugins/a/manifest.json": MANIFEST, "plugins/b/manifest.json": MANIFEST}, {"plugins/a": 0o000}, "plugins",
     [("plugins/a", "error:cannot read manifest: ", "plugins/a/manifest.json"), ("plugins/b", "text")]),
    ("manifest without read permission is an error", {"plugins/a/manifest.json": MANIFEST}, {"plugins/a/manifest.json": 0o000}, "plugins",
     [("plugins/a", "error:cannot read manifest: ", "plugins/a/manifest.json")]),
    ("base without permission bits is an error", {"plugins/a/manifest.json": MANIFEST}, {"plugins": 0o000}, "plugins", [("plugins", "error:cannot list: ")]),
    ("inaccessible ancestor of the base is an error", {"root/plugins/a/manifest.json": MANIFEST}, {"root": 0o000}, "root/plugins", [("root/plugins", "error:cannot list: ")]),
    ("unreadable source file inside a plugin names the file", {"plugins/a/manifest.json": MANIFEST, "plugins/a/lib/Helper.qml": ""}, {"plugins/a/lib/Helper.qml": 0o000}, "plugins",
     [("plugins/a", "error:cannot read source: ", "plugins/a/lib/Helper.qml")]),
    ("unreadable directory inside a plugin names the directory", {"plugins/a/manifest.json": MANIFEST, "plugins/a/lib/Helper.qml": ""}, {"plugins/a/lib": 0o000}, "plugins",
     [("plugins/a", "error:cannot read source: ", "plugins/a/lib")]),
    ("manifest that is not UTF-8 is an error", {"plugins/a/manifest.json": b"\xff{}"}, {}, "plugins", [("plugins/a", "error:manifest is not UTF-8: ", "plugins/a/manifest.json")]),
    ("symbolic link cycle inside a plugin is an error", {"plugins/a/manifest.json": MANIFEST}, {}, "plugins", [("plugins/a", "error:cannot read source: directory cycle", "plugins/a/loop")], [], {"plugins/a/loop": "."}),
    ("entry that is neither a file nor a directory is an error", {"plugins/a/manifest.json": MANIFEST}, {}, "plugins", [("plugins/a", "error:cannot read source: not a regular file", "plugins/a/null")], [], {"plugins/a/null": "/dev/null"}),
    ("a symbolic link to a file is read as that file", {"plugins/a/manifest.json": MANIFEST, "shared/Helper.qml": "Item {}"}, {}, "plugins", [("plugins/a", "text")], [], {"plugins/a/Helper.qml": "../../shared/Helper.qml"}),
]


def element_kind(element):
    if "text" in element:
        return "text"
    return "error:" + element["error"]


def matches(got, want):
    if len(got) != len(want):
        return False
    for (got_dir, got_kind, got_path), want_row in zip(got, want):
        want_dir, want_kind = want_row[0], want_row[1]
        if got_dir != want_dir:
            return False
        if want_kind == "text" and got_kind != "text":
            return False
        if want_kind != "text" and not got_kind.startswith(want_kind):
            return False
        if len(want_row) == 3 and got_path != want_row[2]:
            return False
    return True


def plant(tmp, files, links=None):
    for rel, text in files.items():
        path = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(text if isinstance(text, bytes) else text.encode("utf-8"))
    for rel, target in (links or {}).items():
        path = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        os.symlink(target, path)


def scan(*args, script=SCAN, env=ENV):
    return subprocess.run([sys.executable, script, *args], capture_output=True, text=True, check=False, env=env)


def run_row(name, files, modes, base, want, options=(), links=None):
    with tempfile.TemporaryDirectory() as tmp:
        plant(tmp, files, links)
        try:
            for rel, mode in modes.items():
                os.chmod(os.path.join(tmp, rel), mode)
            proc = scan(*options, os.path.join(tmp, base))
        finally:
            for rel in modes:
                os.chmod(os.path.join(tmp, rel), 0o755)
        try:
            elements = json.loads(proc.stdout)
        except ValueError:
            elements = None
        got = None if elements is None else [(os.path.relpath(e["dir"], tmp), element_kind(e), os.path.relpath(e["path"], tmp) if "path" in e else None) for e in elements]
        good = proc.returncode == 0 and got is not None and matches(got, want)
        return report(name, good, f" (exit={proc.returncode} got={got})\n{proc.stdout}{proc.stderr}")


def report(name, good, detail=""):
    print(("  ok    " if good else "  FAIL  ") + name + ("" if good else detail))
    return good


def one_entry(proc):
    """The single element a clean scan of one plugin prints, or None."""
    if proc.returncode != 0:
        return None
    elements = json.loads(proc.stdout)
    if len(elements) != 1 or "error" in elements[0]:
        return None
    return elements[0]


def revision_rows():
    """Revisions, snapshots and pruning, read back from one tree the rows edit in place."""
    results = []
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "plugins")
        plugin = os.path.join(base, "a")
        root = os.path.join(tmp, "snapshots")
        plant(tmp, {"plugins/a/manifest.json": MANIFEST, "plugins/a/Widget.qml": "import QtQuick\nItem {}\n", "plugins/a/lib/Helper.qml": "Item {}\n", "plugins/a/.git/HEAD": "ref: refs/heads/main\n"})
        first = one_entry(scan(base))
        again = one_entry(scan(base))
        results.append(report("the same bytes give the same revision", first is not None and again is not None and first["revision"] == again["revision"] and first["text"] == MANIFEST, f"\n{first}\n{again}"))
        with open(os.path.join(plugin, ".git", "HEAD"), "w", encoding="utf-8") as fh:
            fh.write("ref: refs/heads/other\n")
        results.append(report("a change under .git keeps the revision", one_entry(scan(base))["revision"] == first["revision"]))
        with open(os.path.join(plugin, "lib", "Helper.qml"), "w", encoding="utf-8") as fh:
            fh.write("Item { property int edited: 1 }\n")
        second = one_entry(scan(base))
        results.append(report("an edit to a sibling file changes the revision and keeps the manifest text", second["revision"] != first["revision"] and second["text"] == MANIFEST))
        os.chmod(os.path.join(plugin, "Widget.qml"), 0o755)
        third = one_entry(scan(base))
        results.append(report("an executable bit changes the revision", third["revision"] not in (first["revision"], second["revision"])))

        published = one_entry(scan("--snapshot-dir", root, base))
        snapshot = os.path.join(root, third["revision"])
        results.append(report("a snapshot is published under its revision and named by loadUrl", published["loadUrl"] == pathlib.Path(snapshot).as_uri() and os.path.isdir(snapshot)))
        try:
            with open(os.path.join(snapshot, "lib", "Helper.qml"), "rb") as fh:
                helper = fh.read()
            same_bytes = helper == b"Item { property int edited: 1 }\n"
            executable = os.access(os.path.join(snapshot, "Widget.qml"), os.X_OK) and not os.access(os.path.join(snapshot, "manifest.json"), os.X_OK)
            no_git = not os.path.exists(os.path.join(snapshot, ".git"))
        except OSError as exc:
            same_bytes = executable = no_git = False
            print(f"        snapshot unreadable: {exc}")
        results.append(report("the snapshot holds every source file's bytes and executable bit and no .git", same_bytes and executable and no_git))

        with open(os.path.join(plugin, "Widget.qml"), "w", encoding="utf-8") as fh:
            fh.write("import QtQuick\nItem { property int v: 2 }\n")
        fourth = one_entry(scan("--snapshot-dir", root, "--retain", third["revision"], base))
        listed = sorted(os.listdir(root))
        results.append(report("a retained revision survives the scan that publishes the next one", listed == sorted([third["revision"], fourth["revision"]]), f"\n{listed}"))
        os.mkdir(os.path.join(root, ".writing-stale"))
        fifth = one_entry(scan("--snapshot-dir", root, base))
        listed = sorted(os.listdir(root))
        results.append(report("a scan with no error prunes unretained revisions and half-written trees", fifth["revision"] == fourth["revision"] and listed == [fourth["revision"]], f"\n{listed}"))

        with open(os.path.join(plugin, "lib", "Helper.qml"), "w", encoding="utf-8") as fh:
            fh.write("Item { property int edited: 3 }\n")
        os.chmod(os.path.join(plugin, "lib", "Helper.qml"), 0o000)
        try:
            failed = scan("--snapshot-dir", root, base)
        finally:
            os.chmod(os.path.join(plugin, "lib", "Helper.qml"), 0o644)
        elements = json.loads(failed.stdout) if failed.returncode == 0 else []
        listed = sorted(os.listdir(root))
        results.append(report("a scan with an error publishes nothing and prunes nothing", len(elements) == 1 and "error" in elements[0] and listed == [fourth["revision"]], f"\n{failed.stdout}\n{listed}"))
        results.append(report("a retained revision that is not on disk is not an error", one_entry(scan("--snapshot-dir", root, "--retain", "0" * 64, base)) is not None))
        refused = scan("--retain", "x", base)
        results.append(report("--retain without --snapshot-dir is refused", refused.returncode == 2 and refused.stdout == ""))
    return results


def requirement(command):
    return {"command": command, "purpose": "p"}


# probe rows: name, {plugin dir: manifest text}, {plugin dir: missing list}.
# The stub PATH holds `here` (executable) and `inert` (not executable).
PROBE_ROWS = [
    ("a declared command on PATH is not missing", {"a": {"id": "acme.a", "requirements": [requirement("here")]}}, {"a": []}),
    ("a declared command absent from PATH is missing", {"a": {"id": "acme.a", "requirements": [requirement("gone")]}}, {"a": ["gone"]}),
    ("a file without its executable bit is missing", {"a": {"id": "acme.a", "requirements": [requirement("inert")]}}, {"a": ["inert"]}),
    ("missing keeps declaration order and names a command once", {"a": {"id": "acme.a", "requirements": [requirement("zeta"), requirement("here"), requirement("alpha"), requirement("zeta")]}}, {"a": ["zeta", "alpha"]}),
    ("two plugins declaring one command both report it", {"a": {"id": "acme.a", "requirements": [requirement("gone")]}, "b": {"id": "acme.b", "requirements": [requirement("gone"), requirement("here")]}}, {"a": ["gone"], "b": ["gone"]}),
    ("a manifest without requirements misses nothing", {"a": {"id": "acme.a"}}, {"a": []}),
    ("requirements that are not a list miss nothing", {"a": {"id": "acme.a", "requirements": {"command": "gone"}}}, {"a": []}),
    ("an entry without a string command is not probed", {"a": {"id": "acme.a", "requirements": ["gone", {"command": 3}, {"purpose": "p"}]}}, {"a": []}),
    ("a manifest that is not JSON misses nothing", {"a": "{not json"}, {"a": []}),
]


def probe_rows(script=SCAN, quiet=False):
    """Each probe row's verdict, run against SCRIPT."""
    results = []
    for name, manifests, want in PROBE_ROWS:
        with tempfile.TemporaryDirectory() as tmp:
            files = {os.path.join("plugins", d, "manifest.json"): (m if isinstance(m, str) else json.dumps(m)) for d, m in manifests.items()}
            files["stubs/here"] = "#!/bin/sh\n"
            files["stubs/inert"] = "#!/bin/sh\n"
            plant(tmp, files)
            os.chmod(os.path.join(tmp, "stubs", "here"), 0o755)
            os.chmod(os.path.join(tmp, "stubs", "inert"), 0o644)
            proc = scan(os.path.join(tmp, "plugins"), script=script, env={"PATH": os.path.join(tmp, "stubs"), "LC_ALL": "C"})
            try:
                got = {os.path.basename(e["dir"]): e.get("missing") for e in json.loads(proc.stdout)}
            except (ValueError, KeyError):
                got = None
            good = proc.returncode == 0 and got == want
            results.append(good if quiet else report(name, good, f" (exit={proc.returncode} got={got})\n{proc.stderr}"))
    return results


def mutant_control(label, needle, replacement, rows):
    """The rows ROWS(script, quiet) runs must fail on a copy of the scanner
    with NEEDLE, which occurs once, replaced by REPLACEMENT."""
    with open(SCAN, encoding="utf-8") as fh:
        source = fh.read()
    if source.count(needle) != 1:
        return report(f"control: {needle!r} occurs once in the scanner", False, f" (count={source.count(needle)})")
    with tempfile.TemporaryDirectory() as tmp:
        mutant = os.path.join(tmp, "vgsh-scan")
        with open(mutant, "w", encoding="utf-8") as fh:
            fh.write(source.replace(needle, replacement))
        return report(f"control: {label}", not all(rows(mutant, quiet=True)))


def probe_control():
    """The probe rows must fail on a copy of the scanner that answers every
    command present."""
    return mutant_control("the probe rows fail on a scanner that finds every command",
                          "probed[command] = shutil.which(command) is not None", "probed[command] = True", probe_rows)


# core rows: name, the --core file's text (None: no file), {plugin dir:
# manifest}, want as the first element's kind and its missing list or error
# prefix, then {plugin dir: missing list}. The stub PATH is the probe rows'.
CORE_ROWS = [
    ("the core's absent command is missing and comes first", json.dumps([requirement("gone"), requirement("here")]), {"a": {"id": "acme.a", "requirements": [requirement("gone")]}},
     ("core", ["gone"]), {"a": ["gone"]}),
    ("the core's list of present commands misses nothing", json.dumps([requirement("here")]), {}, ("core", []), {}),
    ("a core file that is no list misses nothing", json.dumps({"requirements": [requirement("gone")]}), {}, ("core", []), {}),
    ("an absent core file is an error element", None, {"a": {"id": "acme.a", "requirements": [requirement("gone")]}},
     ("error", "cannot read core requirements: "), {"a": ["gone"]}),
]


def core_rows(script=SCAN, quiet=False):
    """Each core row's verdict, run against SCRIPT."""
    results = []
    for name, core, manifests, want_core, want_plugins in CORE_ROWS:
        with tempfile.TemporaryDirectory() as tmp:
            files = {os.path.join("plugins", d, "manifest.json"): json.dumps(m) for d, m in manifests.items()}
            files["stubs/here"] = "#!/bin/sh\n"
            if core is not None:
                files["requirements.json"] = core
            plant(tmp, files)
            os.chmod(os.path.join(tmp, "stubs", "here"), 0o755)
            proc = scan("--core", os.path.join(tmp, "requirements.json"), os.path.join(tmp, "plugins"), script=script, env={"PATH": os.path.join(tmp, "stubs"), "LC_ALL": "C"})
            try:
                elements = json.loads(proc.stdout)
                first = elements[0]
                got_core = ("error", first["error"][:len(want_core[1])]) if "error" in first else ("core" if first["core"].endswith("requirements.json") and "text" in first else "?", first["missing"])
                got_plugins = {os.path.basename(e["dir"]): e["missing"] for e in elements[1:]}
            except (ValueError, KeyError, IndexError):
                got_core, got_plugins = None, None
            good = proc.returncode == 0 and got_core == want_core and got_plugins == want_plugins
            results.append(good if quiet else report(name, good, f" (exit={proc.returncode} core={got_core} plugins={got_plugins})\n{proc.stderr}"))
    return results


def core_control():
    """The core rows must fail on a copy of the scanner that reads the core
    file as a manifest."""
    return mutant_control("the core rows fail on a scanner that reads the core list as a manifest",
                          "missing_commands(text, probed, core=True)", "missing_commands(text, probed)", core_rows)


# A snapshot root whose path holds every character class the URL must
# quote: a space, a percent sign that reads as an escape, a fragment mark
# and a non-ASCII letter.
AWKWARD_ROOT = "snap shots %41 #1 \u00e9"

# Runs the scanner as its own entry point would, then prints on stderr
# whether urllib.request is loaded and the scanner's exit status.
IMPORT_PROBE = """
import json, runpy, sys
script = sys.argv[1]
sys.argv = [script, *sys.argv[2:]]
status = 0
try:
    runpy.run_path(script, run_name="__main__")
except SystemExit as exc:
    status = exc.code
sys.stderr.write(json.dumps({"status": status, "urllib.request": "urllib.request" in sys.modules}) + "\\n")
"""


def url_spelling_rows(script=SCAN, quiet=False):
    """The URL spelling row, run against SCRIPT: pathlib's as_uri, which the
    scanner must not call, is the oracle."""
    with tempfile.TemporaryDirectory() as tmp:
        plant(tmp, {"plugins/a/manifest.json": MANIFEST})
        root = os.path.join(tmp, AWKWARD_ROOT)
        entry = one_entry(scan("--snapshot-dir", root, os.path.join(tmp, "plugins"), script=script))
        want = None if entry is None else pathlib.Path(os.path.join(root, entry["revision"])).as_uri()
        good = entry is not None and entry.get("loadUrl") == want
        return [good if quiet else report("loadUrl spells a root that needs quoting as pathlib's as_uri does", good, f" (got={entry and entry.get('loadUrl')} want={want})")]


def url_import_rows(script=SCAN, quiet=False):
    """The import row, run against SCRIPT in a child interpreter."""
    with tempfile.TemporaryDirectory() as tmp:
        plant(tmp, {"plugins/a/manifest.json": MANIFEST})
        base = os.path.join(tmp, "plugins")
        # -I keeps the child's imports to the interpreter's own: no user
        # site directory and no PYTHON* variable.
        proc = subprocess.run([sys.executable, "-I", "-c", IMPORT_PROBE, script, "--snapshot-dir", os.path.join(tmp, "snapshots"), base],
                              capture_output=True, text=True, check=False, env={"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"})
        try:
            probe = json.loads(proc.stderr.splitlines()[-1])
            published = [e for e in json.loads(proc.stdout) if "loadUrl" in e]
        except (ValueError, IndexError):
            probe, published = None, []
        good = proc.returncode == 0 and probe is not None and probe["status"] == 0 and len(published) == 1 and probe["urllib.request"] is False
        return [good if quiet else report("a scan that publishes a snapshot leaves urllib.request unimported", good, f" (probe={probe} published={len(published)})\n{proc.stderr}")]


def url_quote_control():
    """The URL spelling row must fail on a scanner that quotes nothing."""
    return mutant_control("the URL spelling row fails on a scanner that quotes nothing",
                          'return "file://" + urllib.parse.quote(path, encoding=sys.getfilesystemencoding(), errors=sys.getfilesystemencodeerrors())',
                          'return "file://" + path', url_spelling_rows)


def url_import_control():
    """The import row must fail on a scanner that spells the URL through
    as_uri."""
    return mutant_control("the import row fails on a scanner that calls as_uri",
                          "return file_url(str(pathlib.Path(destination).absolute()))",
                          "return pathlib.Path(destination).absolute().as_uri()", url_import_rows)


def main():
    if os.geteuid() == 0:
        print("status=not-measured reason=euid-0")
        return 77
    results = [run_row(*row) for row in ROWS]
    results += revision_rows()
    results += probe_rows()
    results.append(probe_control())
    results += core_rows()
    results.append(core_control())
    results += url_spelling_rows()
    results += url_import_rows()
    results.append(url_quote_control())
    results.append(url_import_control())
    if all(results):
        print("test-vgsh-scan: ok")
        return 0
    print("test-vgsh-scan: failing")
    return 1


if __name__ == "__main__":
    sys.exit(main())
