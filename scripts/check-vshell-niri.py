#!/usr/bin/env python3
"""Focused helper smoke tests for VGS Niri integration paths."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import select
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = REPO_ROOT / "bin" / "vshell-helper"
SHARED_TESTS_PATH = REPO_ROOT / "scripts" / "check-vshell-helper.py"


def load_shared_tests():
    loader = importlib.machinery.SourceFileLoader(
        "check_vshell_helper_shared", str(SHARED_TESTS_PATH)
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


shared = load_shared_tests()
helper = shared.helper
niri = helper._niri()
assert_equal = shared.assert_equal
with_temp_home = shared.with_temp_home


def test_niri_layout_keybinds_and_windowrules():
    layout, meta = niri._niri_layout_payload({
        "surfaceGeometryTarget": "compositor",
        "cornerRadius": 11,
        "niriLayoutRadiusOverride": 13,
        "niriLayoutGapsOverride": 7,
        "niriLayoutBorderSize": 3,
    })
    assert_equal(meta, {
        "target": "compositor",
        "manageNiriShape": True,
        "radius": 13,
        "gaps": 7,
        "border": 3,
    }, "Niri layout metadata")
    for expected in (
        "gaps 7",
        "focus-ring {\n        off",
        "border {\n        on",
        "width 3",
        "geometry-corner-radius 13",
        "clip-to-geometry true",
        "tiled-state true",
        "draw-border-with-background false",
    ):
        if expected not in layout:
            raise AssertionError(f"Niri layout should contain {expected!r}")
    if "tab-indicator" in layout:
        raise AssertionError("Niri window radius must not be rendered as tab-indicator radius")
    zero_border_layout, _ = niri._niri_layout_payload({
        "surfaceGeometryTarget": "sync",
        "cornerRadius": 0,
        "surfaceBorderWidth": 0,
    })
    if "border {\n        off\n        width 0" not in zero_border_layout:
        raise AssertionError("zero Niri border width should disable the compositor border")
    layout, meta = niri._niri_layout_payload({
        "surfaceGeometryTarget": "quickshell",
        "cornerRadius": 11,
        "surfaceBorderWidth": 2,
        "niriLayoutGapsOverride": 5,
    })
    assert_equal(meta["manageNiriShape"], False, "Quickshell target should not manage Niri shape")
    if ("focus-ring" in layout or "window-rule" in layout or "border {" in layout
            or "geometry-corner-radius" in layout or "clip-to-geometry" in layout):
        raise AssertionError("Quickshell target should omit Niri shape blocks")
    if "gaps 5" not in layout:
        raise AssertionError("Quickshell target should preserve non-shape Niri layout")
    unmanaged_layout, unmanaged_meta = niri._niri_layout_payload({
        "niriLayoutGapsOverride": -2,
        "barConfigs": [{"spacing": 17}],
    })
    if "gaps " in unmanaged_layout:
        raise AssertionError("Niri gaps Off must leave gaps to the user's base config")
    assert_equal(unmanaged_meta["gaps"], None, "Niri unmanaged gaps metadata")
    for bad_action in ("spawn; quit", "focus-window} quit"):
        try:
            niri._niri_action_kdl(bad_action)
        except ValueError:
            pass
        else:
            raise AssertionError("Niri bind action names must reject KDL injection")
    try:
        niri._niri_size_rule("default-column-width", "proportion 0.5; } quit")
    except ValueError:
        pass
    else:
        raise AssertionError("Niri size rules must reject KDL injection")

    def run_case(home):
        niri_dir = home / ".config" / "niri"
        niri_dir.mkdir(parents=True)
        (niri_dir / "extra.kdl").write_text("""
