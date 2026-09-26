#!/usr/bin/env python3
"""One temp tree per row for bin/vgsh-scan. Each listing row plants files
under a throwaway directory, removes permission bits where the row says so,
runs the scanner on the named base with the row's options, and asserts the
JSON elements it prints (the dir, either a text entry or the start of the
error, and the failing path where the row names one) plus the exit status.
The revision rows then read the scanner twice over one tree and compare
revisions, snapshots and pruning. Permission rows need a uid that
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


def scan(*args):
    return subprocess.run([sys.executable, SCAN, *args], capture_output=True, text=True, check=False, env=ENV)


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


def main():
    if os.geteuid() == 0:
        print("status=not-measured reason=euid-0")
        return 77
    results = [run_row(*row) for row in ROWS]
    results += revision_rows()
    if all(results):
        print("test-vgsh-scan: ok")
        return 0
    print("test-vgsh-scan: failing")
    return 1


if __name__ == "__main__":
    sys.exit(main())
