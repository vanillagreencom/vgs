#!/usr/bin/env python3
"""The helper's half of the durable wallpaper reference.

`bin/vshell_helper.py` owns the rule: `portable_ref` writes it and `resolve_path`
reads it. A theme applied from a checkout must leave no absolute path into that
checkout in `theme-current.json` or in the shell's `theme.json`, or removing the
directory costs every monitor its wallpaper on the next restart.

The rows come from `lib/wallpaper-ref-cases.json`, which `test-wallpaper-refs.js`
also runs against `Common/Paths.qml`: one statement of the rule, two runtimes.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[1]
CASES = json.loads((REPO_ROOT / "scripts" / "lib" / "wallpaper-ref-cases.json").read_text())


def load_helper():
    loader = importlib.machinery.SourceFileLoader("vshell_helper_ref_test", str(REPO_ROOT / "bin" / "vshell_helper.py"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helper = load_helper()


def fake_roots():
    """Patch the helper onto the case table's roots.

    The table names a checkout, a user theme directory and a home that exist on no
    machine, so a row cannot pass by accident against this repository's own layout.
    """
    roots = CASES["roots"]
    return (
        patch.object(helper, "repo_root", lambda: Path(roots["repo"])),
        patch.object(helper, "user_themes_dir", lambda: Path(roots["userThemes"])),
        patch.object(helper, "home", lambda: Path(roots["home"])),
    )


def test_portable_ref_records_every_case_the_table_names():
    repo, user_themes, home = fake_roots()
    with repo, user_themes, home:
        for row in CASES["ref"]:
            got = helper.portable_ref(row["path"])
            assert got == row["ref"], f"portable_ref({row['path']!r}): {row['why']}: expected {row['ref']!r}, got {got!r}"
            back = helper.resolve_path(got)
            assert back == row["resolved"], (
                f"resolve_path(portable_ref({row['path']!r})): {row['why']}: "
                f"expected {row['resolved']!r}, got {back!r}")


def test_resolve_path_reads_every_reference_form_the_table_names():
    repo, user_themes, home = fake_roots()
    with repo, user_themes, home:
        for row in CASES["resolve"]:
            got = helper.resolve_path(row["ref"])
            assert got == row["path"], f"resolve_path({row['ref']!r}): {row['why']}: expected {row['path']!r}, got {got!r}"


def test_the_ref_modifier_is_the_shell_targets_alone():
    """Only the shell reads a VGS token, so only its template may render one.

    Every other target writes a config another application parses, where a token is
    literal text that names no file.
    """
    targets = REPO_ROOT / "themes" / "targets"
    shell_template = targets / "vgs-shell" / "vgs-theme.json"
    assert '"wallpaper": "{wallpaper.ref}"' in shell_template.read_text(), (
        f"{shell_template} must render the wallpaper as a reference, or the shell's "
        "theme.json pins the checkout that applied the theme")
    others = [path for path in sorted(targets.glob("*/*"))
              if path.is_file() and path != shell_template and ".ref}" in path.read_text(errors="ignore")]
    assert others == [], f"only the shell target may use the .ref modifier; also used by: {others}"


def test_render_template_writes_a_reference_only_where_the_modifier_asks():
    roles = {"wallpaper": CASES["ref"][0]["path"]}
    repo, user_themes, home = fake_roots()
    with repo, user_themes, home:
        assert helper.render_template("{wallpaper.ref}", roles, "t") == CASES["ref"][0]["ref"]
        assert helper.render_template("{wallpaper}", roles, "t") == CASES["ref"][0]["path"], (
            "a target without the modifier keeps the absolute path its application needs")


def test_an_applied_theme_records_a_reference_and_reads_back_the_path():
    """The round trip the bug report names: apply, then read the applied state.

    `applied_theme_state` is what `apply_theme_obj` writes to `theme-current.json`
    and `applied_blueprint` is what reads it, so the two together are the file's
    whole contract.
    """
    row = CASES["ref"][0]
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "config" / "vshell"
        cfg.mkdir(parents=True)
        repo, user_themes, home = fake_roots()
        with repo, user_themes, home, patch.object(helper, "cfg_dir", lambda: cfg):
            state = helper.applied_theme_state({"name": "t", "palette": {"wallpaper": row["path"], "colors": []}})
            assert state["palette"]["wallpaper"] == row["ref"], (
                "theme-current.json must record the reference, not the checkout path")
            (cfg / "theme-current.json").write_text(json.dumps(state))
            assert helper.applied_blueprint()["palette"]["wallpaper"] == row["resolved"], (
                "a reader gets the path on this machine, so an apply rebuilt from the "
                "applied theme keeps the same wallpaper")


def test_state_written_by_an_installation_that_is_gone_recovers():
    """The reported failure: durable state naming a worktree that no longer exists.

    Both files were written before references existed, so both hold an absolute path
    into a directory that has been removed. Each reader must answer with the same
    package background out of this installation.
    """
    stale = next(row for row in CASES["ref"] if row["ref"] != row["path"] and row["resolved"] != row["path"])
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "config" / "vshell"
        cfg.mkdir(parents=True)
        (cfg / "theme-current.json").write_text(json.dumps({"name": "t", "palette": {"wallpaper": stale["path"]}}))
        (cfg / "theme.json").write_text(json.dumps({"name": "t", "wallpaper": stale["path"], "colors": {}}))
        repo, user_themes, home = fake_roots()
        with repo, user_themes, home, patch.object(helper, "cfg_dir", lambda: cfg):
            assert helper.applied_blueprint()["palette"]["wallpaper"] == stale["resolved"], (
                "theme-current.json holding a removed checkout's path must still name this "
                "installation's copy of the same package background")
            assert helper.current_theme()["wallpaper"] == stale["resolved"], (
                "the shell's theme.json must recover the same way")


def test_the_shell_theme_file_reads_back_as_a_path():
    row = CASES["ref"][0]
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "config" / "vshell"
        cfg.mkdir(parents=True)
        (cfg / "theme.json").write_text(json.dumps({"name": "t", "wallpaper": row["ref"], "colors": {}}))
        repo, user_themes, home = fake_roots()
        with repo, user_themes, home, patch.object(helper, "cfg_dir", lambda: cfg):
            assert helper.current_theme()["wallpaper"] == row["resolved"], (
                "`vshell theme current` answers with a path the shell can load")


def main() -> int:
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    failures = []
    for test in tests:
        try:
            test()
        except AssertionError as exc:
            failures.append(f"{test.__name__}: {exc}")
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    print(f"{len(tests) - len(failures)}/{len(tests)} wallpaper reference checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