binds {
    Mod+Q hotkey-overlay-title="Close" { close-window; }
}
window-rule {
    match app-id="^foot$" is-floating=false
    open-floating true
    default-column-width { proportion 0.4; }
    default-floating-position x=20 y=30 relative-to="bottom-right"
}
""")
        (niri_dir / "config.kdl").write_text(
            'include "extra.kdl"\n'
            'include "vgs/binds.kdl"; // managed by VGS\n'
            'include "vgs/windowrules.kdl"\n'
        )

        niri._write_vgs_niri_binds([{
            "key": "Mod+Space",
            "desc": "Launcher",
            "action": "spawn vshell ipc call vshell-menu toggle",
            "allowWhenLocked": True,
            "repeat": False,
        }])
        bind_data = niri.niri_binds_json()
        assert_equal(bind_data["vgsStatus"]["included"], True, "Niri bind include detection")
        all_binds = [bind for group in bind_data["binds"].values() for bind in group]
        keys = {bind["key"] for bind in all_binds}
        if keys != {"Mod+Q", "Mod+Space"}:
            raise AssertionError(f"Niri bind parser keys: {keys!r}")
        managed = next(bind for bind in all_binds if bind["key"] == "Mod+Space")
        assert_equal(managed["allowWhenLocked"], True, "Niri bind allow-when-locked")
        assert_equal(managed["repeat"], False, "Niri bind repeat")

        # Retired launcher targets migrate only inside vshell invocations. Other
        # programs can legitimately use the same IPC-looking arguments.
        niri._write_vgs_niri_binds([
            {"key": "Mod+Space", "desc": "Launcher", "action": "spawn vshell ipc call spotlight toggle"},
            {"key": "Mod+D", "desc": "Spotlight bar", "action": "spawn vshell ipc call spotlight-bar open"},
            {"key": "Mod+Slash", "desc": "Launcher query", "action": "spawn vshell ipc call launcher toggleQuery emoji"},
            {"key": "Mod+T", "desc": "Terminal", "action": "spawn foot"},
            {"key": "Mod+A", "desc": "Absolute path", "action": "spawn /usr/bin/vshell ipc call spotlight toggle"},
            {"key": "Mod+N", "desc": "Not vshell", "action": "spawn notify-send ipc call spotlight toggle"},
            {"key": "Mod+W", "desc": "Lookalike", "action": "spawn my-vshell-wrapper ipc call launcher toggle"},
        ])
        migrated_binds = {bind["key"]: bind["action"] for bind in niri._load_vgs_niri_binds()}
        assert_equal(migrated_binds["Mod+Space"], "spawn vshell ipc call vshell-menu toggle", "spotlight bind migration")
        assert_equal(migrated_binds["Mod+D"], "spawn vshell ipc call vshell-menu open", "spotlight-bar bind migration")
        assert_equal(migrated_binds["Mod+Slash"], "spawn vshell ipc call vshell-menu toggle", "launcher query bind migration")
        assert_equal(migrated_binds["Mod+T"], "spawn foot", "unrelated bind left alone")
        assert_equal(migrated_binds["Mod+A"], "spawn /usr/bin/vshell ipc call vshell-menu toggle", "absolute vshell path should still migrate")
        assert_equal(migrated_binds["Mod+N"], "spawn notify-send ipc call spotlight toggle", "non-vshell program must not be rewritten")
        assert_equal(migrated_binds["Mod+W"], "spawn my-vshell-wrapper ipc call launcher toggle", "lookalike program must not be rewritten")
        assert_equal(niri.migrate_vgs_niri_binds()["migrated"], True, "bind migration should rewrite binds.kdl")
        on_disk = (niri.niri_config_dir() / "binds.kdl").read_text()
        # Scope assertions to vshell; other programs can retain spotlight arguments.
        for retired in ("spotlight-bar", "spotlight", "launcher"):
            if f'"vshell" "ipc" "call" "{retired}"' in on_disk:
                raise AssertionError(f"retired launcher IPC target {retired!r} survived the binds.kdl rewrite")
        if '"notify-send" "ipc" "call" "spotlight" "toggle"' not in on_disk:
            raise AssertionError("a non-vshell bind was rewritten by the launcher migration")
        assert_equal(niri.migrate_vgs_niri_binds()["migrated"], False, "bind migration should be idempotent")

        # A migration Niri refuses to reload leaves the file and the live
        # compositor disagreeing; that must reach the caller, not be dropped.
        reload_calls = []
        original_reload = niri._reload_niri

        def _failing_reload():
            reload_calls.append("called")
            return {"attempted": True, "ok": False, "stdout": "", "stderr": "reload rejected"}

        niri._reload_niri = _failing_reload
        try:
            payload = niri.niri_binds_json()
            assert_equal(reload_calls, [], "clean read should not reload Niri")
            assert_equal("bindMigration" in payload, False, "clean read should report no migration")

            niri._write_vgs_niri_binds([
                {"key": "Mod+Space", "desc": "Launcher", "action": "spawn vshell ipc call spotlight toggle"},
            ])
            result = niri.migrate_vgs_niri_binds()
            assert_equal(result["migrated"], True, "retired bind should migrate")
            assert_equal(result["ok"], False, "failed Niri reload must not report ok")
            assert_equal(result["reload"]["stderr"], "reload rejected", "reload failure detail should survive")
            assert_equal(reload_calls, ["called"], "migration should reload exactly once")

            niri._write_vgs_niri_binds([
                {"key": "Mod+Space", "desc": "Launcher", "action": "spawn vshell ipc call spotlight toggle"},
            ])
            payload = niri.niri_binds_json()
            assert_equal(payload["bindMigration"]["ok"], False, "binds payload must surface the failed reload")
        finally:
            niri._reload_niri = original_reload

        niri._write_vgs_niri_binds([{
            "key": "Mod+Space",
            "desc": "Launcher",
            "action": "spawn vshell ipc call vshell-menu toggle",
            "allowWhenLocked": True,
            "repeat": False,
        }])
        original_reload = niri._reload_niri
        niri._reload_niri = lambda: {
            "attempted": True, "ok": False, "stdout": "", "stderr": "reload rejected"
        }
        try:
            assert_equal(helper.cmd_keybinds([
                "set", "niri", "Mod+R", "spawn foot", "--desc", "Terminal"
            ]), 1, "Niri keybind edit should propagate reload failure")
        finally:
            niri._reload_niri = original_reload

        saved = niri.niri_windowrule_add({
            "name": "Terminal",
            "matchCriteria": {"appId": "^foot$"},
            "actions": {
                "openFloating": True,
                "opacity": 0.9,
                "defaultColumnWidth": "proportion 0.5",
            },
            "enabled": True,
        })
        assert_equal(saved["ok"], True, "Niri rule save")
        first_id = saved["rules"][0]["id"]
        second = niri.niri_windowrule_add({
            "name": "Browser",
            "matchCriteria": {"appId": "^firefox$"},
            "actions": {"openMaximized": True},
            "enabled": True,
        })
        second_id = second["rules"][1]["id"]
        updated = niri.niri_windowrule_update(first_id, {
            "name": "Terminal updated",
            "matchCriteria": {"appId": "^foot$"},
            "actions": {
                "openFloating": True,
                "opacity": 0.9,
                "defaultColumnWidth": "proportion 0.5",
            },
            "enabled": True,
        })
        assert_equal(updated["rules"][0]["name"], "Terminal updated", "Niri rule update")
        reordered = niri.niri_windowrule_reorder([second_id, first_id])
        assert_equal([rule["id"] for rule in reordered["rules"]], [second_id, first_id],
                     "Niri rule reorder")
        removed = niri.niri_windowrule_remove(second_id)
        assert_equal([rule["id"] for rule in removed["rules"]], [first_id], "Niri rule remove")
        rule_data = niri.niri_windowrules_json()
        assert_equal(rule_data["vgsStatus"]["included"], True, "Niri rule include detection")
        managed_rules = [rule for rule in rule_data["rules"] if "vgs/windowrules" in rule["source"]]
        assert_equal(len(managed_rules), 1, "managed Niri rule count")
        assert_equal(managed_rules[0]["actions"]["defaultColumnWidth"], "proportion 0.5", "Niri nested size round trip")
        external = next(rule for rule in rule_data["rules"] if rule["source"].endswith("extra.kdl"))
        assert_equal(external["actions"]["defaultColumnWidth"], "proportion 0.4", "external Niri nested size parse")
        assert_equal(external["actions"]["defaultFloatingX"], 20, "external Niri floating X parse")
        assert_equal(external["actions"]["defaultFloatingRelativeTo"], "bottom-right", "external Niri floating anchor parse")
        rendered = niri.niri_windowrules_path().read_text()
        for expected in ('match app-id="^foot$"', "open-floating true", "default-column-width { proportion 0.5; }"):
            if expected not in rendered:
                raise AssertionError(f"Niri rule output should contain {expected!r}")
        niri.niri_windowrules_state_path().write_text("{broken")
        try:
            niri.niri_windowrule_add({"name": "Must not overwrite"})
        except ValueError as exc:
            if str(niri.niri_windowrules_state_path()) not in str(exc):
                raise AssertionError("corrupt Niri sidecar error should name its path")
        else:
            raise AssertionError("corrupt Niri sidecar must block mutations")
        niri._save_niri_windowrules(managed_rules)
        niri.niri_windowrules_state_path().unlink()
        fallback = niri._load_niri_windowrules_state()
        assert_equal(len(fallback), 1, "managed Niri KDL fallback count")
        assert_equal(fallback[0]["actions"]["defaultColumnWidth"], "proportion 0.5", "managed Niri KDL fallback")

    with_temp_home(run_case)


def test_niri_outputs_renderer():
    content = niri._niri_outputs_payload({
        "displayNameMode": "model",
        "outputs": {
            "DP-1": {
                "make": "Acme",
                "model": "Panel",
                "serial": "123",
                "modes": [{"width": 2560, "height": 1440, "refresh_rate": 144000}],
                "current_mode": 0,
                "logical": {"x": 0, "y": 0, "scale": 1.5, "transform": "90"},
                "vrr_enabled": True,
            },
            "HDMI-A-1": {
                "explicitIdentifier": True,
                "logical": {"x": 1707, "y": 0, "scale": 1, "transform": "Normal"},
            },
        },
        "settings": {
            "Acme Panel 123": {
                "vrrOnDemand": True,
                "focusAtStartup": True,
                "backdropColor": "#112233",
                "hotCorners": {"corners": ["top-left", "invalid-corner"]},
                "layout": {
                    "gaps": 7,
                    "defaultColumnWidth": {"type": "proportion", "value": 0.5},
                    "presetColumnWidths": [{"type": "proportion", "value": 0.33}],
                    "alwaysCenterSingleColumn": False,
                },
            },
            "HDMI-A-1": {"disabled": True},
        },
    })
    for expected in (
        'output "Acme Panel 123" {',
        'mode "2560x1440@144.000"',
        "scale 1.5",
        'transform "90"',
        "position x=0 y=0",
        "variable-refresh-rate on-demand=true",
        "focus-at-startup",
        'backdrop-color "#112233"',
        "top-left",
        "default-column-width { proportion 0.5; }",
        "always-center-single-column false",
        'output "HDMI-A-1" {',
        "    off",
    ):
        if expected not in content:
            raise AssertionError(f"Niri outputs renderer should contain {expected!r}")
    if "invalid-corner" in content:
        raise AssertionError("Niri outputs renderer should reject unknown hot-corner names")


def test_niri_config_lock():
    def run_case(_tmp_home):
        env = os.environ.copy()
        env["PYTHONPATH"] = str(REPO_ROOT / "bin")
        child = """
