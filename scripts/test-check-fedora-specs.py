#!/usr/bin/env python3
"""Controls for check-fedora-specs.py: the real tree passes, and one planted
defect per rule fails with that rule's key. Each row copies the files the
check reads into a scratch root, applies one edit and runs the check there."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
CHECK = HERE / "check-fedora-specs.py"
REL = "packaging/fedora/vgs.spec"
GIT = "packaging/fedora/vgs-git.spec"
BOTH = (REL, GIT)


def copy_inputs(root):
    paths = ["bin/vgsh", "VERSION", "config/requirements.json", REL, GIT]
    paths += [str(p.relative_to(REPO)) for p in sorted((REPO / "shell" / "plugins").glob("*/manifest.json"))]
    for rel in paths:
        dest = root / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO / rel, dest)


def replace(files, old, new):
    """An edit replacing OLD, which must occur once, in each of FILES."""
    def edit(root):
        for rel in files:
            path = root / rel
            text = path.read_text()
            if text.count(old) != 1:
                raise SystemExit(f"test-check-fedora-specs: expected one {old!r} in {rel}, found {text.count(old)}")
            path.write_text(text.replace(old, new))
    return edit


def add_requirement(requirement):
    """An edit adding REQUIREMENT to the first shipped plugin's manifest."""
    def edit(root):
        manifest = sorted((root / "shell" / "plugins").glob("*/manifest.json"))[0]
        data = json.loads(manifest.read_text())
        data.setdefault("requirements", []).append(requirement)
        manifest.write_text(json.dumps(data, indent=2) + "\n")
    return edit


def rename_dnf(command, new):
    def edit(root):
        path = root / "config" / "requirements.json"
        data = json.loads(path.read_text())
        hits = [r for r in data if r["command"] == command]
        if len(hits) != 1:
            raise SystemExit(f"test-check-fedora-specs: no single {command} requirement")
        hits[0]["packages"]["dnf"] = new
        path.write_text(json.dumps(data, indent=2) + "\n")
    return edit


def write(rel, text):
    def edit(root):
        (root / rel).write_text(text)
    return edit


