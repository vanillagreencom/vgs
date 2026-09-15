#!/usr/bin/env python3
"""The helper's half of the durable wallpaper reference.

`bin/vshell_helper.py` owns the rule: `portable_ref` records, `recovered_package_ref`
repairs a background another installation recorded, and `resolve_path` reads. A theme
applied from a checkout must leave no absolute path into that checkout in
`theme-current.json` or in the shell's `theme.json`, or removing the directory costs
every monitor its wallpaper on the next restart.

`docs/architecture/wallpaper.md` states the rule. The rows come from
`lib/wallpaper-ref-cases.json`; `test-wallpaper-refs.js` runs its `ref` and `resolve`
sections against `Common/Paths.qml`. The `recover` section is this suite's alone,
because the repair tests the filesystem and the shell carries no such rule.
"""
from __future__ import annotations

import contextlib
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
TABLE_ROOTS = CASES["roots"]


def load_helper():
    loader = importlib.machinery.SourceFileLoader("vshell_helper_ref_test", str(REPO_ROOT / "bin" / "vshell_helper.py"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helper = load_helper()


@contextlib.contextmanager
def installation(present=None, keep_repo=False):
    """A throwaway VGS installation the helper acts as.

    `present` seeds package files this installation holds, as
    `{"repo": ["themes/<pkg>/backgrounds/<file>"], "userThemes": ["<pkg>/backgrounds/<file>"]}`,
    so the repair's filesystem test reads something a row chose rather than whatever
    this repository happens to contain. `keep_repo` leaves the real root in place for
    a case that has to render a shipped target template.

    Yields the directories, keyed as the case table names its roots.
    """
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp) / "home"
        dirs = {
            "repo": REPO_ROOT if keep_repo else Path(tmp) / "root",
            # The real relationship, so a `~` reference and the user theme root are
            # the same directory here as they are on a machine.
            "userThemes": home / ".config" / "vshell" / "themes",
            "home": home,
            "cfg": home / ".config" / "vshell",
            "state": home / ".local" / "state" / "vshell",
        }
        for key in ("cfg", "state", "userThemes"):
            dirs[key].mkdir(parents=True, exist_ok=True)
        for where, relatives in (present or {}).items():
            for relative in relatives:
                seeded = dirs[where] / relative
                seeded.parent.mkdir(parents=True, exist_ok=True)
                seeded.write_text("")
        with patch.object(helper, "repo_root", lambda: dirs["repo"]), \
                patch.object(helper, "user_themes_dir", lambda: dirs["userThemes"]), \
                patch.object(helper, "home", lambda: dirs["home"]), \
                patch.object(helper, "cfg_dir", lambda: dirs["cfg"]), \
                patch.object(helper, "state_dir", lambda: dirs["state"]):
            yield dirs


def here(value, dirs):
    """A case-table path as it reads on the installation `dirs`."""
    for key in ("repo", "userThemes", "home"):
        value = value.replace(TABLE_ROOTS[key] if key != "userThemes" else TABLE_ROOTS["userThemes"], str(dirs[key]))
    return value


def test_portable_ref_records_what_this_installation_owns_and_nothing_else():
    """Recording is containment alone, whatever the filesystem holds.

    Each row is run on an installation seeded with the package files it names, so a
    row whose package this installation does have still records as it stands: the
    difference between recording and repairing is what this pins.
    """
    for row in CASES["ref"]:
        with installation(row["present"]) as dirs:
            path = here(row["path"], dirs)
            got = helper.portable_ref(path)
            want = here(row["ref"], dirs)
            assert got == want, f"portable_ref({path!r}): {row['why']}: expected {want!r}, got {got!r}"
            back = helper.resolve_path(got)
            want_back = here(row["resolved"], dirs)
            assert back == want_back, (
                f"resolve_path(portable_ref({path!r})): {row['why']}: expected {want_back!r}, got {back!r}")


def test_reading_repairs_only_a_package_this_installation_holds():
    """The repair emits a path only when the file it names is present here.

    A row whose file is absent comes back untouched: a reader whose root carries no
    packages at all, as the greeter's staged runtime does not, changes nothing, and a
    directory outside VGS that merely looks like a package keeps loading.
    """
    for row in CASES["recover"]:
        with installation(row["present"]) as dirs:
            path = here(row["path"], dirs)
            got = helper.resolved_wallpaper(path)
            want = here(row["recovered"], dirs)
            assert got == want, (
                f"resolved_wallpaper({path!r}) holding {row['present']}: {row['why']}: "
                f"expected {want!r}, got {got!r}")


def test_resolve_path_reads_every_reference_form_the_table_names():
    with installation() as dirs:
        for row in CASES["resolve"]:
            got = helper.resolve_path(here(row["ref"], dirs))
            want = here(row["path"], dirs)
            assert got == want, f"resolve_path({row['ref']!r}): {row['why']}: expected {want!r}, got {got!r}"


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
    row = CASES["ref"][0]
    with installation() as dirs:
        roles = {"wallpaper": here(row["path"], dirs)}
        assert helper.render_template("{wallpaper.ref}", roles, "t") == here(row["ref"], dirs)
        assert helper.render_template("{wallpaper}", roles, "t") == here(row["path"], dirs), (
            "a target without the modifier keeps the absolute path its application needs")


def test_an_applied_theme_records_a_reference_and_reads_back_the_path():
    """The round trip the bug report names: apply, then read the applied state.

    `applied_theme_state` is what `apply_theme_obj` writes to `theme-current.json`
    and `applied_blueprint` is what reads it, so the two together are the file's
    whole contract.
    """
    row = CASES["ref"][0]
    with installation() as dirs:
        path = here(row["path"], dirs)
        state = helper.applied_theme_state({"name": "t", "palette": {"wallpaper": path, "colors": []}})
        assert state["palette"]["wallpaper"] == here(row["ref"], dirs), (
            "theme-current.json must record the reference, not the checkout path")
        (dirs["cfg"] / "theme-current.json").write_text(json.dumps(state))
        assert helper.applied_blueprint()["palette"]["wallpaper"] == path, (
            "a reader gets the path on this machine, so an apply rebuilt from the "
            "applied theme keeps the same wallpaper")


def test_state_written_by_an_installation_that_is_gone_recovers():
    """The reported failure: durable state naming a worktree that no longer exists.

    Both files were written before references existed, so both hold an absolute path
    into a directory that has been removed. Each reader must answer with this
    installation's copy of the same package background.
    """
    stale = CASES["recover"][0]
    with installation(stale["present"]) as dirs:
        path = here(stale["path"], dirs)
        (dirs["cfg"] / "theme-current.json").write_text(json.dumps({"name": "t", "palette": {"wallpaper": path}}))
        (dirs["cfg"] / "theme.json").write_text(json.dumps({"name": "t", "wallpaper": path, "colors": {}}))
        want = here(stale["recovered"], dirs)
        assert helper.applied_blueprint()["palette"]["wallpaper"] == want, (
            "theme-current.json holding a removed checkout's path must name this "
            "installation's copy of the same package background")
        assert helper.current_theme()["wallpaper"] == want, (
            "the shell's theme.json must recover the same way, which is what carries the "
            "repair into the session through MethodTheme")


def test_the_shell_theme_file_reads_back_as_a_path():
    row = CASES["ref"][0]
    with installation() as dirs:
        (dirs["cfg"] / "theme.json").write_text(
            json.dumps({"name": "t", "wallpaper": here(row["ref"], dirs), "colors": {}}))
        assert helper.current_theme()["wallpaper"] == here(row["resolved"], dirs), (
            "`vshell theme current` answers with a path the shell can load")


def test_the_default_theme_answers_with_a_path_before_any_apply():
    """A fresh install has no theme.json, so `current_theme` renders the default.

    That render runs the same `{wallpaper.ref}` template, so without resolving it
    `vshell theme current` and every in-process caller get a token instead of a path.
    """
    with installation(keep_repo=True):
        wallpaper = helper.current_theme()["wallpaper"]
    assert helper.VSHELL_ROOT_TOKEN not in wallpaper, (
        f"the default theme's wallpaper must reach a caller as a path, got {wallpaper!r}")
    assert wallpaper.startswith(str(REPO_ROOT) + "/"), (
        f"the default theme's background sits under this installation, got {wallpaper!r}")


def flagged_session_keys():
    """The session keys `SessionSpec.js` marks `ref` or `refMap`, read by brace.

    Collected from each entry's own body rather than from its first line, so an entry
    whose flag wraps is still seen. A miss here would drop a key from both sides of
    the comparison below and pass, which is the direction that costs a wallpaper.
    """
    spec = (REPO_ROOT / "quickshell" / "vshell" / "Common" / "settings" / "SessionSpec.js").read_text()
    entries = re.findall(r"(\w+):\s*\{((?:[^{}]|\{[^{}]*\})*)\}", spec, re.DOTALL)
    flagged = {name for name, body in entries if re.search(r"\b(?:ref|refMap):\s*true", body)}
    declared = len(re.findall(r"\b(?:ref|refMap):\s*true", spec))
    assert len(flagged) == declared, (
        f"SessionSpec.js declares {declared} reference flags but the brace scan collected "
        f"{len(flagged)} keys ({sorted(flagged)}); the scan is broken, not the spec")
    return flagged


def test_the_greeter_copy_carries_paths_and_covers_every_wallpaper_key():
    """The greeter resolves a reference against its own staged runtime.

    `sync_greeter_runtime` copies `quickshell/vshell` and the runtime bin files into
    the cache and no `themes/`, while `bin/vshell` sets VSHELL_ROOT to that runtime,
    so a rooted reference in the copied files names nothing and the login screen
    shows no wallpaper. The copy therefore carries resolved paths.

    The key set is pinned against `SessionSpec.js`, which owns it.
    """
    assert flagged_session_keys() == set(helper.SESSION_WALLPAPER_KEYS), (
        "SESSION_WALLPAPER_KEYS must name exactly the keys SessionSpec.js marks ref or refMap; "
        f"the spec marks {sorted(flagged_session_keys())} and the helper lists "
        f"{sorted(helper.SESSION_WALLPAPER_KEYS)}")

    package = CASES["ref"][0]
    stale = CASES["recover"][0]
    with installation(stale["present"]) as dirs:
        reference = here(package["ref"], dirs)
        stale_path = here(stale["path"], dirs)
        (dirs["cfg"] / "theme.json").write_text(json.dumps({"name": "t", "wallpaper": reference, "colors": {}}))
        (dirs["state"] / "session.json").write_text(json.dumps({
            "wallpaperPath": reference,
            "wallpaperPathLight": reference,
            "wallpaperPathDark": stale_path,
            "monitorWallpapers": {"DP-1": reference},
            "monitorWallpapersLight": {"DP-1": reference},
            "monitorWallpapersDark": {"DP-1": stale_path},
        }))
        theme = helper.current_theme_json()
        session = helper.current_session_json(theme)
        wanted = {here(package["resolved"], dirs), here(stale["recovered"], dirs)}
        assert helper.VSHELL_ROOT_TOKEN not in json.dumps(theme), (
            "the greeter's theme.json copy must carry no token; the greeter's own root has no themes/")
        assert helper.VSHELL_ROOT_TOKEN not in json.dumps(session), (
            "the greeter's session.json copy must carry no token, for the same reason")
        for key in helper.SESSION_WALLPAPER_KEYS:
            value = session[key]
            for got in ([value] if isinstance(value, str) else list(value.values())):
                assert got in wanted, (
                    f"{key} reached the greeter copy as {got!r}, which is neither the resolved "
                    "package background nor the repaired one")


def test_the_greeter_cache_takes_its_state_from_the_resolving_readers():
    """Every writer of the greeter cache reads through the two functions above.

    A writer that read `~/.config/vshell/theme.json` directly again would put a
    reference back into the cache with both suites otherwise green.
    """
    source = (REPO_ROOT / "bin" / "vshell_helper.py").read_text()
    calls = re.findall(r"sync_profile_cache\(([^)]*)\)", source)
    definitions = [call for call in calls if call.startswith("cache_dir_path: Path")]
    assert len(definitions) == 1, "sync_profile_cache must be defined once"
    for call in [call for call in calls if call not in definitions]:
        assert "theme" in call and "session" in call, (
            f"sync_profile_cache({call}) must pass the theme and session the readers produced")
    for body_name in ("sync_profile_cache_unprivileged", "cmd_greeter_sync"):
        match = re.search(rf"def {body_name}\(.*?(?=\ndef )", source, re.DOTALL)
        if not match:
            continue
        body = match.group(0)
        assert "current_theme_json()" in body and "current_session_json(" in body, (
            f"{body_name} must take its theme and session from current_theme_json and "
            "current_session_json, which are where a reference becomes a path for the greeter")
    producers = len(re.findall(r"\bcurrent_session_json\(", source))
    assert producers == len(re.findall(r"\bcurrent_theme_json\(\)", source)), (
        "every reader of the greeter's theme state reads its session state too, so a new "
        "writer cannot take one without the other")


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