import os
from pathlib import Path
import vshell_niri as niri

niri.configure(niri.NiriRuntime(
    home=lambda: Path(os.environ["HOME"]),
    cfg_dir=lambda: Path(os.environ["HOME"]) / ".config" / "vshell",
    run=lambda *args, **kwargs: None,
    write_file=lambda path, content: path.write_text(content),
    load_settings=lambda: {},
    coerce_int=lambda value, default, low, high: default,
    optional_nonnegative_int=lambda value, low, high: None,
))
print("ready", flush=True)
with niri.niri_config_lock():
    print("acquired", flush=True)
"""
        with niri.niri_config_lock():
            proc = subprocess.Popen(
                [sys.executable, "-c", child],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            assert proc.stdout is not None
            assert_equal(proc.stdout.readline().strip(), "ready", "Niri lock child readiness")
            readable, _, _ = select.select([proc.stdout], [], [], 0.2)
            if readable:
                raise AssertionError("Niri config child acquired a lock held by another process")
        assert proc.stdout is not None
        assert_equal(proc.stdout.readline().strip(), "acquired", "Niri lock child acquisition")
        stdout, stderr = proc.communicate(timeout=5)
        if proc.returncode != 0:
            raise AssertionError(f"Niri lock child failed: {stderr or stdout}")

    with_temp_home(run_case)


def test_niri_helper_cli():
    def run_case(tmp_home):
        fake_bin = tmp_home / "bin"
        fake_bin.mkdir()
        fake_niri = fake_bin / "niri"
        fake_niri.write_text("""#!/usr/bin/env bash
