#!/usr/bin/env python3
"""One temp tree per row for bin/vgsh-scan. Each row plants files under a
throwaway directory, removes permission bits where the row says so, runs the
scanner on the named base and asserts the JSON elements it prints (the dir,
and either a text entry or the start of the error) plus the exit status.
Permission rows need a uid that permissions bind; under euid 0 the script
reports status=not-measured and exits 77 instead of passing vacuously."""
import json
import os
import subprocess
import sys
import tempfile

SCAN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "vgsh-scan")
MANIFEST = '{"id": "acme.widget"}'

# rows: name, files {relative path: text}, modes {relative path: mode}, base (relative), want [(dir, "text" | "error:<prefix>")]
ROWS = [
    ("absent base is skipped", {}, {}, "plugins", []),
    ("base that is a file is an error", {"plugins": "x"}, {}, "plugins", [("plugins", "error:cannot list: ")]),
    ("plugin dir without a manifest is skipped", {"plugins/a/Widget.qml": ""}, {}, "plugins", []),
    ("entry that is a file is skipped", {"plugins/README": ""}, {}, "plugins", []),
    ("readable manifest is a text entry", {"plugins/a/manifest.json": MANIFEST}, {}, "plugins", [("plugins/a", "text")]),
    ("plugin dir without its search bit is an error", {"plugins/a/manifest.json": MANIFEST, "plugins/b/manifest.json": MANIFEST}, {"plugins/a": 0o000}, "plugins",
     [("plugins/a", "error:cannot read manifest: "), ("plugins/b", "text")]),
    ("manifest without read permission is an error", {"plugins/a/manifest.json": MANIFEST}, {"plugins/a/manifest.json": 0o000}, "plugins", [("plugins/a", "error:cannot read manifest: ")]),
    ("base without permission bits is an error", {"plugins/a/manifest.json": MANIFEST}, {"plugins": 0o000}, "plugins", [("plugins", "error:cannot list: ")]),
    ("inaccessible ancestor of the base is an error", {"root/plugins/a/manifest.json": MANIFEST}, {"root": 0o000}, "root/plugins", [("root/plugins", "error:cannot list: ")]),
]


def element_kind(element):
    if "text" in element:
        return "text"
    return "error:" + element["error"]


def matches(got, want):
    if len(got) != len(want):
        return False
    for (got_dir, got_kind), (want_dir, want_kind) in zip(got, want):
        if got_dir != want_dir:
            return False
        if want_kind == "text" and got_kind != "text":
            return False
        if want_kind != "text" and not got_kind.startswith(want_kind):
            return False
    return True


def run_row(name, files, modes, base, want):
    with tempfile.TemporaryDirectory() as tmp:
        for rel, text in files.items():
            path = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
        try:
            for rel, mode in modes.items():
                os.chmod(os.path.join(tmp, rel), mode)
            proc = subprocess.run([sys.executable, SCAN, os.path.join(tmp, base)], capture_output=True, text=True, check=False,
                                  env={"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"})
        finally:
            for rel in modes:
                os.chmod(os.path.join(tmp, rel), 0o755)
        try:
            elements = json.loads(proc.stdout)
        except ValueError:
            elements = None
        got = None if elements is None else [(os.path.relpath(e["dir"], tmp), element_kind(e)) for e in elements]
        good = proc.returncode == 0 and got is not None and matches(got, want)
        print(("  ok    " if good else "  FAIL  ") + name + ("" if good else f" (exit={proc.returncode} got={got})\n{proc.stdout}{proc.stderr}"))
        return good


def main():
    if os.geteuid() == 0:
        print("status=not-measured reason=euid-0")
        return 77
    results = [run_row(*row) for row in ROWS]
    if all(results):
        print("test-vgsh-scan: ok")
        return 0
    print("test-vgsh-scan: failing")
    return 1


if __name__ == "__main__":
    sys.exit(main())
