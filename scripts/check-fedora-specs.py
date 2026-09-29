#!/usr/bin/env python3
"""Hold the Fedora specs to the data they package.

Usage: scripts/check-fedora-specs.py [--root DIR]

Reads packaging/fedora/vgs.spec and packaging/fedora/vgs-git.spec under
DIR, the repository by default, and checks:

- The block between `# begin runtime dependencies` and `# end runtime
  dependencies` is the same in both specs. Its Requires and Recommends lines
  are exactly these, in any order:
  - one Requires per row of the preflight floor in bin/vgsh, named by the
    `dnf` package config/requirements.json gives the row's probe command, else
    by the row's tool, with `>= [EPOCH:]FLOOR` when the row has a version;
  - one Requires per other non-optional requirement of config/requirements.json
    and of every shipped plugin's manifest, by its `dnf` package;
  - one Recommends per optional requirement whose package no Requires names.
  A requirement with no `dnf` package has no Fedora line.
- vgs.spec's Version is VERSION's line, and its newest %changelog entry is
  that version at its Release.
- vgs-git.spec provides vgs at its version, conflicts with vgs, and ends with
  an empty %changelog, which packaging/fedora/srpm.sh fills.
- Both are noarch, share License, URL, BuildRequires and the %build,
  %install, %check and %files sections, install through
  packaging/install-system.sh and check the tree with
  scripts/check-install-tree.sh.

Prints `fedora-specs: ok requires=N recommends=M`, or one keyed line per
problem and exits 1. Exit 2: bad usage.
"""

import json
import pathlib
import re
import sys

BEGIN = "# begin runtime dependencies"
END = "# end runtime dependencies"
INSTALL = "DESTDIR=%{buildroot} PREFIX=%{_prefix} packaging/install-system.sh"
CHECK = "scripts/check-install-tree.sh %{buildroot} %{_prefix}"
SHARED_SECTIONS = ("%build", "%install", "%check", "%files")
DEP_LINE = re.compile(r"^(Requires|Recommends|Conflicts):\s+(\S+)(?:\s+>=\s+(?:\d+:)?(\S+))?\s*$")
SECTION = re.compile(r"^%(description|prep|build|install|check|files|changelog)\b")

problems = []


def problem(line):
    problems.append(f"fedora-specs: {line}")


def preflight_rows(vgsh):
    """(tool, need, probe command) for each row of bin/vgsh's preflight_floor."""
    text = vgsh.read_text()
    found = re.search(r"^preflight_floor='\n(.*?)^'", text, re.S | re.M)
    if not found:
        problem(f"preflight=unreadable path={vgsh}")
        return []
    rows = []
    for line in found.group(1).splitlines():
        fields = line.split()
        if not fields:
            continue
        if len(fields) < 4:
            problem(f"preflight=unreadable row={line.strip()}")
            continue
        rows.append((fields[0], fields[1], fields[3]))
    return rows


def requirements(root):
    """Every requirement of the core and of the shipped plugins, in order."""
    out = []
    core = root / "config" / "requirements.json"
    try:
        out.extend(json.loads(core.read_text()))
    except (OSError, ValueError) as error:
        problem(f"requirements=unreadable path={core} error={error}")
    for manifest in sorted((root / "shell" / "plugins").glob("*/manifest.json")):
        try:
            out.extend(json.loads(manifest.read_text()).get("requirements", []))
        except (OSError, ValueError, AttributeError) as error:
            problem(f"manifest=unreadable path={manifest} error={error}")
    return out


def expected(root):
    reqs = requirements(root)
    dnf_of = {}
    for req in reqs:
        dnf_of.setdefault(req.get("command"), (req.get("packages") or {}).get("dnf"))
    requires = {}
    for tool, need, command in preflight_rows(root / "bin" / "vgsh"):
        name = dnf_of.get(command) or tool
        requires[name] = None if need == "present" else need
    recommends = set()
    for req in reqs:
        name = (req.get("packages") or {}).get("dnf")
        if not name:
            continue
        if not req.get("optional", False):
            requires.setdefault(name, None)
        else:
            recommends.add(name)
    return requires, recommends - set(requires)


def read_spec(path):
    try:
        return path.read_text().splitlines()
    except OSError:
        problem(f"spec=missing path={path}")
        return None


def block(lines, name):
    starts = [i for i, line in enumerate(lines) if line.strip() == BEGIN]
    ends = [i for i, line in enumerate(lines) if line.strip() == END]
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        problem(f"block=missing spec={name}")
        return None
    return [line.strip() for line in lines[starts[0] + 1 : ends[0]] if line.strip() and not line.lstrip().startswith("#")]


def tags(lines):
    """Preamble tags before the first section, each name to its values."""
    out = {}
    for line in lines:
        if SECTION.match(line):
            break
        found = re.match(r"^([A-Za-z0-9]+):\s*(.*?)\s*$", line)
        if found:
            out.setdefault(found.group(1), []).append(found.group(2))
    return out


def sections(lines):
    """Each section's name to its body lines, trailing blank lines dropped."""
    out, name = {}, None
    for line in lines:
        found = SECTION.match(line)
        if found:
            name = "%" + found.group(1)
            out[name] = []
        elif name:
            out[name].append(line)
    for body in out.values():
        while body and not body[-1].strip():
            body.pop()
    return out