if [[ $1 == msg && $2 == -j && $3 == outputs ]]; then
  if [[ ${FAKE_NIRI_INVALID_OUTPUT:-0} == 1 ]]; then printf 'not-json\\n'; else printf '{"DP-1":{"name":"DP-1"}}\\n'; fi
  exit 0
fi
if [[ $1 == validate && $2 == -c ]]; then
  [[ -f $3 ]] || { printf 'validation file missing\\n' >&2; exit 2; }
  printf '%s\\n' "$3" >"$FAKE_NIRI_VALIDATE_MARKER"
  if [[ ${FAKE_NIRI_OUTPUT_VALIDATE_FAIL:-0} == 1 ]]; then printf 'invalid output config\\n' >&2; exit 1; fi
  exit 0
fi
if [[ $1 == validate ]]; then
  if [[ ${FAKE_NIRI_VALIDATE_FAIL:-0} == 1 ]]; then printf 'invalid config\\n' >&2; exit 1; fi
  exit 0
fi
if [[ $1 == msg && $2 == action && $3 == load-config-file ]]; then exit 0; fi
exit 1
""")
        fake_niri.chmod(0o755)
        env = os.environ.copy()
        env.update({
            "HOME": str(tmp_home),
            "PATH": str(fake_bin) + os.pathsep + env["PATH"],
            "NIRI_SOCKET": str(tmp_home / "niri.sock"),
            "FAKE_NIRI_VALIDATE_MARKER": str(tmp_home / "validated-path"),
        })

        def invoke(*args, extra_env=None):
            next_env = env.copy()
            next_env.update(extra_env or {})
            return subprocess.run(
                [str(HELPER_PATH), *args],
                env=next_env,
                capture_output=True,
                text=True,
                timeout=5,
            )

        current = invoke("config", "niri-outputs-current")
        assert_equal(current.returncode, 0, "Niri outputs CLI success")
        assert_equal(json.loads(current.stdout)["outputs"]["DP-1"]["name"], "DP-1",
                     "Niri outputs CLI payload")

        invalid = invoke("config", "niri-outputs-current",
                         extra_env={"FAKE_NIRI_INVALID_OUTPUT": "1"})
        assert_equal(invalid.returncode, 1, "Niri outputs CLI invalid JSON status")
        if "invalid Niri outputs response" not in json.loads(invalid.stdout)["error"]:
            raise AssertionError("Niri outputs CLI should explain invalid compositor JSON")

        validation = invoke("config", "niri-validate",
                            extra_env={"FAKE_NIRI_VALIDATE_FAIL": "1"})
        assert_equal(validation.returncode, 1, "Niri validate CLI failure status")
        assert_equal(json.loads(validation.stdout)["error"], "invalid config",
                     "Niri validate CLI error")

        reload_result = invoke("config", "niri-reload")
        assert_equal(reload_result.returncode, 0, "Niri reload CLI success")

        valid_payload = json.dumps({"outputs": {}, "settings": {}})
        output_validation = invoke("config", "niri-outputs-validate", valid_payload)
        assert_equal(output_validation.returncode, 0, "Niri output validation CLI success")
        validated_path = Path(env["FAKE_NIRI_VALIDATE_MARKER"]).read_text().strip()
        if not validated_path.endswith(".kdl"):
            raise AssertionError("Niri output validation should pass a temporary KDL file")

        failed_output_validation = invoke(
            "config", "niri-outputs-validate", valid_payload,
            extra_env={"FAKE_NIRI_OUTPUT_VALIDATE_FAIL": "1"},
        )
        assert_equal(failed_output_validation.returncode, 1,
                     "Niri output validation CLI failure status")
        assert_equal(json.loads(failed_output_validation.stdout)["error"],
                     "invalid output config", "Niri output validation CLI error")

        bad_payload = invoke("config", "niri-outputs-validate", "{")
        assert_equal(bad_payload.returncode, 2, "Niri output payload parse failure")

    with_temp_home(run_case)


def test_niri_capture_script_guards():
    def run_case(tmp_home):
        fake_bin = tmp_home / "bin"
        fake_bin.mkdir()
        marker = tmp_home / "hyprland-tool-called"
        clipboard = tmp_home / "clipboard.png"
        for name, script in {
            "niri": """#!/usr/bin/env bash