# rows: name, edit or None, expected key in the output or None for a pass
ROWS = [
    ("the shipped specs pass", None, None),
    ("a dropped Requires fails", replace(BOTH, "Requires:       git\n", ""), "requires=missing name=git"),
    ("an extra Requires fails", replace(BOTH, "Requires:       git\n", "Requires:       git\nRequires:       jq\n"), "requires=extra name=jq"),
    ("a spec floor below the preflight fails", replace(BOTH, "quickshell >= 0.3.1", "quickshell >= 0.3.0"), "floor=mismatch name=quickshell have=0.3.0 want=0.3.1"),
    ("a spec floor with no version fails", replace(BOTH, "Requires:       hyprland >= 0.56", "Requires:       hyprland"), "floor=mismatch name=hyprland have=none want=0.56"),
    ("a raised preflight floor fails", replace(["bin/vgsh"], "quickshell 0.3.1 ", "quickshell 0.3.2 "), "floor=mismatch name=quickshell have=0.3.1 want=0.3.2"),
    ("an explicit epoch 0 on a floor passes", replace(BOTH, "hyprland >= 0.56", "hyprland >= 0:0.56"), None),
    ("a node floor without its epoch fails", replace(BOTH, "nodejs >= 1:18", "nodejs >= 18"), "epoch=mismatch name=nodejs have=0 want=1"),
    ("a node floor with another epoch fails", replace(BOTH, "nodejs >= 1:18", "nodejs >= 2:18"), "epoch=mismatch name=nodejs have=2 want=1"),
    ("an epoch on an epoch-0 package fails", replace(BOTH, "quickshell >= 0.3.1", "quickshell >= 1:0.3.1"), "epoch=mismatch name=quickshell have=1 want=0"),
    ("an optional requirement as Requires fails", replace(BOTH, "Recommends:     gum\n", "Requires:       gum\n"), "recommends=missing name=gum"),
    ("an extra Recommends fails", replace(BOTH, "Recommends:     fzf\n", "Recommends:     fzf\nRecommends:     jq\n"), "recommends=extra name=jq"),
    ("a renamed dnf package fails", rename_dnf("node", "nodejs22"), "requires=missing name=nodejs22"),
    ("a plugin's optional requirement must be recommended", add_requirement({"command": "wl-copy", "packages": {"pacman": "wl-clipboard", "dnf": "wl-clipboard"}, "optional": True, "purpose": "Copies to the clipboard"}), "recommends=missing name=wl-clipboard"),
    ("a plugin's required requirement must be required", add_requirement({"command": "grim", "packages": {"dnf": "grim"}, "purpose": "Takes screenshots"}), "requires=missing name=grim"),
    ("a requirement with no dnf package has no Fedora line", add_requirement({"command": "checkupdates", "packages": {"pacman": "pacman-contrib"}, "optional": True, "purpose": "Lists pending updates"}), None),
    ("an unreadable dependency line fails", replace(BOTH, "quickshell >= 0.3.1", "quickshell > 0.3.1"), "line=unreadable text=Requires:       quickshell > 0.3.1"),
    ("blocks that differ fail", replace([REL], "Recommends:     fzf\n", ""), "block=differs"),
    ("a missing block marker fails", replace([GIT], "# end runtime dependencies\n", ""), "block=missing spec=vgs-git.spec"),
    ("a Version off VERSION fails", write("VERSION", "0.1.1\n"), "version=mismatch spec=vgs.spec have=0.1.0 want=0.1.1"),
    ("a changelog entry off the version fails", replace([REL], "- 0.1.0-1\n", "- 0.0.9-1\n"), "changelog=mismatch spec=vgs.spec"),
    ("vgs-git without its vgs provide fails", replace([GIT], "Provides:       vgs = %{version}\n", ""), "provides=missing spec=vgs-git.spec"),
    ("vgs-git without its vgs conflict fails", replace([GIT], "Conflicts:      vgs\n", ""), "conflicts=missing spec=vgs-git.spec"),
    ("a vgs-git changelog entry fails", replace([GIT], "\n%changelog\n", "\n%changelog\n* Mon Sep 28 2026 A <a@b> - 0-1\n- x\n"), "changelog=entries spec=vgs-git.spec"),
    ("an arch-bound spec fails", replace([REL], "BuildArch:      noarch", "BuildArch:      x86_64"), "buildarch=x86_64 spec=vgs.spec"),
    ("a licence that differs fails", replace([GIT], "License:        MIT AND OFL-1.1 AND ISC", "License:        MIT"), "tag=differs name=License"),
    ("an install section that differs fails", replace([GIT], "PREFIX=%{_prefix} packaging/install-system.sh", "PREFIX=/usr/local packaging/install-system.sh"), "section=differs name=%install"),
    ("an install off the shared installer fails", replace(BOTH, "packaging/install-system.sh", "make install"), "install=missing"),
    ("a check off the manifest checker fails", replace(BOTH, "scripts/check-install-tree.sh %{buildroot} %{_prefix}", "true"), "check=missing"),
    ("a renamed package fails", replace([REL], "Name:           vgs\n", "Name:           vgs2\n"), "name=mismatch spec=vgs.spec have=vgs2 want=vgs"),
]


def main():
    results = []
    for name, edit, key in ROWS:
        with tempfile.TemporaryDirectory(prefix="test-fedora-specs.") as scratch:
            root = pathlib.Path(scratch)
            copy_inputs(root)
            if edit:
                edit(root)
            proc = subprocess.run([sys.executable, str(CHECK), "--root", str(root)], capture_output=True, text=True,
                                  env={"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"})
            lines = proc.stdout.splitlines()
            if key is None:
                good = proc.returncode == 0 and len(lines) == 1 and lines[0].startswith("fedora-specs: ok ")
            else:
                good = proc.returncode == 1 and any(line.startswith(f"fedora-specs: {key}") for line in lines)
            print(("  ok    " if good else "  FAIL  ") + name + ("" if good else f" (exit={proc.returncode})\n{proc.stdout}{proc.stderr}"))
            results.append(good)
    proc = subprocess.run([sys.executable, str(CHECK), "--bogus"], capture_output=True, text=True)
    good = proc.returncode == 2 and proc.stderr.startswith("fedora-specs: refused: argument=--bogus")
    print(("  ok    " if good else "  FAIL  ") + "an unknown argument exits 2")
    results.append(good)
    if all(results):
        print(f"test-check-fedora-specs: ok rows={len(results)}")
        return 0
    print("test-check-fedora-specs: failing")
    return 1


if __name__ == "__main__":
    sys.exit(main())