def check_block(entries, requires, recommends):
    have_requires, have_recommends = {}, set()
    for line in entries:
        found = DEP_LINE.match(line)
        if not found:
            problem(f"line=unreadable text={line}")
            continue
        kind, name, floor = found.groups()
        if kind == "Requires":
            have_requires[name] = floor
        elif kind == "Recommends":
            have_recommends.add(name)
    for name, floor in requires.items():
        if name not in have_requires:
            problem(f"requires=missing name={name}" + (f" want=>={floor}" if floor else ""))
        elif have_requires[name] != floor:
            problem(f"floor=mismatch name={name} have={have_requires[name] or 'none'} want={floor or 'none'}")
    for name in sorted(set(have_requires) - set(requires)):
        problem(f"requires=extra name={name}")
    for name in sorted(recommends - have_recommends):
        problem(f"recommends=missing name={name}")
    for name in sorted(have_recommends - recommends):
        problem(f"recommends=extra name={name}")


def one(values, tag, spec):
    if not values or len(values) != 1:
        problem(f"tag=missing name={tag} spec={spec}")
        return None
    return values[0]


def main(argv):
    root = pathlib.Path(__file__).resolve().parent.parent
    if argv[:1] in (["-h"], ["--help"]):
        print(__doc__.strip())
        return 0
    if argv[:1] == ["--root"] and len(argv) == 2:
        root = pathlib.Path(argv[1]).resolve()
    elif argv:
        print(f"fedora-specs: refused: argument={argv[0]}", file=sys.stderr)
        return 2

    fedora = root / "packaging" / "fedora"
    rel_lines, git_lines = read_spec(fedora / "vgs.spec"), read_spec(fedora / "vgs-git.spec")
    if rel_lines is None or git_lines is None:
        print("\n".join(problems))
        return 1
    requires, recommends = expected(root)

    rel_block, git_block = block(rel_lines, "vgs.spec"), block(git_lines, "vgs-git.spec")
    if rel_block is not None and git_block is not None:
        if rel_block != git_block:
            problem("block=differs specs=vgs.spec,vgs-git.spec")
        check_block(rel_block, requires, recommends)

    rel_tags, git_tags = tags(rel_lines), tags(git_lines)
    rel_sections, git_sections = sections(rel_lines), sections(git_lines)
    for spec, spec_tags, want in (("vgs.spec", rel_tags, "vgs"), ("vgs-git.spec", git_tags, "vgs-git")):
        name = one(spec_tags.get("Name"), "Name", spec)
        if name is not None and name != want:
            problem(f"name=mismatch spec={spec} have={name} want={want}")
        arch = one(spec_tags.get("BuildArch"), "BuildArch", spec)
        if arch is not None and arch != "noarch":
            problem(f"buildarch={arch} spec={spec} want=noarch")
    for tag in ("License", "URL", "BuildRequires"):
        if sorted(rel_tags.get(tag, [])) != sorted(git_tags.get(tag, [])) or not rel_tags.get(tag):
            problem(f"tag=differs name={tag} specs=vgs.spec,vgs-git.spec")
    for name in SHARED_SECTIONS:
        if name not in rel_sections or rel_sections.get(name) != git_sections.get(name):
            problem(f"section=differs name={name} specs=vgs.spec,vgs-git.spec")
    if INSTALL not in [line.strip() for line in rel_sections.get("%install", [])]:
        problem(f"install=missing want={INSTALL}")
    if CHECK not in [line.strip() for line in rel_sections.get("%check", [])]:
        problem(f"check=missing want={CHECK}")

    version_file = root / "VERSION"
    try:
        version = version_file.read_text().strip()
    except OSError:
        version = None
        problem(f"version=missing path={version_file}")
    rel_version = one(rel_tags.get("Version"), "Version", "vgs.spec")
    if version is not None and rel_version is not None and rel_version != version:
        problem(f"version=mismatch spec=vgs.spec have={rel_version} want={version}")
    release = one(rel_tags.get("Release"), "Release", "vgs.spec") or ""
    release_number = release.replace("%{?dist}", "")
    entries = [line for line in rel_sections.get("%changelog", []) if line.startswith("* ")]
    want_entry = f"- {rel_version}-{release_number}"
    if not entries or not entries[0].endswith(want_entry):
        problem(f"changelog=mismatch spec=vgs.spec want=...{want_entry} have={entries[0] if entries else 'none'}")

    if "vgs = %{version}" not in git_tags.get("Provides", []):
        problem("provides=missing spec=vgs-git.spec want=vgs = %{version}")
    if "vgs" not in git_tags.get("Conflicts", []):
        problem("conflicts=missing spec=vgs-git.spec want=vgs")
    if "%changelog" not in git_sections:
        problem("changelog=missing spec=vgs-git.spec")
    elif any(line.strip() for line in git_sections["%changelog"]):
        problem("changelog=entries spec=vgs-git.spec want=empty, srpm.sh writes the entry")

    if problems:
        print("\n".join(problems))
        return 1
    print(f"fedora-specs: ok requires={len(requires)} recommends={len(recommends)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