[[ $1 == msg && $2 == version ]] && exit 0
for arg in "$@"; do
  [[ $arg == --path ]] && exit 64
done
if [[ $1 == msg && $2 == action ]]; then
  if [[ $3 == screenshot-window || $3 == screenshot-screen ]]; then
    [[ " $* " == *" --write-to-disk false "* ]] || exit 65
  fi
  (sleep 0.15; printf 'fake-niri-png' >"$FAKE_NIRI_CLIPBOARD") &
  exit 0
fi
exit 1
""",
            "grim": """#!/usr/bin/env bash
for arg in "$@"; do target=$arg; done
printf 'fake-png' >"$target"
""",
            "wl-copy": """#!/usr/bin/env bash
cat >"$FAKE_CLIPBOARD"
""",
            "wl-paste": """#!/usr/bin/env bash
if [[ " $* " == *" --watch "* ]]; then
  payload="${@: -2:1}"
  done_marker="${@: -1}"
  while [[ ! -s $FAKE_NIRI_CLIPBOARD ]]; do sleep 0.02; done
  printf 'fake-' >"$payload"
  sleep 0.10
  printf 'niri-png' >>"$payload"
  : >"$done_marker"
  sleep 30
else
  cat "$FAKE_NIRI_CLIPBOARD"
fi
""",
            "notify-send": """#!/usr/bin/env bash
