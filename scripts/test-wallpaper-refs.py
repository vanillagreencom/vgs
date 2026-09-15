#!/usr/bin/env python3
"""The helper's half of the durable wallpaper reference.

`bin/vshell_helper.py` owns the rule: `portable_ref` records, `recovered_package_ref`
repairs what another installation recorded, and `resolve_path` reads. A theme applied
from a checkout must leave no absolute path into that checkout in `theme-current.json`
or in the shell's `theme.json`, or removing the directory costs every monitor its
wallpaper on the next restart.

The rows come from `lib/wallpaper-ref-cases.json`, which `test-wallpaper-refs.js`
also runs against `Common/Paths.qml`: one statement of the rule, two runtimes.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import re
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


def test_portable_ref_records_what_this_installation_owns_and_nothing_else():
    repo, user_themes, home = fake_roots()
    with repo, user_themes, home:
        for row in CASES["ref"]:
            got = helper.portable_ref(row["path"])
            assert got == row["ref"], f"portable_ref({row['path']!r}): {row['why']}: expected {row['ref']!r}, got {got!r}"
            back = helper.resolve_path(got)
            assert back == row["resolved"], (
                f"resolve_path(portable_ref({row['path']!r})): {row['why']}: "
                f"expected {row['resolved']!r}, got {back!r}")


def test_reading_repairs_only_a_package_neither_root_holds():
    repo, user_themes, home = fake_roots()
    with repo, user_themes, home:
        for row in CASES["recover"]:
            got = helper.resolved_wallpaper(row["path"])
            assert got == row["recovered"], (
                f"resolved_wallpaper({row['path']!r}): {row['why']}: "
                f"expected {row['recovered']!r}, got {got!r}")


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


def test_the_default_theme_answers_with_a_path_before_any_apply():
    """A fresh install has no theme.json, so `current_theme` renders the default.

    That render runs the same `{wallpaper.ref}` template, so without resolving it
    `vshell theme current` and every in-process caller get a token instead of a path.
    """
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "config" / "vshell"
        cfg.mkdir(parents=True)
        # The real root, because the render reads the shipped target template and the
        # default theme package; only the home this writes into is thrown away.
        with patch.object(helper, "home", lambda: Path(tmp)), patch.object(helper, "cfg_dir", lambda: cfg):
            wallpaper = helper.current_theme()["wallpaper"]
        assert helper.VSHELL_ROOT_TOKEN not in wallpaper, (
            f"the default theme's wallpaper must reach a caller as a path, got {wallpaper!r}")
        assert wallpaper.startswith(str(REPO_ROOT) + "/"), (
            f"the default theme's background sits under this installation, got {wallpaper!r}")


def test_the_greeter_copy_carries_paths_and_covers_every_wallpaper_key():
    """The greeter resolves a reference against its own staged runtime.

    `sync_greeter_runtime` copies `quickshell/vshell` and the runtime bin files into
    the cache and no `themes/`, while `bin/vshell` sets VSHELL_ROOT to that runtime,
    so a rooted reference in the copied files names nothing and the login screen
    shows no wallpaper. The copy therefore carries resolved paths.

    The key set is pinned against `SessionSpec.js`, which owns it: the flags there
    are what the shell maps, and this list is what the greeter copy resolves.
    """
    spec = (REPO_ROOT / "quickshell" / "vshell" / "Common" / "settings" / "SessionSpec.js").read_text()
    flagged = {match.group(1) for match in
               re.finditer(r"^\s*(\w+):\s*\{.*\b(?:ref|refMap):\s*true", spec, re.MULTILINE)}
    assert flagged == set(helper.SESSION_WALLPAPER_KEYS), (
        "SESSION_WALLPAPER_KEYS must name exactly the keys SessionSpec.js marks ref or refMap; "
        f"the spec marks {sorted(flagged)} and the helper lists {sorted(helper.SESSION_WALLPAPER_KEYS)}")

    package = CASES["ref"][0]
    stale = CASES["recover"][0]
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "config" / "vshell"
        state = Path(tmp) / "state" / "vshell"
        cfg.mkdir(parents=True)
        state.mkdir(parents=True)
        (cfg / "theme.json").write_text(json.dumps({"name": "t", "wallpaper": package["ref"], "colors": {}}))
        (state / "session.json").write_text(json.dumps({
            "wallpaperPath": package["ref"],
            "wallpaperPathLight": package["ref"],
            "wallpaperPathDark": stale["path"],
            "monitorWallpapers": {"DP-1": package["ref"]},
            "monitorWallpapersLight": {"DP-1": package["ref"]},
            "monitorWallpapersDark": {"DP-1": stale["path"]},
        }))
        repo, user_themes, home = fake_roots()
        with repo, user_themes, home, \
                patch.object(helper, "cfg_dir", lambda: cfg), patch.object(helper, "state_dir", lambda: state):
            theme = helper.current_theme_json()
            session = helper.current_session_json(theme)
        assert helper.VSHELL_ROOT_TOKEN not in json.dumps(theme), (
            "the greeter's theme.json copy must carry no token; the greeter's own root has no themes/")
        assert helper.VSHELL_ROOT_TOKEN not in json.dumps(session), (
            "the greeter's session.json copy must carry no token, for the same reason")
        for key in helper.SESSION_WALLPAPER_KEYS:
            value = session[key]
            for got in ([value] if isinstance(value, str) else list(value.values())):
                assert got in (package["resolved"], stale["recovered"]), (
                    f"{key} reached the greeter copy as {got!r}, which is neither the resolved "
                    "package background nor the repaired one")


def test_state_written_by_an_installation_that_is_gone_recovers():
    """The reported failure: durable state naming a worktree that no longer exists.

    Both files were written before references existed, so both hold an absolute path
    into a directory that has been removed. Each reader must answer with the same
    package background out of this installation.
    """
    stale = CASES["recover"][0]
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "config" / "vshell"
        cfg.mkdir(parents=True)
        (cfg / "theme-current.json").write_text(json.dumps({"name": "t", "palette": {"wallpaper": stale["path"]}}))
        (cfg / "theme.json").write_text(json.dumps({"name": "t", "wallpaper": stale["path"], "colors": {}}))
        repo, user_themes, home = fake_roots()
        with repo, user_themes, home, patch.object(helper, "cfg_dir", lambda: cfg):
            assert helper.applied_blueprint()["palette"]["wallpaper"] == stale["recovered"], (
                "theme-current.json holding a removed checkout's path must still name this "
                "installation's copy of the same package background")
            assert helper.current_theme()["wallpaper"] == stale["recovered"], (
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