exit 0
""",
            "hyprctl": """#!/usr/bin/env bash
touch "$FAKE_HYPR_MARKER"
exit 1
""",
            "hyprpicker": """#!/usr/bin/env bash
touch "$FAKE_HYPR_MARKER"
exit 1
""",
            "slurp": """#!/usr/bin/env bash
touch "$FAKE_HYPR_MARKER"
exit 1
""",
        }.items():
            path = fake_bin / name
            path.write_text(script)
            path.chmod(0o755)

        output_dir = tmp_home / "screenshots"
        state_dir = tmp_home / "state"
        env = os.environ.copy()
        env.update({
            "HOME": str(tmp_home),
            "PATH": str(fake_bin) + os.pathsep + env["PATH"],
            "NIRI_SOCKET": str(tmp_home / "niri.sock"),
            "XDG_STATE_HOME": str(state_dir),
            "VSHELL_SCREENSHOT_DIR": str(output_dir),
            "FAKE_CLIPBOARD": str(clipboard),
            "FAKE_NIRI_CLIPBOARD": str(tmp_home / "niri-clipboard.png"),
            "FAKE_HYPR_MARKER": str(marker),
        })
        copied = subprocess.run(
            [str(REPO_ROOT / "bin" / "vshell-capture-screenshot"), "all-displays", "copy"],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert_equal(copied.returncode, 0, "Niri copy-only screenshot")
        assert_equal(list(output_dir.iterdir()), [], "Niri copy-only screenshot output directory")
        scratch = list((state_dir / "vshell-capture").glob("clipboard-*.png"))
        assert_equal(len(scratch), 1, "Niri copy-only scratch preview")
        assert_equal(clipboard.read_bytes(), b"fake-png", "Niri screenshot clipboard content")

        copied_window = subprocess.run(
            [str(REPO_ROOT / "bin" / "vshell-capture-screenshot"), "window", "copy"],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert_equal(copied_window.returncode, 0, "Niri window screenshot")
        assert_equal(clipboard.read_bytes(), b"fake-niri-png", "Niri action screenshot clipboard content")
        assert_equal(list(output_dir.iterdir()), [], "Niri action must not depend on screenshot output path")

        saved_region = subprocess.run(
            [str(REPO_ROOT / "bin" / "vshell-capture-screenshot"), "region", "save"],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert_equal(saved_region.returncode, 0, "Niri screenshot with disk saving disabled")
        saved_path = Path(saved_region.stdout.strip())
        assert_equal(saved_path.parent, output_dir, "Niri VGS-owned screenshot destination")
        assert_equal(saved_path.read_bytes(), b"fake-niri-png", "Niri clipboard screenshot persistence")

        recording_env = env.copy()
        recording_env["VSHELL_SCREENRECORD_PORTAL"] = "false"
        guarded = subprocess.run(
            [str(REPO_ROOT / "bin" / "vshell-capture-screenrecording"), "start", "fullscreen"],
            env=recording_env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert_equal(guarded.returncode, 1, "Niri non-portal recording guard")
        if "requires the XDG desktop portal" not in guarded.stderr:
            raise AssertionError("Niri recording guard should explain the portal requirement")
        if marker.exists():
            raise AssertionError("Niri recording guard must run before Hyprland-only tools")

    with_temp_home(run_case)


def test_niri_greeter_config():
    rendered = niri.niri_greeter_config("/usr/bin/qs -p /var/cache/vshell/runtime")
    for expected in (
        "hotkey-overlay { skip-at-startup; }",
        "prefer-no-csd",
        'spawn-at-startup "sh" "-lc"',
        "niri msg action quit --skip-confirmation",
    ):
        if expected not in rendered:
            raise AssertionError(f"Niri greeter config should contain {expected!r}")


def test_niri_include_repair():
    def run_case(tmp_home):
        main = tmp_home / ".config" / "niri" / "config.kdl"
        missing = niri.ensure_niri_include("colors.kdl")
        assert_equal(missing["ok"], False, "missing Niri config repair")
        assert_equal(missing["setupRequired"], True, "missing Niri config setup status")
        if main.exists():
            raise AssertionError("include repair must not replace Niri's embedded default with a stub")

        main.parent.mkdir(parents=True, exist_ok=True)
        main.write_text("input {}\n")
        repaired = niri.ensure_niri_include("colors.kdl")
        assert_equal(repaired["changed"], True, "Niri include repair")
        if main.read_text().count('include "vgs/colors.kdl"') != 1:
            raise AssertionError("Niri include repair should append exactly one include")
        assert_equal(niri.ensure_niri_include("colors.kdl")["changed"], False,
                     "Niri include repair idempotency")
        if len(list(main.parent.glob("config.kdl.vgsbackup*"))) != 1:
            raise AssertionError("Niri include repair should preserve one pre-edit backup")

        fragment = main.parent / "vgs" / "colors.kdl"
        for equivalent in (
            'include "./vgs/colors.kdl"\n',
            f'include "{fragment}"\n',
            "include vgs/colors.kdl;\n",
        ):
            main.write_text(equivalent)
            status = niri.niri_include_status("colors.kdl")
            assert_equal(status["included"], True, f"Niri equivalent include {equivalent!r}")
            assert_equal(niri.ensure_niri_include("colors.kdl")["changed"], False,
                         f"Niri equivalent include repair {equivalent!r}")
            if len(main.read_text().splitlines()) != 1:
                raise AssertionError("equivalent Niri include must not be duplicated")

        main.write_text('include "vgs/other.kdl"\n')
        assert_equal(niri.niri_include_status("colors.kdl")["included"], False,
                     "missing Niri managed include status")

    with_temp_home(run_case)


def test_ppm_color_pixel():
    pixel = helper.ppm_first_pixel(b"P6\n# generated by grim\n1 1\n255\n\x12\x34\x56")
    assert_equal(pixel, (0x12, 0x34, 0x56), "Niri color picker PPM pixel")

def main():
    test_niri_layout_keybinds_and_windowrules()
    test_niri_outputs_renderer()
    test_niri_config_lock()
    test_niri_helper_cli()
    test_niri_capture_script_guards()
    test_niri_greeter_config()
    test_niri_include_repair()
    test_ppm_color_pixel()
    print("VGS Niri helper smoke tests passed.")


if __name__ == "__main__":
    main()
