#!/usr/bin/env python3
"""Focused helper smoke tests for VGS settings-owned integration paths."""
from __future__ import annotations

import contextlib
import argparse
import ast
import colorsys
import fcntl
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import math
import os
import plistlib
import pwd
import signal
import site
import re
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import traceback
import zlib
from unittest.mock import patch
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = REPO_ROOT / "bin" / "vshell_helper.py"


def load_helper():
    loader = importlib.machinery.SourceFileLoader("vshell_helper_test_module", str(HELPER_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helper = load_helper()

# Record HOME so main() can identify a leaked temporary home before the Niri subprocess.
_HOME_AT_IMPORT = os.environ.get("HOME")

# gsettings writes this process refused, as (test, argv). A temporary HOME does not
# isolate them: they travel over the session bus to the dconf service, which writes the
# login user's database. A child process the suite starts is not covered.
_GSETTINGS_WRITES = []
_GSETTINGS_WRITE_VERBS = {"set", "reset", "reset-recursively"}


class _RefuseGsettingsWrites(subprocess.Popen):
    def __init__(self, args, *rest, **kwargs):
        if isinstance(args, str):
            argv = args.split()
        elif isinstance(args, (bytes, os.PathLike)):
            argv = [os.fsdecode(args)]
        else:
            argv = [os.fsdecode(arg) for arg in args]
        if len(argv) > 1 and Path(argv[0]).name == "gsettings" and argv[1] in _GSETTINGS_WRITE_VERBS:
            test = next((frame.name for frame in reversed(traceback.extract_stack())
                         if frame.name.startswith("test_")), "(outside a test)")
            _GSETTINGS_WRITES.append((test, argv))
            raise PermissionError(f"gsettings-write-refused: {test}")
        super().__init__(args, *rest, **kwargs)


subprocess.Popen = _RefuseGsettingsWrites


def assert_equal(actual, expected, message):
    if actual != expected:
        raise AssertionError(f"{message}: expected {expected!r}, got {actual!r}")


def _restore_env(name, value):
    if value is None:
        os.environ.pop(name, None)
    else:
        os.environ[name] = value


def with_temp_home(fn):
    # XDG_CONFIG_HOME travels with HOME, or a helper resolving config through
    # it reads the real ~/.config from a test that thought it held a temp one.
    saved = {n: os.environ.get(n) for n in ("HOME", "XDG_CONFIG_HOME", "SUDO_USER")}
    os.environ.pop("SUDO_USER", None)
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["HOME"] = tmp
        os.environ["XDG_CONFIG_HOME"] = str(Path(tmp) / ".config")
        try:
            fn(Path(tmp))
        finally:
            for name, value in saved.items():
                _restore_env(name, value)


def test_system_font_normalization():
    original_env = helper.system_font_env
    helper.system_font_env = lambda: {
        "isWayland": True,
        "isX11": False,
        "sessionType": "wayland",
        "gsettingsKeys": [],
    }
    try:
        result = helper.normalized_system_font_settings({
            "systemFontsManaged": "yes",
            "systemFontInterfaceHinting": "bogus",
            "systemFontInterfaceSubpixel": "rgb",
            "systemFontInterfaceLcdFilter": "light",
            "systemFontInterfaceAutohint": "on",
            "systemFontMonoHinting": "full",
            "systemFontMonoSubpixel": "bgr",
            "systemFontMonoLcdFilter": "legacy",
            "systemFontMonoAntialias": 0,
        })
    finally:
        helper.system_font_env = original_env

    assert_equal(result["managed"], True, "system font managed coercion")
    assert_equal(result["interface"]["hinting"], "slight", "invalid interface hinting fallback")
    assert_equal(result["interface"]["subpixel"], "none", "Wayland disables interface subpixel")
    assert_equal(result["interface"]["lcdFilter"], "light", "interface LCD filter")
    assert_equal(result["interface"]["autohint"], True, "interface autohint")
    assert_equal(result["monospace"]["hinting"], "full", "mono hinting")
    assert_equal(result["monospace"]["subpixel"], "none", "Wayland disables mono subpixel")
    assert_equal(result["monospace"]["antialias"], False, "mono antialias coercion")


def _oklch(value):
    lightness, a, b = helper.color_to_oklab(value)
    return (
        lightness,
        math.hypot(a, b),
        math.degrees(math.atan2(b, a)) % 360.0,
    )


def _hue_distance(a, b):
    distance = abs(a - b) % 360.0
    return min(distance, 360.0 - distance)


def _relative_chroma(value):
    lightness, chroma, hue = _oklch(value)
    maximum = helper._oklch_max_chroma(lightness, hue)
    return chroma / maximum if maximum > 1e-8 else 0.0


def _oklab_delta(a, b):
    lab_a = helper.color_to_oklab(a)
    lab_b = helper.color_to_oklab(b)
    return math.sqrt(sum((left - right) ** 2 for left, right in zip(lab_a, lab_b)))


def test_perceptual_theme_adjustments():
    colors = {
        "mode": "dark",
        "background": "#26323d",
        "foreground": "#b4c1cc",
        "accent": "#647f98",
        "cursor": "#91a8b9",
        "selection_background": "#40566a",
        "selection_foreground": "#d2dae1",
        **{f"color{i}": value for i, value in enumerate(helper.DEFAULT_COLORS)},
    }
    zero = helper.apply_adjustments(colors, {
        "brightness": 0, "vibrancy": 0, "contrast": 0, "hue": 0, "temperature": 0,
    })
    assert_equal(zero, colors, "neutral restyle must be byte-exact")

    # Brightness changes perceptual lightness without hue or saturation drift.
    brightness_samples = []
    for amount in (-40, -20, 0, 20, 40):
        adjusted = helper.apply_adjustments(colors, {"brightness": amount})["accent"]
        brightness_samples.append(_oklch(adjusted))
    lightness_values = [sample[0] for sample in brightness_samples]
    if any(right <= left for left, right in zip(lightness_values, lightness_values[1:])):
        raise AssertionError(f"brightness must raise OKLab L monotonically: {lightness_values!r}")
    base_relative_chroma = _relative_chroma(colors["accent"])
    base_hue = brightness_samples[2][2]
    for amount, (_lightness, _chroma, hue) in zip((-40, -20, 0, 20, 40), brightness_samples):
        adjusted = helper.apply_adjustments(colors, {"brightness": amount})["accent"]
        if abs(_relative_chroma(adjusted) - base_relative_chroma) > 0.02:
            raise AssertionError("brightness should preserve gamut-relative chroma")
        if _hue_distance(hue, base_hue) > 2.0:
            raise AssertionError("brightness should preserve hue")

    base_l, base_c, base_h = _oklch(colors["accent"])
    vibrant = _oklch(helper.apply_adjustments(colors, {"vibrancy": 35})["accent"])
    if vibrant[1] <= base_c or abs(vibrant[0] - base_l) > 0.005 or _hue_distance(vibrant[2], base_h) > 1.5:
        raise AssertionError("vibrancy must increase chroma without moving lightness or hue")
    rotated = _oklch(helper.apply_adjustments(colors, {"hue": 35})["accent"])
    rotated_hex = helper.apply_adjustments(colors, {"hue": 35})["accent"]
    if abs(rotated[0] - base_l) > 0.005 or abs(
        _relative_chroma(rotated_hex) - _relative_chroma(colors["accent"])
    ) > 0.02:
        raise AssertionError("hue must not alter perceptual lightness or gamut-relative chroma")
    if _hue_distance(rotated[2], (base_h + 35.0) % 360.0) > 1.5:
        raise AssertionError("hue slider must rotate by the requested angle")
    warmed_hex = helper.apply_adjustments(colors, {"temperature": 40})["accent"]
    warmed_l, warmed_a, warmed_b = helper.color_to_oklab(warmed_hex)
    _base_l, base_a, base_b = helper.color_to_oklab(colors["accent"])
    if abs(warmed_l - _base_l) > 0.005 or warmed_a <= base_a or warmed_b <= base_b:
        raise AssertionError("temperature must apply a reversible warm vector without changing lightness")

    contrasted = helper.apply_adjustments(colors, {"contrast": 40})
    bg_before, fg_before = _oklch(colors["background"]), _oklch(colors["foreground"])
    bg_after, fg_after = _oklch(contrasted["background"]), _oklch(contrasted["foreground"])
    if fg_after[0] - bg_after[0] <= fg_before[0] - bg_before[0]:
        raise AssertionError("positive contrast must increase the palette lightness spread")
    for before, after in ((bg_before, bg_after), (fg_before, fg_after)):
        if _hue_distance(before[2], after[2]) > 5.0:
            raise AssertionError("contrast must preserve hue")


def test_curated_app_role_passthrough():
    blueprint = helper.load_theme_package("tokyo-night")
    if not blueprint:
        raise AssertionError("Tokyo Night package missing")
    shell_roles = helper.target_roles(blueprint)
    app_roles = helper.app_target_roles(blueprint, shell_roles)
    palette = blueprint["palette"]
    extended = palette["extendedColors"]
    assert_equal(app_roles["background"], extended["background"], "curated app background")
    assert_equal(app_roles["foreground"], extended["foreground"], "curated app foreground")
    assert_equal(app_roles["selection_foreground"], extended["selection_foreground"],
                 "curated app selection foreground")
    for index, color in enumerate(palette["colors"]):
        assert_equal(app_roles[f"color{index}"], color, f"curated app ANSI color {index}")
    if shell_roles["selection_foreground"] == app_roles["selection_foreground"]:
        raise AssertionError("fixture must exercise the shell-only readability correction")
    for app in ("foot", "kitty"):
        view = helper.app_role_view(app, blueprint)
        values = {item["role"]: item["value"] for item in view["roles"]}
        assert_equal(values["selection_foreground"], extended["selection_foreground"],
                     f"{app} app role selection foreground")


# The colour keys each agent CLI documents for its own theme file. A rendered
# target that misses one leaves that CLI painting it from its built-in default,
# and an extra key is a validation error for omp and opencode.
OPENCODE_THEME_KEYS = {
    "primary", "secondary", "accent", "error", "warning", "success", "info",
    "text", "textMuted", "background", "backgroundPanel", "backgroundElement",
    "border", "borderActive", "borderSubtle",
    "diffAdded", "diffRemoved", "diffContext", "diffHunkHeader",
    "diffHighlightAdded", "diffHighlightRemoved", "diffAddedBg", "diffRemovedBg",
    "diffContextBg", "diffLineNumber", "diffAddedLineNumberBg", "diffRemovedLineNumberBg",
    "markdownText", "markdownHeading", "markdownLink", "markdownLinkText",
    "markdownCode", "markdownBlockQuote", "markdownEmph", "markdownStrong",
    "markdownHorizontalRule", "markdownListItem", "markdownListEnumeration",
    "markdownImage", "markdownImageText", "markdownCodeBlock",
    "syntaxComment", "syntaxKeyword", "syntaxFunction", "syntaxVariable",
    "syntaxString", "syntaxNumber", "syntaxType", "syntaxOperator", "syntaxPunctuation",
}

OMP_REQUIRED_COLORS = {
    "accent", "border", "borderAccent", "borderMuted", "success", "error", "warning",
    "muted", "dim", "text", "thinkingText",
    "selectedBg", "userMessageBg", "customMessageBg", "toolPendingBg", "toolSuccessBg",
    "toolErrorBg", "statusLineBg",
    "userMessageText", "customMessageText", "customMessageLabel", "toolTitle", "toolOutput",
    "mdHeading", "mdLink", "mdLinkUrl", "mdCode", "mdCodeBlock", "mdCodeBlockBorder",
    "mdQuote", "mdQuoteBorder", "mdHr", "mdListBullet",
    "toolDiffAdded", "toolDiffRemoved", "toolDiffContext",
    "syntaxComment", "syntaxKeyword", "syntaxFunction", "syntaxVariable", "syntaxString",
    "syntaxNumber", "syntaxType", "syntaxOperator", "syntaxPunctuation",
    "thinkingOff", "thinkingMinimal", "thinkingLow", "thinkingMedium", "thinkingHigh",
    "thinkingXhigh", "bashMode", "pythonMode",
    "statusLineSep", "statusLineModel", "statusLinePath", "statusLineGitClean",
    "statusLineGitDirty", "statusLineContext", "statusLineSpend", "statusLineStaged",
    "statusLineDirty", "statusLineUntracked", "statusLineOutput", "statusLineCost",
    "statusLineSubagents",
}
# Falls back to thinkingXhigh when absent, so omp accepts it either way.
OMP_OPTIONAL_COLORS = {"thinkingMax"}

HERMES_SKIN_COLORS = {
    "banner_border", "banner_title", "banner_accent", "banner_dim", "banner_text",
    "ui_accent", "ui_label", "ui_ok", "ui_error", "ui_warn",
    "prompt", "input_rule", "response_border",
    "status_bar_bg", "status_bar_text", "status_bar_strong", "status_bar_dim",
    "status_bar_good", "status_bar_warn", "status_bar_bad", "status_bar_critical",
    "session_label", "session_border", "voice_status_bg", "selection_bg",
    "completion_menu_bg", "completion_menu_current_bg",
    "completion_menu_meta_bg", "completion_menu_meta_current_bg",
}

# Gemini CLI reads these through createCustomTheme; ui.gradient is a colour list.
GEMINI_THEME_SECTIONS = {
    "background": {"primary", "diff"},
    "text": {"primary", "secondary", "link", "accent", "response"},
    "border": {"default", "focused"},
    "status": {"success", "warning", "error"},
    "ui": {"comment", "symbol", "gradient"},
}

AGENT_CLI_TARGETS = ("opencode-vgs", "omp-vgs", "hermes-vgs", "gemini-vgs")


def _agent_cli_config(target):
    return json.loads((helper.targets_dir() / target / "config.json").read_text())


def run_selection_hook(name, roles=None):
    """Run a theme-selection hook, refusing to do so against the real HOME.

    These hooks write the user's own agent-CLI settings files, gated only on a
    rendered theme file existing — the state of any machine that has applied a
    VGS theme. Every call goes through here so a test can only ever reach a
    temporary home.
    """
    if os.environ.get("HOME") == _HOME_AT_IMPORT:
        raise AssertionError(
            f"{name} would write the real HOME; run selection hooks inside with_temp_home")
    return helper.run_hook(name, roles or {}, {})


def _render_agent_cli_target(target, blueprint, mode_maps):
    """Every (destination, text) pair the target writes for this blueprint."""
    config = _agent_cli_config(target)
    template = (helper.targets_dir() / target / config["template"]).read_text()
    roles = helper.app_target_roles(blueprint)
    passes = helper.target_render_passes(
        config, roles, helper.expand_dest(config["destination"]), lambda: mode_maps, {}
    )
    return [(dest, helper.render_template(template, pass_roles, "agent CLI template")) for pass_roles, dest in passes]


def _assert_hex(value, message):
    if not isinstance(value, str) or not re.fullmatch(r"#[0-9a-f]{6}", value):
        raise AssertionError(f"{message}: expected an #rrggbb colour, got {value!r}")


_HERMES_SKIN_LINE = re.compile(r'^  ([a-z_]+): "(#[0-9a-f]{6})"$')


def _parse_hermes_skin(text, label):
    """The skin's scalars and colours, refusing any line the format does not
    document. VGS ships no YAML dependency, so the check reads the block it
    writes rather than adding one for the suite alone."""
    scalars, colours, in_colours = {}, {}, False
    for line in text.splitlines():
        if not line.strip():
            continue
        if line == "colors:":
            in_colours = True
            continue
        entry = _HERMES_SKIN_LINE.match(line)
        if in_colours and entry:
            colours[entry.group(1)] = entry.group(2)
            continue
        top = re.fullmatch(r"([a-z_]+): (.+)", line)
        if top and not in_colours:
            scalars[top.group(1)] = top.group(2)
            continue
        raise AssertionError(f"{label}: hermes skin line is not a documented entry: {line!r}")
    return scalars, colours


class _WriteWatchingHandle:
    """Forwards to a real file handle, calling `on_write` before the first write
    so a test can observe the temporary file at the instant content reaches it."""

    def __init__(self, handle, on_write):
        self._handle = handle
        self._on_write = on_write

    def __enter__(self):
        self._handle.__enter__()
        return self

    def __exit__(self, *exception):
        return self._handle.__exit__(*exception)

    def write(self, data):
        self._on_write()
        return self._handle.write(data)


def _observe_temp_file_modes(home, write_file_call):
    """Every (name, mode) of a .tmp. file in `home` at the instant content first
    reaches it, plus whatever write_file_call raises."""
    observed = []
    real_fdopen = os.fdopen

    def watching_fdopen(fd, *args, **kwargs):
        def record():
            for path in sorted(home.iterdir()):
                if ".tmp." in path.name:
                    observed.append((path.name, stat.S_IMODE(path.stat().st_mode)))

        return _WriteWatchingHandle(real_fdopen(fd, *args, **kwargs), record)

    with patch("os.fdopen", watching_fdopen):
        write_file_call()
    return observed


def test_write_file_gives_the_temporary_file_the_requested_mode_before_writing():
    """The temporary file carries the requested mode at the instant content
    first reaches it, under a umask that would otherwise narrow it.

    os.open's mode argument alone caps the temporary file, so content never
    lands at a wider mode than asked. What the fchmod adds is fidelity: without
    it a user's 0644 config comes back 0600 on a umask 0o077 machine, and the
    file the destination is replaced from never carried the mode requested.
    """
    def check(home):
        target = home / "config.yaml"
        target.write_text("theme: old\n")
        os.chmod(target, 0o644)
        saved_umask = os.umask(0o077)
        try:
            observed = _observe_temp_file_modes(
                home, lambda: helper.write_file(target, "theme: vgs\n", 0o644))
        finally:
            os.umask(saved_umask)
        if not observed:
            raise AssertionError("the write never passed through a temporary file")
        for name, mode in observed:
            assert_equal(mode, 0o644, f"{name} did not carry the requested mode at its first write")
        assert_equal(stat.S_IMODE(target.stat().st_mode), 0o644, "the destination mode")

    with_temp_home(check)


def test_write_file_leaves_no_temporary_behind_when_the_write_fails():
    """A write that fails part way must not leave a temporary beside the user's
    config holding partial content at the target's mode, which nothing removes."""
    def check(home):
        target = home / "config.yaml"
        target.write_text("theme: old\n")
        real_fdopen = os.fdopen

        def failing_fdopen(fd, *args, **kwargs):
            def fail():
                raise OSError(28, "No space left on device")

            return _WriteWatchingHandle(real_fdopen(fd, *args, **kwargs), fail)

        with patch("os.fdopen", failing_fdopen):
            try:
                helper.write_file(target, "theme: vgs\n", 0o600)
            except OSError as error:
                assert_equal(error.errno, 28, "the failure reaches the caller")
            else:
                raise AssertionError("a failed write reported success")
        strays = sorted(path.name for path in home.iterdir() if ".tmp." in path.name)
        assert_equal(strays, [], "a failed write left a temporary file behind")
        assert_equal(target.read_text(), "theme: old\n", "the destination is untouched")

    with_temp_home(check)


def test_write_file_reports_whether_the_destination_moved():
    """The apply tells a consumer to reload only the files whose bytes moved, so
    the write itself has to answer whether they did.

    Without the answer every apply reported every destination written, and a
    wallpaper pick reloaded the compositor, every tmux server and every editor
    for files it had just rewritten byte for byte.
    """
    def check(home):
        target = home / "config.yaml"
        assert_equal(helper.write_file(target, "theme: vgs\n"), True, "a destination that did not exist")
        before = target.stat()
        assert_equal(helper.write_file(target, "theme: vgs\n"), False, "the same bytes again")
        after = target.stat()
        # write_file replaces the destination, so an inode that survived is the
        # write not happening rather than a write that happened to be identical.
        assert_equal((after.st_ino, after.st_mtime_ns), (before.st_ino, before.st_mtime_ns),
                     "an unchanged destination was replaced anyway")
        assert_equal(helper.write_file(target, "theme: other\n"), True, "different bytes")
        assert_equal(target.read_text(), "theme: other\n", "the content of a changed destination")
        assert_equal(target.stat().st_ino != before.st_ino, True,
                     "a changed destination must be replaced")
        # The mode is applied whether or not the bytes moved. The docstring's own
        # reason for the mode is a config holding another application's API keys,
        # which a skipped write must not leave world-readable.
        os.chmod(target, 0o644)
        assert_equal(helper.write_file(target, "theme: other\n", 0o600), False,
                     "matching bytes still report no byte change")
        assert_equal(stat.S_IMODE(target.stat().st_mode), 0o600,
                     "an unchanged destination still takes the requested mode")

    with_temp_home(check)


# The fixture's targets, one per branch of the apply's render and commit. `app`
# is "shell" on each, which target_enabled admits without detection, so the set
# is the same on a machine with no themed application installed at all.
_APPLY_TARGETS = {
    # A destination plus both hook kinds: the reload hook is gated on the bytes,
    # the config hook is not.
    "alpha": {"app": "shell", "template": "alpha.txt", "destination": "~/.alpha/colors",
              "hook": "alpha-config", "reloadHook": "alpha-reload"},
    # A destination whose render never varies, so its reload hook must stop.
    "beta": {"app": "shell", "template": "beta.txt", "destination": "~/.beta/colors",
             "reloadHook": "beta-reload"},
    # No destination at all: the claude-vgs and fastfetch-vgs shape.
    "gamma": {"app": "shell", "hook": "gamma-config"},
    "delta": {"app": "shell", "template": "delta.txt", "destination": "~/.delta/colors",
              "reloadHook": "delta-reload"},
    # A curated artifact beside a generated file, the nvim-vgs shape. The only
    # entry reaching the curated and stale-curated branches.
    "epsilon": {"app": "shell", "template": "epsilon.txt", "destination": "~/.epsilon/colors",
                "curatedFile": "epsilon.conf", "curatedDestination": "~/.epsilon/curated.conf",
                "curatedMode": "additional",
                "hook": "epsilon-config", "reloadHook": "epsilon-reload"},
}
_APPLY_TEMPLATES = {"alpha": "wallpaper {wallpaper}\n", "beta": "fixed\n",
                    "delta": "wallpaper {wallpaper}\n", "epsilon": "wallpaper {wallpaper}\n"}
_EPSILON_CURATED = "curated = vgs\n"


def _seed_apply_targets(root: Path, templates=None):
    """`_APPLY_TARGETS` written out as a targets directory the apply can read."""
    for name, cfg in _APPLY_TARGETS.items():
        (root / name).mkdir(parents=True, exist_ok=True)
        (root / name / "config.json").write_text(json.dumps(cfg))
    for name, text in (templates or _APPLY_TEMPLATES).items():
        (root / name / f"{name}.txt").write_text(text)


def _apply_blueprint(home: Path, curated: bool):
    """The fixture blueprint, carrying epsilon's curated file only when asked."""
    blueprint = helper.load_theme_package("tokyo-night")
    apps = dict(blueprint.get("apps") or {})
    if curated:
        source = home / "package" / "epsilon.conf"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(_EPSILON_CURATED)
        apps["epsilon.conf"] = str(source)
    else:
        apps.pop("epsilon.conf", None)
    blueprint["apps"] = apps
    return blueprint


def _hooks_of(result):
    return sorted(entry.get("hook") for entry in result.get("hooks", []))


def _dirs_of(paths):
    return sorted(Path(path).parent.name for path in paths)


def test_theme_apply_runs_only_the_reload_hooks_whose_target_changed():
    """A reload verb is sent only when the bytes the application re-reads moved.
    Every other hook runs on every apply.

    Every apply used to send every enabled target's reload verb. A wallpaper pick
    that keeps the palette moves only the targets whose template names
    {wallpaper}, so every other verb reloaded its application for nothing. The
    inverse defect costs more: a hook that asserts wiring no destination carries,
    such as the icon-theme gsettings key or a VS Code variant installed since the
    last apply, must not be gated on bytes that never move.
    """
    def check(home):
        targets = home / "targets"
        _seed_apply_targets(targets)
        blueprint = _apply_blueprint(home, curated=False)
        with patch.object(helper, "targets_dir", lambda: targets):
            first = helper.apply_theme_obj(blueprint)
            assert_equal(_dirs_of(first["changed"]),
                         [".alpha", ".beta", ".delta", ".epsilon"],
                         "the first apply writes every target")
            assert_equal(_hooks_of(first),
                         ["alpha-config", "alpha-reload", "beta-reload", "delta-reload",
                          "epsilon-config", "epsilon-reload", "gamma-config"],
                         "the first apply runs every hook of every target")
            # kitty-vgs used to carry this order as data, hook: [kitty-config,
            # kitty-reload]. It now comes from the commit loop alone: the include
            # line has to be in kitty.conf before the SIGUSR1 that re-reads it,
            # and the apply that moved the bytes is the only one that signals.
            order = [entry["hook"] for entry in first["hooks"]]
            for target in ("alpha", "epsilon"):
                assert_equal(order.index(f"{target}-config") < order.index(f"{target}-reload"), True,
                             f"{target} must assert its wiring before it tells its consumer to re-read")

            again = helper.apply_theme_obj(blueprint)
            assert_equal(again["changed"], [], "re-applying the same theme moves no bytes")
            assert_equal(_dirs_of(again["rendered"]),
                         [".alpha", ".beta", ".delta", ".epsilon"],
                         "every destination is still rendered and confirmed")
            assert_equal(_hooks_of(again), ["alpha-config", "epsilon-config", "gamma-config"],
                         "an apply that moves nothing still asserts every target's wiring")

            # A pick that keeps the palette: only the targets naming {wallpaper}
            # move. An extracting pick re-derives the palette and moves them all.
            moved = dict(blueprint)
            moved["palette"] = {**blueprint.get("palette", {}), "wallpaper": str(home / "wall.png")}
            third = helper.apply_theme_obj(moved)
            assert_equal(_dirs_of(third["changed"]), [".alpha", ".delta", ".epsilon"],
                         "only the targets naming the wallpaper move")
            assert_equal(_hooks_of(third),
                         ["alpha-config", "alpha-reload", "delta-reload", "epsilon-config",
                          "epsilon-reload", "gamma-config"],
                         "the unchanged target's reload verb stays out of the apply")
            assert_equal((home / ".beta" / "colors").read_text(), "fixed\n",
                         "the unchanged target keeps its file")

    with_temp_home(check)


def test_theme_apply_runs_a_failed_hook_again_on_the_next_apply():
    """A hook that failed runs again when the same theme is applied again.

    Nothing records hook success, so re-applying the theme is the remedy the
    failure warning invites. Gated on the destination bytes that remedy did
    nothing: the failed hook wrote nothing, so the second apply saw identical
    bytes and never called it again.
    """
    def check(home):
        targets = home / "targets"
        _seed_apply_targets(targets)
        blueprint = _apply_blueprint(home, curated=False)
        real_hook = helper.run_hook

        def failing_epsilon(hook, roles, bp):
            if hook == "epsilon-config":
                return {"hook": hook, "ok": False, "error": "epsilon config write refused"}
            return real_hook(hook, roles, bp)

        with patch.object(helper, "targets_dir", lambda: targets):
            helper.apply_theme_obj(blueprint)
            with patch.object(helper, "run_hook", failing_epsilon):
                failed = helper.apply_theme_obj(blueprint)
            assert_equal(failed["partial"], True, "an apply with a failed hook is partial")
            assert_equal([w for w in failed["warnings"] if w.startswith("epsilon-config:")],
                         ["epsilon-config: epsilon config write refused"],
                         "the failed hook is named in its own warning")
            after = helper.apply_theme_obj(blueprint)
            assert_equal(after["changed"], [], "the failed hook moved no destination bytes")
            assert_equal("epsilon-config" in _hooks_of(after), True,
                         "the next apply of the same theme must call the failed hook again")

    with_temp_home(check)


def test_theme_apply_commits_a_curated_target_as_one_unit():
    """A curated artifact and the generated file beside it land together, and a
    curated file this theme does not ship is removed so consumers fall back to
    the generated output.

    The removal is what enables that fallback, so a stale artifact that cannot be
    removed must not also cost the generated write it exists to expose.
    """
    def shipped(home):
        targets = home / "targets"
        _seed_apply_targets(targets)
        blueprint = _apply_blueprint(home, curated=True)
        with patch.object(helper, "targets_dir", lambda: targets):
            first = helper.apply_theme_obj(blueprint)
            assert_equal(sorted(Path(path).name for path in first["changed"]
                                if Path(path).parent.name == ".epsilon"),
                         ["colors", "curated.conf"],
                         "both of the curated target's destinations are written")
            assert_equal((home / ".epsilon" / "curated.conf").read_text(), _EPSILON_CURATED,
                         "the curated file lands verbatim")
            assert_equal("epsilon.conf" in first["curated"], True,
                         "the apply reports the curated file it installed")
            assert_equal("epsilon-reload" in _hooks_of(first), True,
                         "the first apply reloads the curated target")

            again = helper.apply_theme_obj(blueprint)
            assert_equal([path for path in again["changed"] if ".epsilon" in path], [],
                         "re-applying the same theme moves neither of the target's files")
            assert_equal("epsilon-reload" in _hooks_of(again), False,
                         "an unchanged curated target sends no reload verb")

    def stale_removed(home):
        targets = home / "targets"
        _seed_apply_targets(targets)
        stale = home / ".epsilon" / "curated.conf"
        stale.parent.mkdir(parents=True, exist_ok=True)
        stale.write_text("curated = an older theme\n")
        with patch.object(helper, "targets_dir", lambda: targets):
            result = helper.apply_theme_obj(_apply_blueprint(home, curated=False))
        assert_equal(stale.exists(), False, "a curated file this theme does not ship is removed")
        assert_equal("epsilon-reload" in _hooks_of(result), True,
                     "removing the artifact reloads the consumer onto the generated output")
        assert_equal((home / ".epsilon" / "colors").is_file(), True,
                     "the generated output the consumer falls back to is written")
        # The removal alone, with the generated file already correct: nothing but
        # the unlink can move this target, and the consumer still has to be told.
        stale.write_text("curated = an older theme\n")
        with patch.object(helper, "targets_dir", lambda: targets):
            second = helper.apply_theme_obj(_apply_blueprint(home, curated=False))
        assert_equal(second["changed"], [], "the generated files were already correct")
        assert_equal(stale.exists(), False, "the artifact that reappeared is removed again")
        assert_equal("epsilon-reload" in _hooks_of(second), True,
                     "a removal with no write of its own still reloads the consumer")

    def stale_unremovable(home):
        targets = home / "targets"
        _seed_apply_targets(targets)
        # A directory at the curated path: unlink raises an OSError that is not
        # FileNotFoundError, the read-only-mount and root-owned-file case.
        (home / ".epsilon" / "curated.conf").mkdir(parents=True)
        with patch.object(helper, "targets_dir", lambda: targets):
            result = helper.apply_theme_obj(_apply_blueprint(home, curated=False))
        assert_equal([w.split(":")[0] for w in result["warnings"]], ["epsilon"],
                     "the target that kept its stale artifact is named in one warning")
        assert_equal((home / ".epsilon" / "colors").is_file(), True,
                     "a stale artifact that cannot be removed must not cost the generated write")

    def template_missing(home):
        targets = home / "targets"
        # epsilon ships its curated file but no template, so the target renders
        # nothing: the all-or-nothing guarantee the plan and commit split exists for.
        _seed_apply_targets(targets, templates={name: text for name, text
                                                in _APPLY_TEMPLATES.items() if name != "epsilon"})
        with patch.object(helper, "targets_dir", lambda: targets):
            result = helper.apply_theme_obj(_apply_blueprint(home, curated=True))
        assert_equal([w.split(":")[0] for w in result["warnings"]], ["epsilon"],
                     "the target that could not render is named in one warning")
        assert_equal((home / ".epsilon").exists(), False,
                     "a target that could not render whole writes neither destination")
        assert_equal(_hooks_of(result),
                     ["alpha-config", "alpha-reload", "beta-reload", "delta-reload", "gamma-config"],
                     "a target that never reached its commit sends neither of its hooks")
        assert_equal((home / ".alpha" / "colors").is_file(), True,
                     "every other target still lands")

    def second_write_fails(home):
        targets = home / "targets"
        _seed_apply_targets(targets)
        # The curated artifact commits first and the generated file second, so a
        # directory at the generated path fails the target half way through.
        (home / ".epsilon" / "colors").mkdir(parents=True)
        with patch.object(helper, "targets_dir", lambda: targets):
            result = helper.apply_theme_obj(_apply_blueprint(home, curated=True))
        assert_equal([w.split(":")[0] for w in result["warnings"]], ["epsilon"],
                     "the half-committed target is named in one warning")
        assert_equal((home / ".epsilon" / "curated.conf").read_text(), _EPSILON_CURATED,
                     "the write that landed stays on disk")
        assert_equal("epsilon.conf" in result["curated"], True,
                     "a half-committed target still reports the curated file it installed")
        assert_equal(_hooks_of(result),
                     ["alpha-config", "alpha-reload", "beta-reload", "delta-reload", "gamma-config"],
                     "a half-committed target sends neither its wiring hook nor its reload verb")

    for case in (shipped, stale_removed, stale_unremovable, template_missing, second_write_fails):
        with_temp_home(case)


def test_theme_apply_lands_every_other_target_when_one_target_fails():
    """One target's OSError costs that target, not the apply.

    The per-target loop had no handler, so an unwritable destination raised out
    after the shell's own palette had been written and before the applied-state
    file was: the shell showed the new theme while the next wallpaper pick
    rebuilt from the old palette. The applied state is now written before the
    hooks, so a hook cannot strand it either.
    """
    def check(home):
        targets = home / "targets"
        # delta's destination directory is a regular file, so its write fails at
        # the parent mkdir; beta's template is missing, so its render fails. One
        # failure per phase, and neither may cost the targets that work.
        _seed_apply_targets(targets, templates={name: text for name, text
                                                in _APPLY_TEMPLATES.items() if name != "beta"})
        (home / ".delta").write_text("not a directory\n")
        blueprint = _apply_blueprint(home, curated=False)
        seen_state = []
        real_hook = helper.run_hook

        def watching_hook(hook, roles, bp):
            seen_state.append((hook, (home / ".config" / "vshell" / "theme-current.json").is_file()))
            return real_hook(hook, roles, bp)

        with patch.object(helper, "targets_dir", lambda: targets), \
                patch.object(helper, "run_hook", watching_hook):
            result = helper.apply_theme_obj(blueprint)

        assert_equal(result["partial"], True, "an apply that lost a target is partial")
        named = sorted(warning.split(":")[0] for warning in result["warnings"])
        assert_equal(named, ["beta", "delta"], "each failed target is named in its own warning")
        assert_equal((home / ".alpha" / "colors").is_file(), True,
                     "a target that works must still land")
        assert_equal(_hooks_of(result),
                     ["alpha-config", "alpha-reload", "epsilon-config", "epsilon-reload",
                      "gamma-config"],
                     "neither failed target sends the reload verb it declares")
        assert_equal(sorted({state for _hook, state in seen_state}), [True],
                     "the applied state must be on disk before the first hook runs")

    with_temp_home(check)


# Every key a shipped target may declare. A key outside this set is a typo that
# declares nothing, so the apply silently drops whatever it was meant to say.
_TARGET_CONFIG_KEYS = {"app", "template", "destination", "detect", "hook", "reloadHook",
                       "curatedFile", "curatedDestination", "curatedMode", "curatedThemeFile",
                       "modes", "modeVariants"}
# The classification the apply acts on: a reload verb tells a running application
# to re-read a file its target wrote and is sent only when those bytes moved.
# Every other hook asserts wiring no destination carries and runs on every apply
# that reaches its target's commit. Moving a name between the two keys changes
# what an apply does, so the split is held here rather than left to each target's
# own config.
_RELOAD_HOOKS = {"btop-reload", "ghostty-reload", "gtk4-reload", "hypr-reload", "kitty-reload",
                 "niri-reload", "nvim-reload", "pywalfox-update", "shell-reload", "tmux-source"}
_WIRING_HOOKS = {"btop-config", "chromium-policy", "claude-theme", "codex-theme", "fastfetch-logo",
                 "foot-config", "gemini-theme-select", "gtk-settings", "hermes-skin-select",
                 "icon-theme", "kitty-config", "niri-colors-config", "obsidian-theme",
                 "omp-theme-select", "opencode-theme-select", "pi-theme-link", "qt5ct-config",
                 "qt6ct-config", "vscode-theme"}


def _declared_target_hooks():
    """Every shipped target's config, and the hook names under each key, read
    through helper.declared_hooks rather than through a second parser here."""
    configs = {}
    for path in sorted((REPO_ROOT / "themes" / "targets").glob("*/config.json")):
        configs[path.parent.name] = json.loads(path.read_text())
    wiring = {name for cfg in configs.values() for name in helper.declared_hooks(cfg, "hook")}
    reload_verbs = {name for cfg in configs.values() for name in helper.declared_hooks(cfg, "reloadHook")}
    return configs, wiring, reload_verbs


def _dispatched_hook_names():
    """Every hook name run_hook dispatches, read from its own body so a name with
    no dispatch branch cannot pass by appearing in a second list here."""
    body = next(node for node in ast.parse(HELPER_PATH.read_text()).body
                if isinstance(node, ast.FunctionDef) and node.name == "run_hook")
    return {node.comparators[0].value for node in ast.walk(body)
            if isinstance(node, ast.Compare) and isinstance(node.left, ast.Name)
            and node.left.id == "hook" and len(node.ops) == 1
            and isinstance(node.ops[0], ast.Eq)
            and isinstance(node.comparators[0], ast.Constant)
            and isinstance(node.comparators[0].value, str)}


def test_a_btop_selection_failure_is_reported_without_costing_the_rest():
    """btop-config carries its own hook result, so a failed selection makes the
    apply partial instead of hiding behind the signal's status.

    Installing ~/.config/btop/themes/vgs.theme does not select it, and before the
    split a failed selection returned inside btop-reload's result, where the apply
    read only the signal's ok and reported success.
    """
    def check(home):
        settings = home / ".config" / "vshell" / "settings.json"
        settings.parent.mkdir(parents=True, exist_ok=True)
        # The toggle answers before detect_target, so the target renders on a
        # machine with no btop installed.
        settings.write_text(json.dumps({"themeApps": {"btop": True}}))
        blueprint = helper.load_theme_package("tokyo-night")
        with patch.object(helper, "ensure_btop_color_theme", return_value=False):
            result = helper.apply_theme_obj(blueprint)
        assert_equal(result["partial"], True, "a failed selection makes the apply partial")
        assert_equal([w for w in result["warnings"] if w.startswith("btop-config:")],
                     ["btop-config: btop color_theme select failed"],
                     "the failed selection is named in its own warning")
        assert_equal("btop-reload" in _hooks_of(result), True,
                     "the target's reload verb still runs")
        assert_equal((home / ".config" / "btop" / "themes" / "vgs.theme").is_file(), True,
                     "the theme file the selection points at is still installed")
        assert_equal((home / ".config" / "vshell" / "theme.json").is_file(), True,
                     "every other target still lands")

    with_temp_home(check)


def test_every_target_config_declares_known_keys_only():
    """A key a target config misspells declares nothing and the apply drops it.

    This is the gap the classification assertion cannot see. That one compares
    derived sets against pinned sets, so a misspelled hook key reddens it only
    while the dropped name is already pinned; a name it does not yet carry passes.
    A misspelling of any other key is invisible to it entirely: a target writing
    `curatedDestinaton` sends its curated artifact to the generated output's own
    path, because that is what the apply falls back to when the key is absent.
    """
    unknown = []
    for path in sorted((REPO_ROOT / "themes" / "targets").glob("*/config.json")):
        for key in json.loads(path.read_text()):
            if key not in _TARGET_CONFIG_KEYS:
                unknown.append(f"{path.parent.name}: {key}")
    assert_equal(unknown, [], "every key a shipped target declares must be one the apply reads")


def test_every_target_hook_is_dispatched_and_classified():
    """Each declared hook reaches a dispatch branch, and sits under the key that
    matches what it does.

    A name run_hook cannot dispatch returns ok with reason 'unknown hook', so the
    apply reports success while nothing themes that application. Moving a wiring
    hook into `reloadHook` is the other direction: that target stops asserting its
    wiring on an apply that moves no bytes, which is the defect the two keys exist
    to prevent, and it costs only a wasted signal the other way round.
    """
    dispatched = _dispatched_hook_names()
    assert_equal(("btop-reload" in dispatched, "not-a-hook" in dispatched), (True, False),
                 "the dispatch reader is broken: it must find run_hook's own branches, and only those")
    configs, wiring, reload_verbs = _declared_target_hooks()
    assert_equal(len(configs) >= 30, True,
                 f"the target reader is broken: it found only {len(configs)} config(s)")
    assert_equal(sorted((wiring | reload_verbs) - dispatched), [],
                 "every hook a shipped target declares must reach a dispatch branch")
    assert_equal(sorted(reload_verbs), sorted(_RELOAD_HOOKS),
                 "the hooks declared under reloadHook, which is what an apply gates on its bytes")
    assert_equal(sorted(wiring), sorted(_WIRING_HOOKS),
                 "the hooks declared under hook, which run on every apply that reaches their target")
    assert_equal(sorted(wiring & reload_verbs), [],
                 "a hook name belongs to one key, not both")


def test_the_shipped_wallpaper_templates_are_the_ones_the_documented_invariant_names():
    """The shell reloads on a wallpaper pick because vgs-shell's template names the
    wallpaper role. Nothing else makes it reload.

    Before the gate every enabled target's hook ran regardless. Deleting the token
    from themes/targets/vgs-shell/vgs-theme.json now stops the shell reloading
    after a wallpaper change, with every synthetic case still green, so the set is
    derived from the shipped targets rather than restated here. The role is read
    through the helper's own token syntax, so a template naming it with a modifier,
    as the shell's does with `.ref`, counts the same as a bare one.
    """
    naming = []
    for config in sorted((REPO_ROOT / "themes" / "targets").glob("*/config.json")):
        template = json.loads(config.read_text()).get("template")
        if not template:
            continue
        path = config.parent / template
        if any(match.group(1) == "wallpaper" for match in helper.TEMPLATE_RE.finditer(path.read_text())):
            naming.append(str(path.relative_to(REPO_ROOT)))
    assert_equal(naming, ["themes/targets/pywalfox-vgs/colors.json",
                          "themes/targets/vgs-shell/vgs-theme.json"],
                 "the shipped templates naming the wallpaper role")


def test_selection_hooks_refuse_a_home_the_test_did_not_create():
    """The guard every selection-hook call in this file goes through.

    A selection hook is gated only on a rendered theme file existing, which is
    the state of any machine that has applied a VGS theme, so one running
    outside a temporary home rewrites the contributor's own CLI settings.
    """
    global _HOME_AT_IMPORT
    saved_marker, saved_home = _HOME_AT_IMPORT, os.environ.get("HOME")
    with tempfile.TemporaryDirectory() as tmp:
        try:
            # Both the marker and HOME point at a throwaway directory, so a
            # guard that has stopped working still reaches nothing of the user's.
            _HOME_AT_IMPORT = tmp
            os.environ["HOME"] = tmp
            try:
                run_selection_hook("hermes-skin-select")
            except AssertionError:
                return
            raise AssertionError("a selection hook ran against a home the test did not create")
        finally:
            _HOME_AT_IMPORT = saved_marker
            _restore_env("HOME", saved_home)


def test_agent_cli_themes_render_for_every_bundled_theme():
    """Each agent CLI target renders a file its CLI's documented format accepts,
    at the path that CLI reads.

    A CLI validates the whole file, so one unresolved token or one missing key
    drops the user back to that CLI's built-in theme after a VGS theme apply; a
    file at the wrong path is never read at all.
    """
    home = Path(os.path.expanduser("~"))
    expected_paths = {
        "opencode-vgs": [home / ".config/opencode/themes/vgs.json"],
        "omp-vgs": [home / ".omp/agent/themes/vgs-dark.json",
                    home / ".omp/agent/themes/vgs-light.json"],
        "hermes-vgs": [home / ".hermes/skins/vgs.yaml"],
        "gemini-vgs": [home / ".gemini/themes/vgs.json"],
    }
    names = helper.theme_package_names()
    if len(names) < 2:
        raise AssertionError("no bundled themes to render the agent CLI targets from")
    for name in names:
        blueprint = helper.load_theme_package(name)
        if not blueprint:
            raise AssertionError(f"bundled theme {name} does not load")
        mode_maps = helper.mode_variant_role_maps(blueprint)
        rendered = {
            target: _render_agent_cli_target(target, blueprint, mode_maps)
            for target in AGENT_CLI_TARGETS
        }
        for target, files in rendered.items():
            assert_equal([dest for dest, _text in files], expected_paths[target],
                         f"{name} {target} destinations")
            for dest, text in files:
                leftover = sorted({m.group(0) for m in helper.TEMPLATE_RE.finditer(text)})
                if leftover:
                    raise AssertionError(f"{name} {target} left {leftover} unresolved in {dest}")

        (_dest, opencode_text), = rendered["opencode-vgs"]
        opencode = json.loads(opencode_text)
        assert_equal(set(opencode["theme"]), OPENCODE_THEME_KEYS, f"{name} opencode theme keys")
        for key, value in opencode["theme"].items():
            assert_equal(set(value), {"dark", "light"}, f"{name} opencode {key} variants")
            for mode, colour in value.items():
                _assert_hex(colour, f"{name} opencode {key}.{mode}")

        omp_files = {Path(dest).name: json.loads(text) for dest, text in rendered["omp-vgs"]}
        for mode in ("dark", "light"):
            doc = omp_files[f"vgs-{mode}.json"]
            assert_equal(doc["name"], f"vgs-{mode}", f"{name} omp {mode} theme name")
            assert_equal(set(doc["colors"]), OMP_REQUIRED_COLORS | OMP_OPTIONAL_COLORS,
                         f"{name} omp {mode} colour tokens")
            for token, value in doc["colors"].items():
                resolved = doc["vars"].get(value, value)
                _assert_hex(resolved, f"{name} omp {mode} {token}")
        dark_text = omp_files["vgs-dark.json"]["vars"][omp_files["vgs-dark.json"]["colors"]["text"]]
        light_text = omp_files["vgs-light.json"]["vars"][omp_files["vgs-light.json"]["colors"]["text"]]
        if dark_text == light_text:
            raise AssertionError(f"{name}: the omp light file repeats the dark file's text colour")

        (_dest, hermes_text), = rendered["hermes-vgs"]
        scalars, colours = _parse_hermes_skin(hermes_text, name)
        assert_equal(scalars.get("name"), "vgs", f"{name} hermes skin name")
        assert_equal(set(colours), HERMES_SKIN_COLORS, f"{name} hermes skin colours")
        for key, value in colours.items():
            _assert_hex(value, f"{name} hermes {key}")

        (_dest, gemini_text), = rendered["gemini-vgs"]
        gemini = json.loads(gemini_text)
        assert_equal(gemini["type"], "custom", f"{name} gemini theme type")
        for section, keys in GEMINI_THEME_SECTIONS.items():
            assert_equal(set(gemini[section]), keys, f"{name} gemini {section} keys")
        for section in ("text", "border", "status"):
            for key, value in gemini[section].items():
                _assert_hex(value, f"{name} gemini {section}.{key}")
        _assert_hex(gemini["background"]["primary"], f"{name} gemini background.primary")
        for key, value in gemini["background"]["diff"].items():
            _assert_hex(value, f"{name} gemini background.diff.{key}")
        _assert_hex(gemini["ui"]["comment"], f"{name} gemini ui.comment")
        _assert_hex(gemini["ui"]["symbol"], f"{name} gemini ui.symbol")
        if not gemini["ui"]["gradient"]:
            raise AssertionError(f"{name} gemini ui.gradient is empty")
        for index, colour in enumerate(gemini["ui"]["gradient"]):
            _assert_hex(colour, f"{name} gemini ui.gradient[{index}]")


def test_agent_cli_theme_targets_reach_the_apply_path():
    """A real apply writes each target's files at its configured destination and
    runs a hook the helper recognises.

    A typo in a target's hook name returns ok with reason 'unknown hook', so the
    apply reports success while nothing selects the theme.
    """
    def check(home):
        # Before any theme file is rendered, so each hook skips and writes
        # nothing; a name the helper cannot dispatch reads differently.
        for target in AGENT_CLI_TARGETS:
            hook = _agent_cli_config(target)["hook"]
            if run_selection_hook(hook).get("reason") == "unknown hook":
                raise AssertionError(f"{target} names a hook the helper does not dispatch: {hook}")

        (home / ".omp").mkdir(parents=True, exist_ok=True)
        blueprint = helper.load_theme_package("tokyo-night")
        applied = helper.apply_theme_obj(blueprint, only_target="omp-vgs")
        written = sorted(Path(path) for path in applied["rendered"])
        assert_equal(written, [home / ".omp/agent/themes/vgs-dark.json",
                               home / ".omp/agent/themes/vgs-light.json"],
                     "the omp target's applied destinations")
        for path in written:
            json.loads(path.read_text())
        assert_equal((home / ".omp/agent/config.yml").read_text(),
                     "theme:\n  dark: vgs-dark\n  light: vgs-light\n",
                     "the omp config the apply's hook wrote")

    with_temp_home(check)


def test_agent_cli_theme_modes_destination_must_name_the_mode():
    """A modes target whose destination does not vary by mode is refused.

    Left unrefused every mode writes the same file, the last one winning, and
    the apply reports every mode rendered.
    """
    config = {"modes": ["dark", "light"], "destination": "~/.omp/agent/themes/vgs.json"}
    blueprint = helper.load_theme_package("tokyo-night")
    mode_maps = helper.mode_variant_role_maps(blueprint)
    try:
        helper.target_render_passes(config, {}, Path("/unused"), lambda: mode_maps, {})
    except ValueError as error:
        if "does not name the mode" not in str(error):
            raise AssertionError(f"the refusal does not say why: {error}")
    else:
        raise AssertionError("a modes destination that does not vary by mode was accepted")


def test_agent_cli_theme_counterpart_prefers_the_paired_theme():
    """The second mode comes from the theme's pair when one exists.

    Without this a curated light counterpart is ignored and the other file is a
    machine transform of the applied palette, so the two modes stop matching the
    pair the theme author shipped.
    """
    paired = None
    for name in helper.theme_package_names():
        blueprint = helper.load_theme_package(name)
        other = "light" if helper.blueprint_mode(blueprint) == "dark" else "dark"
        if helper.paired_blueprint(blueprint, other):
            paired = (blueprint, other)
            break
    if not paired:
        raise AssertionError("no bundled theme declares or names a counterpart to check")
    blueprint, other = paired
    pair = helper.paired_blueprint(blueprint, other)
    assert_equal(helper.mode_variant_blueprint(blueprint, other).get("name"), pair.get("name"),
                 "counterpart theme name")
    assert_equal(helper.mode_variant_blueprint(blueprint, helper.blueprint_mode(blueprint)),
                 blueprint, "the applied mode reads the applied theme itself")

    # A theme with no counterpart still renders both modes, from a transform.
    lonely = helper.load_theme_package("vantablack")
    if helper.paired_blueprint(lonely, "light"):
        raise AssertionError("the no-pair fixture gained a pair; pick another theme")
    assert_equal(helper.blueprint_mode(helper.mode_variant_blueprint(lonely, "light")), "light",
                 "transformed counterpart mode")


def test_agent_cli_theme_role_overrides_reach_both_modes():
    """The App Theming editor lists opencode's plain role names, and an override
    on one reaches the dark and the light half of its single theme file.

    Without this the editor offers opencode nothing to edit, and an override the
    user does set never reaches the file opencode reads.
    """
    blueprint = helper.load_theme_package("tokyo-night")
    view = helper.app_role_view("opencode", blueprint)
    roles = {item["role"] for item in view["roles"]}
    for role in ("accent", "background", "foreground"):
        if role not in roles:
            raise AssertionError(f"the opencode role editor omits {role}: {sorted(roles)}")
    if any(role.startswith(("dark_", "light_")) for role in roles):
        raise AssertionError(f"the editor exposes mode-prefixed tokens: {sorted(roles)}")

    config = _agent_cli_config("opencode-vgs")
    template = (helper.targets_dir() / "opencode-vgs" / config["template"]).read_text()
    overrides = {"accent": "#0f0f0f"}
    mode_maps = helper.mode_variant_role_maps(blueprint)
    base = {**helper.app_target_roles(blueprint), **overrides}
    (pass_roles, _dest), = helper.target_render_passes(
        config, base, helper.expand_dest(config["destination"]), lambda: mode_maps, overrides
    )
    theme = json.loads(helper.render_template(template, pass_roles, "agent CLI template"))["theme"]
    assert_equal(theme["primary"], {"dark": "#0f0f0f", "light": "#0f0f0f"},
                 "an accent override reaches both opencode variants")


def _write_agent_cli_theme_files(home):
    """The rendered theme files each selection hook requires before it acts, at
    the destinations the targets themselves declare."""
    for target in AGENT_CLI_TARGETS:
        config = _agent_cli_config(target)
        for mode in config.get("modes") or ["dark"]:
            destination = helper.render_template(config["destination"], {"theme_type": mode}, "destination")
            path = Path(destination.replace("~", str(home), 1))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}\n")


def _agent_cli_selections():
    """Each target's hook, read from its config.json, with the settings file
    that hook edits. The omp path is the one omp_config_path picks when neither
    config.yml nor config.yaml exists yet."""
    return (
        (_agent_cli_config("opencode-vgs")["hook"], ".config/opencode/tui.json"),
        (_agent_cli_config("gemini-vgs")["hook"], ".gemini/settings.json"),
        (_agent_cli_config("hermes-vgs")["hook"], ".hermes/config.yaml"),
        (_agent_cli_config("omp-vgs")["hook"], ".omp/agent/config.yml"),
    )


def test_agent_cli_theme_selection_writes_only_the_theme_key():
    """Each hook points its CLI at the VGS theme and leaves the rest of the
    user's settings file alone, writing nothing when the key already matches."""
    def check(home):
        _write_agent_cli_theme_files(home)
        (home / ".gemini").mkdir(parents=True, exist_ok=True)
        (home / ".gemini" / "settings.json").write_text(json.dumps(
            {"ui": {"hideBanner": True}, "model": "gemini-3-pro"}, indent=2) + "\n")
        (home / ".hermes").mkdir(parents=True, exist_ok=True)
        (home / ".hermes" / "config.yaml").write_text(
            "# hermes\nmodel: hermes-4\ndisplay:\n  skin: default\n  markdown: true\n")
        (home / ".omp" / "agent").mkdir(parents=True, exist_ok=True)
        (home / ".omp" / "agent" / "config.yml").write_text("theme:\n  dark: titanium\n")

        for hook, relative in _agent_cli_selections():
            result = run_selection_hook(hook, {"theme_type": "dark"})
            assert_equal(result.get("ok"), True, f"{hook} result")
            assert_equal(result.get("changed"), True, f"{hook} first run writes")
            assert_equal(run_selection_hook(hook, {"theme_type": "dark"}).get("changed"), False,
                         f"{hook} rewrites an already-selected theme")
            if not (home / relative).exists():
                raise AssertionError(f"{hook} wrote no {relative}")

        assert_equal(json.loads((home / ".config/opencode/tui.json").read_text()),
                     {"theme": "vgs"}, "opencode tui.json")
        gemini = json.loads((home / ".gemini/settings.json").read_text())
        assert_equal(gemini["ui"]["theme"], str(home / ".gemini/themes/vgs.json"),
                     "gemini ui.theme path")
        assert_equal(gemini["ui"]["hideBanner"], True, "gemini keeps its other ui settings")
        assert_equal(gemini["model"], "gemini-3-pro", "gemini keeps its other settings")
        assert_equal((home / ".hermes/config.yaml").read_text(),
                     "# hermes\nmodel: hermes-4\ndisplay:\n  skin: vgs\n  markdown: true\n",
                     "the hermes edit changes only display.skin")
        assert_equal((home / ".omp/agent/config.yml").read_text(),
                     "theme:\n  dark: vgs-dark\n  light: vgs-light\n",
                     "the omp edit sets both theme keys")

    with_temp_home(check)


def test_agent_cli_theme_selection_reads_the_users_own_spelling_of_the_value():
    """A value the user wrote as `vgs # pinned` or `"vgs"` is already selected.

    Read literally, every theme apply rewrites their config and reports a
    change, churning a file that holds provider credentials.
    """
    def check(home):
        _write_agent_cli_theme_files(home)
        config = home / ".hermes" / "config.yaml"
        config.parent.mkdir(parents=True, exist_ok=True)
        for spelling in ('vgs # pinned', '"vgs"', "'vgs'"):
            original = f"display:\n  skin: {spelling}\n  markdown: true\n"
            config.write_text(original)
            assert_equal(run_selection_hook("hermes-skin-select").get("changed"), False,
                         f"skin: {spelling} is already the VGS skin")
            assert_equal(config.read_text(), original, f"skin: {spelling} is left byte for byte")

    with_temp_home(check)


def test_agent_cli_theme_selection_adds_an_absent_block_without_reflowing_the_file():
    """A config VGS has never themed carries no display: or theme: block. Adding
    one must keep every other line, blank lines included, byte for byte."""
    original = "# hermes\n\nmodel: hermes-4\n\ntools:\n  web: true\n"

    def check(home):
        _write_agent_cli_theme_files(home)
        config = home / ".hermes" / "config.yaml"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(original)
        assert_equal(run_selection_hook("hermes-skin-select").get("changed"), True,
                     "the first run adds the display block")
        assert_equal(config.read_text(), original + "display:\n  skin: vgs\n",
                     "the appended block keeps the file's own blank lines")
        assert_equal(run_selection_hook("hermes-skin-select").get("changed"), False,
                     "a second run rewrites nothing")

    with_temp_home(check)


def test_agent_cli_theme_selection_ignores_a_deeper_key_of_the_same_name():
    """Only an entry at the block's own indent is the theme key.

    Matching any indentation rewrites an unrelated nested setting, never sets
    the real one, and still reports success.
    """
    def check(home):
        _write_agent_cli_theme_files(home)
        config = home / ".hermes" / "config.yaml"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text("display:\n  panes:\n    skin: fancy\n  markdown: true\n")
        assert_equal(run_selection_hook("hermes-skin-select").get("ok"), True, "hook result")
        assert_equal(config.read_text(),
                     "display:\n  panes:\n    skin: fancy\n  markdown: true\n  skin: vgs\n",
                     "the nested skin is untouched and display.skin is added")

    with_temp_home(check)


# Every settings file a theme apply selects a theme in, with the content its
# writer can parse. One row per writer and caller, so the three file rules below
# cannot be pinned at a point that does not reach the writer they describe:
# opencode, gemini and claude reach set_json_config_key, hermes and omp reach
# set_yaml_config_key, and codex reaches set_codex_tui_theme.
SELECTION_CONFIGS = (
    ("opencode-theme-select", ".config/opencode/tui.json", '{"theme": "ansi"}\n'),
    ("gemini-theme-select", ".gemini/settings.json", '{"ui": {"theme": "ansi"}}\n'),
    ("claude-theme", ".claude/settings.json", '{"theme": "dark-ansi"}\n'),
    ("hermes-skin-select", ".hermes/config.yaml", "display:\n  skin: default\n"),
    ("omp-theme-select", ".omp/agent/config.yml", "theme:\n  dark: titanium\n"),
    ("codex-theme", ".codex/config.toml", '[tui]\ntheme = "ansi"\n'),
)
# The mode a settings file VGS creates must land at, pinned here rather than read
# from the helper: a constant the helper owns moves with the code it is meant to
# hold, so widening it would pass its own assertion.
CREATED_CONFIG_MODE = 0o600
# A mode no umask yields on a fresh file, and not the created mode, so a writer
# that always wrote the created default could not pass the row below that keeps an
# existing file's own mode.
EXISTING_CONFIG_MODE = 0o640


def _selection_wrote(result):
    """Whether a selection hook reports that it wrote its settings file.

    Three result shapes reach here: the hooks that only set a theme key pass the
    writer's own `changed` through, the codex hook omits the key when it wrote and
    sets `unchanged` when it had nothing to do, and the claude hook reports
    `unchanged` either way. This is the one place that reads any of them.
    """
    if "changed" in result:
        return bool(result["changed"])
    return bool(result.get("ok")) and not result.get("unchanged")


def _selection_home(home, relative):
    """A home ready for one selection hook, with its settings file absent."""
    _write_agent_cli_theme_files(home)
    for directory in (".claude", ".codex"):
        (home / directory).mkdir(parents=True, exist_ok=True)
    path = home / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def test_agent_cli_theme_selection_creates_its_config_owner_only():
    """These files hold provider credentials, and a user may add an API key or a
    key helper to one VGS brought into existence, so a created file must not start
    at the process umask."""
    for hook, relative, _content in SELECTION_CONFIGS:
        def check(home, hook=hook, relative=relative):
            path = _selection_home(home, relative)
            previous = os.umask(0o022)
            try:
                assert_equal(_selection_wrote(run_selection_hook(hook)), True, f"{hook} write")
            finally:
                os.umask(previous)
            assert_equal(stat.S_IMODE(path.stat().st_mode), CREATED_CONFIG_MODE,
                         f"{hook} creates {relative} owner-only")

        with_temp_home(check)


def test_agent_cli_theme_selection_keeps_the_settings_file_permissions():
    """A mode the user chose is theirs. A theme apply must neither widen a private
    config nor narrow one they left readable."""
    for hook, relative, content in SELECTION_CONFIGS:
        def check(home, hook=hook, relative=relative, content=content):
            path = _selection_home(home, relative)
            path.write_text(content)
            os.chmod(path, EXISTING_CONFIG_MODE)
            assert_equal(_selection_wrote(run_selection_hook(hook)), True, f"{hook} write")
            assert_equal(stat.S_IMODE(path.stat().st_mode), EXISTING_CONFIG_MODE,
                         f"{hook} keeps the mode of an existing {relative}")

        with_temp_home(check)


def test_agent_cli_theme_selection_writes_through_a_symlinked_config():
    """These files are commonly symlinked into a dotfiles checkout, and a user can
    point several account directories at one of them, as three Claude Code accounts
    do. write_file replaces the name it is given, so without resolving first the
    selection would leave a regular file there, strand the other names and take the
    live config out of the user's version control."""
    for hook, relative, content in SELECTION_CONFIGS:
        def check(home, hook=hook, relative=relative, content=content):
            link = _selection_home(home, relative)
            shared = home / "dotfiles" / Path(relative).name
            shared.parent.mkdir(parents=True, exist_ok=True)
            shared.write_text(content)
            os.chmod(shared, EXISTING_CONFIG_MODE)
            link.symlink_to(shared)
            assert_equal(_selection_wrote(run_selection_hook(hook)), True, f"{hook} write")
            assert_equal(link.is_symlink(), True, f"{relative} is still a symlink")
            assert_equal(link.resolve(), shared.resolve(), f"{relative} still points at the target")
            assert_equal(shared.read_text() != content, True,
                         f"{hook} wrote the theme into the link target")
            assert_equal(stat.S_IMODE(shared.stat().st_mode), EXISTING_CONFIG_MODE,
                         f"{hook} keeps the link target's mode")

        with_temp_home(check)


def test_agent_cli_theme_selection_edits_the_omp_config_that_omp_reads():
    """oh-my-pi loads the first of config.yml and config.yaml that exists.

    Creating config.yml beside an existing config.yaml would hide the user's
    whole omp configuration behind a file holding only a theme block.
    """
    def check(home):
        _write_agent_cli_theme_files(home)
        agent = home / ".omp" / "agent"
        agent.mkdir(parents=True, exist_ok=True)
        (agent / "config.yaml").write_text("model: sonnet\n")
        assert_equal(run_selection_hook("omp-theme-select").get("path"),
                     str(agent / "config.yaml"), "the hook edits the config omp reads")
        if (agent / "config.yml").exists():
            raise AssertionError("the hook created config.yml and hid the user's config.yaml")
        assert_equal((agent / "config.yaml").read_text(),
                     "model: sonnet\ntheme:\n  dark: vgs-dark\n  light: vgs-light\n",
                     "the theme block joins the existing config")

    with_temp_home(check)


def test_agent_cli_theme_selection_waits_for_the_opencode_migration():
    """opencode moves theme and keybinds out of opencode.json into tui.json once,
    and skips that migration when tui.json already exists.

    Creating tui.json first would cancel it and strand the user's keybinds.
    """
    def check(home):
        _write_agent_cli_theme_files(home)
        config = home / ".config" / "opencode" / "opencode.json"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps({"keybinds": {"leader": "ctrl+x"}}) + "\n")
        result = run_selection_hook("opencode-theme-select")
        assert_equal(result.get("skipped"), True, "the hook waits for the migration")
        if (home / ".config/opencode/tui.json").exists():
            raise AssertionError("the hook created tui.json and cancelled opencode's migration")

        # A config the probe cannot read is pending too: creating tui.json beside
        # it cancels the migration once the user repairs the JSON.
        config.write_text('{"keybinds": {"leader": ')
        result = run_selection_hook("opencode-theme-select")
        assert_equal(result.get("skipped"), True, "an unreadable config is not a clear signal")
        if str(config) not in str(result.get("reason") or ""):
            raise AssertionError(f"the skip does not name the file: {result.get('reason')!r}")
        if (home / ".config/opencode/tui.json").exists():
            raise AssertionError("the hook created tui.json from a config it could not read")

        # Each of opencode's other two migration triggers, alone.
        for pending in ({"theme": "tokyonight"}, {"tui": {"scroll_speed": 3}}):
            config.write_text(json.dumps(pending) + "\n")
            assert_equal(run_selection_hook("opencode-theme-select").get("skipped"), True,
                         f"{sorted(pending)} is a key opencode has yet to migrate")
            if (home / ".config/opencode/tui.json").exists():
                raise AssertionError(
                    f"the hook created tui.json with {sorted(pending)} still to migrate")

        # opencode migrates a tui object only for these three settings, so a tui
        # holding anything else leaves nothing pending and the theme is selected.
        config.write_text(json.dumps({"tui": {"foo": 1}}) + "\n")
        assert_equal(run_selection_hook("opencode-theme-select").get("changed"), True,
                     "a tui object opencode would not migrate must not block selection")
        assert_equal(json.loads((home / ".config/opencode/tui.json").read_text()),
                     {"theme": "vgs"}, "opencode tui.json")
        (home / ".config/opencode/tui.json").unlink()

        # Once opencode has migrated, the next apply selects the theme.
        (home / ".config/opencode/tui.json").write_text('{"keybinds": {"leader": "ctrl+x"}}\n')
        assert_equal(run_selection_hook("opencode-theme-select").get("changed"), True,
                     "the hook selects the theme once tui.json exists")
        assert_equal(json.loads((home / ".config/opencode/tui.json").read_text()),
                     {"keybinds": {"leader": "ctrl+x"}, "theme": "vgs"},
                     "the migrated keybinds survive")

    with_temp_home(check)


def test_agent_cli_theme_selection_acts_only_on_a_rendered_theme():
    """With no theme file rendered — the CLI's target toggled off — each hook
    skips instead of naming a theme its CLI cannot load, and creates nothing."""
    def check(home):
        for hook, relative in _agent_cli_selections():
            result = run_selection_hook(hook, {"theme_type": "dark"})
            assert_equal(result.get("ok"), True, f"{hook} result")
            assert_equal(result.get("skipped"), True, f"{hook} skips without a rendered theme")
            if (home / relative).exists():
                raise AssertionError(f"{hook} created {relative} with no theme to select")

    with_temp_home(check)


def test_agent_cli_theme_selection_refuses_a_config_shape_it_cannot_edit():
    """A flow-style or scalar value where the theme block belongs is reported,
    not overwritten: the writers must never rewrite a user's config into a shape
    their CLI does not expect."""
    def check(home):
        _write_agent_cli_theme_files(home)
        config = home / ".omp" / "agent" / "config.yml"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text("theme: titanium\n")
        result = run_selection_hook("omp-theme-select", {"theme_type": "dark"})
        assert_equal(result.get("ok"), False, "omp refuses a flat theme scalar")
        assert_equal(config.read_text(), "theme: titanium\n", "the refused config is unchanged")
        if "theme" not in str(result.get("error") or ""):
            raise AssertionError(f"the refusal does not name the key: {result.get('error')!r}")

        settings = home / ".gemini" / "settings.json"
        settings.parent.mkdir(parents=True, exist_ok=True)
        settings.write_text('{"ui": "compact"}\n')
        result = run_selection_hook("gemini-theme-select", {"theme_type": "dark"})
        assert_equal(result.get("ok"), False, "gemini refuses a non-object ui section")
        assert_equal(settings.read_text(), '{"ui": "compact"}\n', "the refused settings are unchanged")
        if "ui" not in str(result.get("error") or ""):
            raise AssertionError(f"the refusal does not name the section: {result.get('error')!r}")

    with_temp_home(check)


def test_restyle_integer_sweeps():
    # The UI can publish every integer brightness value, so test the full range.
    theme_names = (
        "coppernight", "tokyo-night", "catppuccin-latte", "gruvbox", "arc-raiders",
    )
    sweeps = {}
    for name in theme_names:
        theme_dir = REPO_ROOT / "themes" / name
        meta = json.loads((theme_dir / "theme.json").read_text())
        base = helper.parse_colors_toml(theme_dir / "colors.toml")
        base["mode"] = meta["mode"]
        samples = []
        for brightness in range(-100, 101):
            adjusted = helper.apply_adjustments(base, {"brightness": brightness})
            blueprint = helper.palette_from_colors_map(
                adjusted,
                name=name,
                source=meta.get("source", "curated"),
            )
            blueprint["adjustments"] = helper.normalize_adjustments({"brightness": brightness})
            samples.append((adjusted, helper.target_roles(blueprint)))
        sweeps[name] = samples

        base_keys = [
            key for key, value in base.items()
            if isinstance(value, str) and helper.HEX_RE.match(value.strip())
        ]
        for key in base_keys:
            tones = [_oklch(adjusted[key]) for adjusted, _roles in samples]
            for offset, (left, right) in enumerate(zip(tones, tones[1:]), start=-100):
                if right[0] + 0.002 < left[0]:
                    raise AssertionError(
                        f"{name} {key} lightness reversed at {offset}->{offset + 1}: "
                        f"{left[0]:.4f}->{right[0]:.4f}"
                    )
                if min(left[1], right[1]) > 0.025 and _hue_distance(left[2], right[2]) > 6.0:
                    raise AssertionError(
                        f"{name} {key} hue jumped at {offset}->{offset + 1}: "
                        f"{left[2]:.1f}->{right[2]:.1f}"
                    )

        for index, ((_adjusted_a, roles_a), (_adjusted_b, roles_b)) in enumerate(
            zip(samples, samples[1:]), start=-100
        ):
            for role, value_a in roles_a.items():
                value_b = roles_b.get(role)
                if not (
                    isinstance(value_a, str) and isinstance(value_b, str)
                    and helper.HEX_RE.match(value_a) and helper.HEX_RE.match(value_b)
                ):
                    continue
                delta = _oklab_delta(value_a, value_b)
                if delta > 0.075:
                    raise AssertionError(
                        f"{name} {role} jumped at {index}->{index + 1}: "
                        f"{value_a}->{value_b} (OKLab delta {delta:.4f})"
                    )
                if {value_a, value_b} == {"#000000", "#ffffff"}:
                    raise AssertionError(
                        f"{name} {role} flipped black/white polarity at {index}->{index + 1}"
                    )

        for _adjusted, roles in samples:
            bg = roles["background"]
            fg = roles["foreground"]
            if helper.contrast_ratio(fg, bg) < 6.9:
                raise AssertionError(f"{name} foreground lost readable contrast")
            for role in ("accent", "error", "warning", "success", "info"):
                if helper.contrast_ratio(roles[role], bg) < 4.45:
                    raise AssertionError(f"{name} {role} lost readable contrast")
            bg_l = _oklch(bg)[0]
            ladder = [
                _oklch(roles[key])[0] for key in (
                    "surfaceContainerLowest", "surfaceContainerLow", "surfaceContainer",
                    "surfaceContainerHigh", "surfaceContainerHighest",
                )
            ]
            if meta["mode"] == "dark" and any(tone + 0.003 < bg_l for tone in ladder):
                raise AssertionError(f"{name} dark surface ladder crossed below its background")
            if meta["mode"] == "light" and any(tone - 0.003 > bg_l for tone in ladder):
                raise AssertionError(f"{name} light surface ladder crossed above its background")

    fault_pairs = {
        "coppernight surface -49/-48": ("coppernight", -49, ("surfaceContainerHighest",)),
        "tokyo-night surface -73/-72": ("tokyo-night", -73, ("surfaceContainerHighest",)),
        "gruvbox semantics +90/+91": (
            "gruvbox", 90, ("error", "warning", "success", "info"),
        ),
        "catppuccin-latte surfaces +50/+51": (
            "catppuccin-latte", 50,
            ("surfaceContainerLow", "surfaceContainer", "surfaceContainerHighest"),
        ),
        "arc-raiders accent -1/0": ("arc-raiders", -1, ("accent",)),
        "arc-raiders accent 0/+1": ("arc-raiders", 0, ("accent",)),
    }
    for label, (name, left_amount, roles) in fault_pairs.items():
        left = sweeps[name][left_amount + 100][1]
        right = sweeps[name][left_amount + 101][1]
        for role in roles:
            if _oklab_delta(left[role], right[role]) > 0.075:
                raise AssertionError(
                    f"{label} regressed for {role}: {left[role]}->{right[role]}"
                )

    # Dark and light curated palettes cover both fixed-polarity paths.
    axis_ranges = {
        "vibrancy": range(-100, 101),
        "contrast": range(-100, 101),
        "temperature": range(-100, 101),
        "hue": range(-180, 181),
    }
    for name in ("coppernight", "catppuccin-latte"):
        theme_dir = REPO_ROOT / "themes" / name
        meta = json.loads((theme_dir / "theme.json").read_text())
        base = helper.parse_colors_toml(theme_dir / "colors.toml")
        base["mode"] = meta["mode"]
        for axis, amounts in axis_ranges.items():
            previous = None
            previous_amount = None
            for amount in amounts:
                adjusted = helper.apply_adjustments(base, {axis: amount})
                blueprint = helper.palette_from_colors_map(
                    adjusted,
                    name=name,
                    source=meta.get("source", "curated"),
                )
                blueprint["adjustments"] = helper.normalize_adjustments({axis: amount})
                roles = helper.target_roles(blueprint)
                if previous is not None:
                    for role, left in previous.items():
                        right = roles.get(role)
                        if not (
                            isinstance(left, str) and isinstance(right, str)
                            and helper.HEX_RE.match(left) and helper.HEX_RE.match(right)
                        ):
                            continue
                        delta = _oklab_delta(left, right)
                        if delta > 0.10:
                            raise AssertionError(
                                f"{name} {axis} {role} jumped at "
                                f"{previous_amount}->{amount}: {left}->{right} "
                                f"(OKLab delta {delta:.4f})"
                            )
                        if {left, right} == {"#000000", "#ffffff"}:
                            raise AssertionError(
                                f"{name} {axis} {role} flipped polarity at "
                                f"{previous_amount}->{amount}"
                            )
                bg = roles["background"]
                if helper.contrast_ratio(roles["foreground"], bg) < 6.9:
                    raise AssertionError(f"{name} {axis} foreground lost contrast at {amount}")
                for role in ("accent", "error", "warning", "success", "info"):
                    if helper.contrast_ratio(roles[role], bg) < 4.45:
                        raise AssertionError(f"{name} {axis} {role} lost contrast at {amount}")
                previous = roles
                previous_amount = amount


def test_fastfetch_portable_seed_and_logo_fallback():
    original_pil_image = helper._wp_thumbs.pil_image
    original_which = helper.shutil.which
    original_run = helper.run
    old_xdg_home = os.environ.get("XDG_CONFIG_HOME")
    old_xdg_dirs = os.environ.get("XDG_CONFIG_DIRS")

    def run_case(temp_home):
        xdg_home = temp_home / ".config"
        os.environ["XDG_CONFIG_HOME"] = str(xdg_home)
        os.environ["XDG_CONFIG_DIRS"] = str(temp_home / "system-config")
        wallpaper = temp_home / "wallpaper.png"
        wallpaper.write_bytes(b"image-bytes-fastfetch-can-decode")

        helper._wp_thumbs.pil_image = lambda: None
        helper.shutil.which = lambda _name: None
        result = helper.apply_fastfetch_logo_hook({"wallpaper": str(wallpaper)})
        config = xdg_home / "fastfetch" / "config.jsonc"
        logo = temp_home / ".config" / "vshell" / "generated" / "fastfetch" / "logo.jpg"
        assert_equal(result["configSeeded"], True, "Fastfetch first-run config seed")
        assert_equal(logo.read_bytes(), wallpaper.read_bytes(), "converter-free Fastfetch logo fallback")
        seed_text = config.read_text()
        if '"type": "auto"' not in seed_text or '"recache": true' not in seed_text:
            raise AssertionError("Fastfetch seed must auto-detect the terminal protocol and refresh its image cache")
        if "kitty-icat" in seed_text:
            raise AssertionError("portable Fastfetch seed must not require kitten")
        cached = helper.apply_fastfetch_logo_hook({"wallpaper": str(wallpaper)})
        assert_equal(cached.get("cached"), True, "unchanged Fastfetch wallpaper is not regenerated")

        config.write_bytes(b'{"logo":{"type":"none"}}\n')
        preserved = helper.apply_fastfetch_logo_hook({"wallpaper": ""})
        assert_equal(config.read_bytes(), b'{"logo":{"type":"none"}}\n', "existing Fastfetch config preservation")
        assert_equal(preserved["configSeeded"], False, "existing Fastfetch config is not reseeded")

        config.unlink()
        system_config = temp_home / "system-config" / "fastfetch" / "config.json"
        system_config.parent.mkdir(parents=True)
        system_config.write_text('{"logo":{"type":"none"}}\n')
        alternate = helper.apply_fastfetch_logo_hook({"wallpaper": ""})
        assert_equal(alternate["config"], str(system_config), "effective Fastfetch config discovery")
        if config.exists():
            raise AssertionError("VGS must not shadow an effective Fastfetch config")

        system_config.unlink()
        logo.write_bytes(b"previous-logo")
        (logo.parent / "source.json").unlink(missing_ok=True)
        helper.shutil.which = lambda name: "/usr/bin/magick" if name == "magick" else None
        helper.run = lambda argv, **_kwargs: subprocess.CompletedProcess(argv, 1, "", "conversion failed")
        failed = helper.apply_fastfetch_logo_hook({"wallpaper": str(wallpaper)})
        assert_equal(failed["skipped"], True, "failed Fastfetch conversion is optional")
        assert_equal(logo.read_bytes(), b"previous-logo", "failed conversion preserves prior Fastfetch logo")
        if list(logo.parent.glob(".logo.*.jpg")):
            raise AssertionError("failed Fastfetch conversion must remove its temporary file")
        logo.unlink()
        guaranteed = helper.apply_fastfetch_logo_hook({"wallpaper": str(wallpaper)})
        shipped_logo = REPO_ROOT / "config" / "vshell" / "branding" / "fastfetch-logo.jpg"
        assert_equal(guaranteed.get("fallbackWallpaper"), True,
                     "failed first Fastfetch conversion uses the shipped fallback")
        assert_equal(logo.read_bytes(), shipped_logo.read_bytes(),
                     "new Fastfetch config always has a decodable fallback logo")

    try:
        with_temp_home(run_case)
    finally:
        helper._wp_thumbs.pil_image = original_pil_image
        helper.shutil.which = original_which
        helper.run = original_run
        if old_xdg_home is None:
            os.environ.pop("XDG_CONFIG_HOME", None)
        else:
            os.environ["XDG_CONFIG_HOME"] = old_xdg_home
        if old_xdg_dirs is None:
            os.environ.pop("XDG_CONFIG_DIRS", None)
        else:
            os.environ["XDG_CONFIG_DIRS"] = old_xdg_dirs


def test_compositor_dependency_selection():
    original_load = helper.load_deps
    original_detect = helper.detect_compositor
    original_exists = helper.command_exists
    helper.load_deps = lambda: {
        "version": 1,
        "features": {
            "capture": {
                "commands": ["common"],
                "compositorCommands": {
                    "hyprland": ["hypr-only"],
                    "niri": ["niri-only"],
                },
            },
        },
    }
    try:
        helper.command_exists = lambda command: command in {"common", "niri-only"}
        helper.detect_compositor = lambda: {"compositor": "hyprland", "source": "test"}
        hypr = helper.feature_status()
        assert_equal(hypr["features"]["capture"]["available"], False,
                     "Hyprland dependencies cannot be satisfied by installed Niri tools")
        assert_equal(hypr["features"]["capture"]["missing"], ["hypr-only"],
                     "Hyprland missing dependency")

        helper.detect_compositor = lambda: {"compositor": "niri", "source": "test"}
        niri = helper.feature_status()
        assert_equal(niri["features"]["capture"]["available"], True,
                     "Niri selects its own dependency branch")

        helper.detect_compositor = lambda: {"compositor": "unknown", "source": "test"}
        unknown = helper.feature_status()
        assert_equal(unknown["features"]["capture"]["available"], True,
                     "No active session accepts any complete compositor branch")
    finally:
        helper.load_deps = original_load
        helper.detect_compositor = original_detect
        helper.command_exists = original_exists


def test_capability_probe_reporting():
    """Check capability probe results for unusable, absent and unlaunchable commands."""
    original_load = helper.load_deps
    original_detect = helper.detect_compositor
    original_exists = helper.command_exists
    original_probes = helper.CAPABILITY_PROBES
    original_cache = helper._CAPABILITY_PROBE_CACHE
    helper.load_deps = lambda: {
        "version": 1,
        "features": {"base": {"commands": ["probed", "plain"]}},
    }
    helper.detect_compositor = lambda: {"compositor": "hyprland", "source": "test"}
    try:
        helper.command_exists = lambda command: True
        helper.CAPABILITY_PROBES = {
            "probed": {"argv": ["false"], "requirement": "needs the thing"},
        }
        helper._CAPABILITY_PROBE_CACHE = {}
        base = helper.feature_status()["features"]["base"]
        assert_equal(base["available"], False,
                     "an installed-but-unusable command makes its feature unavailable")
        assert_equal(base["unusable"],
                     ["probed (installed but unusable: needs the thing)"],
                     "unusable commands are broken out from missing ones")
        assert_equal(base["unusable"][0] in base["missing"], True,
                     "unusable commands also reach the existing `missing` consumers")
        assert_equal("plain" in base["missing"], False,
                     "a command with no probe is judged on presence alone")

        helper.CAPABILITY_PROBES = {
            "probed": {"argv": ["true"], "requirement": "needs the thing"},
        }
        helper._CAPABILITY_PROBE_CACHE = {}
        assert_equal(helper.feature_status()["features"]["base"]["missing"], [],
                     "a satisfied probe adds nothing")

        # A missing command must not also be reported as needing an upgrade.
        helper.command_exists = lambda command: command != "probed"
        helper.CAPABILITY_PROBES = {
            "probed": {"argv": ["false"], "requirement": "needs the thing"},
        }
        helper._CAPABILITY_PROBE_CACHE = {}
        base = helper.feature_status()["features"]["base"]
        assert_equal(base["missing"], ["probed"],
                     "an absent command is reported as missing, not as unusable")
        assert_equal(base["unusable"], [], "an absent command is not probed")

        # The helper treats an unlaunchable capability probe as satisfied.
        helper.command_exists = lambda command: True
        helper.CAPABILITY_PROBES = {
            "probed": {"argv": ["/nonexistent/probe/binary"], "requirement": "needs the thing"},
        }
        helper._CAPABILITY_PROBE_CACHE = {}
        assert_equal(helper.feature_status()["features"]["base"]["unusable"], [],
                     "a probe that cannot run is not evidence of an unusable command")

        helper.CAPABILITY_PROBES = original_probes
        helper._CAPABILITY_PROBE_CACHE = {}
        if helper.command_exists("jq"):
            assert_equal(helper.capability_probe_ok("jq"), True,
                         "the installed jq satisfies the shipped capability probe")
    finally:
        helper.load_deps = original_load
        helper.detect_compositor = original_detect
        helper.command_exists = original_exists
        helper.CAPABILITY_PROBES = original_probes
        helper._CAPABILITY_PROBE_CACHE = original_cache


def test_compositor_detection_fallback():
    original_owner = helper._wayland_socket_owner
    original_exists = helper.command_exists
    original_run = helper.run
    old_niri = os.environ.get("NIRI_SOCKET")
    old_hypr = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    os.environ["NIRI_SOCKET"] = "/run/user/1000/stale-niri.sock"
    os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = "live-hypr"
    helper._wayland_socket_owner = lambda: ""
    helper.command_exists = lambda command: command in {"niri", "hyprctl"}
    helper.run = lambda argv, **_kwargs: subprocess.CompletedProcess(
        argv, 1 if argv[0] == "niri" else 0, "", "stale" if argv[0] == "niri" else ""
    )
    try:
        assert_equal(helper.detect_compositor()["compositor"], "hyprland",
                     "stale Niri IPC falls through to live Hyprland IPC")
    finally:
        helper._wayland_socket_owner = original_owner
        helper.command_exists = original_exists
        helper.run = original_run
        if old_niri is None:
            os.environ.pop("NIRI_SOCKET", None)
        else:
            os.environ["NIRI_SOCKET"] = old_niri
        if old_hypr is None:
            os.environ.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        else:
            os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = old_hypr


def test_gtk_settings_merge_and_reset():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "settings.ini"
        path.write_text("[Settings]\ngtk-theme-name=Adwaita\n\n[Other]\nkey=value\n")
        changed = helper._merge_gtk_settings(path, {
            "gtk-xft-antialias": "1",
            "gtk-xft-hinting": "1",
        })
        assert_equal(changed, True, "GTK merge should write")
        text = path.read_text()
        if "gtk-theme-name=Adwaita" not in text or "[Other]" not in text:
            raise AssertionError("GTK merge should preserve unrelated settings")
        if helper.GTK_SETTINGS_BEGIN not in text or "gtk-xft-antialias=1" not in text:
            raise AssertionError("GTK merge should insert managed block")

        changed = helper._merge_gtk_settings(path, None)
        assert_equal(changed, True, "GTK reset should write")
        text = path.read_text()
        if helper.GTK_SETTINGS_BEGIN in text or "gtk-xft-antialias=1" in text:
            raise AssertionError("GTK reset should remove managed block")
        if "gtk-theme-name=Adwaita" not in text or "[Other]" not in text:
            raise AssertionError("GTK reset should preserve unmanaged settings")


def test_apply_system_fonts_temp_home():
    original_env = helper.system_font_env
    original_gsettings = helper._gsettings_set_font_rendering
    original_which = helper.shutil.which
    helper.system_font_env = lambda: {
        "isWayland": True,
        "isX11": False,
        "sessionType": "wayland",
        "gsettingsKeys": ["font-antialiasing", "font-hinting", "font-rgba-order"],
    }
    helper._gsettings_set_font_rendering = lambda config, reset=False: {
        "mechanism": "gsettings",
        "ok": True,
        "reset": reset,
    }
    helper.shutil.which = lambda name: None

    def run_case(home):
        settings_dir = home / ".config" / "vshell"
        settings_dir.mkdir(parents=True)
        (settings_dir / "settings.json").write_text(json.dumps({
            "systemFontsManaged": True,
            "systemFontInterfaceFamily": "Example & Sans",
            "systemFontMonoFamily": "Example Mono",
            "systemFontSize": 13,
            "systemFontInterfaceHinting": "medium",
            "systemFontInterfaceSubpixel": "rgb",
            "systemFontMonoAntialias": False,
        }))

        applied = helper.apply_system_fonts(reset=False)
        assert_equal(applied["partial"], False, "font apply should not warn")
        fc_path = home / ".config" / "fontconfig" / "conf.d" / "60-vgs-fonts.conf"
        gtk3_path = home / ".config" / "gtk-3.0" / "settings.ini"
        if not fc_path.exists() or "hintmedium" not in fc_path.read_text():
            raise AssertionError("font apply should render fontconfig into temp HOME")
        if helper.GTK_SETTINGS_BEGIN not in gtk3_path.read_text():
            raise AssertionError("font apply should write GTK managed block")
        assert "Example &amp; Sans" in fc_path.read_text()
        assert "Example Mono" in fc_path.read_text()
        assert "gtk-font-name=Example & Sans 13" in gtk3_path.read_text()

        helper.set_settings_value("systemFontsManaged", False)
        reset = helper.apply_system_fonts(reset=True)
        assert_equal(reset["partial"], False, "font reset should not warn")
        assert_equal(fc_path.exists(), False, "font reset should remove fontconfig")
        if helper.GTK_SETTINGS_BEGIN in gtk3_path.read_text():
            raise AssertionError("font reset should remove GTK managed block")
        persisted = json.loads((settings_dir / "settings.json").read_text())
        assert_equal(persisted["systemFontsManaged"], False, "font reset should persist disabled setting")

    try:
        with_temp_home(run_case)
    finally:
        helper.system_font_env = original_env
        helper._gsettings_set_font_rendering = original_gsettings
        helper.shutil.which = original_which


def test_system_font_family_targets():
    settings = {"systemFontInterfaceFamily": "Example Sans", "systemFontMonoFamily": "Example Mono", "systemFontSize": 13}
    with patch.object(helper, "system_font_env", return_value={"gsettingsKeys": ["font-name", "monospace-font-name"]}):
        config = helper.normalized_system_font_settings(settings)
        with patch.object(helper.shutil, "which", return_value="gsettings"), patch.object(helper, "_run_hook_cmd", return_value={"ok": True}) as run:
            helper._gsettings_set_font_rendering(config)
            commands = [call.args[1] for call in run.call_args_list]
            assert ["gsettings", "set", "org.gnome.desktop.interface", "font-name", "'Example Sans 13'"] in commands
            assert ["gsettings", "set", "org.gnome.desktop.interface", "monospace-font-name", "'Example Mono 13'"] in commands
            run.reset_mock()
            config["interface"]["family"] = ""
            config["monospace"]["family"] = ""
            helper._gsettings_set_font_rendering(config)
            assert run.call_count == 0, "Unmanaged app fonts must be preserved"
            config["ownedFamilies"] = ["sans-serif"]
            helper._gsettings_set_font_rendering(config)
            assert run.call_args.args[1] == ["gsettings", "reset", "org.gnome.desktop.interface", "font-name"]
        try:
            helper.normalized_system_font_settings({"systemFontInterfaceFamily": "Sans\nInjected=1"})
        except ValueError:
            pass
        else:
            raise AssertionError("Font names must not inject GTK settings")
    generated, _ = helper._hyprland_layout_payload(settings)
    assert 'font_family = "Example Sans"' in generated
    settings["hyprlandFontFamily"] = 'Custom "Font"'
    generated, _ = helper._hyprland_layout_payload(settings)
    assert 'font_family = "Custom \\"Font\\""' in generated
    with patch.object(helper, "apply_system_fonts", return_value={"success": False, "partial": True}), contextlib.redirect_stdout(io.StringIO()):
        assert helper.cmd_fonts(["apply", "--json"]) == 1


def test_system_font_size_targets():
    for gtk_fonts, desktop_fonts, prior_family in [
        ({}, {}, ""),
        ({}, {"font-name": "Desktop Sans 12", "monospace-font-name": "Desktop Mono 10"}, ""),
        ({"gtk-3.0": "GTK Three Semi-Bold 12", "gtk-4.0": "GTK Four 13 @wght=450"},
         {"font-name": "Desktop Sans 12", "monospace-font-name": "Desktop Mono 10"}, ""),
        ({}, {"font-name": "Desktop Sans 12", "monospace-font-name": "Desktop Mono 10"}, "Chosen Sans"),
    ]:
        def run_case(home):
            settings = home / ".config/vshell/settings.json"
            settings.parent.mkdir(parents=True)
            settings.write_text(json.dumps({"systemFontsManaged": True, "systemFontSize": 14}))
            for version, font in gtk_fonts.items():
                path = home / ".config" / version / "settings.ini"
                path.parent.mkdir(parents=True)
                path.write_text(f"[Settings]\ngtk-font-name={font}\ngtk-cursor-theme-size=24\n")
            current = dict(desktop_fonts)

            def gsettings(_hook, command, **_kwargs):
                assert command[0] == "gsettings"
                action, key = command[1], command[3]
                if action == "get":
                    source = desktop_fonts if _kwargs.get("env", {}).get("GSETTINGS_BACKEND") == "memory" else current
                    return {"ok": True, "stdout": repr(source[key])}
                if action == "set":
                    current[key] = ast.literal_eval(command[4])
                elif prior_family and key == "font-name":
                    current[key] = desktop_fonts[key]
                else:
                    raise AssertionError("Size-only reset must restore the original font description")
                return {"ok": True}

            with patch.object(helper, "system_font_env", return_value={"gsettingsKeys": list(current)}), \
                 patch.object(helper.shutil, "which", side_effect=lambda name: "gsettings" if name == "gsettings" and current else None), \
                 patch.object(helper, "_run_hook_cmd", side_effect=gsettings):
                helper.apply_system_fonts()
                assert current == desktop_fonts, "ordinary startup must not claim the default size"
                for version in ("gtk-3.0", "gtk-4.0"):
                    text = (home / ".config" / version / "settings.ini").read_text()
                    managed = text.split(helper.GTK_SETTINGS_BEGIN)[1]
                    assert "gtk-font-name=" not in managed, "untouched Default remains unmanaged"
                fc_path = home / ".config/fontconfig/conf.d/60-vgs-fonts.conf"
                if desktop_fonts:
                    before = fc_path.read_text()
                    with patch.object(helper, "_run_hook_cmd", return_value={"ok": False, "error": "font read failed"}):
                        failed = helper.apply_system_fonts(size_only=True)
                    assert not failed["success"] and fc_path.read_text() == before
                    assert current == desktop_fonts, "failed font read must not substitute a different family"
                if prior_family:
                    helper.set_settings_value("systemFontInterfaceFamily", prior_family)
                    helper.apply_system_fonts()
                with contextlib.redirect_stdout(io.StringIO()):
                    assert helper.cmd_fonts(["apply", "--size-only", "--json"]) == 0
                if prior_family:
                    helper.set_settings_value("systemFontInterfaceFamily", "")
                    helper.apply_system_fonts()
                assert helper.normalized_system_font_settings()["interface"]["family"] == ""
                expected_gtk = {
                    "gtk-3.0": "GTK Three Semi-Bold 14" if gtk_fonts else ("Desktop Sans 14" if desktop_fonts else "Sans 14"),
                    "gtk-4.0": "GTK Four 14 @wght=450" if gtk_fonts else ("Desktop Sans 14" if desktop_fonts else "Sans 14"),
                }
                for version, font in expected_gtk.items():
                    text = (home / ".config" / version / "settings.ini").read_text()
                    assert f"gtk-font-name={font}" in text.split(helper.GTK_SETTINGS_BEGIN)[1]
                if desktop_fonts:
                    assert current == {"font-name": "Desktop Sans 14", "monospace-font-name": "Desktop Mono 14"}
                helper.set_settings_value("systemFontInterfaceHinting", "medium")
                helper.apply_system_fonts()
                for version, font in expected_gtk.items():
                    assert f"gtk-font-name={font}" in (home / ".config" / version / "settings.ini").read_text()
                if desktop_fonts:
                    with patch.object(helper, "_run_hook_cmd", return_value={"ok": False, "error": "font reset failed"}):
                        failed = helper.apply_system_fonts(reset=True)
                    assert not failed["success"] and fc_path.exists(), "failed reset must retain its restore information"
                helper.apply_system_fonts(reset=True)
                assert current == desktop_fonts, "reset must restore size-only GSettings writes"
                assert not fc_path.exists()
                for version in ("gtk-3.0", "gtk-4.0"):
                    text = (home / ".config" / version / "settings.ini").read_text()
                    assert helper.GTK_SETTINGS_BEGIN not in text
                    assert (f"gtk-font-name={gtk_fonts[version]}" in text) if version in gtk_fonts else "gtk-font-name=" not in text
        with_temp_home(run_case)


# Generated tables read as fields, so one table cannot satisfy the other's rounding assertion.
GROUPBAR_TABLE = re.compile(r"^  group = \{\n    groupbar = \{\n(.*?)^    \},\n^  \},$", re.M | re.S)
DECORATION_TABLE = re.compile(r"^  decoration = \{\n(.*?)^  \},$", re.M | re.S)


def _lua_table_fields(table, script):
    match = table.search(script)
    if match is None:
        raise AssertionError(f"layout script should contain the table {table.pattern!r}")
    return {key: int(value) for key, _, value in (line.strip().rstrip(",").partition(" = ") for line in match.group(1).splitlines())}


def test_hyprland_layout_payload():
    script, meta = helper._hyprland_layout_payload({
        "cornerRadius": 99,
        "surfaceBorderWidth": 12,
        "hyprlandLayoutGapsOverride": 6,
        "hyprlandLayoutGapsOutOverride": 8,
        "hyprlandResizeOnBorder": False,
        "configVersion": 15,
    })
    assert_equal(meta["radius"], 20, "layout radius clamp")
    assert_equal(meta["border"], 10, "layout border clamp")
    assert_equal(meta["gaps"], {"gaps_in": 6, "gaps_out": 8}, "layout gaps")
    assert_equal(meta["resizeOnBorder"], False, "resize_on_border v15 false")
    if "rounding = 20" not in script or "border_size = 10" not in script:
        raise AssertionError("layout script should include clamped shape")

    # One radius and one border thickness reach both surfaces. A retired target or override
    # left in a settings file must not resurrect a compositor shape of its own.
    _, meta = helper._hyprland_layout_payload({
        "surfaceGeometryTarget": "quickshell",
        "cornerRadius": 11,
        "surfaceBorderWidth": 2,
        "hyprlandLayoutRadiusOverride": 4,
        "hyprlandLayoutBorderSize": 7,
    })
    assert_equal(meta["manageHyprlandShape"], True, "the compositor shape is always managed")
    assert_equal(meta["radius"], 11, "the shell radius reaches the compositor")
    assert_equal(meta["border"], 2, "the shell border reaches the compositor")

    _, meta = helper._hyprland_layout_payload({
        "cornerRadius": 12,
        "hyprlandResizeOnBorder": False,
        "configVersion": 14,
    })
    assert_equal(meta["radius"], 12, "the shell radius with no override present")
    assert_equal(meta["resizeOnBorder"], True, "legacy resize_on_border false should be upgraded")

    # Both tab options carry the radius times the monitor scale, whole and bounded
    # to 0 to 20; window rounding stays unscaled. Rows: scale 1 across the slider
    # and above it, scale 2 up to and past the bound, and a fractional scale.
    for corner_radius, scale, window, tabs in ((0, 1, 0, 0), (8, 1, 8, 8), (20, 1, 20, 20), (99, 1, 20, 20),
                                               (0, 2, 0, 0), (8, 2, 8, 16), (15, 2, 15, 20), (7, 1.25, 7, 9)):
        script, meta = helper._hyprland_layout_payload({"cornerRadius": corner_radius}, scale)
        assert_equal((_lua_table_fields(GROUPBAR_TABLE, script), _lua_table_fields(DECORATION_TABLE, script), meta["groupbarRadius"]),
                     ({"rounding": tabs, "gradient_rounding": tabs}, {"rounding": window}, tabs), f"rounding at cornerRadius {corner_radius}, scale {scale}")


def test_hyprland_layout_apply_reads_the_highest_monitor_scale():
    # Rows run in order on one file. The highest scale, neither first nor last here, sets the tabs;
    # no session, after a scale-2 row, rewrites at scale 1; an unchanged file is not written or reloaded.
    two = [{"scale": 1.0}, {"scale": 2.0}, {"scale": 1.0}]
    def run_case(home):
        for monitors, tabs, changed in ((two, 16, True), (two, 16, False), (None, 8, True), ([{"scale": 1.0}], 8, False)):
            with patch.object(helper, "load_settings", return_value={"cornerRadius": 8}), \
                    patch.object(helper, "_hyprctl_json", return_value=monitors) as ipc, \
                    patch.object(helper, "write_file", wraps=helper.write_file) as write, \
                    patch.object(helper, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run, \
                    patch.object(helper.shutil, "which", return_value="hyprctl"), patch.dict(os.environ, {"HYPRLAND_INSTANCE_SIGNATURE": "fixture"}):
                result = helper.apply_hyprland_layout()
            assert_equal((ipc.call_args.args, _lua_table_fields(GROUPBAR_TABLE, helper.hyprland_layout_path().read_text()),
                          result["changed"], write.call_count, [c.args for c in run.call_args_list]),
                         (("monitors",), {"rounding": tabs, "gradient_rounding": tabs}, changed, int(changed), [(["hyprctl", "reload"],)] * changed),
                         f"apply with monitors {monitors!r}")
    with_temp_home(run_case)


# Test regex membership and matches, not substring presence in generated Lua.
# Grouped alternation separates the namespace prefix from each listed name.
BLUR_ALLOWLIST = (
    "battery bluetooth-pairing clipboard clipboard-popout color-picker confirm-modal "
    "control-center dash filebrowser input-modal keybinds layout modal mux network-info "
    "network-info-wired network-usage-popout notification-center-modal "
    "notification-center-popout notification-popup polkit-auth-surface popout power-menu "
    "power-profiles process-list-popout switch-user-modal system-update toast tooltip "
    "vgs-menu vpn wifi-password wifi-qrcode"
).split()
# Use namespaces declared by live surfaces; nonexistent names cannot test exclusions.
BLUR_MUST_MATCH = (
    "vshell:control-center vshell:notification-center-popout vshell:dash "
    "vshell:plugins:aiUsage vshell:tooltip"
).split()
# Backdrop-free tooltip hosts must stay outside the blur allowlist; see
# docs/architecture/design-language.md § Invariants.
BLUR_MUST_NOT_MATCH = (
    "vshell:blurwallpaper vshell:workspace-overview vshell:screensaver vshell:fade-to-lock "
    "vshell:launcher-context-menu vshell:notification-context-menu vshell:tray-overflow-menu "
    "vshell:osd vshell:slideout vshell:control-center-widget-library vshell:bar "
    "vshell:control-center:background vshell:plugins:aiUsage:background"
).split()


def assert_blur_namespace_rule(script, source):
    # Bind extraction to the unique layer match stanza while permitting formatting changes.
    patterns = re.findall(r'match\s*=\s*\{\s*namespace\s*=\s*"([^"]*)"', script)
    if len(patterns) != 1:
        raise AssertionError(f"{source}: expected one layer-rule match stanza, found {len(patterns)}")
    pattern = patterns[0]
    members = re.search(r"vshell:\(([^)]+)\)", pattern)
    if not members:
        raise AssertionError(f"{source}: could not read the allowlist out of {pattern!r}")
    assert_equal(sorted(members.group(1).split("|")), sorted(BLUR_ALLOWLIST),
                 f"{source}: blur allowlist membership")
    # .search, not .fullmatch: the pattern's own ^ and $ have to do the work, so
    # dropping either anchor (or loosening the plugins arm to .+) fails here.
    rule = re.compile(pattern)
    for namespace in BLUR_MUST_MATCH:
        if not rule.search(namespace):
            raise AssertionError(f"{source}: {namespace} must be blurred, but the rule misses it")
    for namespace in BLUR_MUST_NOT_MATCH:
        if rule.search(namespace):
            raise AssertionError(
                f"{source}: the rule matches {namespace}, which must not be blurred. A namespace "
                "belongs in blurred_namespaces only when its whole surface rectangle is an "
                "acceptable per-frame live-blur region — docs/architecture/design-language.md "
                "§ Invariants."
            )


def test_hyprland_blur_script():
    script = helper._hyprland_blur_script(True, 1.5, True, 0.01)
    assert_blur_namespace_rule(script, "generated blur script")
    if "special = false" not in script:
        raise AssertionError("Hyprland blur script should not amplify special-workspace scratchpad blur")
    if "ignore_alpha = 0.034" not in script:
        raise AssertionError("Hyprland blur script should clamp opacity before alpha mapping")
    if "brightness = 0.5" not in script:
        raise AssertionError("dark-mode glass blur should sink the backdrop so a bright window can't wash out the tint above")
    if "vibrancy_darkness = 0.25" not in script:
        raise AssertionError("dark-mode glass blur should deepen the sink via vibrancy_darkness")
    light = helper._hyprland_blur_script(True, 0.5, True, 1.0, "light")
    if "brightness = 1.18" not in light:
        raise AssertionError("light-mode glass blur should lift the backdrop toward the light material")
    if "vibrancy_darkness = 0.0" not in light:
        raise AssertionError("light-mode glass blur should not darken vibrancy")

    disabled = helper._hyprland_blur_script(False, -1, False, 1)
    if "if false then" not in disabled:
        raise AssertionError("disabled blur script should disable the runtime rule")

    # Every VGS window is a resizable toplevel sharing one class, and each shows the same
    # trailing chrome during a drag, so the rule matches the class alone. A title match
    # would leave every window but Settings drawing its own border.
    for enabled, radius in [(True, 9), (False, 0)]:
        generated = helper._hyprland_blur_script(enabled, 0.5, True, 1, "dark", radius)
        match_line = next(line for line in generated.splitlines() if "match = { class =" in line)
        assert_equal("title" in match_line, False, "the window rule must not narrow to one title")
        fields = re.findall(r'"(?:[^"\\]|\\.)*"', match_line)
        assert_equal(len(fields), 1, "the window rule matches on class alone")
        class_rule = re.compile(json.loads(fields[0]))
        assert_equal(bool(class_rule.search("com.vanillagreen.vshell")), True, "the VGS window class")
        for other_class in ["com.vanillagreen.vshell.extra", "comXvanillagreenXvshell", "other"]:
            assert_equal(bool(class_rule.search(other_class)), False, "unrelated class")
        assert_equal(f"rounding = {radius}," in generated, True, "client corner radius")
        assert_equal("rounding_power = 2.0," in generated, True, "circular client corners")
        assert_equal("border_size = 2," in generated, True, "compositor-drawn window border")
    # A classic-config session refuses `hyprctl eval` on stdout and still exits 0. Treating
    # that as applied would leave the Settings window with no border and square corners,
    # because the shell stops drawing chrome the compositor never took over.
    import subprocess as _sp
    refusal = _sp.CompletedProcess(["hyprctl", "eval"], 0, "eval is only supported with the lua config manager\n", "")
    assert_equal(helper._hyprctl_eval_ok(refusal), False, "a refused eval is not an applied eval")
    assert_equal(helper._hyprctl_eval_ok(_sp.CompletedProcess(["hyprctl", "eval"], 0, "ok\n", "")), True,
                 "the Lua config manager's success reply")
    assert_equal(helper._hyprctl_eval_ok(_sp.CompletedProcess(["hyprctl", "eval"], 7, "error: boom", "")), False,
                 "a failed Lua chunk is not an applied eval")
    # hyprctl on PATH and a session signature, or _hyprland_blur_support returns
    # unavailable from its own early return and the arm passes on every CI runner without
    # ever reaching the patched eval. The reason pins which of the two answered.
    with patch.object(helper.shutil, "which", return_value="/usr/bin/hyprctl"), \
            patch.dict(os.environ, {"HYPRLAND_INSTANCE_SIGNATURE": "test"}), \
            patch.object(helper, "_hyprctl_eval", return_value=refusal):
        support = helper._hyprland_blur_support()
    assert_equal(support.get("available"), False,
                 "blur support must not be claimed on a session that refused the probe")
    assert_equal(support.get("reason"), "eval is only supported with the lua config manager",
                 "the refusal text, not an absent hyprctl, is why blur is unavailable")
    bordered = helper._hyprland_blur_script(True, 0.5, True, 1, "dark", 9, 3)
    assert_equal("border_size = 3," in bordered, True, "the border width follows the shell")
    assert_equal("border_size = 10," in helper._hyprland_blur_script(True, 0.5, True, 1, "dark", 9, 40), True, "the border width clamps")


@contextlib.contextmanager
def sandbox_homes():
    """Two fixed literals, then two homes the shipped producer's own mktemp can create.

    scripts/qml-smoke.sh builds its home with `mktemp -d -t vshell-smoke.XXXXXX`, which
    honours $TMPDIR: the third row lands wherever this machine points TMPDIR, and the
    fourth directly under the login home, where a $TMPDIR inside $HOME puts it. That last
    one is the case a containment test cannot tell apart from the login user's own session.
    """
    login = Path(pwd.getpwuid(os.getuid()).pw_dir)
    ambient = tempfile.mkdtemp(prefix="vshell-smoke.")
    under_login = tempfile.mkdtemp(prefix="vshell-smoke.", dir=str(login))
    try:
        yield ["/tmp/vshell-smoke.AbCdEf/home", "/var/tmp/agents/vgs273.XyZ/home", ambient, under_login]
    finally:
        shutil.rmtree(ambient, ignore_errors=True)
        shutil.rmtree(under_login, ignore_errors=True)


@contextlib.contextmanager
def as_home(path):
    """Run the block with $HOME (and the config root that travels with it) at `path`."""
    saved = {n: os.environ.get(n) for n in ("HOME", "XDG_CONFIG_HOME", "SUDO_USER")}
    os.environ.pop("SUDO_USER", None)
    os.environ["HOME"] = str(path)
    os.environ["XDG_CONFIG_HOME"] = str(Path(path) / ".config")
    try:
        yield Path(path)
    finally:
        for name, value in saved.items():
            _restore_env(name, value)


def test_chromium_policy_refuses_a_sandbox_home():
    """A shell on a throwaway HOME must not push its default theme into the system policy.

    The nested smoke sandbox runs a full shell against a temporary home. Without this the
    hook wrote that shell's colour to /etc/chromium/policies/managed for every browser on
    the machine.
    """
    login = Path(pwd.getpwuid(os.getuid()).pw_dir)
    with as_home(login):
        assert_equal(helper._sandboxed_home(), False, "the login user's own home is not a sandbox")
    with sandbox_homes() as homes:
        for sandbox in homes:
            with as_home(sandbox):
                assert_equal(helper._sandboxed_home(), True, f"sandbox home {sandbox}")
                # write_chromium_policy must refuse before it ever reaches sudo.
                with patch.object(helper.subprocess, "run") as ran:
                    wrote, reason = helper.write_chromium_policy({"surfaceContainerHigh": "#123456"})
                assert_equal(wrote, False, f"a sandboxed shell must not write the system policy ({sandbox})")
                assert_equal(reason, helper.SANDBOX_REFUSAL,
                             "the refusal names itself, not a missing privilege")
                assert_equal(ran.called, False, "a sandboxed shell must not reach sudo at all")


def test_theme_hooks_stay_out_of_the_login_session():
    """A shell on a throwaway HOME must not restyle the login session's running apps.

    The nested smoke sandbox runs a full shell against a temporary home with its own
    default theme. Its hooks find kitty, btop and ghostty through /proc, and tmux and nvim
    through runtime paths named by the real uid, so without a guard the user's terminals
    were repainted from a test's palette.
    """
    login = Path(pwd.getpwuid(os.getuid()).pw_dir)
    # The scans each hook reaches its targets through. Patching them is what makes the
    # empty result attributable to the guard: a host with no kitty, no tmux server and no
    # nvim returns the same [] with every guard deleted.
    scans = [
        ("the /proc scan", "iterdir", lambda: helper.process_pids_by_comm("kitty")),
        ("the tmux socket probe", "iterdir", lambda: helper.tmux_sockets()),
        ("the nvim runtime-dir walk", "glob", lambda: helper.nvim_sockets()),
    ]
    with sandbox_homes() as homes:
        for sandbox in homes:
            with as_home(sandbox):
                assert_equal(helper._sandboxed_home(), True, f"sandbox home {sandbox}")
                for label, method, call in scans:
                    tripwire = AssertionError(f"{label} ran under a sandbox HOME")
                    with patch.object(helper.Path, method, side_effect=tripwire) as scan:
                        assert_equal(call(), [], f"{label} yields nothing under a sandbox HOME")
                    assert_equal(scan.called, False, f"the guard, not an empty result, stops {label}")
                result = helper.signal_reload_hook("kitty-reload", "kitty", signal.SIGUSR1)
                assert_equal(result["skipped"], True, "the reload hook reports a skip, not a signal")
                assert_equal(result["reason"], helper.SANDBOX_REFUSAL,
                             "the skip names the refusal, not an absent kitty")
                # Every hook that reaches the login session, refused as a whole rather
                # than only where it scans: ghostty falls through to a session-bus reload
                # with no pid to signal, hypr-reload picks the newest live compositor
                # instance, and shell-reload finds the running shell through the real
                # uid's runtime directory. gtk-settings and icon-theme write the login
                # user's dconf database over the session bus, and gtk4-reload quits the
                # login session's Nautilus service on it. None passes through a scan.
                trip = AssertionError("a sandboxed hook must not run a command")
                with patch.object(helper, "_run_hook_cmd", side_effect=trip), \
                        patch.object(helper.subprocess, "run", side_effect=trip):
                    for hook in ("ghostty-reload", "hypr-reload", "shell-reload", "tmux-source", "nvim-reload",
                                 "gtk-settings", "gtk4-reload", "icon-theme"):
                        skipped = helper.run_hook(hook, {"background": "#123456"}, {})
                        assert_equal(skipped.get("skipped"), True, f"{hook} reports a skip under a sandbox HOME")
                        assert_equal(skipped.get("reason"), helper.SANDBOX_REFUSAL,
                                     f"{hook} names the refusal rather than an absent app")
    # The inverse: with the login user's own HOME the same patched scans ARE reached, so
    # the assertions above pin the guard rather than a scan that never runs.
    with as_home(login):
        assert_equal(helper._sandboxed_home(), False, "the login user's own home is not a sandbox")
        for label, method, call in scans:
            with patch.object(helper.Path, method, side_effect=lambda *a, **k: iter([])) as scan:
                call()
            assert_equal(scan.called, True, f"{label} is reached from the login user's own home")
        # Both settings hooks reach gsettings from the login user's own home. The theme
        # directory lookups are stubbed so the icon hook gets as far as its write.
        written = []

        def record(hook, command, **_kwargs):
            written.append(tuple(command[:4]))
            return {"hook": hook, "ok": True}

        real_is_dir = helper.Path.is_dir
        quits = []

        def record_quit():
            quits.append({"ok": True, "quit": True})
            return quits[-1]

        results = {}
        with tempfile.TemporaryDirectory() as generated:
            (Path(generated) / "icons.theme").write_text("vgs-probe-icons\n")
            with patch.object(helper, "_run_hook_cmd", side_effect=record), \
                    patch.object(helper.shutil, "which", return_value="/usr/bin/gsettings"), \
                    patch.object(helper, "_quit_windowless_nautilus", side_effect=record_quit), \
                    patch.object(helper, "ensure_bundled_icon_themes", return_value=[]), \
                    patch.object(helper, "generated_dir", return_value=Path(generated)), \
                    patch.object(helper, "load_settings", return_value={}), \
                    patch.object(helper.Path, "is_dir", lambda self: self.name == "vgs-probe-icons" or real_is_dir(self)), \
                    patch.object(helper.time, "sleep"):
                for hook in ("gtk-settings", "icon-theme", "gtk4-reload"):
                    results[hook] = helper.run_hook(hook, {"theme_type": "dark"}, {})
        interface = ("gsettings", "set", "org.gnome.desktop.interface")
        assert_equal(written, [interface + ("gtk-theme",), interface + ("color-scheme",), interface + ("icon-theme",)],
                     "the settings hooks write gsettings from the login user's own home")
        # Quitting the windowless Files service is gtk4-reload's whole payload:
        # GTK4 reads gtk.css once per process and that file belongs to gtk4-vgs,
        # so the quit is gated on its bytes rather than run beside the gsettings
        # writes. Past the sandbox guard, which the loop above pins from the other
        # side, a branch that stopped calling it would still report ok.
        assert_equal(len(quits), 1, "exactly one hook quits the windowless Files service")
        assert_equal(results["gtk4-reload"]["nautilus"], {"ok": True, "quit": True},
                     "gtk4-reload reports what the quit returned")
        assert_equal("nautilus" in results["gtk-settings"], False,
                     "gtk-settings no longer carries the quit it was moved off")


def test_vshell_blur_cli_contract():
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        fake_bin = tmp_path / "bin"
        fake_bin.mkdir()
        record_path = tmp_path / "hyprctl-eval.txt"
        fake_hyprctl = fake_bin / "hyprctl"
        # Stand in for a session running the Lua config manager: it records the chunk and
        # answers "ok", the reply the helper requires before it reports a rule as applied.
        fake_hyprctl.write_text("""#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == eval ]]; then
  printf '%s' "${2:-}" > "$HYPRCTL_RECORD"
  printf 'ok\\n'
fi
exit 0
""")
        fake_hyprctl.chmod(0o755)

        env = os.environ.copy()
        env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
        env["HOME"] = str(tmp_path / "home")
        env["HYPRLAND_INSTANCE_SIGNATURE"] = "test"
        env["HYPRCTL_RECORD"] = str(record_path)

        proc = subprocess.run(
            [
                str(REPO_ROOT / "bin" / "vshell"),
                "blur",
                "apply",
                "--enabled",
                "true",
                "--strength",
                "1.5",
                "--glass",
                "true",
                "--opacity",
                "0.01",
                "--json",
            ],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        if proc.returncode != 0:
            raise AssertionError(f"vshell blur apply CLI failed: {proc.stderr or proc.stdout}")
        payload = json.loads(proc.stdout)
        assert_equal(payload["ok"], True, "blur CLI ok")
        assert_equal(payload["strength"], 1.0, "blur CLI strength clamp")
        assert_equal(payload["opacity"], 0.08, "blur CLI opacity clamp")

        assert_blur_namespace_rule(record_path.read_text(), "blur CLI hyprctl eval payload")

        # Must-fail control: a session on a classic config prints its refusal and still
        # exits 0. The CLI has to report that as a failure, or the shell drops the window
        # chrome it believes the compositor took over.
        fake_hyprctl.write_text("""#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == eval ]]; then
  printf 'eval is only supported with the lua config manager\\n'
fi
exit 0
""")
        fake_hyprctl.chmod(0o755)
        refused = subprocess.run(
            [str(REPO_ROOT / "bin" / "vshell"), "blur", "apply", "--enabled", "true", "--json"],
            check=False, capture_output=True, text=True, env=env,
        )
        refused_payload = json.loads(refused.stdout)
        assert_equal(refused_payload["ok"], False, "a refused eval must not report success")
        assert_equal(refused_payload.get("windowChrome"), None,
                     "a refused eval must not claim the compositor owns the window chrome")

        # Must-fail control for the second _hyprctl_eval_ok site, the one that produces
        # windowChrome. A config manager that accepts the layer_rule probe and rejects the
        # window rule answers per chunk, so only the rule chunk fails and the support
        # probe no longer short-circuits the apply. Reading the return code alone here
        # reports windowChrome true for a rule the compositor never installed, and every
        # VGS window then renders square and borderless.
        fake_hyprctl.write_text("""#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == eval ]]; then
  if [[ ${2:-} == *"hl.layer_rule unavailable"* ]]; then
    printf 'ok\\n'
  else
    printf 'error: attempt to index a nil value\\n'
  fi
fi
exit 0
""")
        fake_hyprctl.chmod(0o755)
        rejected = subprocess.run(
            [str(REPO_ROOT / "bin" / "vshell"), "blur", "apply", "--enabled", "true", "--json"],
            check=False, capture_output=True, text=True, env=env,
        )
        rejected_payload = json.loads(rejected.stdout)
        assert_equal(rejected_payload["ok"], False, "a rejected rule chunk must not report success")
        assert_equal(rejected_payload["windowChrome"], False,
                     "a rejected rule chunk must not hand the window chrome to the compositor")


def test_generated_theme_consumer_wiring():
    def run(temp_home: Path):
        old_xdg_dirs = os.environ.get("XDG_CONFIG_DIRS")
        system_root = temp_home / "system-xdg"
        system_foot = system_root / "foot" / "foot.ini"
        system_foot.parent.mkdir(parents=True)
        system_foot.write_text("# packaged Foot defaults\n")
        os.environ["XDG_CONFIG_DIRS"] = str(system_root)
        try:
            foot_theme = temp_home / ".config" / "foot" / "vgs-theme.ini"
            foot_theme.parent.mkdir(parents=True)
            foot_theme.write_text("[colors]\nbackground=111111\n")
            first = helper.ensure_foot_theme_config()
            foot_config = temp_home / ".config" / "foot" / "foot.ini"
            foot_text = foot_config.read_text()
            if f"include={system_foot}" not in foot_text:
                raise AssertionError("new Foot config must retain the effective system config")
            if "include=~/.config/foot/vgs-theme.ini" not in foot_text:
                raise AssertionError("Foot config must include the generated VGS fragment")
            assert_equal(first["changed"], True, "first Foot wiring")
            assert_equal(helper.ensure_foot_theme_config()["changed"], False, "Foot wiring idempotency")

            foot_config.write_text("# user setting\ninclude=" + str(foot_theme) + "\n")
            assert_equal(helper.ensure_foot_theme_config()["changed"], False,
                         "equivalent absolute Foot include")
            if foot_config.read_text().count("include=") != 1:
                raise AssertionError("Foot wiring must not duplicate an equivalent include")

            kitty_config = temp_home / ".config" / "kitty" / "kitty.conf"
            kitty_config.parent.mkdir(parents=True)
            kitty_config.write_text("font_size 12\n")
            helper.ensure_kitty_theme_config()
            kitty_text = kitty_config.read_text()
            if "font_size 12" not in kitty_text or kitty_text.count("include vgs-theme.conf") != 1:
                raise AssertionError("Kitty wiring must preserve user config and add one include")
            assert_equal(helper.ensure_kitty_theme_config()["changed"], False,
                         "Kitty wiring idempotency")

            niri_config = temp_home / ".config" / "niri" / "config.kdl"
            niri_config.parent.mkdir(parents=True)
            niri_config.write_text("input {}\n")
            helper.ensure_niri_colors_config()
            if niri_config.read_text().count('include "vgs/colors.kdl"') != 1:
                raise AssertionError("Niri config must include the generated color fragment")
            assert_equal(helper.ensure_niri_colors_config()["changed"], False,
                         "Niri color wiring idempotency")

            qt_config = temp_home / ".config" / "qt6ct" / "qt6ct.conf"
            qt_config.parent.mkdir(parents=True)
            qt_config.write_text("[Appearance]\nstyle=Fusion\ncolor_scheme_path=/old.conf\n")
            helper.ensure_qtct_theme_config(6)
            qt_text = qt_config.read_text()
            if "style=Fusion" not in qt_text:
                raise AssertionError("Qt6ct wiring must preserve unrelated appearance settings")
            if f"color_scheme_path={temp_home}/.config/qt6ct/colors/vgs.conf" not in qt_text:
                raise AssertionError("Qt6ct must select the generated VGS palette")
            if "custom_palette=true" not in qt_text:
                raise AssertionError("Qt6ct must enable its selected custom palette")
            assert_equal(helper.ensure_qtct_theme_config(6)["changed"], False,
                         "Qt6ct wiring idempotency")
        finally:
            if old_xdg_dirs is None:
                os.environ.pop("XDG_CONFIG_DIRS", None)
            else:
                os.environ["XDG_CONFIG_DIRS"] = old_xdg_dirs

    with_temp_home(run)

    original_foot_hook = helper.ensure_foot_theme_config
    try:
        def fail_foot_hook():
            raise OSError("read-only test config")
        helper.ensure_foot_theme_config = fail_foot_hook
        failed = helper.run_hook("foot-config", {}, {})
        assert_equal(failed["ok"], False, "consumer hook failure result")
        if "read-only test config" not in failed.get("error", ""):
            raise AssertionError("consumer hook failure must remain observable")
    finally:
        helper.ensure_foot_theme_config = original_foot_hook


def test_shell_only_theme_preview():
    def run(temp_home: Path):
        blueprint = helper.load_theme_package(helper.DEFAULT_THEME_NAME)
        if not blueprint:
            raise AssertionError(f"{helper.DEFAULT_THEME_NAME} package missing")
        blueprint["adjustments"] = helper.normalize_adjustments({"brightness": 17})
        result = helper.apply_theme_obj(
            blueprint,
            only_target="vgs-shell",
            run_hooks=False,
        )
        rendered = [Path(path) for path in result.get("rendered", [])]
        expected = temp_home / ".config" / "vshell" / "theme.json"
        if rendered != [expected] or not expected.is_file():
            raise AssertionError(f"preview must render only shell state: {rendered!r}")
        if (temp_home / ".config" / "vshell" / "theme-current.json").exists():
            raise AssertionError("preview must not persist current-theme metadata")
        if list((temp_home / ".config").glob("*/vgs*")):
            raise AssertionError("preview must not regenerate app targets")

    with_temp_home(run)


def test_current_theme_reads_without_applying():
    """With no theme.json, reading the current theme answers the default and applies nothing.

    Applying runs hooks whose gsettings writes reach the login user's desktop over the
    session bus even from a temporary HOME, so a read that applied would restyle the live
    desktop from a test.
    """
    def scenario(temp_home: Path):
        with patch.object(helper, "run_hook", side_effect=AssertionError("a read ran a theme hook")):
            data = helper.current_theme()
        assert_equal(data.get("name"), helper.DEFAULT_THEME_NAME, "no theme state reads as the default theme")
        template = json.loads((helper.targets_dir() / "vgs-shell" / "vgs-theme.json").read_text())
        assert_equal(sorted(data.get("colors", {})), sorted(template["colors"]),
                     "the no-state read carries every colour role an apply writes")
        assert_equal(sorted(p.relative_to(temp_home).as_posix() for p in temp_home.rglob("*") if not p.is_dir()), [],
                     "a read writes no file under HOME")
        state = temp_home / ".config" / "vshell" / "theme.json"
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text('{"name": "applied", "mode": "light"}\n')
        assert_equal(helper.current_theme(), {"name": "applied", "mode": "light"},
                     "an applied theme reads back as written")

    with_temp_home(scenario)


def test_cache_prune_bounds_imagecache_and_drops_unreferenced_notification_images():
    """`cache prune` deletes imagecache track art, then thumbnails, oldest-written first past the size cap, and the
    notification images no history entry names once they are past the save grace."""
    def prune() -> tuple:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = helper.cmd_cache(["prune"])
        return status, (err.getvalue().splitlines() or [""])[0]

    def put(path: Path, size: int, age_seconds: float) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * size)
        stamp = time.time() - age_seconds
        os.utime(path, (stamp, stamp))
        return path

    def scenario(temp_home: Path):
        cache = temp_home / ".cache" / "vshell"
        images = cache / "imagecache"
        # (file, survives, why): the owned files total 1800 bytes against a 1000-byte cap.
        image_rows = [
            (put(images / "remote_0000000a", 400, 2000), False, "track art goes first, the oldest-written first"),
            (put(images / "remote_0000000c", 200, 1000), False, "every track art download goes before a thumbnail"),
            (put(images / "0000000b@256x256.png", 400, 3000), False,
             "once no track art is left, the oldest-written thumbnail goes"),
            (put(images / "0000000f@256x256.png", 400, 2500), True,
             "a thumbnail written before the deleted track art stays once the rest fit the cap"),
            (put(images / "0000000d@512x512.png", 400, 10), True, "the newest thumbnail stays"),
            (put(images / "remote_0000000e.tmp", 4000, 5000), True, "a download still being written is not an owned name"),
            (put(images / "notes.txt", 4000, 5000), True, "a file outside the hash scheme is neither counted nor deleted"),
        ]
        notif = cache / "notification_images"
        history = cache / "notification_history.json"
        # (file, image the history names for it or None, survives, why)
        notif_rows = [
            (put(notif / "notif_1000_1.png", 10, 3600), f"file://{notif}/notif_1000_1.png", True,
             "an image a history entry names stays"),
            (put(notif / "notif_1000_2.png", 10, 3600), "file:///var/home/other/.cache/vshell/notification_images/notif_1000_2.png",
             True, "an entry names its image by file name, so another spelling of the cache root keeps it"),
            (put(notif / "notif_1000_3.png", 10, 3600), None, False, "an image no entry names is deleted"),
            (put(notif / "notif_1000_4.png", 10, 5), None, True, "an unnamed image inside the save grace stays"),
            (put(notif / "keep.png", 10, 3600), None, True, "a file outside the notification image scheme stays"),
        ]
        named = [{"image": image} for _path, image, _survives, _why in notif_rows if image]
        history.write_text(json.dumps({"notifications": [*named, {"image": "image://icon/app"}, {}]}))

        with patch.object(helper, "IMAGECACHE_MAX_BYTES", 1000):
            assert_equal(prune(), (0, ""), "cache prune exit status")
        for path, survives, why in image_rows:
            assert_equal(path.exists(), survives, why)
        for path, _image, survives, why in notif_rows:
            assert_equal(path.exists(), survives, why)

        # (history text or None for no file, exit status, stderr key, why)
        for text, status, key, why in [
            (None, 0, "", "a missing history deletes no notification image"),
            ("{not json", 1, f"notification-history-unreadable: {history}", "unparseable history deletes no notification image"),
            (json.dumps({"notifications": 3}), 1, f"notification-history-unreadable: {history}",
             "a history without an entry list deletes no notification image"),
        ]:
            stray = put(notif / "notif_2000_9.png", 10, 3600)
            if text is None:
                history.unlink(missing_ok=True)
            else:
                history.write_text(text)
            assert_equal(prune(), (status, key), why)
            assert_equal(stray.exists(), True, why)

        cli = subprocess.run(
            [str(REPO_ROOT / "bin" / "vshell"), "cache", "prune"],
            check=False, capture_output=True, text=True,
            env={"PATH": os.environ.get("PATH", ""), "HOME": str(temp_home)},
        )
        assert_equal((cli.returncode, (cli.stderr.splitlines() or [""])[0]),
                     (1, f"notification-history-unreadable: {history}"),
                     "the vshell CLI routes cache prune to the helper")

    with_temp_home(scenario)


def test_icon_index_picks_each_name_through_the_inherit_chain():
    """`icons index` maps each icon name to one file of the theme's inherit chain, and
    reuses its per-theme cache until a file in the chain changes."""
    def touch(path: Path, text: str = "") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def index(theme: str) -> dict:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            status = helper.cmd_icons(["index", theme])
        assert_equal(status, 0, f"icons index {theme} exit status")
        return json.loads(buffer.getvalue())

    def scenario(temp_home: Path):
        # The host's own themes stay in the search path, so every probe name is unique.
        os.environ["XDG_DATA_DIRS"] = str(temp_home / "share")
        os.environ.pop("XDG_DATA_HOME", None)
        system = temp_home / "share" / "icons"
        user = temp_home / ".local" / "share" / "icons"
        touch(system / "Child" / "index.theme", "[Icon Theme]\nInherits=Parent\n")
        touch(user / "Parent" / "index.theme", "[Icon Theme]\nInherits=\n")
        # (name, winning file, losing files, what the winner shows)
        rows = [
            ("vgs-probe-chain", system / "Child/16x16/apps/vgs-probe-chain.png",
             [user / "Parent/64x64/apps/vgs-probe-chain.svg"], "an earlier theme in the chain outranks format and size"),
            ("vgs-probe-context", user / "Parent/16x16/apps/vgs-probe-context.png",
             [system / "Child/scalable/actions/vgs-probe-context.svg"], "an app icon outranks an earlier theme's action icon"),
            ("vgs-probe-format", system / "Child/16x16/apps/vgs-probe-format.svg",
             [system / "Child/64x64/apps/vgs-probe-format.png"], "SVG outranks a larger PNG"),
            ("vgs-probe-size", system / "Child/64x64/apps/vgs-probe-size.png",
             [system / "Child/16x16/apps/vgs-probe-size.png"], "the larger PNG wins"),
            ("vgs-probe-scalable", system / "Child/scalable/apps/vgs-probe-scalable.svg",
             [system / "Child/48x48/apps/vgs-probe-scalable.svg"], "a scalable SVG outranks a sized one"),
            ("vgs-probe-fallback", user / "hicolor/48x48/apps/vgs-probe-fallback.png",
             [], "hicolor ends every chain without being inherited"),
        ]
        for _name, winner, losers, _claim in rows:
            for path in [winner, *losers]:
                touch(path)
        touch(system / "Unrelated/48x48/apps/vgs-probe-unrelated.png")

        result = index("Child")
        for name, winner, _losers, claim in rows:
            assert_equal(result.get(name), str(winner), claim)
        assert_equal("vgs-probe-unrelated" in result, False, "a theme outside the chain is not indexed")
        # Two candidates that tie leave the winner to the walk's directory order, which
        # differs per filesystem, so the size rule is pinned on the ranking itself.
        assert_equal(helper._icon_path_score("/64x64/apps/vgs-probe-size.png", 0)
                     > helper._icon_path_score("/16x16/apps/vgs-probe-size.png", 0), True,
                     "the larger PNG outranks a smaller one at the same chain position")

        with patch.object(helper.os, "walk", side_effect=AssertionError("icon-index-rebuilt-unchanged")):
            assert_equal(index("Child"), result, "an unchanged chain reads the cached index")

        added_dir = system / "Child/48x48/apps"
        touch(added_dir / "vgs-probe-added.png")
        stamp = os.stat(added_dir)
        os.utime(added_dir, ns=(stamp.st_atime_ns, stamp.st_mtime_ns + 1_000_000_000))
        assert_equal(index("Child").get("vgs-probe-added"), str(added_dir / "vgs-probe-added.png"),
                     "an icon added to the chain rebuilds the index")

        cache_parent = helper.cache_dir()
        for theme in ("..", "../escape", "a/b"):
            err = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                status = helper.cmd_icons(["index", theme])
            assert_equal((status, (err.getvalue().splitlines() or [""])[0]), (2, f"icon-theme-name-invalid: {theme!r}"),
                         f"icons index refuses theme name {theme!r}")
        assert_equal(sorted(p.name for p in cache_parent.iterdir()), ["icon-index"],
                     "a refused theme name writes nothing beside the index cache")

        cli = subprocess.run(
            [str(REPO_ROOT / "bin" / "vshell"), "icons", "index", "Child"],
            check=False, capture_output=True, text=True,
            env={"PATH": os.environ.get("PATH", ""), "HOME": str(temp_home), "XDG_DATA_DIRS": str(temp_home / "share")},
        )
        assert_equal(cli.returncode, 0, f"vshell icons index exit status: {cli.stderr.strip()}")
        assert_equal(json.loads(cli.stdout).get("vgs-probe-chain"), str(system / "Child/16x16/apps/vgs-probe-chain.png"),
                     "the vshell CLI routes icons index to the helper")

    saved = {n: os.environ.get(n) for n in ("XDG_DATA_DIRS", "XDG_DATA_HOME")}
    try:
        with_temp_home(scenario)
    finally:
        for name, value in saved.items():
            _restore_env(name, value)


def test_icon_picker_lists_every_base_dir_and_samples_each_set():
    """`theme icons --json` lists a set installed under any icon_theme_base_dirs() entry,
    ships the bundled Yaru sets to the picker, and resolves each set's sample icons."""
    def touch(path: Path, text: str = "") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def icons() -> dict:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            status = helper.cmd_theme(["icons", "--json"])
        assert_equal(status, 0, "theme icons --json exit status")
        return json.loads(buffer.getvalue())

    # The names the repository ships, read from the directory the installers copy, so a
    # set added to or dropped from it moves this floor with it.
    bundled = sorted(d.name for d in helper.bundled_icons_dir().iterdir() if (d / "index.theme").is_file())
    # An empty floor would leave both per-set loops below asserting nothing.
    assert_equal(len(bundled) > 0, True, "config/vshell/icons ships at least one set with an index.theme")

    def scenario(temp_home: Path):
        # A data home away from ~/.local/share and a data dir away from /usr/share: the
        # picker reaches both only by reading icon_theme_base_dirs().
        os.environ["XDG_DATA_HOME"] = str(temp_home / "data-home")
        os.environ["XDG_DATA_DIRS"] = str(temp_home / "data-dir")
        shared = temp_home / "data-dir" / "icons"
        # A theme only a data-dir entry carries, with a parent that supplies one sample.
        touch(shared / "VgsProbeSet" / "index.theme", "[Icon Theme]\nInherits=VgsProbeParent\nDirectories=48x48/apps\n")
        touch(shared / "VgsProbeParent" / "index.theme", "[Icon Theme]\nDirectories=48x48/apps\n")
        touch(shared / "VgsProbeSet/48x48/places/folder.png")
        touch(shared / "VgsProbeSet/48x48/apps/system-file-manager.png")
        touch(shared / "VgsProbeSet/48x48/apps/preferences-desktop.png")
        touch(shared / "VgsProbeParent/48x48/apps/utilities-terminal.png")
        # A cursor-only theme declares no Directories and is not a set anyone can pick.
        touch(shared / "VgsProbeCursors" / "index.theme", "[Icon Theme]\nName=VgsProbeCursors\n")
        (shared / "VgsProbeCursors" / "cursors").mkdir(parents=True, exist_ok=True)
        touch(helper.generated_dir() / "icons.theme", "Yaru-purple\n")

        result = icons()
        names = [entry["name"] for entry in result["sets"]]
        # Over-inclusion from a host Flatpak export root stays open: those paths are
        # absolute and a temporary home cannot move them.
        for name in bundled:
            assert_equal(name in names, True, f"the bundled set {name} reaches the picker")
        assert_equal("VgsProbeSet" in names, True, "a set under an XDG_DATA_DIRS entry reaches the picker")
        assert_equal("VgsProbeCursors" in names, False, "a cursor-only theme is not offered as an icon set")
        assert_equal("hicolor" in names, False, "the hicolor fallback base is not offered as an icon set")

        samples = {entry["name"]: entry["samples"] for entry in result["sets"]}
        assert_equal(samples["VgsProbeSet"], [
            str(shared / "VgsProbeSet/48x48/places/folder.png"),
            str(shared / "VgsProbeSet/48x48/apps/system-file-manager.png"),
            str(shared / "VgsProbeParent/48x48/apps/utilities-terminal.png"),
            str(shared / "VgsProbeSet/48x48/apps/preferences-desktop.png"),
        ], "each sample resolves through the set's own inherit chain, in ICON_PREVIEW_SAMPLES order")
        for name in bundled:
            assert_equal(len(samples[name]), len(helper.ICON_PREVIEW_SAMPLES),
                         f"the bundled set {name} resolves every sample icon")
        assert_equal(result["themeIcon"], "Yaru-purple", "the theme's own set is named")
        assert_equal(sorted(result), ["sets", "themeIcon"],
                     "the picker reads one list and one name; whether the theme's set is installed is the tab's to judge from that list")

        # One set whose inherit chain reaches an index.theme this process cannot read,
        # the class list_installed_icon_themes already skips for the listed theme itself:
        # a root-owned 0600 index.theme, or a directory on a mount that went away.
        real_samples = helper.icon_theme_samples

        def refuse_one(theme: str) -> list[str]:
            if theme == "VgsProbeSet":
                raise PermissionError(13, "Permission denied", "index.theme")
            return real_samples(theme)

        err = io.StringIO()
        with patch.object(helper, "icon_theme_samples", side_effect=refuse_one), \
                contextlib.redirect_stderr(err):
            partial = icons()
        partial_samples = {entry["name"]: entry["samples"] for entry in partial["sets"]}
        assert_equal(partial_samples.get("VgsProbeSet"), [],
                     "a set that cannot be sampled keeps its tile and draws no icons")
        assert_equal(partial_samples.get(bundled[0]), samples[bundled[0]],
                     "one unreadable set costs its own sample, not every other set's")
        assert_equal((err.getvalue().splitlines() or [""])[0], "icon-theme-samples-unreadable: VgsProbeSet",
                     "the skipped sample names the set it dropped")

    saved = {n: os.environ.get(n) for n in ("XDG_DATA_DIRS", "XDG_DATA_HOME")}
    try:
        with_temp_home(scenario)
    finally:
        for name, value in saved.items():
            _restore_env(name, value)


def test_a_real_icon_set_install_wins_over_the_bundled_copy_and_counts_as_installed():
    """A set installed under any icon_theme_base_dirs() entry suppresses VGS's symlink for
    that name, and the icon-theme hook counts it as installed rather than skipping."""
    def touch(path: Path, text: str = "") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    bundled = sorted(d.name for d in helper.bundled_icons_dir().iterdir() if (d / "index.theme").is_file())
    assert_equal(len(bundled) > 1, True, "config/vshell/icons ships more than one set with an index.theme")
    shadowed, linked_too = bundled[0], bundled[1]

    def scenario(temp_home: Path):
        os.environ["XDG_DATA_HOME"] = str(temp_home / "data-home")
        os.environ["XDG_DATA_DIRS"] = str(temp_home / "data-dir")
        shared = temp_home / "data-dir" / "icons"
        # A real install of one bundled set, on the search path but not in the user
        # directory VGS links into.
        touch(shared / shadowed / "index.theme", "[Icon Theme]\nDirectories=48x48/apps\n")
        touch(shared / "VgsProbeSet" / "index.theme", "[Icon Theme]\nDirectories=48x48/apps\n")

        linked = helper.ensure_bundled_icon_themes()
        user_dir = helper.icon_theme_user_dir()
        assert_equal((user_dir / shadowed).exists(), False,
                     f"the real install of {shadowed} suppresses the bundled symlink, so it is not shadowed")
        assert_equal(shadowed in linked, False, f"{shadowed} is not reported as linked")
        assert_equal(linked_too in linked and (user_dir / linked_too).is_symlink(), True,
                     f"{linked_too}, which nothing else installs, is still linked")

        # The icon-theme hook applies a set installed only under an XDG_DATA_DIRS entry.
        touch(helper.generated_dir() / "icons.theme", "VgsProbeSet\n")
        written = []

        def record(hook, command, **_kwargs):
            written.append(tuple(command))
            return {"hook": hook, "ok": True}

        with patch.object(helper, "_sandboxed_home", return_value=False), \
                patch.object(helper, "load_settings", return_value={}), \
                patch.object(helper.shutil, "which", return_value="/usr/bin/gsettings"), \
                patch.object(helper, "_run_hook_cmd", side_effect=record):
            result = helper.apply_icon_theme_hook({"theme_type": "dark"})
        assert_equal(result.get("reason"), None,
                     "a set on the search path is not reported as not installed")
        assert_equal(written, [("gsettings", "set", "org.gnome.desktop.interface", "icon-theme", "VgsProbeSet")],
                     "the hook writes the set it found on the search path")

    saved = {n: os.environ.get(n) for n in ("XDG_DATA_DIRS", "XDG_DATA_HOME")}
    try:
        with_temp_home(scenario)
    finally:
        for name, value in saved.items():
            _restore_env(name, value)


def test_theme_init_applies_only_without_state():
    """`theme init` applies the default theme when no theme.json exists, and nothing otherwise."""
    def init():
        hooks = []
        buffer = io.StringIO()
        with patch.object(helper, "run_hook", side_effect=lambda hook, roles, bp: hooks.append(hook) or {"hook": hook, "ok": True}), \
                contextlib.redirect_stdout(buffer):
            status = helper.cmd_theme(["init", "--json"])
        assert_equal(status, 0, "theme init exit status")
        return json.loads(buffer.getvalue()), hooks

    def scenario(temp_home: Path):
        state = temp_home / ".config" / "vshell" / "theme.json"
        result, hooks = init()
        assert_equal(result, {"applied": True, "name": helper.DEFAULT_THEME_NAME, "repaired": []},
                     "first run applies the default theme and has nothing to repair")
        assert_equal(json.loads(state.read_text()).get("name"), helper.DEFAULT_THEME_NAME,
                     "first run writes the default theme's state")
        assert_equal("shell-reload" in hooks, True, "the first-run apply runs the theme hooks")
        applied = '{"name": "applied", "mode": "light"}\n'
        state.write_text(applied)
        result, hooks = init()
        assert_equal(result, {"applied": False, "name": "applied", "repaired": []},
                     "an applied theme is left in place, with no wallpaper to repair")
        assert_equal(state.read_text(), applied, "theme init never rewrites an applied theme")
        assert_equal(hooks, [], "theme init runs no hook when a theme is applied")

    with_temp_home(scenario)


def test_lint_checks_color0_in_light_mode_only():
    """ANSI black is body text in a light terminal and unused in a dark one."""
    def warns(mode: str, bg: str, fg: str, color0: str, terminal_color0: str) -> bool:
        colors = {f"color{i}": fg for i in range(16)}
        colors.update({"background": bg, "foreground": fg, "color0": color0, "mode": mode})
        bp = helper.palette_from_colors_map(colors, name="lint-probe", source="curated")
        bp["terminalColors"] = {"color0": terminal_color0} if terminal_color0 else {}
        return any(w["role"].startswith("color0") for w in helper.lint_blueprint(bp))

    for label, mode, bg, fg, color0, terminal_color0, expected in (
        ("light, color0 equal to the background", "light", "#f5e6d3", "#35302a", "#f5e6d3", "", True),
        ("light, a dark color0", "light", "#f5e6d3", "#35302a", "#35302a", "", False),
        ("dark, color0 equal to the background", "dark", "#1a1b26", "#c0caf5", "#1a1b26", "", False),
        ("light, a dark terminal color0 over a background-equal palette color0",
         "light", "#f5e6d3", "#35302a", "#f5e6d3", "#35302a", False),
        ("light, a background-equal terminal color0 over a dark palette color0",
         "light", "#f5e6d3", "#35302a", "#35302a", "#f5e6d3", True),
    ):
        assert_equal(warns(mode, bg, fg, color0, terminal_color0), expected, f"lint color0 warning, {label}")


def test_lint_reports_listed_shortfalls_as_known():
    """A shortfall listed in theme.json is known only while the palette still measures it."""
    def lint(shortfalls):
        colors = {f"color{i}": "#242424" for i in range(16)}
        colors.update({"background": "#d0d0c8", "foreground": "#242424", "accent": "#de6a41", "cursor": "#242424",
                       "selection_background": "#d0d0c8", "selection_foreground": "#242424", "mode": "light"})
        bp = helper.palette_from_colors_map(colors, name="lint-probe", source="curated")
        bp["contrastShortfalls"] = shortfalls
        results = helper.lint_blueprint(bp)
        return ([w["role"] for w in results if not w["known"]], [w["role"] for w in results if w["known"]])

    for label, shortfalls, expected in (
        ("nothing listed", [], (["accent"], [])),
        ("listed at the measured ratio and floor", [{"slot": "accent", "ratio": 2.17, "floor": 3}], ([], ["accent"])),
        ("listed at a ratio the palette does not measure", [{"slot": "accent", "ratio": 2.5, "floor": 3}],
         (["accent", "contrastShortfalls"], [])),
        ("listed for a slot that meets its floor", [{"slot": "color4", "ratio": 2.17, "floor": 3}],
         (["accent", "contrastShortfalls"], [])),
        ("listed at a floor the slot is not judged against", [{"slot": "accent", "ratio": 2.17, "floor": 4.5}],
         (["accent", "contrastShortfalls"], [])),
    ):
        assert_equal(lint(shortfalls), expected, f"lint shortfall list, {label}")

    def scenario(_temp_home: Path):
        results = helper.lint_blueprint(helper.find_theme_exact("thegreek"))
        assert_equal(([w["role"] for w in results if not w["known"]], [w["role"] for w in results if w["known"]]),
                     ([], ["accent", "color4 (blue)", "color12 (bright_blue)"]),
                     "thegreek lints with no warning and its three upstream shortfalls known")

        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            assert_equal(helper.cmd_theme(["lint", "thegreek", "--json"]), 0, "theme lint thegreek --json exit status")
        payload = json.loads(buffer.getvalue())
        assert_equal((payload["count"], payload["warnings"], [w["role"] for w in payload["known"]]),
                     (0, [], ["accent", "color4 (blue)", "color12 (bright_blue)"]),
                     "theme lint thegreek --json counts no warning and lists the known shortfalls")
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            assert_equal(helper.cmd_theme(["lint", "thegreek"]), 0, "theme lint thegreek exit status")
        assert_equal(buffer.getvalue().splitlines(),
                     [f"{payload['name']} ({payload['source']}): no warnings",
                      f"{len(payload['known'])} known upstream shortfall(s):",
                      *[f"  - {w['message']}" for w in payload["known"]]],
                     "theme lint thegreek prints no warning and each known shortfall")

    with_temp_home(scenario)


def test_lint_all_fails_only_on_an_unlisted_warning():
    """`theme lint --all` exits 1 while any theme has an unlisted warning or a package does not load.

    One theme's lint still exits 0."""
    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        for name, accent in (("steady", "#242424"), ("planted", "#de6a41")):
            package = builtin / name
            package.mkdir(parents=True)
            colors = {f"color{i}": "#242424" for i in range(16)}
            colors.update({"background": "#d0d0c8", "foreground": "#242424", "accent": accent, "cursor": "#242424",
                           "selection_background": "#d0d0c8", "selection_foreground": "#242424"})
            (package / "colors.toml").write_text("".join(f'{key} = "{value}"\n' for key, value in colors.items()))
            (package / "theme.json").write_text(json.dumps({"name": name, "mode": "light", "source": "curated"}) + "\n")

        def lint(argv, shortfalls):
            (builtin / "planted" / "theme.json").write_text(json.dumps(
                {"name": "planted", "mode": "light", "source": "curated", "contrastShortfalls": shortfalls}) + "\n")
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(io.StringIO()):
                status = helper.cmd_theme(argv)
            return status, buffer.getvalue()

        listed = [{"slot": "accent", "ratio": 2.17, "floor": 3}]
        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        try:
            for label, shortfalls, expected in (
                ("unlisted", [], (1, 1, [], {"planted": ["accent"], "steady": []})),
                ("listed at the measured ratio", listed, (0, 0, [], {"planted": [], "steady": []})),
            ):
                status, out = lint(["lint", "--all", "--json"], shortfalls)
                payload = json.loads(out)
                assert_equal((status, payload["count"], payload["unloaded"],
                              {theme["name"]: [w["role"] for w in theme["warnings"]] for theme in payload["themes"]}),
                             expected, f"theme lint --all, planted shortfall {label}")
            status, out = lint(["lint", "--all"], [])
            assert_equal((status, sorted(line for line in out.splitlines() if not line.startswith("  - "))),
                         (1, ["planted (curated): 1 warning(s)", "steady (curated): no warnings"]),
                         "theme lint --all prints the report of every theme")
            status, out = lint(["lint", "planted", "--json"], [])
            payload = json.loads(out)
            assert_equal((status, payload["name"], payload["count"]), (0, "planted", 1),
                         "theme lint of one theme reports its unlisted warning and exits 0")
            (builtin / "broken").mkdir()
            (builtin / "broken" / "theme.json").write_text("{not json\n")
            status, out = lint(["lint", "--all", "--json"], listed)
            payload = json.loads(out)
            assert_equal((status, payload["count"], payload["unloaded"], sorted(t["name"] for t in payload["themes"])),
                         (1, 1, ["broken"], ["planted", "steady"]),
                         "theme lint --all counts a package whose theme.json does not read")
        finally:
            helper.builtin_themes_dir = original_builtin

    with_temp_home(scenario)


def test_every_shipped_theme_package_lints_clean():
    """Every shipped package clears the lint floors or lists the shortfall in its theme.json."""
    def scenario(_temp_home: Path):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            status = helper.cmd_theme(["lint", "--all", "--json"])
        payload = json.loads(buffer.getvalue())
        assert_equal((status, {theme["name"]: theme["warnings"] for theme in payload["themes"] if theme["warnings"]}),
                     (0, {}), "theme lint --all over the shipped packages")
        shipped = sorted(path.parent.name for path in helper.builtin_themes_dir().glob("*/theme.json")
                         if path.parent.name not in helper.RESERVED_THEME_SUBDIRS)
        assert_equal(sorted(theme["name"] for theme in payload["themes"]), shipped,
                     "theme lint --all lints every shipped package")

    with_temp_home(scenario)


def test_theme_list_reports_the_preview_and_the_thumbnail_apart():
    """`preview` is the shipped screenshot or a drawn palette card, and the thumbnail is its own field.

    Every theme surface paints `preview`, and nothing in the shell renders one, so
    a theme the list reports no preview for shows "No preview" wherever it appears.
    """
    # Every band of noshot's card is its own colour, so a decoded pixel names its band.
    card_palette = {"background": "#102030", "foreground": "#e0d0c0", "accent": "#c04080",
                    **{f"color{i}": f"#{i * 16 + 8:02x}{255 - i * 16:02x}80" for i in range(16)}}
    # name -> (has its own preview.jpg, extra theme.json fields, user overlay, colors.toml)
    packages = {
        "withshot": (True, {}, False, {"background": "#101010", "foreground": "#eeeeee"}),
        "noshot": (False, {}, False, card_palette),
        "nothumb": (False, {}, False, {"background": "#202020", "foreground": "#eeeeee"}),
        "restyled": (True, {"adjustments": {"brightness": 17}}, False, {"background": "#101010", "foreground": "#eeeeee"}),
        "overlaid": (True, {}, True, {"background": "#101010", "foreground": "#eeeeee"}),
    }

    def colors_toml(colors: dict) -> str:
        return "".join(f'{key} = "{value}"\n' for key, value in colors.items())

    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        thumbnails = builtin / "thumbnails"
        thumbnails.mkdir(parents=True)
        for name, (packaged, extra, overlaid, colors) in packages.items():
            package = builtin / name
            package.mkdir()
            meta = {"name": name, "mode": "dark", "source": "curated"}
            meta.update(extra)
            (package / "theme.json").write_text(json.dumps(meta) + "\n")
            (package / "colors.toml").write_text(colors_toml(colors))
            if packaged:
                (package / helper.THEME_PREVIEW_FILE).write_bytes(b"\xff\xd8\xff screenshot\n")
            if name != "nothumb":
                (thumbnails / f"{name}.jpg").write_bytes(b"\xff\xd8\xff thumbnail\n")
            if overlaid:
                overlay = helper.user_themes_dir() / name
                overlay.mkdir(parents=True)
                (overlay / "app-colors.toml").write_text("[btop]\nfg = \"#ffffff\"\n")
        # A theme the user saved: a package only the user directory holds.
        saved = helper.user_themes_dir() / "saved"
        saved.mkdir(parents=True)
        (saved / "theme.json").write_text(json.dumps({"name": "saved", "mode": "dark", "source": "generated"}) + "\n")
        (saved / "colors.toml").write_text('background = "#303030"\nforeground = "#eeeeee"\n')

        previews = helper.theme_previews_dir()
        previews.mkdir(parents=True)
        orphan = previews / "noshot-000000000000.png"
        orphan.write_bytes(b"\x89PNG stale card\n")

        def list_with_no_tool() -> dict:
            original_builtin = helper.builtin_themes_dir
            helper.builtin_themes_dir = lambda: builtin
            saved_path = os.environ.get("PATH")
            try:
                # No tool on PATH and no Pillow: the card needs neither.
                os.environ["PATH"] = str(temp_home / "empty-path")
                with patch.dict(sys.modules, {"PIL": None, "PIL.Image": None}):
                    return _theme_list_entries()
            finally:
                helper.builtin_themes_dir = original_builtin
                _restore_env("PATH", saved_path)

        listed = list_with_no_tool()

        # A packaged screenshot is the preview, edited or not. A theme with none
        # gets a card drawn from its palette. The thumbnail is reported beside
        # the preview, never in it.
        cards = {name: listed[name]["preview"] for name in ("noshot", "nothumb", "saved")}
        for name, preview, thumbnail in (
            ("withshot", str(builtin / "withshot" / helper.THEME_PREVIEW_FILE), str(thumbnails / "withshot.jpg")),
            ("restyled", str(builtin / "restyled" / helper.THEME_PREVIEW_FILE), str(thumbnails / "restyled.jpg")),
            ("overlaid", str(builtin / "overlaid" / helper.THEME_PREVIEW_FILE), str(thumbnails / "overlaid.jpg")),
            ("noshot", cards["noshot"], str(thumbnails / "noshot.jpg")),
            ("nothumb", cards["nothumb"], ""),
            ("saved", cards["saved"], ""),
        ):
            assert_equal((listed[name]["preview"], listed[name]["thumbnail"]), (preview, thumbnail),
                         f"theme list preview and thumbnail for {name}")
        for name, card in cards.items():
            assert_equal((Path(card).parent, helper.png_size(Path(card))), (previews, helper.PALETTE_CARD_SIZE),
                         f"{name} paints a palette card drawn with no tool")

        # A list prunes the cards no listed theme names.
        assert_equal((all(Path(card).is_file() for card in cards.values()), orphan.exists()), (True, False),
                     "theme list keeps every listed card and removes an orphaned one")

        # Decoded with zlib alone, the card is one filter-0 byte and RGB triples per scanline.
        png = Path(cards["noshot"]).read_bytes()
        idat, pos = b"", 8
        while pos < len(png):
            length = int.from_bytes(png[pos:pos + 4], "big")
            if png[pos + 4:pos + 8] == b"IDAT":
                idat += png[pos + 8:pos + 8 + length]
            pos += 12 + length
        raw = zlib.decompress(idat)
        width, height = helper.PALETTE_CARD_SIZE
        stride = 1 + width * 3
        assert_equal((len(raw), {raw[y * stride] for y in range(height)}), (height * stride, {0}),
                     "the noshot card decodes to unfiltered RGB scanlines")
        for band, x, y, key in (("background", 4, 4, "background"), ("foreground bar", 40, 50, "foreground"),
                                ("accent bar", 40, 74, "accent"), ("first swatch", 40, 130, "color0"),
                                ("ninth swatch", 40, 230, "color8")):
            offset = y * stride + 1 + x * 3
            assert_equal("#" + raw[offset:offset + 3].hex(), card_palette[key], f"the noshot card paints its {band}")

        # A colour edit draws a new card, and the next list prunes the old one.
        (builtin / "noshot" / "colors.toml").write_text(colors_toml({**card_palette, "background": "#302010"}))
        redrawn = list_with_no_tool()["noshot"]["preview"]
        assert_equal((redrawn != cards["noshot"], Path(redrawn).is_file(), Path(cards["noshot"]).exists()),
                     (True, True, False), "a colour edit draws a new noshot card and prunes the old one")

    with_temp_home(scenario)


def test_theme_list_reports_installed_wallpapers_and_the_star():
    """`installed` says wallpapers are on disk, and a star is stored without reading as an edit.

    The switcher offers a download for a theme that is not installed, and lists
    starred themes under Starred. A star that read as an edit would raise the
    modified badge and drop the theme's shipped screenshot.
    """
    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        for name, background in (("bare", False), ("pictured", True)):
            package = builtin / name
            package.mkdir(parents=True)
            (package / "theme.json").write_text(json.dumps({"name": name, "mode": "dark", "source": "curated"}) + "\n")
            (package / "colors.toml").write_text('background = "#101010"\nforeground = "#eeeeee"\n')
            (package / helper.THEME_PREVIEW_FILE).write_bytes(b"\xff\xd8\xff screenshot\n")
            if background:
                (package / "backgrounds").mkdir()
                (package / "backgrounds" / "1.jpg").write_bytes(b"\xff\xd8\xff wallpaper\n")
        downloaded = helper.user_themes_dir() / "bare" / "backgrounds"

        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        try:
            listed = _theme_list_entries()
            assert_equal((listed["bare"]["installed"], listed["pictured"]["installed"]), (False, True),
                         "a definition-only theme is not installed and a theme with wallpapers is")
            downloaded.mkdir(parents=True)
            (downloaded / "1.jpg").write_bytes(b"\xff\xd8\xff downloaded\n")
            assert_equal(_theme_list_entries()["bare"]["installed"], False,
                         "a wallpaper copied into the user directory, with no download marker, does not install the theme")
            shutil.rmtree(helper.user_themes_dir() / "bare")

            overlay = helper.user_themes_dir() / "pictured"
            shipped = str(builtin / "pictured" / helper.THEME_PREVIEW_FILE)
            for verb, starred, overlay_files in (("star", True, ["theme.json"]), ("unstar", False, None)):
                with contextlib.redirect_stdout(io.StringIO()):
                    assert_equal(helper.cmd_theme([verb, "pictured", "--json"]), 0, f"theme {verb} exit status")
                entry = _theme_list_entries()["pictured"]
                assert_equal((entry["starred"], entry["modified"], entry["preview"]), (starred, False, shipped),
                             f"theme {verb} sets the star without reading as an edit")
                assert_equal(_user_files(overlay) if overlay.is_dir() else None, overlay_files,
                             f"theme {verb} leaves only the star in the overlay")

            # Revert drops an edit and keeps the star.
            with contextlib.redirect_stdout(io.StringIO()):
                helper.cmd_theme(["star", "pictured"])
            (overlay / "app-colors.toml").write_text('[btop]\nfg = "#ffffff"\n')
            assert_equal(_theme_list_entries()["pictured"]["modified"], True, "an edit beside a star reads as an edit")
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["revert", "pictured"]), 0, "theme revert exit status")
            entry = _theme_list_entries()["pictured"]
            assert_equal((entry["starred"], entry["modified"]), (True, False), "revert keeps the star and drops the edit")

            # A copy is a theme the user has not filed yet.
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["duplicate", "pictured", "--as", "pictured-copy"]), 0,
                             "theme duplicate exit status")
            assert_equal(_theme_list_entries()["pictured-copy"]["starred"], False,
                         "a copy of a starred theme starts unstarred")

            # A star and an unstar change the star alone, never an edit beside it.
            helper.write_user_layer("pictured", "theme.json",
                                    {**helper.read_theme_overlay_meta("pictured"), "adjustments": {"brightness": 17}})
            for verb, starred in (("star", True), ("unstar", False)):
                with contextlib.redirect_stdout(io.StringIO()):
                    assert_equal(helper.cmd_theme([verb, "pictured"]), 0, f"theme {verb} exit status over adjustments")
                entry = _theme_list_entries()["pictured"]
                assert_equal((entry["starred"], entry["adjustments"]["brightness"], overlay.is_dir()),
                             (starred, 17, True), f"theme {verb} keeps the restyle adjustments in the overlay")
        finally:
            helper.builtin_themes_dir = original_builtin

    with_temp_home(scenario)


def test_hyprland_preview_native_lua():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "apps.json").write_text(json.dumps([{
            "slot": "nvim",
            "env": {"VGS_PREVIEW_NAME": "Test Theme"},
            "cmd": ["ghostty", "--class=vgs.preview.nvim", "-e", "printf", "%s", "hello world"],
        }]))
        config = helper.preview_hyprland_config(
            {"name": "Test Theme"},
            {"accent": "#7aa2f7", "outline": "#444444", "background": "#101010"},
            root,
            {"theme_json": root / "theme.json"},
            (1600, 900),
        )
        assert_equal(config.name, "hyprland.lua", "preview config extension")
        rendered = config.read_text()
        for expected in (
            "hl.monitor({",
            'mode = "1600x900@60"',
            'hl.on("hyprland.start", function()',
            "hl.exec_cmd(",
            "float = true",
            "no_anim = true",
            "move = {20, 70}",
            "size = {780, 810}",
        ):
            if expected not in rendered:
                raise AssertionError(f"Hyprland preview config should contain {expected!r}")
        for legacy in ("exec-once =", "misc {", "monitor="):
            if legacy in rendered:
                raise AssertionError(f"Hyprland preview config retained legacy syntax {legacy!r}")
        verify_hyprland_config(config, "preview")


def verify_hyprland_config(config: Path, what: str) -> None:
    """Hyprland's own Lua config manager must accept a generated config."""
    hyprland = shutil.which("Hyprland")
    if hyprland is None:
        raise AssertionError(f"Hyprland not installed: the generated {what} Lua cannot be verified")
    # --verify-config aborts without a runtime directory. A private one keeps
    # the check off the live session's and makes it independent of the runner.
    with tempfile.TemporaryDirectory() as runtime:
        verified = subprocess.run(
            [hyprland, "--verify-config", "--config", str(config)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            env={**os.environ, "XDG_RUNTIME_DIR": runtime},
        )
    if verified.returncode != 0:
        raise AssertionError(
            f"Hyprland rejected generated {what} Lua: "
            + (verified.stderr or verified.stdout).strip()
        )


def test_preview_stage_retires_its_window_rule():
    """The staging window rule matches every nested Hyprland window, so it must not outlive the stage."""
    register = ["hyprctl", "eval", helper.PREVIEW_STAGE_ON_LUA]
    retire = ["hyprctl", "eval", helper.PREVIEW_STAGE_OFF_LUA]
    # A pre-Lua session takes a keyword rule, which only a config reload clears.
    reload = ["hyprctl", "reload"]
    remove = ["hyprctl", "output", "remove", helper.PREVIEW_OUTPUT]

    # label; whether `hyprctl eval` runs Lua; exit status of `hyprctl output create
    # headless`; the hyprctl subcommand a stop signal interrupts, or None; whether the
    # preview stages its output; the request that retires the rule.
    # The rule is registered before the output is created, so a refused output still retires it.
    for label, lua, create_status, stop_at, staged_expected, retirement in (
        ("a compositor that accepts every request", True, 0, None, True, retire),
        ("a compositor that refuses the headless output", True, 1, None, False, retire),
        ("a pre-Lua compositor that refuses the headless output", False, 1, None, False, reload),
        # The output exists by then but is not yet sized, so the stage is not handed over.
        ("a stop signal while the stage sizes its output", True, 0, "getoption", True, retire),
    ):
        calls = []

        def fake_run(argv, **_kwargs):
            calls.append(list(argv))
            if argv[1] == stop_at:
                raise SystemExit(128 + signal.SIGTERM)
            stdout = "ok"
            if argv[1] == "eval" and not lua:
                stdout = "eval is only supported with the lua config manager"
            elif argv[1:] == ["cursorpos"]:
                stdout = "0, 0"
            elif argv[1:] == ["monitors", "-j"]:
                # A reserved bar strip, so the stage does not wait out preview_stage_reserved.
                stdout = json.dumps([{"name": helper.PREVIEW_OUTPUT, "reserved": [0, 32, 0, 0]}])
            elif argv[-1] == "-j":
                stdout = "{}" if argv[1] == "getoption" else "[]"
            status = create_status if argv[1:3] == ["output", "create"] else 0
            return subprocess.CompletedProcess(argv, status, stdout, "")

        with patch.object(helper, "run", fake_run), \
             patch.object(helper.shutil, "which", lambda name: "/usr/bin/hyprctl" if name == "hyprctl" else None), \
             patch.dict(os.environ, {"HYPRLAND_INSTANCE_SIGNATURE": "check-vshell-helper"}):
            stopped = False
            try:
                with helper.preview_stage() as (staged, _reassert):
                    assert_equal(staged, staged_expected, f"{label}: stages the preview")
                    assert_equal(register in calls, True, f"{label}: the stage registers its window rule")
                    # A capture needs the rule for as long as its nested session is mapped.
                    assert_equal(retirement in calls, False, f"{label}: the window rule must stay enabled while the stage is up")
            except SystemExit:
                stopped = True
        assert_equal(stopped, stop_at is not None, f"{label}: the stage ends early only on a stop signal")
        teardown = calls[calls.index(register):]
        assert_equal(retirement in teardown, True, f"{label}: the teardown must retire its window rule")
        if staged_expected:
            assert_equal(remove in teardown, True, f"{label}: the teardown must remove the staging output")


# A parent compositor for a preview capture: logs each argv as a JSON line and answers the
# staging requests. Its one monitor is the staging output with a bar strip reserved, so
# the stage does not wait out preview_stage_reserved.
PREVIEW_STOP_HYPRCTL = """
import json, os, sys
args = sys.argv[1:]
with open(os.environ["PREVIEW_HYPRCTL_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:1] == ["eval"]:
    print("ok")
elif args == ["cursorpos"]:
    print("0, 0")
elif args == ["monitors", "-j"]:
    print(json.dumps([{"name": os.environ["PREVIEW_OUTPUT"], "reserved": [0, 32, 0, 0]}]))
elif args[-1:] == ["-j"]:
    print("{}" if args[0] == "getoption" else "[]")
"""


def test_theme_preview_stop_signal_tears_down_its_capture():
    """SIGTERM during scripts/capture-theme-previews.py ends the nested Hyprland, retires
    the staging rule and removes the staging output from the maintainer's compositor."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        stubs = root / "bin"
        stubs.mkdir()
        hyprctl_log = root / "hyprctl.log"
        nested_pid = root / "nested.pid"
        preview_tmp = root / "tmp"
        preview_tmp.mkdir()
        (stubs / "hyprctl").write_text(f"#!{sys.executable}\n{PREVIEW_STOP_HYPRCTL}")
        # The nested session records its pid once it is up, then runs until it is stopped.
        (stubs / "Hyprland").write_text(
            '#!/bin/sh\necho $$ > "$PREVIEW_NESTED_PID.new"\nmv "$PREVIEW_NESTED_PID.new" "$PREVIEW_NESTED_PID"\nexec sleep 300\n')
        for tool in ("ghostty", "nvim", "grim"):
            (stubs / tool).write_text("#!/bin/sh\nexit 0\n")
        for stub in stubs.iterdir():
            stub.chmod(0o755)
        home = root / "home"
        # A current theme on disk, so resolving the preview wallpaper never applies one.
        (home / ".config" / "vshell").mkdir(parents=True)
        (home / ".config" / "vshell" / "theme.json").write_text(json.dumps({"name": "bauhaus", "wallpaper": ""}))

        env = os.environ.copy()
        env.pop("VGS_PREVIEW_KEEP", None)
        env.update({
            "PATH": f"{stubs}{os.pathsep}{env.get('PATH', '')}",
            "HOME": str(home),
            # The user site derives from HOME; keep the caller's, where CI installs Pillow.
            "PYTHONUSERBASE": site.getuserbase(),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "TMPDIR": str(preview_tmp),
            # No real session answers this, should a real hyprctl ever run.
            "HYPRLAND_INSTANCE_SIGNATURE": "check-vshell-helper",
            "PREVIEW_HYPRCTL_LOG": str(hyprctl_log),
            "PREVIEW_NESTED_PID": str(nested_pid),
            "PREVIEW_OUTPUT": helper.PREVIEW_OUTPUT,
        })
        preview = subprocess.Popen(
            [sys.executable, str(REPO_ROOT / "scripts" / "capture-theme-previews.py"), "bauhaus"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        pid = None
        try:
            deadline = time.monotonic() + 60
            while pid is None and preview.poll() is None and time.monotonic() < deadline:
                if nested_pid.exists():
                    pid = int(nested_pid.read_text())
                else:
                    time.sleep(0.1)
            if pid is None:
                preview.kill()
                _out, err = preview.communicate()
                raise AssertionError(f"the preview never started its nested Hyprland (exit {preview.returncode}): {err.strip()}")
            preview.send_signal(signal.SIGTERM)
            _out, err = preview.communicate(timeout=30)
            nested_alive = helper._pid_alive(pid)
        finally:
            if preview.poll() is None:
                preview.kill()
                preview.wait()
            if pid is not None:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)

        assert_equal(preview.returncode, 128 + signal.SIGTERM, f"a stopped preview exits through its teardown: {err.strip()}")
        assert_equal(nested_alive, False, "the nested Hyprland must not outlive the preview")
        assert_equal(sorted(p.name for p in preview_tmp.iterdir()), [], "the preview removes its temp directory")
        calls = [json.loads(line) for line in hyprctl_log.read_text().splitlines()]
        register = ["eval", helper.PREVIEW_STAGE_ON_LUA]
        assert_equal(register in calls, True, "the preview registers its staging rule")
        # Every capture reasserts the rule, so the teardown follows the last registration.
        teardown = calls[len(calls) - 1 - calls[::-1].index(register):]
        assert_equal(["eval", helper.PREVIEW_STAGE_OFF_LUA] in teardown, True, "a stopped preview retires its staging rule")
        assert_equal(["output", "remove", helper.PREVIEW_OUTPUT] in teardown, True, "a stopped preview removes its staging output")


# A fake `hl` whose window_rule counts registrations and live rules. Its arguments are the
# ON and OFF staging Lua, then the steps to run; each step prints the counts it leaves.
PREVIEW_STAGE_LUA_DRIVER = r"""
local registered, live = 0, 0
hl = { workspace_rule = function() end }
function hl.window_rule()
  registered, live = registered + 1, live + 1
  local rule = { enabled = true }
  function rule:set_enabled(on)
    if self.enabled ~= on then live = live + (on and 1 or -1) end
    self.enabled = on
  end
  return rule
end
local compile = loadstring or load
local stage = { on = assert(compile(arg[1])), off = assert(compile(arg[2])) }
for i = 3, #arg do
  stage[arg[i]]()
  print(arg[i] .. " " .. registered .. " " .. live)
end
"""


def test_preview_stage_rule_tiles_the_capture_window():
    """The staging rule tiles the nested window, whatever float rule the user's config gives its class.

    A floated capture window takes the size a user rule names instead of the
    staging output's, and the capture comes out smaller than PREVIEW_SIZE.
    """
    lua = shutil.which("lua")
    if lua is None:
        raise AssertionError("lua not installed: the preview staging Lua cannot run")
    driver = r"""
hl = { workspace_rule = function() end }
function hl.window_rule(spec)
  print(tostring(spec.float) .. " " .. tostring(spec.fullscreen_state) .. " " .. spec.workspace)
  return { set_enabled = function() end }
end
assert((loadstring or load)(arg[1]))()
"""
    result = subprocess.run([lua, "-", helper.PREVIEW_STAGE_ON_LUA], input=driver, text=True,
                            capture_output=True, timeout=10)
    assert_equal((result.returncode, result.stdout.strip()), (0, "false 2 name:vgspreview silent"),
                 f"the staging window rule under {lua}: {result.stderr.strip()}")
    assert_equal(helper.PREVIEW_WINDOW_RULE_LEGACY_TILE.split(",")[0], "tile",
                 "the pre-Lua staging rules tile the capture window too")


def test_preview_stage_lua_keeps_one_live_rule():
    """A stage holds one live window rule, its teardown leaves none, and the next stage registers afresh."""
    lua = shutil.which("lua")
    if lua is None:
        raise AssertionError("lua not installed: the preview staging Lua cannot run, so no check sees it retire its window rule")
    # A stage and its reassert, a teardown and a repeated one, then the next stage and its
    # teardown; each row is the step and the registrations and live rules it leaves.
    steps = (("on", 1, 1), ("on", 1, 1), ("off", 1, 0), ("off", 1, 0), ("on", 2, 1), ("off", 2, 0))
    result = subprocess.run(
        [lua, "-", helper.PREVIEW_STAGE_ON_LUA, helper.PREVIEW_STAGE_OFF_LUA, *(step for step, _, _ in steps)],
        input=PREVIEW_STAGE_LUA_DRIVER, text=True, capture_output=True, timeout=10,
    )
    assert_equal(result.returncode, 0, f"the staging Lua under {lua}: {result.stderr.strip()}")
    rows = result.stdout.splitlines()
    assert_equal(len(rows), len(steps), "one printed row per driven step")
    for index, ((step, registered, live), row) in enumerate(zip(steps, rows), 1):
        assert_equal(row, f"{step} {registered} {live}", f"step {index} ({step}): registrations and live rules")


def test_greeter_primary_monitor_validation():
    with tempfile.TemporaryDirectory() as tmp:
        cache = Path(tmp)
        (cache / "settings.json").write_text(json.dumps({"greeterPrimaryMonitor": "DP-1"}))
        assert_equal(helper.greeter_primary_monitor(cache), "DP-1",
                     "valid greeter primary monitor")
        rendered = helper.render_hyprland_greeter_config(
            "/usr/bin/qs -p /var/cache/vshell-greeter/runtime/quickshell/vshell",
            cache,
            {"XCURSOR_THEME": "Adwaita"},
        )
        for expected in (
            'hl.env("VSHELL_RUN_GREETER", "1")',
            'hl.env("XCURSOR_THEME", "Adwaita")',
            'cursor = {\n    default_monitor = "DP-1",\n  },',
            'hl.on("hyprland.start", function()',
            "hl.exec_cmd(",
        ):
            if expected not in rendered:
                raise AssertionError(f"Hyprland greeter config should contain {expected!r}")
        for legacy in ("exec-once =", "misc {", "env = "):
            if legacy in rendered:
                raise AssertionError(f"Hyprland greeter config retained legacy syntax {legacy!r}")
        config = cache / "greeter.lua"
        config.write_text(rendered)
        verify_hyprland_config(config, "greeter")

        (cache / "settings.json").write_text(json.dumps({
            "greeterPrimaryMonitor": "DP-1\nexec-once = unsafe",
        }))
        assert_equal(helper.greeter_primary_monitor(cache), "",
                     "greeter primary monitor config injection guard")

        (cache / "settings.json").write_text("{}")
        assert_equal(helper.greeter_primary_monitor(cache), "",
                     "automatic greeter primary monitor")


def test_helper_import_loads_no_image_or_http_stack():
    """Every helper call imports the helper module, and most decode no image and fetch nothing.

    Pillow or urllib.request loaded at import would add its load time to every call.
    """
    probe = (
        "import json, sys; sys.path.insert(0, sys.argv[1]); import vshell_helper; "
        "print(json.dumps(sorted(name for name in ('PIL', 'urllib.request') if name in sys.modules)))"
    )
    with tempfile.TemporaryDirectory() as home:
        result = subprocess.run(
            [sys.executable, "-c", probe, str(REPO_ROOT / "bin")],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home},
        )
    assert_equal((result.returncode, result.stdout.strip()), (0, "[]"),
                 f"importing the helper module loads no Pillow or urllib.request: {result.stderr}")


def test_helper_entrypoint_runs_the_helper():
    """Both the stub and the module reach main when run as a script.

    A run that loads the code and exits 0 would let a sudo re-exec report success
    having changed nothing, whichever of the two paths a caller spawns.
    """
    rows = (
        ("stub", helper.helper_entrypoint()),
        ("module", HELPER_PATH),
    )
    for label, script in rows:
        with tempfile.TemporaryDirectory() as home:
            result = subprocess.run(
                [sys.executable, str(script), "no-such-command"],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
                env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home},
            )
        assert_equal(result.returncode, 2, f"the helper {label} refuses an unknown command: {result.stderr}")


def test_greeter_runtime_helper_dependencies():
    with tempfile.TemporaryDirectory() as tmp:
        runtime_bin = Path(tmp) / "runtime" / "bin"
        helper.sync_greeter_runtime_bin(runtime_bin)
        expected = set(helper.GREETER_RUNTIME_BIN_FILES)
        actual = {path.name for path in runtime_bin.iterdir()}
        assert_equal(actual, expected, "cached greeter runtime files")
        result = subprocess.run(
            [str(runtime_bin / "vshell-helper"), "greeter", "run", "--help"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(
                "cached greeter helper must load with its copied Python modules:\n"
                f"{result.stderr}"
            )


def test_greeter_sync_survives_a_missing_wallpaper():
    """A configured greeter wallpaper that is not there must not stop the sync.

    The greeter is the path between a powered machine and a logged-in session, so
    a missing image removes the override and records the reason instead of raising.
    """
    def scenario(tmp: Path):
        cache = tmp / "greeter-cache"
        target = cache / "users" / "tester"
        target.mkdir(parents=True)
        override = target / "greeter_wallpaper_override"
        override.write_bytes(b"stale override")
        present = tmp / "present.jpg"
        present.write_bytes(b"wallpaper bytes")

        original_load = helper.load_settings
        original_theme = helper.current_theme_json
        original_session = helper.current_session_json
        original_eprint = helper.eprint
        said = []
        helper.eprint = said.append
        helper.current_theme_json = lambda: {"name": "bauhaus"}
        helper.current_session_json = lambda theme: {"name": "bauhaus"}
        try:
            # Both sync paths share this one decision, so testing it once covers
            # the privileged copy, which needs root and cannot run here.
            published = []
            assert_equal(helper.publish_greeter_wallpaper(str(present), override, published.append),
                         "", "a present wallpaper reports nothing missing")
            assert_equal(published, [present], "a present wallpaper is published")
            assert_equal(helper.publish_greeter_wallpaper(str(tmp / "gone.jpg"), override,
                                                          published.append),
                         str(tmp / "gone.jpg"), "a missing wallpaper is named to the caller")
            assert_equal(len(published), 1, "a missing wallpaper is never published")
            assert_equal(any(str(tmp / "gone.jpg") in line and "built-in background" in line
                             for line in said), True,
                         "the reason is printed, not only recorded in the manifest")
            assert_equal(helper.publish_greeter_wallpaper("", override, published.append),
                         "", "no configured wallpaper is not a missing one")
            # A relative configured path resolves against the working directory,
            # so the reason names the file that was actually looked for.
            original_cwd = os.getcwd()
            os.chdir(tmp)
            try:
                assert_equal(helper.publish_greeter_wallpaper("present.jpg", override,
                                                              published.append),
                             "", "a relative path that resolves is published")
                assert_equal(helper.publish_greeter_wallpaper("nowhere/gone.jpg", override,
                                                              published.append),
                             str(Path(tmp) / "nowhere" / "gone.jpg"),
                             "a relative missing path is reported as the absolute one searched")
            finally:
                os.chdir(original_cwd)
            override.write_bytes(b"stale override")

            helper.load_settings = lambda: {"greeterWallpaperPath": str(tmp / "gone.jpg")}
            helper.sync_profile_cache_unprivileged(cache, "tester")
            manifest = json.loads((target / "sync-manifest.json").read_text())
            assert_equal(manifest.get("greeterWallpaperMissing"), str(tmp / "gone.jpg"),
                         "a missing greeter wallpaper is named in the sync manifest")
            assert_equal(override.exists(), False,
                         "a missing greeter wallpaper removes the stale override")

            helper.load_settings = lambda: {"greeterWallpaperPath": str(present)}
            helper.sync_profile_cache_unprivileged(cache, "tester")
            manifest = json.loads((target / "sync-manifest.json").read_text())
            assert_equal("greeterWallpaperMissing" in manifest, False,
                         "a present wallpaper records no missing-wallpaper reason")
            assert_equal(override.read_bytes(), b"wallpaper bytes", "the override carries the configured image")
        finally:
            helper.load_settings = original_load
            helper.current_theme_json = original_theme
            helper.current_session_json = original_session
            helper.eprint = original_eprint

    with_temp_home(scenario)


def test_launcher_search_unicode_ranges_and_preview():
    line = "📦 café ComponentBehavior"
    match = "ComponentBehavior"
    byte_start = line.encode("utf-8").index(match.encode("utf-8"))
    utf16_start = helper._utf8_byte_offset_to_utf16(line, byte_start)
    utf16_end = helper._utf8_byte_offset_to_utf16(line, byte_start + len(match))
    encoded = line.encode("utf-16-le")
    assert_equal(
        encoded[utf16_start * 2:utf16_end * 2].decode("utf-16-le"),
        match,
        "ripgrep byte offsets map to QML UTF-16 offsets",
    )

    ranges = helper._launcher_literal_match_ranges(line, "café")
    assert_equal(len(ranges), 1, "preview match count")
    highlighted = encoded[ranges[0]["start"] * 2:ranges[0]["end"] * 2].decode("utf-16-le")
    assert_equal(highlighted, "café", "preview UTF-16 match range")

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "unicode-preview.txt"
        path.write_text(line + "\n", encoding="utf-8")
        preview = helper._launcher_preview(path, 20, query=match)
        assert_equal(preview["ok"], True, "launcher preview succeeds")
        preview_range = preview["submatches"][0]
        preview_encoded = preview["text"].encode("utf-16-le")
        assert_equal(
            preview_encoded[preview_range["start"] * 2:preview_range["end"] * 2].decode("utf-16-le"),
            match,
            "preview range selects the requested Unicode-safe match",
        )

        (Path(tmp) / "dev").mkdir()
        (Path(tmp) / "Desktop").mkdir()
        old_home = os.environ.get("HOME")
        os.environ["HOME"] = tmp
        try:
            folder_hits = helper._launcher_folder_path_hits(
                "~/de", [Path(tmp)], [], 10
            )
        finally:
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home
        assert_equal(folder_hits[0]["name"], "dev", "folder completion ranks closest prefix first")
        assert_equal(folder_hits[0]["completion"], "~/dev/", "folder completion preserves tilde path")


def test_instance_listing():
    """The listing holds live shells of this entrypoint, oldest first, and reports an unreadable registry."""
    shell_path = str(REPO_ROOT / "quickshell" / "vshell" / "shell.qml")
    session = {
        "pid": 100,
        "id": "aaa",
        "shell_id": "shell-1",
        "config_path": shell_path,
        "launch_time": "2026-08-01T10:00:00",
    }
    younger = {
        "pid": 200,
        "id": "bbb",
        "shell_id": "shell-1",
        "config_path": shell_path,
        "launch_time": "2026-08-01T12:00:00",
    }
    other_app = {
        "pid": 300,
        "id": "ccc",
        "shell_id": "other",
        "config_path": "/home/someone/.config/quickshell/other/shell.qml",
        "launch_time": "2026-07-01T00:00:00",
    }

    original_list = helper.qs_list_instances
    # _vgs_peer_alive confirms a pid is a live Quickshell process; these
    # synthetic pids are not, so liveness is supplied by the fixture.
    original_alive = helper._vgs_peer_alive
    alive = {100, 200, 300}
    helper._vgs_peer_alive = lambda pid: pid in alive
    try:
        def listed(entries):
            helper.qs_list_instances = lambda: {"ok": True, "instances": entries}
            return [entry["pid"] for entry in helper.vgs_instance_report(shell_path)["instances"]]

        assert_equal(listed([]), [], "an empty registry lists no shells")
        assert_equal(listed([younger, other_app, session]), [100, 200],
                     "shells of this entrypoint list oldest first; other Quickshell applications are never listed")
        alive = {200, 300}
        assert_equal(listed([younger, session]), [200], "a registry entry whose process is gone is not listed")
        alive = {100, 200, 300}
        assert_equal(listed([{**session, "launch_time": ""}, younger]), [200, 100],
                     "an entry with no launch time lists last")

        helper.qs_list_instances = lambda: {"ok": False, "error": "qs missing", "instances": []}
        report = helper.vgs_instance_report(shell_path)
        assert_equal(report["ok"], False, "an unreadable registry is reported")
        assert_equal(report["error"], "qs missing", "the registry error is carried through")
    finally:
        helper.qs_list_instances = original_list
        helper._vgs_peer_alive = original_alive


def test_launcher_folder_opener_agreement():
    # The advertised opener list is what Settings offers the user, so every entry
    # in it must actually launch. Probe every combination of the binaries the two
    # functions look at rather than restating either one's condition: the invariant
    # under test is that they agree, not what either of them happens to check.
    binaries = ["yazi", "gio"]
    original_which = helper.shutil.which
    original_popen = helper.subprocess.Popen
    original_candidates = helper.terminal_candidates
    original_manager = helper.file_manager

    class _LiveTerminal:
        """A spawned terminal that is still running when the settle window ends."""

        returncode = None

        def wait(self, timeout=None):
            raise helper.subprocess.TimeoutExpired("terminal", timeout)

    # Both the file manager the user configured and whether it is a TUI matter:
    # a terminal file manager advertised without a terminal opens nothing.
    managers = [
        {},
        {"argv": ["nautilus"], "name": "Files", "terminal": False, "source": "xdg-mime", "entry": ""},
        {"argv": ["yazi"], "name": "Yazi", "terminal": True, "source": "xdg-mime", "entry": ""},
    ]

    with tempfile.TemporaryDirectory() as tmp:
        for mask in range(1 << len(binaries)):
            for has_terminal in (False, True):
                for manager in managers:
                    present = {name for index, name in enumerate(binaries) if mask & (1 << index)}
                    present.update(manager.get("argv", [])[:1])
                    # Accept the absolute form too: _launcher_open_folder()
                    # re-checks command[0], which by then is the resolved path.
                    helper.shutil.which = lambda name, _p=present: (
                        f"/usr/bin/{os.path.basename(name)}" if os.path.basename(name) in _p else None
                    )
                    helper.subprocess.Popen = lambda *a, **k: _LiveTerminal()
                    helper.terminal_candidates = lambda prefer=None, _t=has_terminal: [["kitty"]] if _t else []
                    helper.file_manager = lambda _m=manager: dict(_m)
                    state = f"binaries={sorted(present)} terminal={has_terminal} fm={manager.get('name')}"
                    try:
                        for opener in helper._launcher_folder_openers():
                            if opener["id"] == "default":
                                # "Preferred app" is always offered and falls
                                # through to `gio open`; it is not probe-gated,
                                # so it is not a claim about an installed binary
                                # the way the others are.
                                continue
                            result = helper._launcher_open_folder(tmp, "", opener["id"])
                            assert_equal(
                                result.get("ok"), True,
                                f"advertised opener {opener['id']!r} must launch with {state}"
                                f" (got {result.get('error')!r})",
                            )
                    finally:
                        helper.shutil.which = original_which
                        helper.subprocess.Popen = original_popen
                        helper.terminal_candidates = original_candidates
                        helper.file_manager = original_manager


def test_launcher_zoxide_results():
    original_which = helper.shutil.which
    original_run = helper.subprocess.run
    helper.shutil.which = lambda command: "/usr/bin/zoxide" if command == "zoxide" else original_which(command)
    with tempfile.TemporaryDirectory() as tmp:
        first = Path(tmp) / "frequent"
        second = Path(tmp) / "recent"
        first.mkdir()
        second.mkdir()
        helper.subprocess.run = lambda *args, **kwargs: subprocess.CompletedProcess(
            args[0], 0, stdout=f" 42.0 {first}\n 7.5 {second}\n", stderr=""
        )
        try:
            hits = helper._launcher_zoxide_hits("", 10)
        finally:
            helper.shutil.which = original_which
            helper.subprocess.run = original_run
    assert_equal([hit["name"] for hit in hits], ["frequent", "recent"], "zoxide result order")
    assert_equal(hits[0]["zoxide_score"], 42.0, "zoxide score parsing")


def test_sudo_toggle_dropin_lifecycle():
    """Exercise the privileged drop-in writer against a temp dir (no sudo).

    The real path is /etc/sudoers.d, which needs root; the function takes the
    drop-in path so the enable/validate/disable logic is testable unprivileged.
    """
    visudo = shutil.which("visudo")
    with tempfile.TemporaryDirectory() as tmp:
        dropin = Path(tmp) / "50-tester-nopasswd-toggle"

        ok, message = helper.sudo_toggle_apply(dropin, "tester", True, visudo)
        if visudo is None:
            assert_equal(ok, False, "Enable without visudo must refuse")
            assert_equal(dropin.exists(), False, "Refused enable must leave no drop-in")
            return
        assert_equal(ok, True, f"Enable must succeed: {message}")
        assert_equal(dropin.read_text(), "tester ALL=(ALL) NOPASSWD: ALL\n",
                     "Drop-in content must be the NOPASSWD rule for the named user")
        assert_equal(oct(dropin.stat().st_mode & 0o777), "0o440",
                     "Drop-in must be mode 0440")
        assert_equal(sorted(p.name for p in Path(tmp).iterdir()), [dropin.name],
                     "Enable must leave no staging file behind")

        ok, _ = helper.sudo_toggle_apply(dropin, "tester", True, visudo)
        assert_equal(ok, True, "Re-enable must be idempotent")

        ok, _ = helper.sudo_toggle_apply(dropin, "tester", False, visudo)
        assert_equal(ok, True, "Disable must succeed")
        assert_equal(dropin.exists(), False, "Disable must remove the drop-in")

        ok, _ = helper.sudo_toggle_apply(dropin, "tester", False, visudo)
        assert_equal(ok, True, "Disable on an absent drop-in must be a no-op")

        bad, message = helper.sudo_toggle_apply(dropin, "not a valid user spec !!", True, visudo)
        assert_equal(bad, False, "visudo must reject a malformed user spec")
        assert_equal(dropin.exists(), False, "Rejected candidate must not be installed")
        assert_equal(sorted(p.name for p in Path(tmp).iterdir()), [],
                     "Rejected candidate must leave no staging file behind")

        link = Path(tmp) / "50-link-nopasswd-toggle"
        link.symlink_to(Path(tmp) / "elsewhere")
        ok, message = helper.sudo_toggle_apply(link, "tester", True, visudo)
        assert_equal(ok, False, "Symlinked drop-in path must be refused")
        assert_equal((Path(tmp) / "elsewhere").exists(), False,
                     "Refused symlink must not write through to the target")


def test_sudo_toggle_status_reads_flag_mirror():
    """Unprivileged status comes from the state mirror, old path included."""
    def check(home_path: Path):
        flag = home_path / ".local" / "state" / "vshell" / "sudo-passwordless-toggle"
        legacy = home_path / ".local" / "state" / "sudo-passwordless-toggle"
        status = helper.sudo_toggle_status("tester", probe_sudo=False)
        assert_equal(status["enabled"], False, "Absent flag must read as disabled")
        assert_equal(status["flag"], str(flag), "Status must report the mirror path")
        assert_equal(status["dropin"], "/etc/sudoers.d/50-tester-nopasswd-toggle",
                     "Status must report the drop-in path for the named user")

        flag.parent.mkdir(parents=True, exist_ok=True)
        flag.touch()
        assert_equal(helper.sudo_toggle_status("tester", probe_sudo=False)["enabled"], True,
                     "Present flag must read as enabled")
        flag.unlink()

        # The fixture includes the legacy state-mirror path.
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.touch()
        assert_equal(helper.sudo_toggle_status("tester", probe_sudo=False)["enabled"], True,
                     "Legacy mirror path must still read as enabled (migration)")
        legacy.unlink()

        available, reason = helper.sudo_toggle_availability()
        expected = bool(shutil.which("sudo") and shutil.which("visudo")
                        and Path("/etc/sudoers.d").is_dir())
        assert_equal(available, expected,
                     "Availability must reflect the actual sudo/visudo/sudoers.d probe")
        assert_equal(bool(reason) is not available, True,
                     "Unavailable must carry a reason and available must not")

    with_temp_home(check)


def test_sudo_toggle_status_reports_other_passwordless_sources():
    """`disabled` must not be claimed on a machine that already never prompts.

    `sudoNonInteractive` is a separate signal from VGS's own drop-in, and it is
    only probed when the drop-in is absent (an installed drop-in already
    implies it, and probing on every shell start would litter the auth log).
    """
    def check(home_path: Path):
        probes = []

        def yes():
            probes.append("called")
            return 0

        def no():
            probes.append("called")
            return 1

        status = helper.sudo_toggle_status("tester", sudo_probe=yes)
        assert_equal(status["dropinInstalled"], False, "No mirror means no VGS drop-in")
        assert_equal(status["sudoNonInteractive"], True,
                     "sudo not prompting must be reported even without the VGS drop-in")
        assert_equal(len(probes), 1, "The probe must actually run when the drop-in is absent")

        probes.clear()
        assert_equal(helper.sudo_toggle_status("tester", sudo_probe=no)["sudoNonInteractive"], False,
                     "A prompting sudo must report sudoNonInteractive false")

        flag = home_path / ".local" / "state" / "vshell" / "sudo-passwordless-toggle"
        flag.parent.mkdir(parents=True, exist_ok=True)
        flag.touch()
        probes.clear()
        status = helper.sudo_toggle_status("tester", sudo_probe=no)
        assert_equal(status["sudoNonInteractive"], True,
                     "An installed drop-in implies sudo does not prompt")
        assert_equal(probes, [], "The probe must be skipped when the drop-in is installed")

    with_temp_home(check)


def test_sudo_toggle_set_refuses_stale_direction():
    """A stale state mirror must not turn a requested revoke into a grant.

    The mirror can say enabled after an administrator removes the drop-in.
    """
    if shutil.which("visudo") is None:
        return

    def check(home_path: Path):
        with tempfile.TemporaryDirectory() as tmp:
            dropin = Path(tmp) / "50-tester-nopasswd-toggle"
            flag = home_path / ".local" / "state" / "vshell" / "sudo-passwordless-toggle"
            original = helper.sudo_toggle_dropin
            helper.sudo_toggle_dropin = lambda user: dropin
            try:
                flag.parent.mkdir(parents=True, exist_ok=True)
                flag.touch()
                code = helper.sudo_toggle_set("tester", False)
                assert_equal(code, helper.SUDO_TOGGLE_EXIT_STALE,
                             "A revoke against a stale mirror must report the mismatch")
                assert_equal(dropin.exists(), False,
                             "A revoke must NEVER create the drop-in")
                assert_equal(flag.exists(), False,
                             "The stale mirror must be re-synced to reality")

                code = helper.sudo_toggle_set("tester", True)
                assert_equal(code, 0, "Enable from an agreed state must succeed")
                assert_equal(dropin.is_file(), True, "Enable must install the drop-in")
                assert_equal(flag.is_file(), True, "Enable must write the mirror")

                flag.unlink()
                code = helper.sudo_toggle_set("tester", True)
                assert_equal(code, helper.SUDO_TOGGLE_EXIT_STALE,
                             "A grant against a stale mirror must report the mismatch")
                assert_equal(dropin.is_file(), True, "Drop-in must be left as it was")
                assert_equal(flag.is_file(), True, "Mirror must be re-synced to reality")

                code = helper.sudo_toggle_set("tester", False)
                assert_equal(code, 0, "Revoke from an agreed state must succeed")
                assert_equal(dropin.exists(), False, "Revoke must remove the drop-in")
                assert_equal(flag.exists(), False, "Revoke must clear the mirror")
            finally:
                helper.sudo_toggle_dropin = original

    with_temp_home(check)


def test_sudo_toggle_enable_never_takes_quiet_sudo_path():
    """Enabling requires a terminal even when sudo -n already succeeds.

    A credential cache must not silently turn a click into a permanent grant.
    """
    calls = []

    original_ensure = helper.ensure_root_for
    original_avail = helper.sudo_toggle_availability
    original_enable_avail = helper.sudo_toggle_enable_availability
    original_euid = helper.os.geteuid
    helper.sudo_toggle_availability = lambda: (True, "")
    # Stub terminal availability so host tools cannot determine whether the privilege
    # path is reached. Terminal refusal has a separate case.
    helper.sudo_toggle_enable_availability = lambda: (True, "")
    helper.os.geteuid = lambda: 1000

    def fake_ensure_root_for(argv, terminal=False):
        calls.append((list(argv), terminal))
        return 0

    helper.ensure_root_for = fake_ensure_root_for
    try:
        calls.clear()
        code = helper.cmd_sudo_toggle(["set", "on"])
        assert_equal(code, 0, "Enable must report the terminal launch result")
        assert_equal(len(calls), 1, "Enable must elevate exactly once")
        assert_equal(calls[0][1], True,
                     "Enable must elevate through a terminal, never the quiet sudo -n path")
        assert_equal("on" in calls[0][0], True, "Enable must pass the explicit direction")

        # Disable may use the quiet path: it only ever removes privilege.
        calls.clear()
        code = helper.cmd_sudo_toggle(["set", "off"])
        assert_equal(code, 0, "Disable must succeed on the quiet path")
        assert_equal(len(calls), 1, "A successful quiet disable must not also open a terminal")
        assert_equal(calls[0][1], False, "Disable must try the quiet path first")

        # `toggle` resolves the direction and must obey the same rule. With no
        # mirror present the direction is 'on', so it must use a terminal.
        def check(home_path: Path):
            calls.clear()
            helper.cmd_sudo_toggle(["toggle"])
            assert_equal(len(calls), 1, "toggle must elevate exactly once")
            assert_equal(calls[0][1], True,
                         "toggle resolving to enable must still go through a terminal")
            assert_equal("on" in calls[0][0], True, "toggle must convert to an explicit direction")

        with_temp_home(check)

        # Without a terminal, enabling must refuse while revocation remains available.
        helper.sudo_toggle_enable_availability = lambda: (False, "no terminal emulator found")
        calls.clear()
        code = helper.cmd_sudo_toggle(["set", "on"])
        assert_equal(code, 1, "Enable with no terminal must fail")
        assert_equal(calls, [], "Enable with no terminal must not elevate at all")

        calls.clear()
        code = helper.cmd_sudo_toggle(["set", "off"])
        assert_equal(code, 0, "Revoke must still work with no terminal")
        assert_equal(len(calls), 1, "Revoke with no terminal must take the quiet path")
        assert_equal(calls[0][1], False, "Revoke must not demand a terminal")
    finally:
        helper.ensure_root_for = original_ensure
        helper.sudo_toggle_availability = original_avail
        helper.sudo_toggle_enable_availability = original_enable_avail
        helper.os.geteuid = original_euid


def test_sudo_toggle_flag_write_refuses_symlinks():
    """Root writes the mirror into a user-controlled tree; never follow a link."""
    def check(home_path: Path):
        state = home_path / ".local" / "state"
        state.mkdir(parents=True, exist_ok=True)
        target = home_path / "planted"

        # A symlinked state directory must be refused, not traversed. The
        # target exists, so without the check the write would land inside it.
        planted_dir = home_path / "planted-dir"
        planted_dir.mkdir()
        (state / "vshell").symlink_to(planted_dir)
        ok, message = helper.sudo_toggle_write_flag(True)
        assert_equal(ok, False, "A symlinked mirror directory must be refused")
        assert_equal(sorted(p.name for p in planted_dir.iterdir()), [],
                     "A refused write must not create anything inside the link target")
        (state / "vshell").unlink()

        (state / "vshell").mkdir()
        (state / "vshell" / "sudo-passwordless-toggle").symlink_to(target)
        ok, message = helper.sudo_toggle_write_flag(True)
        assert_equal(ok, False, "A symlinked mirror file must be refused")
        assert_equal(target.exists(), False, "A refused write must not create the link target")
        (state / "vshell" / "sudo-passwordless-toggle").unlink()

        ok, message = helper.sudo_toggle_write_flag(True)
        assert_equal(ok, True, f"A clean mirror write must succeed: {message}")
        assert_equal((state / "vshell" / "sudo-passwordless-toggle").is_file(), True,
                     "A clean mirror write must create a real file")

        legacy = state / "sudo-passwordless-toggle"
        legacy.touch()
        ok, _ = helper.sudo_toggle_write_flag(True)
        assert_equal(ok, True, "Mirror write must succeed with a legacy file present")
        assert_equal(legacy.exists(), False, "Mirror write must retire the legacy flag")

    with_temp_home(check)


def test_sudo_toggle_revoke_retires_legacy_flag_without_state_dir():
    """Revocation clears the legacy mirror even when the current state tree is absent."""
    def check(home_path: Path):
        legacy = home_path / ".local" / "state" / "sudo-passwordless-toggle"
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.touch()
        assert_equal((home_path / ".local" / "state" / "vshell").exists(), False,
                     "Test setup: the new state directory must not exist yet")

        ok, message = helper.sudo_toggle_write_flag(False)
        assert_equal(ok, True, f"Revoke must succeed with no state dir: {message}")
        assert_equal(legacy.exists(), False,
                     "Revoke must retire the legacy flag even when the new tree is absent")
        assert_equal(helper.sudo_toggle_mirror_state(), False,
                     "After a revoke the mirror must read as disabled")

    with_temp_home(check)


def test_launch_terminal_rejects_immediately_failing_terminal():
    """A terminal that dies on spawn must not be reported as launched."""
    original = helper.terminal_candidates
    original_scope = helper.app_scope_prefix
    # The systemd-scope wrapper is an environment detail; this test is about the
    # terminal itself, so spawn without it.
    helper.app_scope_prefix = lambda: []
    helper.terminal_candidates = lambda prefer=None: [["/bin/false"]]
    try:
        assert_equal(helper.launch_terminal(["true"]), helper.TERMINAL_EXIT_FAILED,
                     "A terminal that exits non-zero immediately must be a failure")
    finally:
        helper.terminal_candidates = original

    helper.terminal_candidates = lambda prefer=None: []
    try:
        assert_equal(helper.launch_terminal(["true"]), 1,
                     "No terminal at all must report a distinct status")
    finally:
        helper.terminal_candidates = original
        helper.app_scope_prefix = original_scope

    assert_equal(helper.TERMINAL_EXIT_FAILED == helper.SUDO_TOGGLE_EXIT_STALE, False,
                 "A failed terminal must not be reportable as a stale-state refusal")


def test_sudo_toggle_revoke_never_needs_a_terminal():
    """Revocation must remain available without a terminal."""
    calls = []

    original_ensure = helper.ensure_root_for
    original_terminals = helper.terminal_candidates
    original_avail = helper.sudo_toggle_availability
    original_euid = helper.os.geteuid
    helper.terminal_candidates = lambda prefer=None: []
    helper.sudo_toggle_availability = lambda: (True, "")
    helper.os.geteuid = lambda: 1000

    def fake_ensure_root_for(argv, terminal=False):
        calls.append((list(argv), terminal))
        return 0

    helper.ensure_root_for = fake_ensure_root_for
    try:
        assert_equal(helper.have_terminal(), False, "Test setup: no terminal must be visible")

        calls.clear()
        code = helper.cmd_sudo_toggle(["set", "off"])
        assert_equal(code, 0, "Revoking must work with no terminal installed")
        assert_equal(len(calls), 1, "Revoke must still elevate once, on the quiet path")
        assert_equal(calls[0][1], False, "Revoke must not need a terminal")

        calls.clear()
        code = helper.cmd_sudo_toggle(["set", "on"])
        assert_equal(code, 1, "Granting with no terminal must fail")
        assert_equal(calls, [], "Granting with no terminal must not elevate at all")

        helper.os.geteuid = lambda: 0
        original_set = helper.sudo_toggle_set
        recorded = []
        helper.sudo_toggle_set = lambda user, want: recorded.append((user, want)) or 0
        try:
            code = helper.cmd_sudo_toggle(["set", "on"])
            assert_equal(code, 0, "Root must be able to grant with no terminal installed")
            assert_equal(len(recorded), 1, "Root must reach the privileged half directly")
            assert_equal(recorded[0][1], True, "Root must be asked for the requested direction")
        finally:
            helper.sudo_toggle_set = original_set
            helper.os.geteuid = lambda: 1000

        can_enable, reason = helper.sudo_toggle_enable_availability()
        assert_equal(can_enable, False, "enable-availability must be false with no terminal")
        assert_equal("terminal" in reason, True, "The reason must name the missing terminal")
        available, _ = helper.sudo_toggle_availability()
        assert_equal(available, True,
                     "General availability must NOT depend on a terminal")
    finally:
        helper.ensure_root_for = original_ensure
        helper.terminal_candidates = original_terminals
        helper.sudo_toggle_availability = original_avail
        helper.os.geteuid = original_euid


def test_terminal_candidates_match_dependency_manifest():
    """One list of terminals, two files: they must not drift apart."""
    manifest = json.loads((REPO_ROOT / "config" / "vshell" / "dependencies.json").read_text())
    features = manifest["features"]
    any_commands = features["terminal"]["anyCommands"]
    assert_equal(len(any_commands), 1, "terminal must declare exactly one alternative set")
    assert_equal(sorted(any_commands[0]), sorted(helper.TERMINAL_CANDIDATES),
                 "dependencies.json terminals must match helper TERMINAL_CANDIDATES")
    # xdg-terminal-exec is a launcher and does not establish an installed terminal.
    assert_equal("xdg-terminal-exec" in any_commands[0], False,
                 "a terminal launcher must not count as a terminal")
    # Features that need a terminal depend on its owning group, not a copied list.
    for feature in ("sudo-toggle", "launcher-folder-open-yazi"):
        assert_equal(features[feature].get("anyCommands"), None,
                     f"{feature} must not restate the terminal list")
    assert_equal("terminal" in (features["launcher-folder-open-yazi"].get("requiresFeatures") or []),
                 True, "the Yazi opener must require the terminal feature")
    # Revocation needs no terminal; only granting requires somewhere to prompt.
    assert_equal(features["sudo-toggle"].get("requiresFeatures"), None,
                 "sudo-toggle must stay available without a terminal so a grant can be revoked")
    assert_equal(sorted(features["sudo-toggle-grant"]["requiresFeatures"]),
                 ["sudo-toggle", "terminal"],
                 "the grant half must require both sudo and a terminal")


def test_sudo_toggle_status_stays_available_without_a_terminal():
    """`deps status` must not tell a terminal-less user they cannot revoke."""
    original_exists = helper.command_exists
    helper.command_exists = lambda name: name in {"sudo", "visudo"}
    try:
        features = helper.feature_status()["features"]
        assert_equal(features["terminal"]["available"], False, "no terminal is installed here")
        assert_equal(features["sudo-toggle"]["available"], True,
                     "status and revoke need no terminal, so the group must stay available")
        assert_equal(features["sudo-toggle-grant"]["available"], False,
                     "granting does need a terminal, so that half must report unavailable")
        assert_equal("@terminal" in features["sudo-toggle-grant"]["missing"], True,
                     "the grant half must name the terminal it is missing")
    finally:
        helper.command_exists = original_exists
    assert_equal(sorted(features["file-manager"]["anyCommands"][0]),
                 sorted(helper.FILE_MANAGER_CANDIDATES),
                 "dependencies.json file managers must match helper FILE_MANAGER_CANDIDATES")


def test_requires_features_propagates_to_availability():
    """A group that requires an unavailable group must not report ok."""
    original_load = helper.load_deps
    original_exists = helper.command_exists
    helper.load_deps = lambda: {
        "version": 2,
        "features": {
            "terminal": {"anyCommands": [["kitty"]]},
            "sudo-toggle": {"commands": ["sudo"], "requiresFeatures": ["terminal"]},
        },
    }
    helper.command_exists = lambda name: name == "sudo"
    try:
        features = helper.feature_status()["features"]
        assert_equal(features["terminal"]["available"], False, "terminal must be unavailable")
        assert_equal(features["sudo-toggle"]["available"], False,
                     "sudo-toggle must inherit the missing terminal")
        assert_equal("@terminal" in features["sudo-toggle"]["missing"], True,
                     "sudo-toggle must name the feature it is missing")
    finally:
        helper.load_deps = original_load
        helper.command_exists = original_exists


def test_terminal_resolution_prefers_the_vgs_setting():
    """One resolver, and its order is the documented one."""
    original_candidates_env = os.environ.get("TERMINAL")
    original_which = helper.shutil.which
    original_override = helper.session_terminal_override
    original_list = helper.xdg_terminals_list
    helper.shutil.which = lambda name: f"/usr/bin/{name}" if name in {"kitty", "foot", "xdg-terminal-exec"} else None
    helper.xdg_terminals_list = lambda: []
    try:
        helper.session_terminal_override = lambda: ["foot"]
        os.environ["TERMINAL"] = "kitty"
        assert_equal(helper.terminal_candidates()[0], ["foot"],
                     "the Settings terminal override must outrank $TERMINAL")

        helper.session_terminal_override = lambda: []
        assert_equal(helper.terminal_candidates()[0], ["kitty"],
                     "$TERMINAL must outrank xdg-terminal-exec")

        os.environ.pop("TERMINAL", None)
        assert_equal(helper.terminal_candidates()[0], ["xdg-terminal-exec"],
                     "xdg-terminal-exec must be preferred when installed")

        helper.shutil.which = lambda name: f"/usr/bin/{name}" if name == "foot" else None
        assert_equal(helper.terminal_candidates(), [["foot"]],
                     "an installed terminal must still be found without xdg-terminal-exec")
    finally:
        helper.shutil.which = original_which
        helper.session_terminal_override = original_override
        helper.xdg_terminals_list = original_list
        if original_candidates_env is None:
            os.environ.pop("TERMINAL", None)
        else:
            os.environ["TERMINAL"] = original_candidates_env


def test_terminal_argv_shapes_per_terminal():
    """The app-id is translated per terminal, never handed over blindly."""
    assert_equal(helper.terminal_argv(["kitty"], ["true"], "TUI.float"),
                 ["kitty", "--class=TUI.float", "-e", "true"],
                 "kitty takes --class=")
    assert_equal(helper.terminal_argv(["xterm"], ["true"], "TUI.float"),
                 ["xterm", "-class", "TUI.float", "-e", "true"],
                 "xterm takes -class as a separate argument")
    assert_equal(helper.terminal_argv(["konsole"], ["true"], "TUI.float"),
                 ["konsole", "-e", "true"],
                 "a terminal with no app-id flag must drop the app-id, not pass it")
    assert_equal(helper.terminal_argv(["xdg-terminal-exec"], ["true"], "TUI.float"),
                 ["xdg-terminal-exec", "--app-id=TUI.float", "--", "true"],
                 "xdg-terminal-exec separates its options with --")
    assert_equal(helper.terminal_argv(["kitty"], [], ""), ["kitty"],
                 "opening a bare terminal adds nothing")
    # `wezterm -e` is not a valid invocation: its launcher is a subcommand.
    assert_equal(helper.terminal_argv(["wezterm"], ["true"], "TUI.float"),
                 ["wezterm", "start", "--class=TUI.float", "--", "true"],
                 "wezterm runs commands through `start --`")
    assert_equal(helper.terminal_argv(["wezterm"], [], ""), ["wezterm", "start"],
                 "wezterm opens a bare terminal through `start` too")


def test_app_scope_is_probed_rather_than_assumed():
    """uwsm being installed must not be able to break every terminal launch.

    Usability is settled once with a no-op probe. The alternative — launch the
    payload, watch it die, launch it again unscoped — would run the user's
    command twice.
    """
    original_which = helper.shutil.which
    original_run = helper.run
    original_cached = helper._app_scope_usable
    probes = []

    class _Result:
        def __init__(self, code):
            self.returncode = code
            self.stdout = ""
            self.stderr = ""

    def fake_run(argv, **kwargs):
        probes.append(argv)
        return _Result(1 if usable[0] is False else 0)

    usable = [True]
    helper.shutil.which = lambda name: "/usr/bin/uwsm" if name == "uwsm" else None
    helper.run = fake_run
    try:
        helper._app_scope_usable = None
        assert_equal(helper.app_scope_prefix(), ["/usr/bin/uwsm", "app", "--"],
                     "a usable scope must be used")
        assert_equal(probes[0][-1], "true", "the probe must run a no-op, not the payload")
        helper.app_scope_prefix()
        assert_equal(len(probes), 1, "the probe result must be cached, not re-run per launch")

        usable[0] = False
        helper._app_scope_usable = None
        probes.clear()
        assert_equal(helper.app_scope_prefix(), [],
                     "a scope this session cannot use must be dropped entirely")
    finally:
        helper.shutil.which = original_which
        helper.run = original_run
        helper._app_scope_usable = original_cached


def test_terminal_never_reruns_an_unwrapped_command():
    """A command that fails fast must run once, not once per installed terminal.

    The "distrust a fast exit" retry only tells us anything when the payload
    cannot exit fast, which is what the hold wrapper guarantees. Without it the
    status belongs to the user's command, and retrying would flash a window and
    re-run it for every candidate.
    """
    original_candidates = helper.terminal_candidates
    original_scope = helper.app_scope_prefix
    original_popen = helper.subprocess.Popen
    launches = []

    class _FailsFast:
        returncode = 3

        def wait(self, timeout=None):
            return 3

    helper.terminal_candidates = lambda prefer=None: [["kitty"], ["ghostty"], ["foot"], ["alacritty"]]
    helper.app_scope_prefix = lambda: []
    helper.subprocess.Popen = lambda argv, **k: (launches.append(argv), _FailsFast())[1]
    try:
        assert_equal(helper.spawn_terminal(["false"]), 3,
                     "an unwrapped command's own status must be returned as-is")
        assert_equal(len(launches), 1,
                     "an unwrapped command must not be re-run on the next terminal")

        launches.clear()
        # The hold wrapper cannot exit fast, so a fast exit really is the
        # terminal failing and every candidate is still worth trying.
        assert_equal(helper.spawn_terminal(["false"], hold=True), helper.TERMINAL_EXIT_FAILED,
                     "a wrapped payload exiting fast is a terminal failure")
        assert_equal(len(launches), 4, "every candidate must be tried for a wrapped payload")
    finally:
        helper.terminal_candidates = original_candidates
        helper.app_scope_prefix = original_scope
        helper.subprocess.Popen = original_popen


def test_missing_terminal_reaches_the_user():
    """Report terminal launch failure to detached callers that receive no stderr."""
    original_candidates = helper.terminal_candidates
    original_notify = helper.notify_user
    reported = []
    helper.terminal_candidates = lambda prefer=None: []
    helper.notify_user = lambda title, details="": reported.append((title, details))
    try:
        assert_equal(helper.spawn_terminal(["true"], notify=True), 1,
                     "no terminal must still be a failure status")
        assert_equal(len(reported), 1, "the user must be told there is no terminal")
        assert_equal("Settings" in reported[0][1], True,
                     "the message must name the fix, not just the symptom")
        reported.clear()
        assert_equal(helper.spawn_terminal(["true"]), 1,
                     "callers that can see stderr keep the quiet path")
        assert_equal(reported, [], "a visible caller must not be toasted at")
    finally:
        helper.terminal_candidates = original_candidates
        helper.notify_user = original_notify


def test_terminal_wait_blocks_until_the_terminal_exits():
    """A supervisor treating our exit as completion must get the full lifetime."""
    original_candidates = helper.terminal_candidates
    original_scope = helper.app_scope_prefix
    original_popen = helper.subprocess.Popen
    waits = []

    class _LongRunning:
        returncode = None

        def wait(self, timeout=None):
            waits.append(timeout)
            if timeout is not None:
                raise helper.subprocess.TimeoutExpired("terminal", timeout)
            return 7

    helper.terminal_candidates = lambda prefer=None: [["kitty"]]
    helper.app_scope_prefix = lambda: []
    helper.subprocess.Popen = lambda *a, **k: _LongRunning()
    try:
        assert_equal(helper.spawn_terminal(["true"], wait=True), 7,
                     "--wait must return the terminal's status, not the settle result")
        assert_equal(waits[-1], None, "the second wait must be unbounded")
        waits.clear()
        assert_equal(helper.spawn_terminal(["true"]), 0,
                     "without --wait the settle window still ends the call")
        assert_equal(len(waits), 1, "the default path must not wait a second time")
    finally:
        helper.terminal_candidates = original_candidates
        helper.app_scope_prefix = original_scope
        helper.subprocess.Popen = original_popen


def test_preferred_terminal_is_tried_first():
    """A caller that resolved a terminal must not have it silently discarded."""
    original_which = helper.shutil.which
    original_override = helper.session_terminal_override
    original_list = helper.xdg_terminals_list
    helper.shutil.which = lambda name: f"/usr/bin/{name}" if name in {"kitty", "foot"} else None
    helper.session_terminal_override = lambda: ["kitty"]
    helper.xdg_terminals_list = lambda: []
    try:
        assert_equal(helper.terminal_candidates(["foot"])[0], ["foot"],
                     "an explicit caller preference must outrank the stored setting")
        assert_equal([["kitty"]] == helper.terminal_candidates(["foot"])[1:], True,
                     "the normal chain must still follow the preference")
    finally:
        helper.shutil.which = original_which
        helper.session_terminal_override = original_override
        helper.xdg_terminals_list = original_list


def _notification_env(root: Path, owner: dict | None, activation: str | None = None):
    """Point the helper's bus, procfs and data dirs at a scratch session.

    Nothing here may reach the live session bus or the live user manager: the
    real one is running the shell these tests are checking.
    """
    data_home = root / "home" / ".local" / "share"
    system_share = root / "usr" / "share"
    if activation is not None:
        services = system_share / "dbus-1" / "services"
        services.mkdir(parents=True, exist_ok=True)
        (services / "fr.emersion.mako.service").write_text(activation)

    calls: list[list[str]] = []

    def fake_bus(member, signature, *args):
        if owner is None:
            return {"value": None, "error": ""}
        if owner.get("busError"):
            return {"value": None, "error": owner["busError"]}
        if member == "GetNameOwner":
            return {"value": owner["unique"], "error": ""}
        if member == "GetConnectionUnixProcessID":
            return {"value": owner["pid"], "error": ""}
        return {"value": None, "error": ""}

    def fake_systemctl(argv, timeout=10.0):
        calls.append(list(argv))
        if argv[0] == "show":
            unit_state = (owner or {}).get("unitShow", {})
            body = "\n".join(f"{key}={value}" for key, value in unit_state.get(argv[1], {}).items())
            return subprocess.CompletedProcess(argv, 0, body, "")
        if argv[0] in {"mask", "stop"} and (owner or {}).get("refuse", "") == argv[1]:
            return subprocess.CompletedProcess(argv, 1, "", "refused")
        return subprocess.CompletedProcess(argv, 0, "", "")

    if owner is not None:
        proc_dir = root / "proc" / str(owner["pid"])
        proc_dir.mkdir(parents=True, exist_ok=True)
        (proc_dir / "comm").write_text(owner["comm"] + "\n")
        (proc_dir / "cmdline").write_text("\0".join(owner["cmdline"]) + "\0")
        (proc_dir / "cgroup").write_text(
            f"0::/user.slice/user-1000.slice/user@1000.service/app.slice/{owner['unit']}\n"
            if owner["unit"] else "0::/user.slice/user-1000.slice/session-1.scope\n"
        )

    os.environ["VSHELL_PROC_ROOT"] = str(root / "proc")
    os.environ["XDG_DATA_HOME"] = str(data_home)
    os.environ["XDG_DATA_DIRS"] = str(system_share)
    helper._session_bus_call = fake_bus
    helper._systemctl_user = fake_systemctl
    return calls


def test_notification_ownership_detects_a_foreign_daemon():
    original_bus, original_systemctl = helper._session_bus_call, helper._systemctl_user
    original_env = {key: os.environ.get(key) for key in ("VSHELL_PROC_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS")}

    def body(tmp: Path):
        activation = (
            "[D-BUS Service]\n"
            "Name=org.freedesktop.Notifications\n"
            "Exec=/usr/bin/mako\n"
            "SystemdService=mako.service\n"
        )
        owner = {
            "unique": ":1.7",
            "pid": 4242,
            "comm": "mako",
            "cmdline": ["/usr/bin/mako"],
            "unit": "mako.service",
            "unitShow": {"mako.service": {
                "LoadState": "loaded", "ActiveState": "active", "UnitFileState": "disabled",
                "MainPID": "4242",
                "ExecStart": "{ path=/usr/bin/mako ; argv[]=/usr/bin/mako ; ignore_errors=no }",
            }},
        }
        calls = _notification_env(tmp, owner, activation)

        status = helper.notification_status()
        assert_equal(status["state"], "foreign", "a mako-owned bus name must read as foreign")
        assert_equal(status["owner"]["unit"], "mako.service", "the unit must come from the cgroup, not busctl's session unit")
        assert_equal(len(status["conflicts"]), 1, "the owner and its activation file are one conflict, not two")
        assert_equal(status["conflicts"][0]["daemon"], "mako", "conflict must be labelled by daemon")
        assert_equal(status["takeover"]["available"], True, "a running user unit is takeover-able")

        result = helper.notification_takeover()
        shadow = tmp / "home" / ".local" / "share" / "dbus-1" / "services" / "fr.emersion.mako.service"
        assert shadow.is_file(), "takeover must shadow the activation file in the data home"
        assert helper.NOTIFICATION_SHADOW_MARKER in shadow.read_text(), "the shadow must be identifiable for restore"
        assert_equal(["mask", "mako.service"] in calls, True, "takeover must mask the conflicting unit")
        assert_equal(["stop", "mako.service"] in calls, True, "takeover must stop the conflicting unit")
        assert_equal(any(call[0] in {"kill", "kill-user"} for call in calls), False, "takeover must never kill anything")
        assert_equal(result["ok"], True, "takeover with a stoppable unit must succeed")

        helper.notification_restore()
        assert_equal(shadow.exists(), False, "restore must remove the shadow it wrote")
        assert_equal(["unmask", "mako.service"] in calls, True, "restore must unmask what takeover masked")

    try:
        with_temp_home(body)
    finally:
        helper._session_bus_call, helper._systemctl_user = original_bus, original_systemctl
        for key, value in original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_notification_ownership_recognises_the_shell_itself():
    original_bus, original_systemctl = helper._session_bus_call, helper._systemctl_user
    original_env = {key: os.environ.get(key) for key in ("VSHELL_PROC_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS")}

    def body(tmp: Path):
        owner = {
            "unique": ":1.55",
            "pid": 5093,
            "comm": "qs",
            "cmdline": ["qs", "-p", "/home/user/.config/quickshell/vshell"],
            "unit": "vshell.service",
            "unitShow": {},
        }
        _notification_env(tmp, owner)
        status = helper.notification_status()
        assert_equal(status["state"], "vgs", "the shell's own registration must not read as a conflict")
        assert_equal(status["conflicts"], [], "VGS must never list itself as a conflicting daemon")
        assert_equal(status["atRisk"], False, "no other claimant means nothing to warn about")

        # Same shell, started straight from a compositor rule rather than the
        # unit: the cgroup gives no unit name, so the process must identify it.
        proc_dir = tmp / "proc" / "5093"
        proc_dir.joinpath("cgroup").write_text("0::/user.slice/user-1000.slice/session-1.scope\n")
        assert_equal(helper.notification_status()["state"], "vgs",
                     "a unit-less VGS process must still be recognised as VGS")

    try:
        with_temp_home(body)
    finally:
        helper._session_bus_call, helper._systemctl_user = original_bus, original_systemctl
        for key, value in original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_notification_unowned_bus_is_not_a_conflict():
    original_bus, original_systemctl = helper._session_bus_call, helper._systemctl_user
    original_env = {key: os.environ.get(key) for key in ("VSHELL_PROC_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS")}

    def body(tmp: Path):
        _notification_env(tmp, None)
        status = helper.notification_status()
        assert_equal(status["state"], "unowned", "no owner must read as unowned, not foreign")
        assert_equal(status["takeover"]["available"], False, "there is nothing to take over")

    try:
        with_temp_home(body)
    finally:
        helper._session_bus_call, helper._systemctl_user = original_bus, original_systemctl
        for key, value in original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_notification_takeover_never_touches_an_inherited_unit():
    """The session's own unit must never be masked or stopped.

    A daemon started from a compositor rule (`exec-once = mako`) has no unit of
    its own: its cgroup leaf is the compositor's unit, so acting on it would
    kill the graphical session and block the next login.
    """
    original_bus, original_systemctl = helper._session_bus_call, helper._systemctl_user
    original_env = {key: os.environ.get(key) for key in ("VSHELL_PROC_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS")}

    def body(tmp: Path):
        session_unit = "wayland-wm@hyprland.desktop.service"
        owner = {
            "unique": ":1.7",
            "pid": 4242,
            "comm": "mako",
            "cmdline": ["/usr/bin/mako"],
            "unit": session_unit,
            "unitShow": {session_unit: {
                "LoadState": "loaded", "ActiveState": "active", "UnitFileState": "enabled",
                "MainPID": "3099",
                "ExecStart": "{ path=/usr/bin/uwsm ; argv[]=/usr/bin/uwsm aux exec -- hyprland.desktop ; ignore_errors=no }",
            }},
        }
        calls = _notification_env(tmp, owner)

        status = helper.notification_status()
        assert_equal(status["state"], "foreign", "the daemon still owns the bus name")
        conflict = status["conflicts"][0]
        assert_equal(conflict["unit"], session_unit, "the inherited unit is still reported")
        assert_equal(conflict["unitControls"], False, "an inherited unit must never be actionable")
        assert_equal(status["takeover"]["available"], False,
                     "no takeover may be offered when the only lever is the session unit")
        assert session_unit in status["takeover"]["reason"], "the reason must name the unit it refuses to touch"

        result = helper.notification_takeover()
        for verb in ("mask", "stop", "kill", "disable"):
            assert_equal(any(call[0] == verb and session_unit in call for call in calls), False,
                         f"takeover must never {verb} the session's own unit")
        assert_equal(len(result["manual"]), 1, "the daemon must be handed to the user instead")
        assert session_unit in result["manual"][0], "the manual note must explain what was left alone"

    try:
        with_temp_home(body)
    finally:
        helper._session_bus_call, helper._systemctl_user = original_bus, original_systemctl
        for key, value in original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_notification_restore_starts_what_takeover_stopped():
    original_bus, original_systemctl = helper._session_bus_call, helper._systemctl_user
    original_env = {key: os.environ.get(key) for key in ("VSHELL_PROC_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS")}

    def body(tmp: Path):
        owner = {
            "unique": ":1.7", "pid": 4242, "comm": "mako", "cmdline": ["/usr/bin/mako"],
            "unit": "mako.service",
            "unitShow": {"mako.service": {
                "LoadState": "loaded", "ActiveState": "active", "UnitFileState": "disabled",
                "MainPID": "4242",
                "ExecStart": "{ path=/usr/bin/mako ; argv[]=/usr/bin/mako ; ignore_errors=no }",
            }},
        }
        calls = _notification_env(tmp, owner)
        helper.notification_takeover()
        assert_equal(["stop", "mako.service"] in calls, True, "the daemon's own unit is stoppable")

        calls.clear()
        helper.notification_restore()
        assert_equal(["unmask", "mako.service"] in calls, True, "restore must unmask first")
        assert_equal(["start", "mako.service"] in calls, True,
                     "restore must put the daemon back, not leave it dead until relogin")
        assert_equal(calls.index(["unmask", "mako.service"]) < calls.index(["start", "mako.service"]), True,
                     "starting a masked unit would fail, so unmask must come first")

    try:
        with_temp_home(body)
    finally:
        helper._session_bus_call, helper._systemctl_user = original_bus, original_systemctl
        for key, value in original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_notification_takeover_records_who_asked():
    """Use the persistent undo record to distinguish automatic from manual takeover.

    Runtime flags disappear on restart while masks and stopped units persist.
    """
    original_bus, original_systemctl = helper._session_bus_call, helper._systemctl_user
    original_env = {key: os.environ.get(key) for key in ("VSHELL_PROC_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS")}

    def owner_spec():
        return {
            "unique": ":1.7", "pid": 4242, "comm": "mako", "cmdline": ["/usr/bin/mako"],
            "unit": "mako.service",
            "unitShow": {"mako.service": {
                "LoadState": "loaded", "ActiveState": "active", "UnitFileState": "disabled",
                "MainPID": "4242",
                "ExecStart": "{ path=/usr/bin/mako ; argv[]=/usr/bin/mako ; ignore_errors=no }",
            }},
        }

    def manual(tmp: Path):
        _notification_env(tmp, owner_spec())
        helper.notification_takeover()
        # A takeover nobody labelled is not one VGS may claim to have made, so
        # the shell must leave it alone: reversing it would undo a deliberate
        # choice the user made from the CLI or the Settings button.
        assert_equal(helper.notification_status()["restore"]["initiator"], "manual",
                     "a takeover the user asked for is recorded as manual")
        assert_equal(helper.notification_status()["restore"]["automatic"], False,
                     "a manual takeover must not read as VGS's own doing")

    def automatic(tmp: Path):
        _notification_env(tmp, owner_spec())
        helper.notification_takeover(automatic=True)

        # Only the on-disk record survives a shell restart.
        assert_equal(helper._load_takeover_record()["initiator"], "first-run",
                     "the first-run takeover must be recorded on disk, not only in the shell")
        status = helper.notification_status()
        assert_equal(status["restore"]["available"], True, "there is something to undo")
        assert_equal(status["restore"]["automatic"], True,
                     "status must tell a restarted shell the takeover was its own")

        # A later manual takeover cannot launder VGS's own action away: the two
        # sets of changes share one record and cannot be unpicked, and
        # reversing all of them is what keeps a daemon running.
        helper.notification_takeover()
        assert_equal(helper.notification_status()["restore"]["automatic"], True,
                     "a manual takeover on top of an automatic one must not clear provenance")

    def partial_restore_keeps_provenance(tmp: Path):
        _notification_env(tmp, owner_spec())
        helper.notification_takeover(automatic=True)

        stock = helper._systemctl_user

        def refuse_unmask(argv, timeout=10.0):
            if argv[0] == "unmask":
                return subprocess.CompletedProcess(argv, 1, "", "refused")
            return stock(argv, timeout=timeout)

        helper._systemctl_user = refuse_unmask
        result = helper.notification_restore()
        assert_equal(result["ok"], False, "a restore that could not unmask is not ok")
        assert_equal(bool(result["failures"]), True, "the failure must be reported, not swallowed")
        # The mask is still in force, so the daemon may still be down. The
        # record has to survive with its provenance intact or the next opt-out
        # would decline to try again.
        assert_equal(helper._load_takeover_record()["initiator"], "first-run",
                     "a partial restore must keep the record's provenance so the retry still fires")
        assert_equal(helper.notification_status()["restore"]["automatic"], True,
                     "a failed restore stays retryable")

    def an_existing_record_is_never_relabelled(tmp: Path):
        _notification_env(tmp, owner_spec())
        helper.notification_takeover()
        assert_equal(helper._load_takeover_record()["initiator"], "manual",
                     "precondition: the user's own takeover is recorded as manual")

        # An automatic pass afterwards must NOT rewrite that. Relabelling it
        # would let the shell reverse a change the user made on purpose --
        # the one thing the initiator exists to prevent.
        helper.notification_takeover(automatic=True)
        assert_equal(helper._load_takeover_record()["initiator"], "manual",
                     "an automatic takeover must not relabel a record the user created")
        assert_equal(helper.notification_status()["restore"]["automatic"], False,
                     "the shell must not be told a manual takeover was its own")

    def a_record_is_stamped_only_when_created(tmp: Path):
        _notification_env(tmp, owner_spec())
        assert_equal(_takeover_record_is_empty(), True, "precondition: no record yet")
        helper.notification_takeover(automatic=True)
        assert_equal(helper._load_takeover_record()["initiator"], "first-run",
                     "an automatic takeover that creates the record does stamp it")

    def persisted_one_shot_is_read_from_disk(tmp: Path):
        _notification_env(tmp, owner_spec())
        settings = tmp / ".config" / "vshell" / "settings.json"
        settings.parent.mkdir(parents=True, exist_ok=True)

        # With no settings file, the shipped seed decides whether takeover is already spent.
        seed = json.loads((REPO_ROOT / "config" / "vshell" / "settings.default.json").read_text())
        assert_equal(seed["notificationFirstRunTakeoverDone"], False,
                     "the shipped seed must leave the one-shot unspent")
        assert_equal(helper.vgs_first_run_takeover_done(), False,
                     "an absent settings.json must not read as a spent one-shot")
        assert_equal(helper.notification_status()["vgsFirstRunTakeoverDone"], False,
                     "status must surface the on-disk answer")

        settings.write_text("{ this is not json")
        assert_equal(helper.vgs_first_run_takeover_done(), False,
                     "an unreadable settings.json must not read as a spent one-shot")

        settings.write_text(json.dumps({"notificationFirstRunTakeoverDone": False}))
        assert_equal(helper.vgs_first_run_takeover_done(), False, "false is false")
        settings.write_text(json.dumps({"notificationFirstRunTakeoverDone": "yes"}))
        assert_equal(helper.vgs_first_run_takeover_done(), False,
                     "a non-boolean must not be coerced into a spent one-shot")

        settings.write_text(json.dumps({"notificationFirstRunTakeoverDone": True}))
        assert_equal(helper.vgs_first_run_takeover_done(), True,
                     "a persisted true is what the shell waits for")
        assert_equal(helper.notification_status()["vgsFirstRunTakeoverDone"], True,
                     "status must surface the on-disk answer")

    def garbage_is_not_trusted(tmp: Path):
        _notification_env(tmp, owner_spec())
        helper.notification_takeover(automatic=True)
        path = helper.notification_state_file()
        record = json.loads(path.read_text())
        record["initiator"] = "../../etc/passwd"
        path.write_text(json.dumps(record))
        assert_equal(helper._load_takeover_record()["initiator"], "manual",
                     "an unrecognised initiator must fall back to manual, never be taken as given")

    def _takeover_record_is_empty() -> bool:
        return not helper._takeover_record_has_changes(helper._load_takeover_record())

    try:
        for case in (manual, automatic, partial_restore_keeps_provenance,
                     an_existing_record_is_never_relabelled,
                     a_record_is_stamped_only_when_created,
                     persisted_one_shot_is_read_from_disk,
                     garbage_is_not_trusted):
            with_temp_home(case)
    finally:
        helper._session_bus_call, helper._systemctl_user = original_bus, original_systemctl
        for key, value in original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_notification_status_respects_the_server_opt_out():
    """A user who turned VGS's server off is not told to fix anything."""
    original_enabled = helper.vgs_notification_server_enabled
    try:
        helper.vgs_notification_server_enabled = lambda: False
        status = {
            "busName": helper.NOTIFICATION_BUS_NAME, "state": "foreign", "error": "",
            "vgsServerEnabled": False, "atRisk": False,
            "owner": {"present": True, "pid": 42, "process": "mako", "exe": "/usr/bin/mako",
                      "unit": "mako.service", "isVgs": False, "unique": ":1.7", "cmdline": "", "error": ""},
            "conflicts": [], "takeover": {"available": True, "reason": ""},
            "restore": {"available": False},
        }
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            helper._print_notification_status(status)
        printed = buffer.getvalue()
        assert "VGS notifications are inert" not in printed, \
            "an intentional opt-out must not be described as a broken shell"
        assert "vshell notifications takeover" not in printed, \
            "nothing needs fixing when the user turned the server off"
        assert "turned off in settings" in printed, "the reason must be stated"
    finally:
        helper.vgs_notification_server_enabled = original_enabled


def test_notification_probe_failure_is_not_an_unowned_bus():
    """A broken probe must never read as a settled session."""
    original_bus, original_systemctl = helper._session_bus_call, helper._systemctl_user
    original_env = {key: os.environ.get(key) for key in ("VSHELL_PROC_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS")}

    def body(tmp: Path):
        _notification_env(tmp, {"unique": "", "pid": 0, "comm": "", "cmdline": [], "unit": "",
                                "busError": "busctl is not installed"})
        status = helper.notification_status()
        assert_equal(status["state"], "unknown", "a failed probe must not be reported as unowned")
        assert_equal(status["error"], "busctl is not installed", "the reason must survive to the caller")
        assert_equal(status["atRisk"], False, "an unknown state claims nothing either way")

    try:
        with_temp_home(body)
    finally:
        helper._session_bus_call, helper._systemctl_user = original_bus, original_systemctl
        for key, value in original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_notification_unowned_error_phrasings():
    """Every bus implementation's "no owner" wording must read as unowned."""
    for message in ("Call failed: The name does not have an owner",
                    "Could not get owner of name 'x': no such name",
                    "org.freedesktop.DBus.Error.NameHasNoOwner"):
        assert helper._BUS_NO_SUCH_NAME.search(message), f"{message!r} must classify as unowned"
    assert not helper._BUS_NO_SUCH_NAME.search("Connection timed out"), \
        "a transport failure must not be mistaken for an unowned name"


def test_notification_takeover_preserves_a_user_activation_file():
    """A shadow must never destroy a file the user put there themselves."""
    original_bus, original_systemctl = helper._session_bus_call, helper._systemctl_user
    original_env = {key: os.environ.get(key) for key in ("VSHELL_PROC_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS")}

    def body(tmp: Path):
        owner = {"unique": ":1.9", "pid": 4343, "comm": "mako", "cmdline": ["/usr/bin/mako"],
                 "unit": "", "unitShow": {}}
        _notification_env(tmp, owner)
        user_file = tmp / "home" / ".local" / "share" / "dbus-1" / "services" / "fr.emersion.mako.service"
        user_file.parent.mkdir(parents=True, exist_ok=True)
        original = ("[D-BUS Service]\n"
                    "Name=org.freedesktop.Notifications\n"
                    "Exec=/home/user/bin/my-mako\n")
        user_file.write_text(original)

        result = helper.notification_takeover()
        assert helper.NOTIFICATION_SHADOW_MARKER in user_file.read_text(), "the shadow must be in place"
        backups = result["restore"]["backups"]
        assert_equal(len(backups), 1, "the displaced file must be recorded exactly once")
        saved = Path(next(iter(backups.values())))
        assert_equal(saved.read_text(), original, "the user's file must be kept byte for byte")

        helper.notification_restore()
        assert_equal(user_file.read_text(), original, "restore must put the user's file back")
        assert_equal(saved.exists(), False, "the saved copy must not be left behind")

    try:
        with_temp_home(body)
    finally:
        helper._session_bus_call, helper._systemctl_user = original_bus, original_systemctl
        for key, value in original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_notification_takeover_reports_an_unrecordable_state():
    """Changes that cannot be recorded are not reversible, so not a success."""
    original_bus, original_systemctl = helper._session_bus_call, helper._systemctl_user
    original_save = helper._save_takeover_record
    original_env = {key: os.environ.get(key) for key in ("VSHELL_PROC_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS")}

    def body(tmp: Path):
        activation = ("[D-BUS Service]\n"
                      "Name=org.freedesktop.Notifications\n"
                      "Exec=/usr/bin/mako\n")
        owner = {"unique": ":1.9", "pid": 4343, "comm": "mako", "cmdline": ["/usr/bin/mako"],
                 "unit": "", "unitShow": {}}
        _notification_env(tmp, owner, activation)
        helper._save_takeover_record = lambda record: "disk is read-only"
        result = helper.notification_takeover()
        assert_equal(result["ok"], False, "an unrecordable takeover must not report success")
        assert any("disk is read-only" in failure for failure in result["failures"]), \
            "the persistence failure must reach the caller"

    try:
        with_temp_home(body)
    finally:
        helper._session_bus_call, helper._systemctl_user = original_bus, original_systemctl
        helper._save_takeover_record = original_save
        for key, value in original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_notification_daemon_label_handles_scope_units():
    assert_equal(helper._daemon_label("", "", "dunst.scope"), "dunst",
                 "a daemon under a .scope unit must still be named")
    assert_equal(helper._daemon_label("", "", "mako.service"), "mako",
                 "a daemon under a .service unit must still be named")


def _load_script(module_name: str, filename: str):
    """Load one of scripts/ as a module. Their names are not importable identifiers."""
    import importlib.machinery
    import importlib.util

    loader = importlib.machinery.SourceFileLoader(module_name, str(REPO_ROOT / "scripts" / filename))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def _theme_archive(files: dict[str, bytes]) -> bytes:
    """The publisher's own archive bytes.

    The download fixture is built by scripts/publish-theme-assets.py itself, so a
    change to what it packs — a member name the downloader refuses, a prefix, a
    layout — reddens the download test rather than shipping unnoticed.
    """
    publisher = _load_script("publish_theme_assets_fixture", "publish-theme-assets.py")
    with tempfile.TemporaryDirectory() as tmp:
        members = []
        # build_archive reads the source path for bytes and size only, so the
        # member name never has to be the name on disk. Keeping them apart is
        # what lets a hostile member name reach the downloader exactly as
        # written: writing to `Path(tmp) / "../../evil"` instead makes the
        # fixture's own path depend on how deep the temp directory sits, which
        # raises PermissionError where it is shallow and writes outside the
        # test's directory where it is not.
        for index, (rel, blob) in enumerate(sorted(files.items())):
            path = Path(tmp) / f"member-{index}"
            path.write_bytes(blob)
            members.append((rel, path))
        return publisher.build_archive(members)


def _write_catalog(builtin: Path, archives: Path, name: str, blob: bytes,
                   release: str = "themes-v1", rev: int = 1) -> None:
    archive = f"vgs-theme-{name}-r{rev}.tar.gz"
    (archives / release).mkdir(parents=True, exist_ok=True)
    (archives / release / archive).write_bytes(blob)
    (builtin / "catalog.json").write_text(json.dumps({
        "version": 2,
        "source": {"type": "github-release", "ref": "vTest",
                   "baseUrl": "https://example.invalid/releases/download"},
        "themes": [{
            "name": name, "mode": "dark", "size": len(blob),
            "assets": {"release": release, "archive": archive, "rev": rev,
                       "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest()},
        }],
    }))


def _theme_list_entries() -> dict:
    """What theme list --json prints, per theme name.

    The settings tabs read this and nothing else, so a field the helper computes
    and the entry dict omits does not exist as far as the interface is concerned.
    """
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        status = helper.cmd_theme(["list", "--json"])
    assert_equal(status, 0, "theme list --json exit status")
    return {entry["name"]: entry for entry in json.loads(buffer.getvalue())["blueprints"]}


def _catalog_entry(name: str) -> dict:
    """What `theme catalog list --json` reports for one theme."""
    return [entry for entry in helper.catalog_entries() if entry["name"] == name][0]


def _user_files(root: Path) -> list:
    return sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file())


def test_theme_catalog_offers_a_builtin_theme_with_no_imagery():
    """A built-in theme's wallpapers download beside its user overlay, which they never touch.

    Every theme's definitions ship in the package while only the default theme
    keeps its wallpapers there (D015), so the user directory a download lands in
    can already hold the user's own edits.
    """
    wallpaper = b"\xff\xd8\xff\xe0 demo wallpaper bytes\n"
    blob = _theme_archive({"backgrounds/1-demo.jpg": wallpaper})

    def scenario(tmp: Path):
        builtin = tmp / "builtin"
        (builtin / "demo" / "apps").mkdir(parents=True)
        (builtin / "demo" / "theme.json").write_text('{"name":"demo","mode":"dark","source":"curated"}\n')
        (builtin / "demo" / "colors.toml").write_text('background = "#101010"\nforeground = "#eeeeee"\n')
        (builtin / "demo" / "apps" / "btop.theme").write_text('theme[main_bg]="#101010"\n')
        preview = builtin / "demo" / helper.THEME_PREVIEW_FILE
        preview.write_bytes(b"\xff\xd8\xff demo preview bytes\n")
        (builtin / "thumbnails").mkdir()
        (builtin / "thumbnails" / "demo.jpg").write_bytes(b"\xff\xd8\xff thumbnail bytes\n")
        archives = tmp / "releases"
        _write_catalog(builtin, archives, "demo", blob)

        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        os.environ["VGS_THEME_CATALOG_BASE_URL"] = "file://" + str(archives)
        try:
            catalog = helper.load_theme_catalog()
            base_urls, allow_local = helper.theme_catalog_base_urls(catalog)
            entry = helper.catalog_theme_entry(catalog, "demo")

            offered = _catalog_entry("demo")
            assert_equal((offered["builtin"], offered["imageryInstalled"], offered["downloaded"],
                          offered["imageryUpdateAvailable"], offered["imagerySize"], offered["preview"],
                          offered["background"], offered["foreground"]),
                         (True, False, False, False, len(blob), str(preview), "#101010", "#eeeeee"),
                         "a built-in theme with no wallpapers is offered at its archive size and in its package's "
                         "colours, painted from its preview, with no update for a download it never had")

            # The user edited the theme's colours before downloading its wallpapers.
            dest = helper.user_themes_dir() / "demo"
            dest.mkdir(parents=True)
            overlay = b'background = "#202020"\n'
            (dest / "colors.toml").write_bytes(overlay)
            result = helper.catalog_download_theme(entry, base_urls, allow_local)
            assert_equal(result["status"], "installed", "a built-in theme with no wallpapers downloads")
            assert_equal((dest / "backgrounds" / "1-demo.jpg").read_bytes(), wallpaper,
                         "the downloaded wallpaper lands in the user directory")
            assert_equal((dest / "colors.toml").read_bytes(), overlay,
                         "a download leaves an existing overlay colors.toml untouched")
            assert_equal((_user_files(dest), helper.catalog_marker("demo")["files"]),
                         ([helper.CATALOG_MARKER, "backgrounds/1-demo.jpg", "colors.toml"],
                          {"backgrounds/1-demo.jpg": hashlib.sha256(wallpaper).hexdigest()}),
                         "a download adds its wallpapers and its marker, and records only the wallpapers")
            (dest / "colors.toml").unlink()

            blueprint = helper.load_theme_package("demo")
            assert_equal(len(blueprint["backgrounds"]), 1, "the theme now has a wallpaper")
            # Two questions, two flags. The download landed in the directory a
            # user overlay uses, so it IS a change to the package the badge and
            # the revert control read; what it is not is an edit the user made,
            # which is what decides whether the shipped screenshot still
            # describes the theme.
            assert_equal((blueprint["modified"], blueprint["catalogPristine"]), (True, True),
                         "an untouched download is a change to the package, not a user edit")

            after = _catalog_entry("demo")
            assert_equal((after["imageryInstalled"], after["downloaded"], after["imageryUpdateAvailable"]),
                         (True, True, False), "the downloaded wallpapers report installed and current")
            again = helper.catalog_download_theme(entry, base_urls, allow_local)
            assert_equal(again["status"], "skipped", "installed wallpapers are not re-downloaded")

            # A package update that pins another archive offers the new wallpapers,
            # and a forced download replaces the ones the earlier download placed.
            _write_catalog(builtin, archives, "demo", _theme_archive({"backgrounds/1-demo.jpg": b"newer\n"}), rev=2)
            assert_equal(_catalog_entry("demo")["imageryUpdateAvailable"], True,
                         "a catalog pinning another archive than the download reports an update")
            newer = helper.catalog_theme_entry(helper.load_theme_catalog(), "demo")
            helper.catalog_download_theme(newer, base_urls, allow_local, force=True)
            assert_equal(((dest / "backgrounds" / "1-demo.jpg").read_bytes(), helper.catalog_marker("demo")["files"],
                          _catalog_entry("demo")["imageryUpdateAvailable"]),
                         (b"newer\n", {"backgrounds/1-demo.jpg": hashlib.sha256(b"newer\n").hexdigest()}, False),
                         "a forced download replaces the wallpapers an earlier download placed")
            _write_catalog(builtin, archives, "demo", blob)
            helper.catalog_download_theme(entry, base_urls, allow_local, force=True)

            listed = _theme_list_entries()["demo"]
            assert_equal((listed["preview"], listed["installed"]), (str(preview), True),
                         "an untouched download keeps the preview the package ships and installs the theme")
            # The settings tabs hide the modified badge and the Revert control on
            # modified && !catalogPristine.
            assert_equal((listed.get("modified"), listed.get("catalogPristine"), listed.get("catalogOwned")),
                         (True, True, True), "theme list reports the flags for an untouched download")
            # A star files the download rather than editing it.
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["star", "demo"]), 0, "theme star exit status on a download")
            starred = _theme_list_entries()["demo"]
            assert_equal((starred["starred"], starred["catalogPristine"], starred["preview"]), (True, True, str(preview)),
                         "a starred download stays pristine and keeps the preview the package ships")
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["unstar", "demo"]), 0, "theme unstar exit status on a download")

            # Every overlay write adds a file beside the downloaded set.
            for label, rel, content in (
                ("an app colour override", "app-colors.toml", '[btop]\nfg = "#ffffff"\n'),
                ("restyle adjustments", "theme.json",
                 json.dumps({"adjustments": helper.normalize_adjustments({"brightness": 17})})),
                ("a hidden background", "theme.json", json.dumps({"hiddenBackgrounds": ["1-demo.jpg"]})),
            ):
                (dest / rel).write_text(content + "\n")
                edited = _theme_list_entries()["demo"]
                assert_equal((edited.get("modified"), edited.get("catalogPristine"), edited["preview"]),
                             (True, False, str(preview)),
                             f"{label} beside a download is a user edit that keeps the preview the package ships")
                (dest / rel).unlink()

            # Revert drops the overlay and keeps the wallpapers it cannot fetch back.
            (dest / "app-colors.toml").write_text('[btop]\nfg = "#ffffff"\n')
            with contextlib.redirect_stdout(io.StringIO()):
                reverted = helper.cmd_theme(["revert", "demo"])
            assert_equal((reverted, _user_files(dest), helper.catalog_pristine("demo")),
                         (0, [helper.CATALOG_MARKER, "backgrounds/1-demo.jpg"], True),
                         "revert drops the overlay beside a download and keeps its wallpapers")

            # A marker with no file list names no download, so the directory is a
            # plain overlay: revert drops all of it and remove refuses it.
            marker_path = dest / helper.CATALOG_MARKER
            marker = json.loads(marker_path.read_text())
            marker.pop("files")
            marker_path.write_text(json.dumps(marker, indent=2) + "\n")
            legacy = helper.load_theme_package("demo")
            assert_equal((legacy["modified"], legacy["catalogPristine"], legacy["catalogOwned"]), (True, False, False),
                         "a marker with no file list names no download")
            try:
                helper.catalog_remove_theme("demo")
                raise AssertionError("remove must refuse a marker with no file list")
            except ValueError:
                pass
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal((helper.cmd_theme(["revert", "demo"]), dest.exists()), (0, False),
                             "revert drops a directory whose marker lists no files")
            helper.catalog_download_theme(entry, base_urls, allow_local)

            # The two writers of a built-in theme's overlay leave the download reading as edited.
            for label, edit in (
                ("a persisted colour edit", lambda: helper.persist_color_edits(
                    ["background=#ff0000"], "demo")),
                ("a curated app recolour", lambda: assert_equal(helper.cmd_theme([
                    "app-curated-recolor", "btop", "--theme", "demo",
                    "--set", "#101010=#00ff00", "--json"]), 0,
                    "app-curated-recolor exit status")),
            ):
                shutil.rmtree(dest)
                helper.catalog_download_theme(entry, base_urls, allow_local)
                assert_equal(_theme_list_entries()["demo"]["catalogPristine"], True,
                             f"the download is untouched before {label}")
                with contextlib.redirect_stdout(io.StringIO()):
                    edit()
                written = _theme_list_entries()["demo"]
                assert_equal((written.get("modified"), written.get("catalogPristine")),
                             (True, False),
                             f"{label} leaves the download reading as edited")

            # A directory an earlier release downloaded whole lists its definitions
            # too. Only its wallpapers count as the download, so the definitions
            # read as a user overlay: revert drops them and keeps the wallpaper.
            for rel, content in (("theme.json", '{"name":"demo","mode":"dark","source":"curated"}\n'),
                                 ("colors.toml", 'background = "#303030"\nforeground = "#eeeeee"\n'),
                                 ("apps/btop.theme", 'theme[main_bg]="#303030"\n')):
                (dest / rel).parent.mkdir(parents=True, exist_ok=True)
                (dest / rel).write_text(content)
            # The released helper wrote that record as a list, with no digests.
            whole = sorted(["theme.json", "colors.toml", "apps/btop.theme", "backgrounds/1-demo.jpg"])
            marker_path.write_text(json.dumps(helper.catalog_marker_payload(
                "demo", dest, entry["assets"], whole, 1, "v0.5.0"), indent=2) + "\n")
            earlier = helper.load_theme_package("demo")
            assert_equal((earlier["catalogPristine"], earlier["palette"]["extendedColors"]["background"]),
                         (False, "#303030"), "a whole-package download reads as an edited overlay")
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["revert", "demo"]), 0, "revert exit status")
            reverted = helper.load_theme_package("demo")
            assert_equal((_user_files(dest), reverted["catalogPristine"],
                          reverted["palette"]["extendedColors"]["background"]),
                         ([helper.CATALOG_MARKER, "backgrounds/1-demo.jpg"], True, "#101010"),
                         "revert drops the old definitions, keeps the wallpaper, and the built-in colour loads")

            # A wallpaper the user put there under the archive's name stays theirs.
            shutil.rmtree(dest)
            (dest / "backgrounds").mkdir(parents=True)
            (dest / "backgrounds" / "1-demo.jpg").write_bytes(b"the user's own image\n")
            forced = helper.catalog_download_theme(entry, base_urls, allow_local, force=True)
            assert_equal((forced["status"], (dest / "backgrounds" / "1-demo.jpg").read_bytes(),
                          helper.catalog_marker("demo")["files"]),
                         ("installed", b"the user's own image\n", {}),
                         "a download never replaces a file it did not place, nor records it")

            # A package carrying its own wallpapers, the default theme's, stays refused.
            (builtin / "demo" / "backgrounds").mkdir()
            (builtin / "demo" / "backgrounds" / "1-demo.jpg").write_bytes(wallpaper)
            shutil.rmtree(dest)
            bundled = helper.catalog_download_theme(entry, base_urls, allow_local)
            assert_equal((bundled["status"], bundled["reason"]),
                         ("skipped", "already installed as a built-in theme"),
                         "a built-in theme that carries its own wallpapers stays refused")
        finally:
            helper.builtin_themes_dir = original_builtin
            os.environ.pop("VGS_THEME_CATALOG_BASE_URL", None)

    with_temp_home(scenario)


def test_theme_catalog_wallpaper_add_keeps_the_download_offered():
    """A wallpaper the user adds to a theme with no download is not the theme's imagery: the download stays offered and still lands."""
    wallpaper = b"\xff\xd8\xff\xe0 demo wallpaper bytes\n"
    blob = _theme_archive({"backgrounds/1-demo.jpg": wallpaper})

    def scenario(tmp: Path):
        builtin = tmp / "builtin"
        (builtin / "demo").mkdir(parents=True)
        (builtin / "demo" / "theme.json").write_text('{"name":"demo","mode":"dark","source":"curated"}\n')
        (builtin / "demo" / "colors.toml").write_text('background = "#101010"\nforeground = "#eeeeee"\n')
        archives = tmp / "releases"
        _write_catalog(builtin, archives, "demo", blob)
        own = tmp / "mine.jpg"
        own.write_bytes(b"\xff\xd8 the user's own image\n")
        original_builtin = helper.builtin_themes_dir
        saved_base = os.environ.get("VGS_THEME_CATALOG_BASE_URL")
        helper.builtin_themes_dir = lambda: builtin
        os.environ["VGS_THEME_CATALOG_BASE_URL"] = "file://" + str(archives)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["wallpaper-add", str(own), "--theme", "demo"]), 0, "wallpaper-add exit status")
            assert_equal(_catalog_entry("demo")["imageryInstalled"], False,
                         "a wallpaper the user added leaves the theme's imagery reported not installed")
            catalog = helper.load_theme_catalog()
            base_urls, allow_local = helper.theme_catalog_base_urls(catalog)
            result = helper.catalog_download_theme(helper.catalog_theme_entry(catalog, "demo"), base_urls, allow_local)
            dest = helper.user_themes_dir() / "demo" / "backgrounds"
            assert_equal((result["status"], (dest / "1-demo.jpg").read_bytes(), (dest / "mine.jpg").is_file(),
                          _catalog_entry("demo")["imageryInstalled"]),
                         ("installed", wallpaper, True, True),
                         "the download places the archive beside the added wallpaper, then reports installed")
        finally:
            helper.builtin_themes_dir = original_builtin
            _restore_env("VGS_THEME_CATALOG_BASE_URL", saved_base)

    with_temp_home(scenario)


def _write_builtin_theme(builtin: Path, name: str, backgrounds: tuple = ()) -> Path:
    """A packaged theme under the test's built-in directory, shipping `backgrounds` under its backgrounds/."""
    package = builtin / name
    package.mkdir(parents=True, exist_ok=True)
    (package / "theme.json").write_text(json.dumps({"name": name, "mode": "dark", "source": "curated"}) + "\n")
    (package / "colors.toml").write_text('background = "#101010"\nforeground = "#eeeeee"\n')
    for file in backgrounds:
        (package / "backgrounds").mkdir(exist_ok=True)
        (package / "backgrounds" / file).write_bytes(f"{name} {file}\n".encode())
    return package


def _theme_command_json(*argv: str) -> tuple:
    """A `theme` subcommand's exit status and, on success, its --json output."""
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(io.StringIO()):
        status = helper.cmd_theme([*argv, "--json"])
    return status, json.loads(buffer.getvalue()) if status == 0 else None


def test_theme_wallpaper_remove_keeps_the_file_and_the_download_installed():
    """`wallpaper-remove` takes downloaded wallpapers out of a theme's set and deletes nothing.

    The set it leaves is the user's: the imagery still reads installed, so no
    download card and no apply-time offer returns, a forced download restores
    neither removed file, `wallpapers --all` lists both as removed and thumbnails
    stay built for them, and `wallpaper-add` on a removed file, downloaded or
    packaged, puts it back without copying it.
    """
    archive = {f"backgrounds/{n}-demo.jpg": f"demo {n}\n".encode() for n in range(1, 5)}

    def scenario(tmp: Path):
        builtin = tmp / "builtin"
        _write_builtin_theme(builtin, "demo")
        _write_builtin_theme(builtin, "shipped", ("x.jpg",))
        archives = tmp / "releases"
        _write_catalog(builtin, archives, "demo", _theme_archive(archive))
        original_builtin = helper.builtin_themes_dir
        saved_base = os.environ.get("VGS_THEME_CATALOG_BASE_URL")
        helper.builtin_themes_dir = lambda: builtin
        os.environ["VGS_THEME_CATALOG_BASE_URL"] = "file://" + str(archives)
        try:
            catalog = helper.load_theme_catalog()
            base_urls, allow_local = helper.theme_catalog_base_urls(catalog)
            entry = helper.catalog_theme_entry(catalog, "demo")
            helper.catalog_download_theme(entry, base_urls, allow_local)
            wallpapers = helper.user_themes_dir() / "demo" / "backgrounds"

            def theme_set() -> list:
                return [item["file"] for item in _theme_command_json("wallpapers", "demo")[1]["wallpapers"]]

            assert_equal([_theme_command_json("wallpaper-remove", name, "--theme", "demo")[0]
                          for name in ("1-demo.jpg", "3-demo.jpg")], [0, 0], "wallpaper-remove exit status")
            listed = _theme_command_json("wallpapers", "--all", "--folder", str(tmp / "no-folder"))[1]["wallpapers"]
            for label, actual, expected in (
                ("removal deletes no file", sorted(p.name for p in wallpapers.iterdir()),
                 ["1-demo.jpg", "2-demo.jpg", "3-demo.jpg", "4-demo.jpg"]),
                ("the theme's set lists what the user kept", theme_set(), ["2-demo.jpg", "4-demo.jpg"]),
                ("wallpapers --all lists the removed files after the set, marked removed",
                 [(item["file"], item.get("removed", False)) for item in listed if item["source"] == "demo"],
                 [("2-demo.jpg", False), ("4-demo.jpg", False), ("1-demo.jpg", True), ("3-demo.jpg", True)]),
                ("the thumbnail build and prune still cover the removed files",
                 sorted(p.name for p in helper.installed_wallpaper_paths() if p.parent == wallpapers),
                 ["1-demo.jpg", "2-demo.jpg", "3-demo.jpg", "4-demo.jpg"]),
                ("the catalog offers no download or update card for the kept set",
                 (_catalog_entry("demo")["imageryInstalled"], _catalog_entry("demo")["imageryUpdateAvailable"]), (True, False)),
                ("theme list reports the imagery installed, so an apply offers no download",
                 _theme_list_entries()["demo"]["installed"], True),
            ):
                assert_equal(actual, expected, label)
            forced = helper.catalog_download_theme(entry, base_urls, allow_local, force=True)
            assert_equal((forced["status"], theme_set()), ("installed", ["2-demo.jpg", "4-demo.jpg"]),
                         "a deliberate download restores nothing the user removed")
            added = _theme_command_json("wallpaper-add", str(wallpapers / "1-demo.jpg"), "--theme", "demo")[0]
            assert_equal((added, theme_set(), len(list(wallpapers.iterdir()))), (0, ["1-demo.jpg", "2-demo.jpg", "4-demo.jpg"], 4),
                         "adding a removed file back puts it in the set without a copy")
            shipped = builtin / "shipped" / "backgrounds" / "x.jpg"
            statuses = (_theme_command_json("wallpaper-remove", "x.jpg", "--theme", "shipped")[0],
                        _theme_command_json("wallpaper-add", str(shipped), "--theme", "shipped")[0])
            assert_equal((statuses, [item["file"] for item in _theme_command_json("wallpapers", "shipped")[1]["wallpapers"]],
                          sorted(p.name for p in (helper.user_themes_dir() / "shipped" / "backgrounds").glob("*"))),
                         ((0, 0), ["x.jpg"], []),
                         "adding a removed packaged wallpaper back puts it in the set without copying it into the user directory")
        finally:
            helper.builtin_themes_dir = original_builtin
            _restore_env("VGS_THEME_CATALOG_BASE_URL", saved_base)

    with_temp_home(scenario)


def test_theme_wallpaper_delete_removes_the_file_and_its_set_names():
    """`wallpaper-delete` deletes one wallpaper inside the wallpaper folder or a user theme's backgrounds.

    It drops the hidden and default names the theme holds for the file unless
    the package ships a file of that name, and refuses a file outside those
    roots, a non-image, a missing file and one the shell still names, deleting
    nothing.
    """
    def scenario(tmp: Path):
        builtin = tmp / "builtin"
        _write_builtin_theme(builtin, "shipped", ("gone.jpg",))
        package = helper.user_themes_dir() / "mine"
        wallpapers = package / "backgrounds"
        wallpapers.mkdir(parents=True)
        (package / "theme.json").write_text(json.dumps({"name": "mine", "mode": "dark", "source": "curated",
                                                        "hiddenBackgrounds": ["gone.jpg", "kept.jpg"], "wallpaper": "gone.jpg"}))
        (package / "colors.toml").write_text('background = "#101010"\nforeground = "#eeeeee"\n')
        for name in ("gone.jpg", "kept.jpg", "shown.jpg"):
            (wallpapers / name).write_bytes(b"theme wallpaper\n")
        (package / "extras").mkdir()
        (package / "extras" / "x.png").write_bytes(b"theme file outside backgrounds\n")
        folder = tmp / "Pictures"
        (folder / "sub").mkdir(parents=True)
        (folder / "loose.png").write_bytes(b"folder image\n")
        (folder / "sub" / "deep.png").write_bytes(b"image below the folder\n")
        (folder / "notes.txt").write_text("not an image\n")
        outside = tmp / "elsewhere.jpg"
        outside.write_bytes(b"not a wallpaper root\n")
        shown = ["--applied", str(wallpapers / "shown.jpg")]
        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin

        def delete(path: Path, *extra: str) -> tuple:
            return _theme_command_json("wallpaper-delete", str(path), "--folder", str(folder), *extra)

        try:
            for label, path in (
                ("a file outside the wallpaper folder and the user theme directories is refused", outside),
                ("a wallpaper the shell still names is refused", wallpapers / "shown.jpg"),
                ("an image in a user theme directory outside backgrounds/ is refused", package / "extras" / "x.png"),
                ("an image below the wallpaper folder rather than directly inside it is refused", folder / "sub" / "deep.png"),
                ("a file without an image suffix is refused", folder / "notes.txt"),
                ("a missing image is refused", folder / "absent.png"),
            ):
                present = path.exists()
                assert_equal((delete(path, *shown)[0], path.exists()), (1, present), label)
            status, result = delete(wallpapers / "gone.jpg", *shown)
            meta = json.loads((package / "theme.json").read_text())
            assert_equal((status, (wallpapers / "gone.jpg").exists(), result["deleted"], result["themes"],
                          meta.get("hiddenBackgrounds"), "wallpaper" in meta),
                         (0, False, str(wallpapers.resolve() / "gone.jpg"), ["mine"], ["kept.jpg"], False),
                         "a theme's wallpaper is deleted with the hidden and default names its theme held for it")
            status, result = delete(folder / "loose.png", *shown)
            assert_equal((status, (folder / "loose.png").exists(), result["themes"]), (0, False, []),
                         "an image in the wallpaper folder is deleted and names no theme")
            copy = helper.user_themes_dir() / "shipped" / "backgrounds" / "gone.jpg"
            copy.parent.mkdir(parents=True)
            copy.write_bytes(b"user copy over the packaged file\n")
            (copy.parent.parent / "theme.json").write_text(json.dumps({"hiddenBackgrounds": ["gone.jpg"]}))
            status = delete(copy, *shown)[0]
            assert_equal((status, copy.exists(), sorted(helper.hidden_background_names(helper.read_theme_overlay_meta("shipped")))),
                         (0, False, ["gone.jpg"]),
                         "the hidden name stays while the package ships a file of that name, which it still hides")
        finally:
            helper.builtin_themes_dir = original_builtin

    with_temp_home(scenario)


def test_theme_catalog_update_keeps_the_users_wallpapers():
    """`theme catalog update` replaces only the wallpapers a download placed and the user left alone.

    One update from r1 to r2 reaches every case; each row names one wallpaper
    and the bytes and marker record the update must leave for it.
    """
    first = {"backgrounds/1-demo.jpg": b"r1 one\n", "backgrounds/2-demo.jpg": b"r1 two\n",
             "backgrounds/3-demo.jpg": b"r1 three\n", "backgrounds/4-demo.jpg": b"r1 four\n",
             "backgrounds/5-demo.jpg": b"r1 five\n", "backgrounds/8-demo.jpg": b"r1 eight\n"}
    second = {"backgrounds/1-demo.jpg": b"r2 one\n", "backgrounds/2-demo.jpg": b"r2 two\n",
              "backgrounds/3-demo.jpg": b"r2 three\n", "backgrounds/6-demo.jpg": b"r2 six\n",
              "backgrounds/7-demo.jpg": b"r2 seven\n", "backgrounds/8-demo.jpg": b"r2 eight\n"}

    def scenario(tmp: Path):
        builtin = tmp / "builtin"
        (builtin / "demo").mkdir(parents=True)
        (builtin / "demo" / "theme.json").write_text('{"name":"demo","mode":"dark","source":"curated"}\n')
        (builtin / "demo" / "colors.toml").write_text('background = "#101010"\nforeground = "#eeeeee"\n')
        archives = tmp / "releases"
        _write_catalog(builtin, archives, "demo", _theme_archive(first))

        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        os.environ["VGS_THEME_CATALOG_BASE_URL"] = "file://" + str(archives)
        try:
            catalog = helper.load_theme_catalog()
            base_urls, allow_local = helper.theme_catalog_base_urls(catalog)
            helper.catalog_download_theme(helper.catalog_theme_entry(catalog, "demo"), base_urls, allow_local)
            dest = helper.user_themes_dir() / "demo"
            wallpapers = dest / "backgrounds"
            (wallpapers / "2-demo.jpg").write_bytes(b"user two\n")
            (wallpapers / "5-demo.jpg").write_bytes(b"user five\n")
            added = tmp / "6-demo.jpg"
            added.write_bytes(b"user six\n")
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal((helper.cmd_theme(["wallpaper-add", str(added), "--theme", "demo"]),
                              helper.cmd_theme(["wallpaper-remove", "3-demo.jpg", "--theme", "demo"]),
                              helper.cmd_theme(["wallpaper-delete", str(wallpapers / "8-demo.jpg")])),
                             (0, 0, 0), "wallpaper-add, wallpaper-remove and wallpaper-delete exit status")

            _write_catalog(builtin, archives, "demo", _theme_archive(second), release="themes-v2", rev=2)
            entry = helper.catalog_theme_entry(helper.load_theme_catalog(), "demo")
            marker_path = dest / helper.CATALOG_MARKER
            downloaded = json.loads(marker_path.read_text())
            before = {rel: (dest / rel).read_bytes() for rel in _user_files(dest)}

            # A package copied here from elsewhere carries a marker naming another directory.
            marker_path.write_text(json.dumps({**downloaded, "path": str(tmp / "elsewhere" / "demo")}))
            try:
                helper.catalog_update_theme(entry, base_urls, allow_local)
                raise AssertionError("an update must refuse a fork")
            except ValueError:
                pass
            assert_equal((helper.catalog_updates(), _catalog_entry("demo")["imageryUpdateAvailable"]), ([], False),
                         "a fork reports no update")

            # A marker the released helper wrote records its wallpapers as a list.
            marker_path.write_text(json.dumps({**downloaded, "files": sorted(downloaded["files"])}))
            listed = helper.catalog_updates()
            try:
                helper.catalog_update_theme(entry, base_urls, allow_local)
                raise AssertionError("an update must refuse a marker with no digests")
            except ValueError:
                pass
            assert_equal(([item["digests"] for item in listed],
                          {rel: (dest / rel).read_bytes() for rel in _user_files(dest) if rel != helper.CATALOG_MARKER}),
                         ([False], {rel: blob for rel, blob in before.items() if rel != helper.CATALOG_MARKER}),
                         "a list-shaped marker still lists its update and the update refuses it, touching no file")

            marker_path.write_text(json.dumps(downloaded))

            def catalog_command(*argv: str) -> tuple:
                buffer = io.StringIO()
                with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(io.StringIO()):
                    status = helper.cmd_theme(["catalog", *argv])
                return status, json.loads(buffer.getvalue()) if "--json" in argv else None

            listed_status, listed = catalog_command("updates", "--json")
            assert_equal((listed_status, [(item["name"], item["installedRev"], item["latestRev"], item["digests"])
                                          for item in listed["themes"]]),
                         (0, [("demo", 1, 2, True)]), "an owned download with digests lists its update")
            assert_equal(catalog_command("update")[0], 2, "an update with no names and no --all is a usage error")
            status, updated = catalog_command("update", "--all", "--json")
            assert_equal((status, updated["success"], updated["updated"]), (0, True, ["demo"]),
                         "update --all updates the pending download")
            result = updated["results"][0]
            for label, name, content in (
                ("a pristine wallpaper is replaced", "1-demo.jpg", b"r2 one\n"),
                ("a wallpaper the user edited is kept", "2-demo.jpg", b"user two\n"),
                ("a pristine wallpaper removed from the set through wallpaper-remove is still replaced", "3-demo.jpg", b"r2 three\n"),
                ("a pristine wallpaper the new archive drops is removed", "4-demo.jpg", None),
                ("an edited wallpaper the new archive drops is kept", "5-demo.jpg", b"user five\n"),
                ("a wallpaper added through wallpaper-add is never touched", "6-demo.jpg", b"user six\n"),
                ("a wallpaper new in the archive is added", "7-demo.jpg", b"r2 seven\n"),
                ("a placed wallpaper the user deleted through wallpaper-delete stays deleted", "8-demo.jpg", None),
            ):
                path = wallpapers / name
                assert_equal(path.read_bytes() if path.exists() else None, content, label)
            digest = lambda blob: hashlib.sha256(blob).hexdigest()
            assert_equal(helper.catalog_marker("demo")["files"], {
                "backgrounds/1-demo.jpg": digest(second["backgrounds/1-demo.jpg"]),
                "backgrounds/2-demo.jpg": digest(first["backgrounds/2-demo.jpg"]),
                "backgrounds/3-demo.jpg": digest(second["backgrounds/3-demo.jpg"]),
                "backgrounds/5-demo.jpg": digest(first["backgrounds/5-demo.jpg"]),
                "backgrounds/7-demo.jpg": digest(second["backgrounds/7-demo.jpg"]),
                "backgrounds/8-demo.jpg": digest(first["backgrounds/8-demo.jpg"]),
            }, "the marker records replaced and added wallpapers at the new digest and kept ones at the digest "
               "they were placed with, and never records a pristine file the archive dropped or a user-added file")
            assert_equal("3-demo.jpg" in [Path(p).name for p in helper.load_theme_package("demo")["backgrounds"]], False,
                         "the update restores nothing the user removed from the set")
            assert_equal((result["status"], result["fromRev"], result["toRev"], helper.catalog_marker("demo")["rev"],
                          helper.catalog_updates()),
                         ("updated", 1, 2, 2, []),
                         "the update records the new pin, so nothing is left to update")
            status, again = catalog_command("update", "demo", "missing", "--json")
            assert_equal((status, again["success"], again["updated"],
                          [(item["name"], item["status"]) for item in again["results"]]),
                         (1, False, [], [("demo", "current"), ("missing", "failed")]),
                         "an update naming a theme outside the catalog fails with exit 1, and a current one stays current")
        finally:
            helper.builtin_themes_dir = original_builtin
            os.environ.pop("VGS_THEME_CATALOG_BASE_URL", None)

    with_temp_home(scenario)


def test_theme_catalog_download_verifies_its_archive():
    """A catalog download must land the published archive verbatim, and refuse anything else."""
    package = {
        "backgrounds/1-demo.jpg": b"\xff\xd8\xff\xe0 demo wallpaper bytes\n",
        "backgrounds/2-demo.png": b"\x89PNG\r\n\x1a\n demo wallpaper bytes\n",
    }

    def scenario(tmp: Path):
        builtin = tmp / "builtin"
        builtin.mkdir()
        archives = tmp / "releases"
        blob = _theme_archive(package)
        _write_catalog(builtin, archives, "demo", blob)

        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        os.environ["VGS_THEME_CATALOG_BASE_URL"] = "file://" + str(archives)
        try:
            catalog = helper.load_theme_catalog()
            base_urls, allow_local = helper.theme_catalog_base_urls(catalog)
            entry = helper.catalog_theme_entry(catalog, "demo")
            cache = helper.theme_asset_cache_dir()

            # A thumbnail is never reported as a preview, with or without wallpapers.
            thumbnail = builtin / "thumbnails" / "demo.jpg"
            thumbnail.parent.mkdir(parents=True)
            thumbnail.write_bytes(b"\xff\xd8\xff thumbnail bytes\n")
            before = _catalog_entry("demo")
            assert_equal((before["imageryInstalled"], before["preview"]), (False, ""),
                         "a theme with no preview.jpg and no wallpapers reports no preview")

            result = helper.catalog_download_theme(entry, base_urls, allow_local)
            assert_equal(result["status"], "installed", "catalog download status")
            dest = helper.user_themes_dir() / "demo"
            for rel, blob_bytes in package.items():
                assert_equal((dest / rel).read_bytes(), blob_bytes,
                             f"downloaded {rel} must be byte-identical")
            marker = helper.catalog_marker("demo")
            assert_equal((marker.get("ref"), marker.get("release"), marker.get("rev")),
                         ("vTest", "themes-v1", 1), "download marker records the ref and the release")
            # The cache holds in-flight downloads only: a finished install leaves
            # no archive behind, so the disk cost is exactly the theme tree.
            assert_equal(sorted(p.name for p in cache.glob("*")), [],
                         "a successful install deletes its cached archive")

            listed = _catalog_entry("demo")
            assert_equal((listed["imageryInstalled"], listed["downloaded"]), (True, True), "catalog list state")

            again = helper.catalog_download_theme(entry, base_urls, allow_local)
            assert_equal(again["status"], "skipped", "an installed theme is not re-downloaded")

            # A force re-download must never destroy the installed copy before
            # its replacement is in place: a failure mid-way leaves it intact.
            tampered_force = json.loads(json.dumps(entry))
            tampered_force["assets"]["sha256"] = "1" * 64
            try:
                helper.catalog_download_theme(tampered_force, base_urls, allow_local, force=True)
                raise AssertionError("a tampered force re-download must fail")
            except ValueError:
                pass
            assert_equal((dest / "backgrounds" / "1-demo.jpg").read_bytes(), package["backgrounds/1-demo.jpg"],
                         "a failed force re-download must leave the installed wallpapers in place")
            assert_equal(sorted(p.name for p in helper.user_themes_dir().glob(".catalog-*")), [],
                         "a failed force re-download leaves no staging dir")
            assert_equal(sorted(p.name for p in cache.glob("*")), [],
                         "a failed download leaves no cached archive")

            # Reading the current theme for the safety check must not apply the
            # default theme: current_theme() writes files and runs hooks when
            # ~/.config/vshell/theme.json is absent.
            assert_equal((helper.cfg_dir() / "theme.json").exists(), False, "no theme state before remove")
            (dest / "colors.toml").write_text('background = "#202020"\n')
            assert_equal(helper.catalog_remove_theme("demo")["status"], "removed", "catalog remove")
            assert_equal(_user_files(dest), ["colors.toml"],
                         "catalog remove deletes the wallpapers and the marker, and keeps the overlay")
            (dest / "colors.toml").unlink()
            dest.rmdir()
            assert_equal((helper.cfg_dir() / "theme.json").exists(), False,
                         "catalog remove must not apply the default theme as a side effect")

            # A removal that cannot proceed must fail loudly, not report success.
            helper.catalog_download_theme(entry, base_urls, allow_local)
            (dest / "backgrounds").chmod(0o555)
            try:
                helper.catalog_remove_theme("demo")
                raise AssertionError("undeletable wallpapers must not report removal")
            except ValueError:
                pass
            finally:
                (dest / "backgrounds").chmod(0o755)
            assert_equal((dest / helper.CATALOG_MARKER).is_file(), True,
                         "a failed removal keeps the marker, so the removal can be retried")
            assert_equal(helper.catalog_remove_theme("demo")["status"], "removed", "removal after the block")

            # Downloads must not hold the theme lock while bytes move; applies and restyles
            # need that same lock.
            lock_free_during_transfer = []
            original_fetch = helper._catalog_fetch_verified

            def probing_fetch(*fetch_args, **fetch_kwargs):
                lock_path = helper.cfg_dir() / ".theme-mutation.lock"
                lock_path.parent.mkdir(parents=True, exist_ok=True)
                probe = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
                try:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    lock_free_during_transfer.append(True)
                    fcntl.flock(probe, fcntl.LOCK_UN)
                except OSError:
                    lock_free_during_transfer.append(False)
                finally:
                    os.close(probe)
                return original_fetch(*fetch_args, **fetch_kwargs)

            helper._catalog_fetch_verified = probing_fetch
            try:
                helper.catalog_download_theme(entry, base_urls, allow_local)
            finally:
                helper._catalog_fetch_verified = original_fetch
            assert_equal(lock_free_during_transfer, [True],
                         "the theme mutation lock must stay free while a download transfers")
            helper.catalog_remove_theme("demo")

            # A duplicate of a downloaded theme inherits the marker file, so
            # ownership must be identity, not presence — otherwise `catalog
            # remove` deletes the user's own copy.
            helper.catalog_download_theme(entry, base_urls, allow_local)
            copy = helper.user_themes_dir() / "mycopy"
            shutil.copytree(dest, copy)
            assert_equal(helper.catalog_owns("mycopy"), False, "a copied marker must not confer ownership")
            try:
                helper.catalog_remove_theme("mycopy")
                raise AssertionError("removing a copy of a downloaded theme must fail")
            except ValueError:
                pass
            assert_equal((copy / "backgrounds" / "1-demo.jpg").is_file(), True, "the user's copy survives")
            assert_equal([e["downloaded"] for e in helper.catalog_entries() if e["name"] == "demo"], [True],
                         "the downloaded theme is still reported as downloaded")
            shutil.rmtree(copy)
            assert_equal(helper.catalog_remove_theme("demo")["status"], "removed", "the original is still removable")

            # A hand-made user theme carries no marker: remove must refuse it.
            (helper.user_themes_dir() / "mine").mkdir(parents=True)
            try:
                helper.catalog_remove_theme("mine")
                raise AssertionError("removing a non-downloaded theme must fail")
            except ValueError:
                pass
            assert_equal((helper.user_themes_dir() / "mine").exists(), True, "local theme survives a refused remove")

            # Several locations are tried in order and only checksum-matching
            # bytes are accepted, so a stale first location cannot serve a
            # different archive and cannot stop a good location from working.
            stale = tmp / "stale"
            (stale / "themes-v1").mkdir(parents=True)
            (stale / "themes-v1" / "vgs-theme-demo-r1.tar.gz").write_bytes(
                _theme_archive({"backgrounds/1-demo.jpg": b"stale wallpaper\n"}))
            stale_url = "file://" + str(stale)
            result = helper.catalog_download_theme(entry, [stale_url, base_urls[0]], allow_local)
            assert_equal(result["status"], "installed", "a stale first location must fall through")
            assert_equal((dest / "backgrounds" / "1-demo.jpg").read_bytes(), package["backgrounds/1-demo.jpg"],
                         "the accepted bytes are the catalogued ones, never the stale location's")
            helper.catalog_remove_theme("demo")
            try:
                helper.catalog_download_theme(entry, [stale_url], allow_local)
                raise AssertionError("no matching location must fail the download")
            except ValueError as exc:
                assert_equal("no source served" in str(exc), True, "failure names the exhausted locations")

            # The catalogued size is the read cap, so a location that keeps
            # sending is cut off there instead of at the far larger per-file
            # ceiling. Without it the peak buffer is whatever the server sends.
            overlong = json.loads(json.dumps(entry))
            overlong["assets"]["size"] = len(blob) - 16
            try:
                helper.catalog_download_theme(overlong, base_urls, allow_local)
                raise AssertionError("an archive longer than its catalogued size must be refused")
            except ValueError as exc:
                assert_equal("exceeds the catalogued" in str(exc), True,
                             "the refusal names the catalogued size as the cap")
            assert_equal(sorted(p.name for p in cache.glob("*")), [],
                         "an over-long download leaves nothing in the cache")

            # An archive whose bytes do not match the catalogued checksum is
            # never unpacked, so a replaced release asset cannot install itself.
            tampered = json.loads(json.dumps(entry))
            tampered["assets"]["sha256"] = "0" * 64
            try:
                helper.catalog_download_theme(tampered, base_urls, allow_local)
                raise AssertionError("checksum mismatch must fail the download")
            except ValueError:
                pass
            assert_equal(dest.exists(), False, "a failed download leaves no theme dir")
            assert_equal(list(helper.user_themes_dir().glob(".catalog-*")), [],
                         "a failed download leaves no staging dir")

            # A catalog entry whose archive pin is unusable is refused before any
            # of it becomes a URL or a path, so no request is ever made for it.
            for label, patch in (
                ("release", {"release": "../../etc"}),
                ("release", {"release": "latest"}),
                ("archive", {"archive": "../../etc/passwd"}),
                ("archive", {"archive": "demo.tar.gz"}),
                ("checksum", {"sha256": "nothex"}),
                ("size", {"size": 0}),
                ("size", {"size": helper.CATALOG_MAX_FILE_BYTES + 1}),
            ):
                broken = json.loads(json.dumps(entry))
                broken["assets"].update(patch)
                try:
                    helper._catalog_check_assets("demo", broken["assets"])
                    raise AssertionError(f"an unusable {label} pin must be refused: {patch}")
                except ValueError:
                    pass
                try:
                    helper.catalog_download_theme(broken, base_urls, allow_local)
                    raise AssertionError(f"an unusable {label} pin must fail the download: {patch}")
                except ValueError:
                    pass

            # Archive members go through the imagery path rule, so a member
            # outside it cannot escape the staging directory or shadow a theme
            # definition the package ships, and a member that is not a regular
            # file is never followed.
            for label, member in (("escaping path", "../../evil"), ("dotfile", ".ssh/id_rsa"),
                                  ("nested", "backgrounds/season/img.png"),
                                  ("definition file", "theme.json"), ("app file", "apps/btop.theme"),
                                  ("preview", helper.THEME_PREVIEW_FILE)):
                hostile = _theme_archive({"backgrounds/1-demo.jpg": package["backgrounds/1-demo.jpg"], member: b"x"})
                _write_catalog(builtin, archives, "demo", hostile, rev=2)
                hostile_entry = helper.catalog_theme_entry(helper.load_theme_catalog(), "demo")
                try:
                    helper.catalog_download_theme(hostile_entry, base_urls, allow_local)
                    raise AssertionError(f"an archive member with an {label} must be refused")
                except ValueError:
                    pass
                assert_equal(dest.exists(), False, f"a refused {label} member leaves no theme dir")

            linked = io.BytesIO()
            with tarfile.open(fileobj=linked, mode="w:gz") as tar:
                info = tarfile.TarInfo("backgrounds/1-demo.jpg")
                info.size = len(package["backgrounds/1-demo.jpg"])
                tar.addfile(info, io.BytesIO(package["backgrounds/1-demo.jpg"]))
                link = tarfile.TarInfo("backgrounds/2-demo.png")
                link.type = tarfile.SYMTYPE
                link.linkname = "/etc/passwd"
                tar.addfile(link)
            _write_catalog(builtin, archives, "demo", linked.getvalue(), rev=3)
            link_entry = helper.catalog_theme_entry(helper.load_theme_catalog(), "demo")
            try:
                helper.catalog_download_theme(link_entry, base_urls, allow_local)
                raise AssertionError("a symlink member must be refused")
            except ValueError:
                pass
            assert_equal(dest.exists(), False, "a refused symlink member leaves no theme dir")

            for bad in ("../evil", "/etc/passwd", "apps/../../evil", ".ssh/id_rsa", "notes.txt",
                        "theme.json", "colors.toml", "apps/btop.theme", "preview.jpg", "backgrounds",
                        "apps/.hidden", "backgrounds/.env", "apps/../theme.json", "apps/", "apps//x",
                        "backgrounds/season/img.png", "apps\\evil", "theme.json\x00.sh"):
                try:
                    helper._catalog_check_relpath(bad)
                    raise AssertionError(f"catalog path {bad!r} must be rejected")
                except ValueError:
                    pass

            # https is the only scheme accepted without the test-only override.
            try:
                helper._catalog_check_scheme("file:///etc/passwd", False)
                raise AssertionError("non-https downloads must be refused")
            except ValueError:
                pass
            try:
                helper._catalog_fetch_to_file("file:///etc/passwd", cache / "leak.tar.gz",
                                              False, 1, "0" * 64)
                raise AssertionError("a non-https fetch must never write a file")
            except ValueError:
                pass
            assert_equal((cache / "leak.tar.gz").exists(), False,
                         "a refused fetch leaves nothing on disk")
        finally:
            helper.builtin_themes_dir = original_builtin
            os.environ.pop("VGS_THEME_CATALOG_BASE_URL", None)

    with_temp_home(scenario)


def test_theme_asset_publisher():
    """The publisher's archive shape, path rule, upload refusal and pull verification."""
    publisher = _load_script("publish_theme_assets_test", "publish-theme-assets.py")
    generator = _load_script("gen_theme_catalog_publisher_test", "gen-theme-catalog.py")
    from PIL import Image

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        source = root / "demo"
        (source / "backgrounds").mkdir(parents=True)
        (source / "backgrounds" / "1-demo.jpg").write_bytes(b"wallpaper\n")
        members = [("backgrounds/1-demo.jpg", source / "backgrounds" / "1-demo.jpg")]

        # Byte-reproducibility is what makes the unchanged-content skip work. Lose
        # it and every publish uploads a fresh revision of every theme into a
        # release D015 says is never deleted.
        class _ChangingSource:
            """A member source whose bytes differ on every read.

            A second read of an unchanged file is invisible, so proving that
            build_archive reads each member once needs a source that says so.
            """

            def __init__(self):
                self.reads = 0

            def read_bytes(self):
                self.reads += 1
                return f"read {self.reads}\n".encode()

        changing = _ChangingSource()
        once = publisher.build_archive([("backgrounds/1-demo.jpg", changing)])
        assert_equal(changing.reads, 1, "build_archive reads each member exactly once")
        with tarfile.open(fileobj=io.BytesIO(once), mode="r:gz") as tar:
            assert_equal(tar.extractfile("backgrounds/1-demo.jpg").read(), b"read 1\n",
                         "the archive carries the bytes of that one read")

        first = publisher.build_archive(members)
        assert_equal(publisher.build_archive(members), first,
                     "the same content must pack to the same archive bytes")
        with tarfile.open(fileobj=io.BytesIO(first), mode="r:gz") as tar:
            packed = tar.getmembers()
        assert_equal(sorted(m.name for m in packed), ["backgrounds/1-demo.jpg"],
                     "archive members are theme-package paths with no added prefix")
        for member in packed:
            # A member the downloader refuses fails every install of that theme
            # only after the whole archive has come down.
            helper._catalog_check_relpath(member.name)
            assert_equal(member.isfile(), True, f"{member.name} must be a regular file")

        # The imagery rule is the installer's own, so what the publisher packs is
        # what catalog_download_theme accepts: definitions and the preview stay behind.
        (source / "NOTES.md").write_text("scratch\n")
        (source / "theme.json").write_text('{"name":"demo"}\n')
        (source / helper.THEME_PREVIEW_FILE).write_bytes(b"preview\n")
        assert_equal(publisher.package_members("demo", source), members,
                     "an archive carries the wallpapers and nothing beside them")
        for label, rel in (("nested", "backgrounds/season/img.png"), ("dotfile", "backgrounds/.env")):
            bad = source / rel
            bad.parent.mkdir(parents=True, exist_ok=True)
            bad.write_bytes(b"x")
            try:
                publisher.imagery_relpaths(source)
                raise AssertionError(f"a {label} imagery path must fail the build")
            except SystemExit:
                pass
            bad.unlink()
        try:
            publisher.package_members("bare", root / "bare")
            raise AssertionError("a theme with no wallpapers must not publish an empty archive")
        except SystemExit:
            pass

        # The thumbnail is rebuilt when it is missing, which recovers a deleted
        # one, and when the preview's CONTENT differs from the one it came from.
        # An mtime-preserving copy can put different pixels under an older
        # timestamp, and a timestamp rule paints the wrong theme's screenshot.
        thumbnail = root / "demo.jpg"
        shots = []
        for colour in ((16, 16, 16), (200, 40, 40)):
            buffer = io.BytesIO()
            Image.new("RGB", (1280, 720), colour).save(buffer, "JPEG")
            shots.append(buffer.getvalue())
        publisher.write_thumbnail(shots[0], thumbnail)
        current, replaced = (hashlib.sha256(shot).hexdigest() for shot in shots)
        os.utime(thumbnail, (0, 0))
        for label, digest, recorded, present, expected in (
            ("missing thumbnail", current, current, False, True),
            ("unchanged preview", current, current, True, False),
            ("replaced preview", replaced, current, True, True),
        ):
            probe = thumbnail if present else (root / "absent.jpg")
            assert_equal(publisher.thumbnail_needs_rebuild(digest, recorded, probe), expected,
                         f"thumbnail rebuild decision for a {label}")

        # A published asset is never replaced, but an interrupted run that
        # already uploaded these exact bytes is a resume, not a collision.
        digest = hashlib.sha256(first).hexdigest()
        stage = root / "stage"
        stage.mkdir()
        uploads = []

        class _Release:
            REPO_SLUG = "vanillagreencom/vgs"

            def __init__(self, assets):
                self.assets = assets

            def gh_release(self, _tag):
                return None if self.assets is None else {"assets": [{"name": n} for n in self.assets]}

            def is_imagery(self, rel):
                return generator.is_imagery(rel)

        original_generator, original_gh, original_digest = (
            publisher.GENERATOR, publisher.gh, publisher.published_asset_digest)
        try:
            publisher.gh = lambda *args: uploads.append(args) or subprocess.CompletedProcess(args, 0, "", "")
            publisher.GENERATOR = _Release(["vgs-theme-demo-r1.tar.gz"])
            publisher.published_asset_digest = lambda _tag, _name: digest
            assert_equal(publisher.publish_archive("themes-v1", "demo", 1, first, digest, stage),
                         ("vgs-theme-demo-r1.tar.gz", 1),
                         "an asset already published at these bytes keeps its revision")
            assert_equal(uploads, [], "an asset already published at these bytes is not re-uploaded")
            # A published asset is never replaced, and the release's own asset
            # list is where the free revision comes from: the lock cannot supply
            # one, so a rerun would otherwise refuse the same name forever.
            publisher.published_asset_digest = lambda _tag, _name: "0" * 64
            publisher.GENERATOR = _Release(["vgs-theme-demo-r1.tar.gz", "vgs-theme-demo-r2.tar.gz"])
            assert_equal(publisher.publish_archive("themes-v1", "demo", 1, first, digest, stage),
                         ("vgs-theme-demo-r3.tar.gz", 3),
                         "a name held by different bytes takes the first free revision")
            assert_equal([args[:2] for args in uploads], [("release", "upload")],
                         "the freed revision is uploaded")
            assert_equal(sorted(p.name for p in stage.iterdir()), [],
                         "an uploaded archive is not left in the staging directory")
            uploads.clear()
            publisher.GENERATOR = _Release([])
            assert_equal(publisher.publish_archive("themes-v1", "demo", 1, first, digest, stage),
                         ("vgs-theme-demo-r1.tar.gz", 1), "an absent asset is uploaded as pinned")
            assert_equal([args[:2] for args in uploads], [("release", "upload")],
                         "an absent asset is uploaded")
            publisher.GENERATOR = _Release(None)
            try:
                publisher.publish_archive("themes-v1", "demo", 1, first, digest, stage)
                raise AssertionError("uploading to a release that does not exist must fail")
            except SystemExit:
                pass

            # pull must refuse bytes the lock does not describe, and must apply the
            # installer's path rule rather than a weaker copy of it.
            entry = {"release": "themes-v1", "archive": "vgs-theme-demo-r1.tar.gz",
                     "size": len(first), "sha256": digest, "published": True}
            dest = root / "pulled"
            publisher.extract_imagery("demo", entry, first, dest)
            assert_equal(sorted(p.relative_to(dest).as_posix() for p in dest.rglob("*") if p.is_file()),
                         ["backgrounds/1-demo.jpg"], "pull lays out the imagery")
            try:
                publisher.extract_imagery("demo", dict(entry, sha256="0" * 64), first, dest)
                raise AssertionError("a pulled archive whose checksum misses the lock must fail")
            except SystemExit:
                pass
            hostile = io.BytesIO()
            with tarfile.open(fileobj=hostile, mode="w:gz") as tar:
                info = tarfile.TarInfo("backgrounds/../../escaped.jpg")
                info.size = 1
                tar.addfile(info, io.BytesIO(b"x"))
            blob = hostile.getvalue()
            try:
                publisher.extract_imagery("demo", dict(
                    entry, size=len(blob), sha256=hashlib.sha256(blob).hexdigest()), blob, dest)
                raise AssertionError("a pulled member outside the package shape must fail")
            except SystemExit:
                pass
            assert_equal((root / "escaped.jpg").exists(), False,
                         "a refused member never lands outside the asset root")

            # A link in the imagery is refused rather than followed, the same way
            # the download path refuses one.
            linked = io.BytesIO()
            with tarfile.open(fileobj=linked, mode="w:gz") as tar:
                link = tarfile.TarInfo("backgrounds/1-demo.jpg")
                link.type = tarfile.SYMTYPE
                link.linkname = "/etc/passwd"
                tar.addfile(link)
            blob = linked.getvalue()
            try:
                publisher.extract_imagery("demo", dict(
                    entry, size=len(blob), sha256=hashlib.sha256(blob).hexdigest()), blob, dest)
                raise AssertionError("a pulled symlink member must fail")
            except SystemExit:
                pass

            # Nothing is fetchable for a pin that was never published, so pull
            # must say so rather than requesting a URL that returns 404.
            original_lock = publisher.LOCK_PATH
            unpublished = root / "unpublished-lock.json"
            unpublished.write_text(json.dumps({"version": 1, "themes": {"demo": dict(
                entry, published=False)}}))
            publisher.LOCK_PATH = unpublished
            try:
                publisher.pull(argparse.Namespace(asset_root=str(root / "pull-root")))
                raise AssertionError("pulling an unpublished pin must fail")
            except SystemExit:
                pass
            finally:
                publisher.LOCK_PATH = original_lock
        finally:
            publisher.GENERATOR, publisher.gh, publisher.published_asset_digest = (
                original_generator, original_gh, original_digest)

    # "could not ask" must never read as "not published": gh exits 1 for a
    # missing release and 4 when it is unauthenticated.
    original_run = generator.subprocess.run
    try:
        for label, code, stderr, expect in (
            ("present", 0, "", "release"),
            ("missing", 1, "release not found", None),
            ("unauthenticated", 4, "gh auth login required", "raise"),
            ("rate limited", 1, "API rate limit exceeded", "raise"),
        ):
            generator.subprocess.run = (lambda *a, code=code, stderr=stderr, **k:
                                        subprocess.CompletedProcess(a, code, '{"assets":[]}', stderr))
            if expect == "raise":
                try:
                    generator.gh_release("themes-v1")
                    raise AssertionError(f"an {label} gh must not answer for the release")
                except generator.GhUnavailable:
                    pass
            elif expect is None:
                assert_equal(generator.gh_release("themes-v1"), None,
                             f"a {label} release reads as absent")
            else:
                assert_equal(generator.gh_release("themes-v1"), {"assets": []},
                             f"a {label} release reads as present")
    finally:
        generator.subprocess.run = original_run


def test_theme_asset_publish_records_what_is_on_the_release():
    """The published flag and the revision arithmetic that keep a pin fetchable."""
    publisher = _load_script("publish_theme_assets_publish_test", "publish-theme-assets.py")

    def scenario(tmp: Path):
        themes = tmp / "themes"
        (themes / "demo").mkdir(parents=True)
        (themes / "demo" / "theme.json").write_text('{"name":"demo","mode":"dark"}\n')
        (themes / "demo" / "colors.toml").write_text('background = "#101010"\n')
        assets = tmp / "assets" / "demo"
        (assets / "backgrounds").mkdir(parents=True)
        (assets / "backgrounds" / "1-demo.jpg").write_bytes(b"wallpaper\n")
        # A real screenshot, so the thumbnail path runs and its bookkeeping is
        # assertable rather than merely described.
        from PIL import Image

        preview = themes / "demo" / helper.THEME_PREVIEW_FILE
        Image.new("RGB", (1280, 720), (16, 16, 16)).save(preview, "JPEG")

        class _Release:
            """Release store keyed by tag, so a release created empty is visible."""

            def __init__(self):
                self.assets: dict[str, list[str]] = {}
                self.lookups = 0
                self.LOCK_VERSION = real.LOCK_VERSION

            REPO_SLUG = "vanillagreencom/vgs"

            def gh_release(self, tag):
                self.lookups += 1
                if tag not in self.assets:
                    return None
                return {"assets": [{"name": n} for n in self.assets[tag]]}

            def is_imagery(self, rel):
                return real.is_imagery(rel)

            def theme_names(self, themes_dir=None):
                return real.theme_names(themes_dir)

        real = _load_script("gen_theme_catalog_publish_probe", "gen-theme-catalog.py")
        release = _Release()

        repos: set[str] = set()
        shipped: dict[str, bytes] = {}

        def fake_gh(*args):
            if "--repo" in args:
                repos.add(args[args.index("--repo") + 1])
            if args[:2] == ("release", "create"):
                release.assets.setdefault(args[2], [])
            if args[:2] == ("release", "upload"):
                staged = Path(args[3])
                shipped[staged.name] = staged.read_bytes()
                release.assets[args[2]].append(staged.name)
            return subprocess.CompletedProcess(args, 0, "", "")

        saved = (publisher.THEMES_DIR, publisher.LOCK_PATH, publisher.THUMBNAIL_DIR,
                 publisher.GENERATOR, publisher.gh, publisher.regenerate_catalog)
        publisher.THEMES_DIR = themes
        publisher.LOCK_PATH = tmp / "asset-lock.json"
        publisher.THUMBNAIL_DIR = tmp / "thumbnails"
        publisher.GENERATOR = release
        publisher.gh = fake_gh
        publisher.regenerate_catalog = lambda: None

        def run(upload: bool) -> dict:
            publisher.publish(argparse.Namespace(asset_root=str(tmp / "assets"), upload=upload))
            return json.loads(publisher.LOCK_PATH.read_text())["themes"]

        try:
            # Every theme ships a preview, so a theme without one stops the run
            # before anything is written or uploaded.
            (themes / "bare").mkdir()
            (themes / "bare" / "theme.json").write_text('{"name":"bare","mode":"dark"}\n')
            try:
                run(False)
                raise AssertionError("a theme without a preview must stop the publish")
            except SystemExit as exc:
                assert_equal((str(exc).splitlines()[0], publisher.LOCK_PATH.exists(), release.assets),
                             ("preview-missing bare", False, {}),
                             "the refusal names the theme, and nothing is written or uploaded")
            shutil.rmtree(themes / "bare")

            # A dry run pins the archive without claiming it is on a release.
            dry = run(False)["demo"]
            assert_equal((dry["published"], dry["rev"], dry["archive"], dry["release"]),
                         (False, 1, "vgs-theme-demo-r1.tar.gz", "themes-v1"),
                         "a dry run pins revision 1 as unpublished")
            assert_equal(release.assets, {}, "a dry run creates no release and uploads nothing")
            assert_equal(json.loads(publisher.LOCK_PATH.read_text())["version"], real.LOCK_VERSION,
                         "the publisher writes the lock version the generator reads")
            from_tree = tmp / "from-tree.jpg"
            publisher.write_thumbnail(preview.read_bytes(), from_tree)
            assert_equal(((publisher.THUMBNAIL_DIR / "demo.jpg").read_bytes(), dry["preview"]),
                         (from_tree.read_bytes(), hashlib.sha256(preview.read_bytes()).hexdigest()),
                         "the thumbnail is derived from the committed preview, and the lock records which")

            # The real run must still upload it. A skip that looked only at the
            # archive digest would leave the catalog naming an archive nobody
            # uploaded, and every install of that theme a 404.
            # A second theme, so the release-lookup count distinguishes one
            # lookup for the run from one per theme.
            (themes / "extra").mkdir()
            (themes / "extra" / "theme.json").write_text('{"name":"extra","mode":"dark"}\n')
            (tmp / "assets" / "extra" / "backgrounds").mkdir(parents=True)
            (tmp / "assets" / "extra" / "backgrounds" / "1.jpg").write_bytes(b"extra\n")
            Image.new("RGB", (1280, 720), (40, 40, 40)).save(themes / "extra" / helper.THEME_PREVIEW_FILE, "JPEG")

            release.lookups = 0
            wet = run(True)["demo"]
            assert_equal((wet["published"], wet["rev"], wet["archive"]),
                         (True, 1, "vgs-theme-demo-r1.tar.gz"),
                         "the real run publishes the same revision the dry run pinned")
            assert_equal(sorted(release.assets["themes-v1"]),
                         ["vgs-theme-demo-r1.tar.gz", "vgs-theme-extra-r1.tar.gz"],
                         "both archives reach the release")
            # One release lookup for the run plus one per upload. Putting the
            # release check back inside the loop doubles the GitHub round trips,
            # which is 78 extra calls and about 37 seconds over 79 themes.
            assert_equal(release.lookups, 3,
                         "a publish looks the release up once, plus once per upload")
            # One repository. A second constant here would upload to one place
            # while the catalog's baseUrl named another, and every install 404s.
            assert_equal(sorted(repos), [release.REPO_SLUG],
                         "uploads go to the repository the catalog downloads from")

            # Unchanged published content is skipped: a rerun must not orphan a
            # fresh revision on a release nothing is ever deleted from.
            # A rerun with nothing to publish must not create a release, which
            # on the real service is also a git tag every clone then fetches.
            release.lookups = 0
            again = run(True)["demo"]
            assert_equal((again["rev"], sorted(release.assets)), (1, ["themes-v1"]),
                         "unchanged published content uploads nothing and creates no release")
            assert_equal(release.lookups, 0, "a run that publishes nothing asks GitHub nothing")

            # A preview re-captured with no wallpaper change uploads nothing, and
            # the lock names the new preview, so the next run leaves its thumbnail alone.
            Image.new("RGB", (1280, 720), (90, 20, 20)).save(preview, "JPEG")
            recaptured = run(True)["demo"]
            assert_equal((recaptured["rev"], recaptured["preview"], sorted(release.assets)),
                         (1, hashlib.sha256(preview.read_bytes()).hexdigest(), ["themes-v1"]),
                         "a preview-only change is recorded in the lock with no upload")
            rebuilt = []
            working_thumbnail = publisher.write_thumbnail
            publisher.write_thumbnail = lambda data, dest: rebuilt.append(dest.name) or working_thumbnail(data, dest)
            try:
                run(True)
            finally:
                publisher.write_thumbnail = working_thumbnail
            assert_equal(rebuilt, [], "a run after the recorded preview change rebuilds no thumbnail")

            # Changed content bumps by exactly one.
            (assets / "backgrounds" / "1-demo.jpg").write_bytes(b"different wallpaper\n")
            changed = run(True)["demo"]
            assert_equal((changed["rev"], changed["archive"], changed["release"]),
                         (2, "vgs-theme-demo-r2.tar.gz", "themes-v2"),
                         "changed content bumps the revision by one into the next release")
            assert_equal(release.assets["themes-v2"], ["vgs-theme-demo-r2.tar.gz"],
                         "the new release carries only the archive that changed")

            # An incremental run records each theme as its own upload returns, so
            # a failure leaves no unpublished pin naming the release it was
            # filling. The lock records that release itself, and the rerun
            # continues into it instead of opening the next number and leaving a
            # partly filled release behind.
            (assets / "backgrounds" / "1-demo.jpg").write_bytes(b"third wallpaper\n")
            working_gh = publisher.gh

            def failing_gh(*args):
                if args[:2] == ("release", "upload"):
                    return subprocess.CompletedProcess(args, 1, "", "the network went away")
                return working_gh(*args)

            publisher.gh = failing_gh
            try:
                run(True)
                raise AssertionError("a failed upload must stop the publish")
            except SystemExit:
                pass
            finally:
                publisher.gh = working_gh
            stranded = json.loads(publisher.LOCK_PATH.read_text())
            assert_equal(stranded.get("publishing"), "themes-v3",
                         "a failed upload leaves the release it was filling recorded")
            assert_equal(publisher.next_release_tag(stranded), "themes-v3",
                         "the rerun continues into that release rather than opening the next")
            recovered = run(True)["demo"]
            assert_equal((recovered["rev"], recovered["release"]), (3, "themes-v3"),
                         "the rerun publishes into the release the failed run opened")
            assert_equal(sorted(release.assets), ["themes-v1", "themes-v2", "themes-v3"],
                         "no release number is stranded by the failure")
            assert_equal("publishing" in json.loads(publisher.LOCK_PATH.read_text()), False,
                         "a run that finishes its batch clears the in-progress release")

            # Everything the lock records about an archive comes from the one
            # read that packed it, so a wallpaper replaced while the run uploads
            # is not recorded as published.
            (assets / "backgrounds" / "1-demo.jpg").write_bytes(b"fourth wallpaper\n")
            working_build = publisher.build_archive

            def editing_build(members):
                result = working_build(members)
                (assets / "backgrounds" / "1-demo.jpg").write_bytes(b"fifth wallpaper\n")
                return result

            publisher.build_archive = editing_build
            try:
                raced = run(True)["demo"]
            finally:
                publisher.build_archive = working_build
            archive_bytes = shipped[raced["archive"]]
            assert_equal((raced["sha256"], raced["size"]),
                         (hashlib.sha256(archive_bytes).hexdigest(), len(archive_bytes)),
                         "the lock records the archive that was uploaded")
            with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as tar:
                published = {member.name: tar.extractfile(member).read() for member in tar.getmembers()}
            # The tree holds theme.json, colors.toml and the preview beside it.
            assert_equal(published, {"backgrounds/1-demo.jpg": b"fourth wallpaper\n"},
                         "a published archive holds only the wallpapers, as they were packed")

            # A theme dropped from the tree loses its pin and its thumbnail.
            shutil.rmtree(themes / "demo")
            assert_equal(sorted(run(True)), ["extra"],
                         "a theme no longer in the tree is dropped from the lock")
            assert_equal((publisher.THUMBNAIL_DIR / "demo.jpg").exists(), False,
                         "a removed theme leaves no thumbnail behind")
        finally:
            (publisher.THEMES_DIR, publisher.LOCK_PATH, publisher.THUMBNAIL_DIR,
             publisher.GENERATOR, publisher.gh, publisher.regenerate_catalog) = saved

    with_temp_home(scenario)


def test_theme_asset_release_selection():
    """Which release a publish fills, from the three inputs in order."""
    publisher = _load_script("publish_theme_assets_tag_test", "publish-theme-assets.py")
    for label, lock, expected in (
        ("an unpublished pin, which names its own destination",
         {"themes": {"a": {"release": "themes-v4", "published": False}}}, "themes-v4"),
        ("an interrupted run's own record",
         {"publishing": "themes-v7", "themes": {"a": {"release": "themes-v1", "published": True}}},
         "themes-v7"),
        ("an unpublished pin outranking a stale record",
         {"publishing": "themes-v7", "themes": {"a": {"release": "themes-v4", "published": False}}},
         "themes-v4"),
        ("a junk record, which never becomes a tag",
         {"publishing": "../evil", "themes": {"a": {"release": "themes-v1", "published": True}}},
         "themes-v2"),
        ("only published pins", {"themes": {"a": {"release": "themes-v1", "published": True}}},
         "themes-v2"),
        ("an empty lock", {"themes": {}}, "themes-v1"),
    ):
        assert_equal(publisher.next_release_tag(lock), expected, f"release chosen from {label}")
    try:
        publisher.next_release_tag({"themes": {
            "a": {"release": "themes-v1", "published": False},
            "b": {"release": "themes-v2", "published": False}}})
        raise AssertionError("unpublished pins across several releases must be refused")
    except SystemExit:
        pass


def test_theme_asset_publication_gate():
    """The gate CI runs: a pin whose archive a user cannot download must not merge."""
    generator = _load_script("gen_theme_catalog_gate_test", "gen-theme-catalog.py")
    catalog = {"themes": [{"name": "demo", "assets": {
        "release": "themes-v1", "archive": "vgs-theme-demo-r1.tar.gz"}}]}

    def with_lock(entry: dict, listed):
        original_load, original_release = generator.load_lock, generator.gh_release
        generator.load_lock = lambda: {"demo": entry}
        generator.gh_release = lambda _tag: listed
        try:
            return generator.check_assets_published(catalog)
        finally:
            generator.load_lock, generator.gh_release = original_load, original_release

    listed = {"assets": [{"name": "vgs-theme-demo-r1.tar.gz"}]}
    for label, entry, release, expected in (
        ("published archive present", {"published": True}, listed, 0),
        ("pin never published", {"published": False}, listed, 1),
        ("release absent", {"published": True}, None, 1),
        # A tag alone proves nothing: an interrupted upload leaves a release that
        # exists and carries no such asset, and that install returns 404.
        ("asset absent from the release", {"published": True}, {"assets": []}, 1),
        ("release carries another revision", {"published": True},
         {"assets": [{"name": "vgs-theme-demo-r2.tar.gz"}]}, 1),
    ):
        assert_equal(with_lock(entry, release), expected, f"asset publication gate: {label}")


def test_theme_catalog_generator():
    """The catalog pins imagery archives from a current lock, and the package ships every definition."""
    generator = _load_script("gen_theme_catalog_generator_test", "gen-theme-catalog.py")
    default = generator.load_helper().DEFAULT_THEME_NAME

    with tempfile.TemporaryDirectory() as tmp:
        themes = Path(tmp) / "themes"
        for name in (default, "other"):
            (themes / name / "apps").mkdir(parents=True)
            (themes / name / "backgrounds").mkdir()
            (themes / name / "theme.json").write_text(json.dumps({"name": name, "mode": "dark"}) + "\n")
            (themes / name / "apps" / "btop.theme").write_text("theme\n")
            (themes / name / "backgrounds" / "1.jpg").write_bytes(b"wallpaper")
            (themes / name / helper.THEME_PREVIEW_FILE).write_bytes(b"preview")
        lock = {"version": generator.LOCK_VERSION, "themes": {name: {
            "release": "themes-v1", "archive": f"vgs-theme-{name}-r1.tar.gz", "rev": 1,
            "size": 1, "sha256": "a" * 64, "published": True} for name in (default, "other")}}
        (themes / "asset-lock.json").write_text(json.dumps(lock))

        original = (generator.THEMES_DIR, generator.CATALOG_PATH, generator.LOCK_PATH)
        generator.THEMES_DIR = themes
        generator.CATALOG_PATH = themes / "catalog.json"
        generator.LOCK_PATH = themes / "asset-lock.json"
        try:
            assert_equal(generator.main(["--write"]), 0, "a catalog matching its lock is written")
            assert_equal(generator.main(["--check"]), 0, "the written catalog is up to date")
            written = json.loads((themes / "catalog.json").read_text())["themes"][0]
            assert_equal(sorted(written), ["assets", "mode", "name", "pair", "size", "source"],
                         "a catalog entry pins the archive and carries no definition files or colours")

            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                assert_equal(generator.main(["--package-files"]), 0, "--package-files exit status")
            assert_equal(buffer.getvalue().splitlines(), [
                f"{default}/apps/btop.theme", f"{default}/backgrounds/1.jpg",
                f"{default}/{helper.THEME_PREVIEW_FILE}", f"{default}/theme.json",
                "other/apps/btop.theme", f"other/{helper.THEME_PREVIEW_FILE}", "other/theme.json",
            ], "the package ships every definition and preview, and only the default theme's wallpapers")

            # An older lock pins archives that also carry definitions, which the
            # download path refuses, so generation stops until they are republished.
            lock["version"] = generator.LOCK_VERSION - 1
            (themes / "asset-lock.json").write_text(json.dumps(lock))
            for mode in ("--check", "--write"):
                try:
                    generator.main([mode])
                    raise AssertionError(f"{mode} must refuse a lock of another version")
                except SystemExit as exc:
                    assert_equal("publish-theme-assets.py" in str(exc), True,
                                 f"{mode} must name the publisher as the remedy")
        finally:
            generator.THEMES_DIR, generator.CATALOG_PATH, generator.LOCK_PATH = original


def test_theme_preview_set_check():
    """Every theme ships a preview at PREVIEW_SIZE or larger, and the set fits its budget."""
    previews = _load_script("capture_theme_previews_test", "capture-theme-previews.py")
    from PIL import Image

    width, height = helper.PREVIEW_SIZE

    def jpeg(size):
        buffer = io.BytesIO()
        Image.new("RGB", size, (20, 20, 20)).save(buffer, "JPEG")
        return buffer.getvalue()

    full = jpeg((width, height))
    publisher = previews.load_publisher()
    original_budget = previews.PREVIEW_SET_BUDGET_BYTES
    with tempfile.TemporaryDirectory() as tmp:
        try:
            for index, (label, shots, budget, expected) in enumerate((
                ("a complete set", {"a": full, "b": full}, original_budget, (0, [])),
                ("a theme with no preview", {"a": full, "b": None}, original_budget,
                 (1, ["preview-missing b"])),
                ("a preview below PREVIEW_SIZE", {"a": full, "b": jpeg((1920, 1080))}, original_budget,
                 (1, ["preview-small b 1920x1080"])),
                ("a preview that is not a JPEG", {"a": full, "b": b"\x89PNG\r\n\x1a\n"}, original_budget,
                 (1, ["preview-unreadable b"])),
                ("a set over its budget", {"a": full, "b": full}, len(full),
                 (1, [f"preview-budget {2 * len(full)} {len(full)}"])),
            )):
                themes = Path(tmp) / str(index)
                for name, shot in shots.items():
                    (themes / name).mkdir(parents=True)
                    (themes / name / "theme.json").write_text("{}\n")
                    if shot is not None:
                        (themes / name / helper.THEME_PREVIEW_FILE).write_bytes(shot)
                previews.PREVIEW_SET_BUDGET_BYTES = budget
                errors = io.StringIO()
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(errors):
                    status = previews.check(publisher, themes)
                keys = [line for line in errors.getvalue().splitlines() if line.startswith("preview-")]
                assert_equal((status, keys), expected, f"preview set check: {label}")
        finally:
            previews.PREVIEW_SET_BUDGET_BYTES = original_budget

        # A capture is a PNG; the package ships it as a JPEG at the captured size.
        png = io.BytesIO()
        Image.new("RGB", (width, height), (40, 120, 200)).save(png, "PNG")
        dest = Path(tmp) / "encoded" / helper.THEME_PREVIEW_FILE
        previews.encode_preview(publisher, png.getvalue(), dest)
        assert_equal(previews.jpeg_size(dest.read_bytes()), (width, height),
                     "a captured screenshot is encoded as a JPEG at its captured size")


def test_theme_catalog_manifest_matches_the_repo():
    """The committed catalog must describe the themes in the tree and a pinned archive for each."""
    catalog = json.loads((REPO_ROOT / "themes" / "catalog.json").read_text())
    lock = json.loads((REPO_ROOT / "themes" / "asset-lock.json").read_text())["themes"]
    names = sorted(e["name"] for e in catalog["themes"])
    on_disk = sorted(p.parent.name for p in (REPO_ROOT / "themes").glob("*/theme.json"))
    assert_equal(names, on_disk, "catalog themes must match themes/ on disk")
    assert_equal(sorted(lock), on_disk, "the asset lock must pin every theme in themes/ and no other")
    assert_equal(catalog["source"]["baseUrl"].startswith("https://"), True, "catalog must download over https")
    for theme in catalog["themes"]:
        # Every entry must survive the download path's own validator, so no
        # committed entry can be one the shell refuses at install time.
        assets = helper._catalog_check_assets(theme["name"], theme["assets"])
        assert_equal(assets["sha256"], lock[theme["name"]]["sha256"],
                     f"{theme['name']}: the catalog and the asset lock must pin the same archive")
        assert_equal(theme["size"], assets["size"],
                     f"{theme['name']}: the advertised size must be the archive's download size")
        # The browser paints an uninstalled theme from its shipped thumbnail.
        assert_equal((REPO_ROOT / "themes" / "thumbnails" / f"{theme['name']}.jpg").is_file(), True,
                     f"{theme['name']}: no shipped thumbnail")


# Sunshine selects its capture target at startup. Create and verify the virtual
# output first or it can capture a physical monitor.

_RD_SESSION_LINES = [
    "2026-08-06T11:10:42+0200 host sunshine[1]: Info: Creating encoder [hevc_nvenc]",
    "2026-08-06T11:10:42+0200 host sunshine[1]: Info: Color depth: 10-bit",
    "2026-08-06T11:10:42+0200 host sunshine[1]: Info: Streaming bitrate is 27788000",
    "2026-08-06T11:10:43+0200 host sunshine[1]: Info: New streaming session started [active sessions: 1]",
    "2026-08-06T11:10:43+0200 host sunshine[1]: Info: CLIENT CONNECTED",
]


@contextlib.contextmanager
def _rd_journal(lines=None, returncode=0, stderr=""):
    original_run = helper.run
    original_window = helper._rd_journal_window
    helper._rd_journal_window = lambda: ["--boot"]
    helper.run = lambda argv, **kw: subprocess.CompletedProcess(
        argv, returncode, "\n".join(lines or []), stderr)
    try:
        yield
    finally:
        helper.run = original_run
        helper._rd_journal_window = original_window


def test_remote_desktop_reports_streaming_separately_from_listening():
    with _rd_journal(_RD_SESSION_LINES):
        streaming = helper._rd_session_state()
    assert_equal(streaming["active"], True, "a client connected with no later disconnect is streaming")
    assert_equal(streaming["count"], 1, "the session count comes from Sunshine's own tally")
    assert_equal(streaming["codec"], "hevc_nvenc", "the live session's encoder is reported")
    assert_equal(streaming["bitrateBps"], 27788000, "the live session's bitrate is reported")
    assert_equal(streaming["readable"], True, "a journal that was read is readable")

    with _rd_journal(_RD_SESSION_LINES + [
        "2026-08-06T11:45:30+0200 host sunshine[1]: Info: CLIENT DISCONNECTED",
    ]):
        listening = helper._rd_session_state()
    assert_equal(listening["active"], False, "a disconnect ends the session")
    assert_equal(listening["count"], 0, "the tally returns to zero")
    # Reporting the ended session's encoder next to "listening" would read as a
    # live stream's settings.
    assert_equal(listening["codec"], "", "an ended session reports no encoder")
    assert_equal(listening["bitrateBps"], 0, "an ended session reports no bitrate")

    with _rd_journal([]):
        idle = helper._rd_session_state()
    assert_equal(idle["active"], False, "a host nobody has connected to is not streaming")
    assert_equal(idle["readable"], True, "an empty journal is still an answer")

    # "nobody is watching" and "nobody could say" must not be the same state:
    # only one of them is safe to render as an idle indicator.
    with _rd_journal(returncode=1, stderr="No journal files were found."):
        unknown = helper._rd_session_state()
    assert_equal(unknown["active"], False, "an unreadable journal never claims a session")
    assert_equal(unknown["readable"], False, "an unreadable journal is reported as unreadable")
    assert_equal(
        unknown["error"], "No journal files were found.",
        "the reason the session state is unknown must survive to the caller",
    )


@contextlib.contextmanager
def _rd_lifecycle(output_present, hyprctl_ok=True, unit_running=False, systemctl_ok=True,
                  instance="hypr-instance-A", create_takes_effect=True):
    """Record the order of hyprctl/systemctl calls a lifecycle command makes.

    HOME is real (a temp dir), so the ownership record under
    ~/.local/state/vshell is genuinely written and read rather than stubbed --
    that record is what decides whether a user's own virtual output gets
    deleted, so a stub would test the wrong thing.
    """
    calls = []
    originals = {name: getattr(helper, name) for name in (
        "run", "_systemctl_user", "_rd_output_present", "_rd_unit_state",
        "detect_compositor", "remote_desktop_status", "_rd_hypr_instance",
        "_rd_manages_output",
    )}
    state = {"present": output_present}

    def fake_run(argv, **kwargs):
        calls.append(argv)
        if argv[:2] == ["hyprctl", "output"]:
            if not hyprctl_ok:
                return subprocess.CompletedProcess(argv, 1, "", "no such output")
            if argv[2] == "create":
                # create_takes_effect=False models hyprctl exiting 0 without
                # the output appearing, and None models a presence check that
                # cannot answer afterwards.
                state["present"] = True if create_takes_effect is True else create_takes_effect
            else:
                state["present"] = False
            return subprocess.CompletedProcess(argv, 0, "ok", "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    def fake_systemctl(argv, **kwargs):
        calls.append(["systemctl", "--user", *argv])
        if argv and argv[0] in {"start", "stop"} and not systemctl_ok:
            return subprocess.CompletedProcess(argv, 1, "", "Job failed")
        return subprocess.CompletedProcess(argv, 0, "", "")

    helper.run = fake_run
    helper._systemctl_user = fake_systemctl
    helper._rd_output_present = lambda: state["present"]
    helper._rd_unit_state = lambda: {
        "known": True, "error": "", "exists": True, "running": unit_running,
    }
    helper.detect_compositor = lambda: {"compositor": "hyprland", "source": "test"}
    helper._rd_manages_output = lambda: {
        "manages": True, "compositor": "hyprland", "blocked": False, "reason": "",
    }
    helper.remote_desktop_status = lambda: {"stubbed": True}
    helper._rd_hypr_instance = lambda: instance

    old_home = os.environ.get("HOME")
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["HOME"] = tmp
        try:
            yield calls, state
        finally:
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home
            for name, value in originals.items():
                setattr(helper, name, value)


def _rd_hyprctl_calls(calls):
    return [call for call in calls if call and call[0] == "hyprctl"]


def test_remote_desktop_start_creates_the_output_before_starting_the_unit():
    with _rd_lifecycle(output_present=False) as (calls, _state):
        result = helper.remote_desktop_start()
    assert_equal(result["ok"], True, "a clean start succeeds")
    kinds = [call[0] for call in calls]
    assert_equal(kinds, ["hyprctl", "systemctl"], "the output must exist before the unit starts")
    assert_equal(
        calls[0], ["hyprctl", "output", "create", "headless"],
        "the virtual output is created by this command, not by the caller",
    )


def test_remote_desktop_start_refuses_when_the_output_cannot_be_checked():
    # Starting without a verified virtual output can capture a physical monitor.
    with _rd_lifecycle(output_present=None) as (calls, _state):
        result = helper.remote_desktop_start()
    assert_equal(result["ok"], False, "an unverifiable output must not start the host")
    assert_equal(calls, [], "nothing is started and nothing is created when the output is unknown")
    if not result["failures"] or helper.RD_OUTPUT not in result["failures"][0]:
        raise AssertionError(f"the refusal must name {helper.RD_OUTPUT}: {result['failures']!r}")


def test_remote_desktop_start_does_not_recreate_an_existing_output():
    with _rd_lifecycle(output_present=True) as (calls, _state):
        result = helper.remote_desktop_start()
    assert_equal(result["ok"], True, "an existing output is fine")
    assert_equal([call[0] for call in calls], ["systemctl"], "an existing output is left alone")


def test_remote_desktop_failed_start_removes_the_output_it_created():
    # A failed host start must remove a virtual output it created.
    with _rd_lifecycle(output_present=False, systemctl_ok=False) as (calls, state):
        result = helper.remote_desktop_start()
        record_exists = helper._rd_output_record_file().exists()
    assert_equal(result["ok"], False, "a failed systemctl start is a failure")
    assert_equal(state["present"], False, "the output created for this start must be rolled back")
    assert_equal(
        _rd_hyprctl_calls(calls),
        [["hyprctl", "output", "create", "headless"], ["hyprctl", "output", "remove", "HEADLESS-1"]],
        "the rollback removes exactly what this call created",
    )
    assert_equal(record_exists, False, "the ownership record goes with the output it described")


def test_remote_desktop_failed_start_keeps_an_output_it_did_not_create():
    # A pre-existing output belongs to another caller even if host startup fails.
    with _rd_lifecycle(output_present=True, systemctl_ok=False) as (calls, state):
        result = helper.remote_desktop_start()
    assert_equal(result["ok"], False, "a failed systemctl start is still a failure")
    assert_equal(state["present"], True, "an output this call found must survive the rollback")
    assert_equal(_rd_hyprctl_calls(calls), [], "nothing is created and nothing is removed")


def test_remote_desktop_stop_removes_only_an_output_vgs_created():
    # Stopping Sunshine must not delete a virtual output it does not own.
    with _rd_lifecycle(output_present=False) as (calls, state):
        assert_equal(helper.remote_desktop_start()["ok"], True, "the start succeeds")
        assert_equal(state["present"], True, "the start created the output")
        calls.clear()
        helper.remote_desktop_stop()
        assert_equal(state["present"], False, "an output VGS created is removed on stop")
        assert_equal(
            helper._rd_output_record_file().exists(), False,
            "the record is cleared once the output it described is gone",
        )

    with _rd_lifecycle(output_present=True) as (calls, state):
        assert_equal(helper.remote_desktop_start()["ok"], True, "the start succeeds")
        calls.clear()
        result = helper.remote_desktop_stop()
        assert_equal(state["present"], True, "an output VGS did not create must survive stop")
        assert_equal(_rd_hyprctl_calls(calls), [], "stop issues no output command it does not own")
        if not any("not created by VGS" in note for note in result["manual"]):
            raise AssertionError(f"stop must say why it left the output: {result['manual']!r}")


def test_remote_desktop_stop_ignores_a_record_from_another_compositor_instance():
    # Headless outputs die with the compositor and Hyprland's signature changes
    # on every start, so a record from a previous instance cannot describe the
    # output present now. Trusting it would delete an output created since.
    with _rd_lifecycle(output_present=False, instance="hypr-instance-A") as (calls, state):
        helper.remote_desktop_start()
        record = json.loads(helper._rd_output_record_file().read_text())
        assert_equal(record["instance"], "hypr-instance-A", "the record carries the instance")
        assert_equal(helper._rd_output_is_ours(), True, "same instance, same output: ours")

        helper._rd_hypr_instance = lambda: "hypr-instance-B"
        assert_equal(
            helper._rd_output_is_ours(), False,
            "a record from a previous compositor instance is not ownership",
        )
        calls.clear()
        helper.remote_desktop_stop()
        assert_equal(state["present"], True, "an output from another instance is left alone")
        assert_equal(_rd_hyprctl_calls(calls), [], "and no hyprctl output command is issued")

    # No signature at all cannot match either -- an unplaceable record must not
    # authorise removing anything.
    with _rd_lifecycle(output_present=False, instance="") as (calls, state):
        helper.remote_desktop_start()
        assert_equal(
            helper._rd_output_is_ours(), False,
            "a record with no compositor instance to place it is not ownership",
        )


def test_remote_desktop_stop_drops_the_record_when_the_output_vanished():
    # Removed by hand between start and stop. Nothing to remove, no error --
    # but the record must go, or it would authorise removing a LATER output
    # that happens to carry the same name.
    with _rd_lifecycle(output_present=False) as (calls, state):
        helper.remote_desktop_start()
        state["present"] = False
        calls.clear()
        result = helper.remote_desktop_stop()
        assert_equal(result["ok"], True, "a vanished output is not an error")
        assert_equal(_rd_hyprctl_calls(calls), [], "there is nothing to remove")
        assert_equal(
            helper._rd_output_record_file().exists(), False,
            "a record whose output is gone must not survive to authorise a later removal",
        )


def test_remote_desktop_start_is_idempotent_when_the_host_is_already_running():
    # The unit can start between a toggle query and action; an already-running host
    # must not gain another virtual output.
    with _rd_lifecycle(output_present=False, unit_running=True) as (calls, state):
        result = helper.remote_desktop_start()
    assert_equal(result["ok"], True, "starting an already-running host is not a failure")
    assert_equal(_rd_hyprctl_calls(calls), [], "no output is created for a host already running")
    assert_equal([c for c in calls if c[0] == "systemctl"], [], "and the unit is not restarted")
    if not any("already running" in note for note in result["manual"]):
        raise AssertionError(f"the no-op must be reported: {result['manual']!r}")


def test_remote_desktop_start_reports_an_unrecordable_ownership_claim():
    # If the ownership record cannot be saved, stopping cannot safely remove the
    # output. Report that failure.
    with _rd_lifecycle(output_present=False) as (calls, state):
        original = helper._rd_record_output_created
        helper._rd_record_output_created = lambda: "Read-only file system"
        try:
            result = helper.remote_desktop_start()
        finally:
            helper._rd_record_output_created = original
    assert_equal(result["ok"], True, "an unrecordable claim does not fail the start")
    if not any("could not record" in note and "leave it in place" in note for note in result["manual"]):
        raise AssertionError(f"the unrecorded claim must be reported: {result['manual']!r}")


def test_remote_desktop_start_verifies_the_output_it_created():
    # hyprctl success without a visible output must not permit host startup.
    with _rd_lifecycle(output_present=False, create_takes_effect=False) as (calls, state):
        result = helper.remote_desktop_start()
        record_exists = helper._rd_output_record_file().exists()
    assert_equal(result["ok"], False, "an unverified output must not start the host")
    assert_equal(
        [c for c in calls if c[0] == "systemctl"], [],
        "the unit is never started against a display that does not exist",
    )
    assert_equal(
        record_exists, False,
        "ownership is recorded only after verification, so nothing was created to own",
    )
    if not any("not present" in failure for failure in result["failures"]):
        raise AssertionError(f"the refusal must say the output is absent: {result['failures']!r}")

    # Unknown presence is neither absence nor authorization to remove an output.
    with _rd_lifecycle(output_present=False, create_takes_effect=None) as (calls, state):
        result = helper.remote_desktop_start()
    assert_equal(result["ok"], False, "an unverifiable output must not start the host either")
    assert_equal([c for c in calls if c[0] == "systemctl"], [], "and still no unit start")
    assert_equal(
        _rd_hyprctl_calls(calls), [["hyprctl", "output", "create", "headless"]],
        "nothing is removed when the presence check cannot answer",
    )
    if not any("could not be verified" in failure for failure in result["failures"]):
        raise AssertionError(f"'cannot tell' must not be reported as 'absent': {result['failures']!r}")


@contextlib.contextmanager
def _rd_systemctl(replies):
    """Drive _systemctl_user from a {property-query-kind: CompletedProcess} map."""
    original = helper._systemctl_user

    def fake(argv, **kwargs):
        joined = " ".join(argv)
        for key, reply in replies.items():
            if key in joined:
                return reply
        return subprocess.CompletedProcess(argv, 0, "", "")

    helper._systemctl_user = fake
    try:
        yield
    finally:
        helper._systemctl_user = original


def test_remote_desktop_journal_window_never_falls_back_to_unbounded_history():
    # Only logs from the current service run can establish a connected client.
    good = subprocess.CompletedProcess([], 0, "Thu 2026-08-06 16:44:12 CEST\n", "")
    with _rd_systemctl({"ActiveEnterTimestamp": good}):
        assert_equal(
            helper._rd_journal_window(), ["--since", "2026-08-06 16:44:12"],
            "a parseable start time anchors the read to the current run")

    for label, reply in {
        "the query failed": subprocess.CompletedProcess([], 1, "", "Failed to connect to bus"),
        "the value is empty": subprocess.CompletedProcess([], 0, "\n", ""),
        "the value is unparseable": subprocess.CompletedProcess([], 0, "n/a\n", ""),
        "the shape is unexpected": subprocess.CompletedProcess([], 0, "Thu 06/08/2026 16:44:12 CEST\n", ""),
    }.items():
        with _rd_systemctl({"ActiveEnterTimestamp": reply}):
            assert_equal(
                helper._rd_journal_window(), None,
                f"no anchor when {label} -- and specifically not a boot-wide replay")

    # An unreadable session is unknown, not idle.
    calls = []
    original_run = helper.run

    def fake_run(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "Info: CLIENT CONNECTED\n", "")

    helper.run = fake_run
    try:
        with _rd_systemctl({"ActiveEnterTimestamp": subprocess.CompletedProcess([], 1, "", "boom")}):
            session = helper._rd_session_state()
    finally:
        helper.run = original_run

    assert_equal(calls, [], "no journal is read at all without an anchor to bound it")
    assert_equal(session["readable"], False, "an unanchored session is unknown")
    assert_equal(session["active"], False, "and it never claims a session it did not read")
    if "start time" not in session["error"]:
        raise AssertionError(f"the reason must name the missing anchor: {session['error']!r}")


def test_remote_desktop_unit_query_failure_is_not_a_missing_unit():
    # A failed systemctl query must differ from an absent unit.
    loaded = subprocess.CompletedProcess([], 0, "LoadState=loaded\nActiveState=inactive\n", "")
    absent = subprocess.CompletedProcess([], 0, "LoadState=not-found\nActiveState=inactive\n", "")
    broken = subprocess.CompletedProcess([], 1, "", "Failed to connect to bus: No such file")
    silent = subprocess.CompletedProcess([], 0, "", "")

    with _rd_systemctl({"LoadState": loaded}):
        state = helper._rd_unit_state()
    assert_equal(state, {"known": True, "error": "", "exists": True, "running": False},
                 "a loaded, inactive unit reads exactly that")

    with _rd_systemctl({"LoadState": absent}):
        state = helper._rd_unit_state()
    assert_equal(state["known"], True, "'not-found' IS an answer")
    assert_equal(state["exists"], False, "and the answer is that the unit is absent")

    # Both LoadState and ActiveState need values; a partial reply cannot establish host state.
    partial = {
        "ActiveState missing": subprocess.CompletedProcess([], 0, "LoadState=loaded\n", ""),
        "LoadState missing": subprocess.CompletedProcess([], 0, "ActiveState=active\n", ""),
        "ActiveState empty": subprocess.CompletedProcess([], 0, "LoadState=loaded\nActiveState=\n", ""),
        "LoadState empty": subprocess.CompletedProcess([], 0, "LoadState=\nActiveState=active\n", ""),
        "reply truncated mid-line": subprocess.CompletedProcess([], 0, "LoadState=loaded\nActiveSta", ""),
    }
    for label, reply in partial.items():
        with _rd_systemctl({"LoadState": reply}):
            state = helper._rd_unit_state()
        assert_equal(state["known"], False, f"{label}: a partial reply is not an answer")
        assert_equal(state["running"], False, f"{label}: and it must not report a running state")
        assert_equal(state["exists"], False, f"{label}: nor an existence verdict")
        if "incomplete" not in state["error"]:
            raise AssertionError(f"{label}: the reason must say the reply was incomplete: {state['error']!r}")

    with _rd_systemctl({"LoadState": partial["ActiveState missing"]}):
        state = helper._rd_unit_state()
    if state["known"] and not state["running"]:
        raise AssertionError(
            "a reply carrying only LoadState must not read as 'installed and stopped'")

    for label, reply in {"the query failed": broken, "the query said nothing": silent}.items():
        with _rd_systemctl({"LoadState": reply}):
            state = helper._rd_unit_state()
        assert_equal(state["known"], False, f"{label}: that is not an answer")
        assert_equal(state["exists"], False, f"{label}: and it must not read as installed either")
        if not state["error"]:
            raise AssertionError(f"{label}: the reason must survive to the caller")

    originals = {n: getattr(helper, n) for n in ("_rd_unit_state", "detect_compositor", "_rd_paired_clients", "_rd_web_host")}
    helper.detect_compositor = lambda: {"compositor": "niri", "source": "test"}
    helper._rd_paired_clients = lambda: {"names": [], "known": True, "error": "", "undecodable": 0}
    helper._rd_web_host = lambda: "localhost"
    try:
        helper._rd_unit_state = lambda: {"known": False, "error": "bus is gone", "exists": False, "running": False}
        status = helper.remote_desktop_status()
        assert_equal(status["state"], "unknown", "a failed query is not 'unavailable'")
        assert_equal(status["unitKnown"], False, "and the payload says so explicitly")
        assert_equal(status["reason"], "bus is gone", "with the reason attached")
        assert_equal(
            status["session"]["readable"], False,
            "a unit whose state is unknown has an unknown session too",
        )

        helper._rd_unit_state = lambda: {"known": True, "error": "", "exists": False, "running": False}
        status = helper.remote_desktop_status()
        assert_equal(status["state"], "unavailable", "a real absence still reads as unavailable")
        assert_equal(status["unitKnown"], True, "because the question was answered")
    finally:
        for name, value in originals.items():
            setattr(helper, name, value)


def test_remote_desktop_start_refuses_when_the_unit_query_fails():
    # A failed query cannot authorize starting a host that may already be running.
    original = helper._rd_unit_state
    helper._rd_unit_state = lambda: {"known": False, "error": "bus is gone", "exists": False, "running": False}
    try:
        result = helper.remote_desktop_start()
    finally:
        helper._rd_unit_state = original
    assert_equal(result["ok"], False, "an unanswerable unit query must not start anything")
    if not any("could not determine" in failure for failure in result["failures"]):
        raise AssertionError(f"the refusal must say the query failed: {result['failures']!r}")


def test_remote_desktop_paired_clients_reads_only_names():
    def check(home: Path):
        config = home / ".config" / "sunshine"
        config.mkdir(parents=True)
        (config / "sunshine_state.json").write_text(json.dumps({
            "username": "method", "salt": "SALTVALUE", "password": "HASHVALUE",
            "root": {"uniqueid": "UNIQUE", "named_devices": [
                {"name": "mbp-1", "cert": "-----BEGIN CERTIFICATE-----"},
                {"name": "  ", "cert": "x"}, {"cert": "no name here"}]},
        }))
        result = helper._rd_paired_clients()
        # Only names, and only usable ones. The same file holds the Web UI
        # credential hash and salt; nothing but `name` may leave this function.
        assert_equal(result["names"], ["mbp-1"], "only non-blank device names are returned")
        assert_equal(result["known"], True, "a well-formed file is an answer")
        if any("SALT" in n or "HASH" in n for n in result["names"]):
            raise AssertionError("credential material must never reach the payload")

    with_temp_home(check)

    # Seed ambient config so an isolated empty fixture proves host data does not leak.
    def check_absent(home):
        result = helper._rd_paired_clients()
        assert_equal(result["names"], [], "no state file means no paired clients")
        assert_equal(result["known"], True, "and an absent file is still an answer")

    with tempfile.TemporaryDirectory() as ambient:
        (Path(ambient) / "sunshine").mkdir()
        (Path(ambient) / "sunshine" / "sunshine_state.json").write_text(
            json.dumps({"root": {"named_devices": [{"name": "ambient-leak"}]}}))
        saved = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = ambient
        try:
            with_temp_home(check_absent)
        finally:
            _restore_env("XDG_CONFIG_HOME", saved)


def test_remote_desktop_malformed_state_degrades_rather_than_raising():
    # Malformed client state must leave independent host and session status available.
    malformed = {
        "a JSON array": "[]",
        "a JSON scalar": "5",
        "a JSON string": '"nope"',
        "null": "null",
        "root is a string": '{"root": "nope"}',
        "root is a list": '{"root": []}',
        "named_devices is a string": '{"root": {"named_devices": "mbp-1"}}',
        "named_devices is an object": '{"root": {"named_devices": {"a": 1}}}',
        "not JSON at all": "{ this is not json",
    }

    def check(home: Path):
        config = home / ".config" / "sunshine"
        config.mkdir(parents=True)
        state = config / "sunshine_state.json"
        old_xdg = os.environ.pop("XDG_CONFIG_HOME", None)
        try:
            for label, body in malformed.items():
                state.write_text(body)
                try:
                    result = helper._rd_paired_clients()
                except Exception as exc:  # noqa: BLE001 - the whole point
                    raise AssertionError(f"{label} must not raise: {exc!r}") from exc
                assert_equal(result["names"], [], f"{label}: no names can be read")
                assert_equal(result["known"], False, f"{label}: and the answer is unknown, not empty")
                if not result["error"]:
                    raise AssertionError(f"{label}: the reason must survive to the caller")

            for label, body in {
                "no root yet": '{"username": "method"}',
                "no named_devices yet": '{"root": {"uniqueid": "X"}}',
                "an empty device list": '{"root": {"named_devices": []}}',
            }.items():
                state.write_text(body)
                result = helper._rd_paired_clients()
                assert_equal(result["names"], [], f"{label}: no devices")
                assert_equal(result["known"], True, f"{label}: but that IS the answer")

            state.write_text(json.dumps({"root": {"named_devices": [
                "not-an-object", {"name": "mbp-1"}, {"cert": "no name"}, None, {"name": 7},
            ]}}))
            result = helper._rd_paired_clients()
            assert_equal(result["names"], ["mbp-1"], "usable entries survive unusable neighbours")
            assert_equal(result["known"], True, "a readable list with junk entries is still readable")
        finally:
            if old_xdg is not None:
                os.environ["XDG_CONFIG_HOME"] = old_xdg

    with_temp_home(check)

    originals = {n: getattr(helper, n) for n in
                 ("_rd_unit_state", "_rd_manages_output", "_rd_paired_clients", "_rd_web_host")}
    helper._rd_unit_state = lambda: {"known": True, "error": "", "exists": True, "running": False}
    helper._rd_manages_output = lambda: {"manages": False, "compositor": "niri", "blocked": False, "reason": ""}
    helper._rd_web_host = lambda: "localhost"
    helper._rd_paired_clients = lambda: {"names": [], "known": False, "error": "the Sunshine state file is not an object", "undecodable": 0}
    try:
        status = helper.remote_desktop_status()
    finally:
        for name, value in originals.items():
            setattr(helper, name, value)
    assert_equal(status["state"], "stopped", "the host state survives a malformed paired list")
    assert_equal(status["pairedClientsKnown"], False, "only the paired axis goes unknown")
    assert_equal(status["pairedClients"], [], "and it carries no invented names")
    if "not an object" not in status["pairedClientsError"]:
        raise AssertionError(f"the reason must reach the payload: {status['pairedClientsError']!r}")


def test_remote_desktop_unknown_compositor_is_probed_not_assumed():
    # SSH can lack compositor environment variables while a Hyprland session runs.
    # Unknown detection alone cannot authorize capture without a virtual output.
    originals = {n: getattr(helper, n) for n in
                 ("detect_compositor", "command_exists", "_rd_hypr_env", "run")}
    try:
        helper.detect_compositor = lambda: {"compositor": "hyprland", "source": "test"}
        assert_equal(helper._rd_manages_output()["manages"], True, "detected Hyprland manages the output")

        helper.detect_compositor = lambda: {"compositor": "niri", "source": "test"}
        managed = helper._rd_manages_output()
        assert_equal(managed["manages"], False, "niri manages no virtual output")
        assert_equal(managed["blocked"], False, "and that is a definite answer, not a refusal")

        helper.detect_compositor = lambda: {"compositor": "unknown", "source": "none"}

        helper.command_exists = lambda name: False
        managed = helper._rd_manages_output()
        assert_equal(managed["manages"], False, "no hyprctl means no Hyprland")
        assert_equal(managed["blocked"], False, "and the host may still start")

        helper.command_exists = lambda name: True
        helper._rd_hypr_env = lambda: {}
        managed = helper._rd_manages_output()
        assert_equal(managed["manages"], False, "no instance means no running Hyprland")
        assert_equal(managed["blocked"], False, "and the host may still start")

        helper._rd_hypr_env = lambda: {"HYPRLAND_INSTANCE_SIGNATURE": "sig"}
        helper.run = lambda argv, **kwargs: subprocess.CompletedProcess(argv, 0, "{}", "")
        managed = helper._rd_manages_output()
        assert_equal(managed["manages"], True, "an ssh start must still create the virtual output")
        assert_equal(managed["compositor"], "hyprland", "and it is reported as Hyprland")

        # Unknown + an instance present but hyprctl unreachable -> refuse.
        # There is a Hyprland session here and we cannot talk to it, so a real
        # monitor cannot be ruled out.
        helper.run = lambda argv, **kwargs: subprocess.CompletedProcess(argv, 1, "", "Couldn't connect")
        managed = helper._rd_manages_output()
        assert_equal(managed["manages"], False, "an unreachable instance manages nothing")
        assert_equal(managed["blocked"], True, "and it must block the start rather than guess")
    finally:
        for name, value in originals.items():
            setattr(helper, name, value)

    with _rd_lifecycle(output_present=False) as (calls, state):
        helper._rd_manages_output = lambda: {
            "manages": False, "compositor": "unknown", "blocked": True,
            "reason": "a Hyprland instance is running but hyprctl could not be reached",
        }
        result = helper.remote_desktop_start()
    assert_equal(result["ok"], False, "a blocked compositor probe must not start the host")
    assert_equal(calls, [], "and must create nothing and start nothing")
    if not any("capture a real monitor" in failure for failure in result["failures"]):
        raise AssertionError(f"the refusal must name the risk: {result['failures']!r}")


def test_remote_desktop_decode_marks_real_replacement_characters():
    # Mark genuine replacement characters before lenient decoding so inserted
    # replacement characters identify undecodable bytes.
    literal = '{"a": "real\ufffdname"}'.encode("utf-8")
    text, marker = helper._rd_decode_marking_real_fffd(literal)
    assert_equal(marker in text, True, "a literal U+FFFD is marked")
    assert_equal("\ufffd" in text, False, "and no bare U+FFFD is left to misread")

    # JSON can encode characters literally or with escapes; test both forms.
    escaped = b'{"a": "real\\ufffdname"}'
    text, marker = helper._rd_decode_marking_real_fffd(escaped)
    assert_equal(json.loads(text)["a"], "real" + marker + "name", "an escaped U+FFFD is marked too")

    # Case is not significant in a JSON hex escape.
    text, marker = helper._rd_decode_marking_real_fffd(b'{"a": "real\\uFFFDname"}')
    assert_equal(json.loads(text)["a"], "real" + marker + "name", "an uppercase escape is the same character")

    text, marker = helper._rd_decode_marking_real_fffd(b'{"a": "bad-\x80-x"}')
    assert_equal(json.loads(text)["a"], "bad-\ufffd-x", "an undecodable byte is the only source of U+FFFD left")

    text, marker = helper._rd_decode_marking_real_fffd(b'{"a": "plain"}')
    assert_equal(json.loads(text)["a"], "plain", "a clean file decodes normally")

    # No usable marker is a refusal, not a guess: the caller withholds every
    # suspicious name instead.
    crowded = ("".join(helper._RD_DECODE_MARKERS)).encode("utf-8")
    text, marker = helper._rd_decode_marking_real_fffd(crowded)
    assert_equal(text, None, "a file containing every candidate marker yields no safe marking")
    assert_equal(marker, "", "and no marker to restore with")


def test_remote_desktop_undecodable_device_names_are_reported_not_mangled():
    # Withhold names changed by decoding replacement so corrupted bytes cannot
    # be presented as a device name.
    def check(home: Path):
        config = home / ".config" / "sunshine"
        config.mkdir(parents=True)
        state = config / "sunshine_state.json"
        old_xdg = os.environ.pop("XDG_CONFIG_HOME", None)
        try:
            state.write_bytes(json.dumps({"root": {"named_devices": [
                {"name": "mbp-1"}, {"name": "Bj\u00f6rn's iPad"},
            ]}}).encode("utf-8"))
            result = helper._rd_paired_clients()
            assert_equal(result["names"], ["mbp-1", "Bj\u00f6rn's iPad"], "valid UTF-8 names pass through")
            assert_equal(result["undecodable"], 0, "and nothing is reported as lost")
            assert_equal(result["known"], True, "a clean file is an answer")

            # A name carrying a lone 0x80 continuation byte. The JSON structure
            # is still readable, so the OTHER device must survive -- one bad
            # name is not a reason to lose the list.
            payload = json.dumps({"root": {"named_devices": [
                {"name": "good-client"}, {"name": "BADNAME"},
            ]}}).encode("utf-8").replace(b"BADNAME", b"bad-\x80-client")
            state.write_bytes(payload)
            result = helper._rd_paired_clients()
            assert_equal(result["known"], True, "the list itself is still readable")
            assert_equal(result["names"], ["good-client"], "a name with invalid bytes is withheld, not mangled")
            assert_equal(result["undecodable"], 1, "and the loss is counted rather than hidden")
            for name in result["names"]:
                if "\ufffd" in name:
                    raise AssertionError(f"a substituted name reached the payload: {name!r}")

            # A genuine replacement character in one name must survive corruption in another.
            payload = json.dumps({"root": {"named_devices": [
                {"name": "real\ufffdname"}, {"name": "BADNAME"},
            ]}}, ensure_ascii=False).encode("utf-8").replace(b"BADNAME", b"bad-\x80-client")
            state.write_bytes(payload)
            result = helper._rd_paired_clients()
            assert_equal(
                result["names"], ["real\ufffdname"],
                "a name the file really contains survives a broken neighbour",
            )
            assert_equal(result["undecodable"], 1, "and only the broken one is counted")

            # Escaped and literal non-ASCII JSON must give the same result.
            payload = json.dumps({"root": {"named_devices": [
                {"name": "real\ufffdname"}, {"name": "BADNAME"},
            ]}, }, ensure_ascii=True).encode("utf-8").replace(b"BADNAME", b"bad-\x80-client")
            state.write_bytes(payload)
            result = helper._rd_paired_clients()
            assert_equal(
                result["names"], ["real\ufffdname"],
                "an escaped U+FFFD is just as real as a literal one",
            )
            assert_equal(result["undecodable"], 1, "and the broken neighbour is still the only loss")

            # The corrupted name also appears cleanly in an unrelated field. Whole-file
            # substring presence cannot establish whether this name decoded cleanly.
            payload = json.dumps({
                "note": "bad-\ufffd-x",
                "root": {"named_devices": [{"name": "BADNAME"}]},
            }, ensure_ascii=False).encode("utf-8").replace(b'"BADNAME"', b'"bad-\x80-x"')
            state.write_bytes(payload)
            result = helper._rd_paired_clients()
            assert_equal(
                result["names"], [],
                "a mangled name must not be rescued by an identical string elsewhere in the file",
            )
            assert_equal(result["undecodable"], 1, "and it is still counted as lost")

            payload = json.dumps({"root": {"named_devices": [{"name": "mbp-1"}], "junk": "PAD"}}).encode("utf-8")
            payload = payload.replace(b'"PAD"', b'"\x80pad"')
            state.write_bytes(payload)
            result = helper._rd_paired_clients()
            assert_equal(result["names"], ["mbp-1"], "a clean name survives dirt elsewhere in the file")
            assert_equal(result["undecodable"], 0, "and nothing is claimed lost that was not")
        finally:
            if old_xdg is not None:
                os.environ["XDG_CONFIG_HOME"] = old_xdg

    with_temp_home(check)

    originals = {n: getattr(helper, n) for n in
                 ("_rd_unit_state", "_rd_manages_output", "_rd_paired_clients", "_rd_web_host")}
    helper._rd_unit_state = lambda: {"known": True, "error": "", "exists": True, "running": False}
    helper._rd_manages_output = lambda: {"manages": False, "compositor": "niri", "blocked": False, "reason": ""}
    helper._rd_web_host = lambda: "localhost"
    helper._rd_paired_clients = lambda: {"names": ["ok"], "known": True, "error": "", "undecodable": 2}
    try:
        status = helper.remote_desktop_status()
    finally:
        for name, value in originals.items():
            setattr(helper, name, value)
    assert_equal(status["pairedClientsUndecodable"], 2, "the withheld count must reach the widget")
    assert_equal(status["pairedClients"], ["ok"], "alongside the names that were readable")


def test_remote_desktop_watch_tokens_cover_every_event():
    # The widget consumes normalized tokens, so journal wording is tested here.
    cases = [
        ("2026-08-06 11:10:43 Info: CLIENT CONNECTED", "connected"),
        ("2026-08-06 11:45:30 Info: CLIENT DISCONNECTED", "disconnected"),
        ("Started Self-hosted game stream host for Moonlight.", "lifecycle"),
        ("Stopping Self-hosted game stream host for Moonlight...", "lifecycle"),
        ("Stopped Self-hosted game stream host for Moonlight.", "lifecycle"),
        ("Info: Creating encoder [hevc_nvenc]", "session"),
        ("Info: Streaming bitrate is 27788000", "session"),
        # Repeated startup noise must not trigger a shell resync for each log line.
        ("Info: [wayland] Found interface: wl_output(71) version 4", ""),
        ("Info: Color range: JPEG", ""),
        ("", ""),
    ]
    for line, expected in cases:
        assert_equal(helper._rd_watch_token(line), expected, f"watch token for {line!r}")


@contextlib.contextmanager
def _scratchpad_state_sandbox():
    """Use temporary pad locks and focus files.

    The default runtime directory belongs to the live session.
    """
    original = helper._scratchpad_state_dir
    with tempfile.TemporaryDirectory(prefix="vgs-scratchpad-state-") as tmp:
        helper._scratchpad_state_dir = lambda: Path(tmp)
        try:
            yield Path(tmp)
        finally:
            helper._scratchpad_state_dir = original


def _hides_on_readback(monitor="DP-1"):
    """Return a stateful visibility stub that confirms a successful hide.

    Each call site needs a fresh instance because reads advance its state.
    """
    seen = {"n": 0}

    def visibility(pad_id):
        seen["n"] += 1
        return ("visible", monitor) if seen["n"] == 1 else ("hidden", "")
    return visibility


def _visibility_from(monitor_fn):
    """Adapt a stub that returns a monitor name (or "") to the (state, monitor)
    shape `_scratchpad_visibility` returns. Every caller of this models a
    compositor that answers, so "" is a real "hidden"; the could-not-determine
    case is covered by its own test rather than smuggled in here."""
    def visibility(pad_id):
        name = monitor_fn(pad_id)
        return ("visible", name) if name else ("hidden", "")
    return visibility


def _pad(**overrides):
    base = {"id": "term", "name": "Terminal", "command": "ghostty",
            "classRegex": r"^(com\.ghostty\.scratchpad)$"}
    base.update(overrides)
    return helper.normalize_scratchpad(base)


def _monitor(name="DP-1", width=1920, height=1080, scale=1.0, x=0, y=0, **extra):
    mon = {"name": name, "width": width, "height": height, "scale": scale, "x": x, "y": y}
    mon.update(extra)
    return mon


def test_scratchpad_size_is_a_percentage_of_the_monitor():
    """The reason a pad stores a percentage instead of pixels: one record has to
    be right on every display it can land on. Pixels are correct on exactly one."""
    pad = _pad(widthPercent=60, heightPercent=70, anchor="top-center", offsetY=36)

    on_1080p = helper.resolve_scratchpad_geometry(pad, _monitor(height=1080))
    assert_equal((on_1080p["width"], on_1080p["height"]), (1152, 756), "60%x70% of 1920x1080")

    on_4k = helper.resolve_scratchpad_geometry(pad, _monitor(width=3840, height=2160))
    assert_equal((on_4k["width"], on_4k["height"]), (2304, 1512), "60%x70% of 3840x2160")

    # Geometry uses logical coordinates; output scaling changes the physical size.
    hidpi = helper.resolve_scratchpad_geometry(pad, _monitor(width=3840, height=2160, scale=2.0))
    assert_equal((hidpi["width"], hidpi["height"]), (1152, 756),
                 "a 4K monitor at scale 2 is logically 1080p")

    # An odd transform rotates the logical box; a portrait monitor is taller
    # than it is wide and the percentages have to follow.
    portrait = helper.resolve_scratchpad_geometry(pad, _monitor(width=2560, height=1440, transform=1))
    assert_equal((portrait["monitorWidth"], portrait["monitorHeight"]), (1440, 2560),
                 "transform 1 swaps the logical axes")

    exact = helper.resolve_scratchpad_geometry(
        _pad(sizeMode="pixels", widthPixels=900, heightPixels=600), _monitor())
    assert_equal((exact["width"], exact["height"]), (900, 600), "pixel override is honoured verbatim")


def test_scratchpad_anchor_resolves_to_coordinates():
    """A named anchor plus an offset is what users mean ("top-centre, 36px down
    to clear the bar"); raw coordinates are what they are forced to compute."""
    mon = _monitor(width=1000, height=800)
    size = {"sizeMode": "pixels", "widthPixels": 400, "heightPixels": 200}

    cases = {
        "top-left": (0, 0),
        "top-center": (300, 0),
        "top-right": (600, 0),
        "center": (300, 300),
        "bottom-right": (600, 600),
        "center-left": (0, 300),
    }
    for anchor, expected in cases.items():
        geometry = helper.resolve_scratchpad_geometry(_pad(anchor=anchor, **size), mon)
        assert_equal((geometry["x"], geometry["y"]), expected, f"anchor {anchor}")

    offset = helper.resolve_scratchpad_geometry(
        _pad(anchor="top-center", offsetY=36, **size), mon)
    assert_equal((offset["x"], offset["y"]), (300, 36), "top-centre, 36px down")

    # A right/bottom anchor measures its offset inward from that edge, so the
    # same positive number moves the pad the direction the user expects.
    inward = helper.resolve_scratchpad_geometry(
        _pad(anchor="bottom-right", offsetX=20, offsetY=10, **size), mon)
    assert_equal((inward["x"], inward["y"]), (580, 590), "offsets measure inward from the anchor")

    # An offset that would push the pad off the monitor is clamped: a scratchpad
    # you cannot see is indistinguishable from a keybind that does nothing.
    off_screen = helper.resolve_scratchpad_geometry(
        _pad(anchor="top-left", offsetX=5000, offsetY=5000, **size), mon)
    assert_equal((off_screen["x"], off_screen["y"]), (600, 600), "clamped onto the monitor")

    # Global coordinates carry the monitor origin, which is what movewindowpixel
    # takes; monitor-local ones are what a window rule `move` takes.
    second = helper.resolve_scratchpad_geometry(
        _pad(anchor="top-left", **size), _monitor(x=1920, y=-200, width=1000, height=800))
    assert_equal((second["x"], second["y"]), (0, 0), "local coordinates stay monitor-relative")
    assert_equal((second["globalX"], second["globalY"]), (1920, -200), "global coordinates carry the origin")


def test_scratchpad_records_that_cannot_work_are_rejected():
    """A partial rule is worse than none: a pad with no class regex would match
    nothing at all, or with a bad one, capture windows it should never touch."""
    assert_equal(helper.normalize_scratchpad({"id": "term", "command": "x"}), None,
                 "a pad with no class regex is rejected")
    assert_equal(helper.normalize_scratchpad({"id": "term", "classRegex": "^x$"}), None,
                 "a pad with no command is rejected")
    assert_equal(helper.normalize_scratchpad(
        {"id": "term", "command": "x", "classRegex": "^(unclosed"}), None,
        "a pad whose class regex does not compile is rejected")
    # The id becomes a special-workspace name and reaches `hyprctl dispatch`;
    # restrict it rather than trying to escape it.
    for bad in ("", "Has Space", "../escape", "a/b", "a" * 40, "-lead"):
        assert_equal(helper.normalize_scratchpad(
            {"id": bad, "command": "x", "classRegex": "^x$"}), None,
            f"id {bad!r} is rejected")
    assert helper.normalize_scratchpad({"id": "term-2_a", "command": "x", "classRegex": "^x$"})

    # Case is normalized rather than rejected — Hyprland special-workspace names
    # are matched literally, so accepting "Term" and "term" as two distinct pads
    # would produce two rule sets that fight over one workspace.
    assert_equal(helper.normalize_scratchpad(
        {"id": "Term", "command": "x", "classRegex": "^x$"})["id"], "term",
        "an id is lowercased, not rejected")

    # Unknown enum values fall back rather than reaching the generator, where
    # they would render an anchor or animation Hyprland does not know.
    pad = _pad(anchor="nowhere", animation="explode", presentation="hologram", sizeMode="cubits")
    assert_equal(pad["anchor"], "top-center", "unknown anchor falls back")
    assert_equal(pad["animation"], "slide-top", "unknown animation falls back")
    assert_equal(pad["presentation"], "float", "unknown presentation falls back")
    assert_equal(pad["sizeMode"], "percent", "unknown size mode falls back")


def test_scratchpad_lua_generation():
    pads = [
        _pad(keybind="SUPER, T", monitor="DP-1", anchor="top-center", offsetY=36,
             widthPercent=60, heightPercent=70, preload=True),
        _pad(id="vm", name="Work VM", classRegex="^(vm-viewer)$", command="virt-viewer",
             presentation="fullscreen", keybind="SUPER, 8"),
        _pad(id="off", classRegex="^(off)$", command="off", enabled=False),
    ]
    monitors = [_monitor("DP-1", focused=True), _monitor("eDP-1", x=1920)]
    text, meta = helper.render_scratchpads_lua(pads, monitors, True)

    assert_equal(meta["count"], 2, "a disabled pad generates no rules")
    assert_equal(meta["defined"], 3, "but is still counted as defined")
    assert_equal(meta["preload"], ["term"], "only pads that ask for it preload")
    assert '"special:term"' in text, "workspace rule names the special workspace"
    assert '"special:term silent"' in text, "window rule assigns it silently"
    assert '"1152 756"' in text, "size is resolved from the percentage, not left as one"
    assert '"384 36"' in text, "move is resolved from the anchor"
    assert "no_initial_focus = true" in text
    assert '"^(off)$"' not in text, "a disabled pad must not appear at all"

    # on_created_empty is what makes a cold press show an empty workspace before
    # the app has spawned; the toggle launches and waits instead.
    assert "on_created_empty" not in text, "generation must not use on_created_empty"

    # The specialWorkspace animation leaf is global. Writing it per pad would let
    # the last pad silently win and overwrite the user's own global animation.
    assert "hl.animation" not in text, "per-pad animation must be a window rule, not the global leaf"
    assert 'animation = "slide top"' in text

    # An app that requests activation after mapping would otherwise reveal its
    # own hidden workspace.
    assert "suppress_event" in text

    empty_text, empty_meta = helper.render_scratchpads_lua([], monitors, True)
    assert_equal(empty_meta["count"], 0, "no pads generates no rules")
    assert "hl.window_rule" not in empty_text, "an empty list writes an inert file, not junk"

    # Generated without a compositor, the geometry came from a guessed display.
    # That has to be visible in the file, not only in the return payload.
    unresolved, unresolved_meta = helper.render_scratchpads_lua(pads, monitors, False)
    assert_equal(unresolved_meta["monitorsResolved"], False, "the payload records it")
    assert "WARNING" in unresolved, "and so does the file itself"


def test_scratchpad_generated_lua_parses():
    """The generator emits Lua that Hyprland will `require`. A syntax error here
    is a config that fails to load at compositor start, so parse what we wrote."""
    luac = shutil.which("luac")
    if not luac:
        raise AssertionError("luac not installed: the generated scratchpad Lua cannot be parse-checked")

    def parses(source: str) -> bool:
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as handle:
            handle.write(source)
            path = handle.name
        try:
            return subprocess.run([luac, "-p", path], capture_output=True).returncode == 0
        finally:
            os.unlink(path)

    assert not parses("hl.window_rule({ this is not lua"), "luac -p must reject broken Lua"

    pads = [
        _pad(keybind="SUPER, T", monitor="DP-1", preload=True),
        _pad(id="vm", classRegex="^(vm-viewer)$", command="virt-viewer", presentation="fullscreen"),
        _pad(id="tiled", classRegex="^(tiled)$", command="tiled", presentation="tile"),
        # Regexes and commands are full of backslashes and quotes; they are the
        # most likely thing to break the generated file.
        _pad(id="quoted", classRegex=r'^(a\.b"c)$', command='sh -c "echo hi"',
             titleExclude=r"^(1Password)$", keybind="SUPER, Q"),
    ]
    text, _ = helper.render_scratchpads_lua(pads, [_monitor("DP-1", focused=True)], True)
    assert parses(text), "generated scratchpad config must be valid Lua"


def test_scratchpad_niri_generation():
    """Test Niri scratchpads as named workspaces and window rules from the shared record."""
    pads = [
        _pad(keybind="Mod+T", monitor="DP-1", preload=True, anchor="top-center", offsetY=36),
        _pad(id="notes", classRegex="^(obsidian)$", command="obsidian",
             titleExclude="^(Quick Switcher)$", anchor="bottom-right", offsetX=24, offsetY=24,
             sizeMode="pixels", widthPixels=1200, heightPixels=800),
        _pad(id="vm", classRegex="^(vm-viewer)$", command="virt-viewer", presentation="fullscreen"),
        _pad(id="tiled", classRegex="^(tiled)$", command="tiled", presentation="tile"),
    ]
    text, meta = helper.render_scratchpads_kdl(pads)

    # Prefix generated workspace names to reduce collisions with user workspaces.
    assert 'workspace "vgs-term" {' in text, "a pad with a monitor pins its workspace to that output"
    assert '    open-on-output "DP-1"' in text, "the configured monitor becomes open-on-output"
    assert 'workspace "vgs-notes"\n' in text, "a pad with no monitor declares a bare workspace"
    assert 'open-on-workspace "vgs-term"' in text, "the window rule routes the app to it"

    # Percentages stay percentages: niri resolves `proportion` against the real
    # output, so unlike the Hyprland backend nothing is frozen into pixels at
    # generation time and no monitor query is needed to render at all.
    assert "default-column-width { proportion 0.6; }" in text, "percent sizing becomes a proportion"
    assert "default-window-height { proportion 0.7; }" in text
    assert "default-column-width { fixed 1200; }" in text, "pixel sizing becomes fixed"

    assert 'default-floating-position x=0 y=36 relative-to="top"' in text, \
        "top-center is niri's single-side 'top', which centres on that edge"
    assert 'default-floating-position x=24 y=24 relative-to="bottom-right"' in text, \
        "and bottom-right offsets count inward, exactly as the Hyprland resolver means them"

    # Both patterns go into the same rule, so a window excluded by title is
    # excluded from every property rather than half-owned.
    assert 'match app-id=r#"^(obsidian)$"#' in text
    assert 'exclude title=r#"^(Quick Switcher)$"#' in text

    assert "open-fullscreen true" in text, "fullscreen presentation"
    assert "open-floating false" in text, "tile presentation"
    assert "open-focused false" in text, \
        "the pad must not steal focus when it maps; the toggle focuses it deliberately"

    assert '{ spawn ' in text and '"scratchpad" "toggle" "term"' in text, "keybind spawns the toggle"
    assert '"scratchpad" "preload" "term"' in text, "preload spawns the preload path"
    assert "spawn-at-startup" in text, "preload uses niri's own startup hook"
    assert_equal(meta["count"], 4, "every enabled pad is rendered")
    assert_equal(meta["preload"], ["term"], "and the preload list is reported")


def test_scratchpad_niri_reports_what_it_cannot_express():
    """Anything Niri cannot do is REPORTED, never silently dropped. A setting
    that is stored, shown in Settings and ignored by the compositor is the
    defect this whole subsystem has refused."""
    text, meta = helper.render_scratchpads_kdl([_pad()])
    fields = {item["field"] for item in meta["unsupported"]}
    assert "animation" in fields, \
        "per-pad entry animation cannot be expressed: niri's window-open animation is global"
    assert "dismissOnFocusLoss" in fields, "and focus-loss dismissal is not wired up on niri"
    assert "animations" not in text, \
        "VGS must not overwrite the user's global animation to fake a per-pad one"

    # Centre + offset: niri has no centre `relative-to`. The pad is still
    # generated and still works, centred — but the dropped offset is named.
    _, centred = helper.render_scratchpads_kdl([_pad(id="mid", anchor="center", offsetX=40)])
    offsets = [item for item in centred["unsupported"] if item.get("field") == "anchor offset"]
    assert offsets, "a centre anchor with an offset must be reported as unexpressible"
    assert "mid" in offsets[0]["reason"] or "Terminal" in offsets[0]["reason"] or offsets[0].get("id")

    _, plain = helper.render_scratchpads_kdl([_pad(id="mid", anchor="center")])
    assert not [i for i in plain["unsupported"] if i.get("field") == "anchor offset"], \
        "an unoffset centre pad loses nothing and must not be reported"


def test_scratchpad_niri_rejects_rules_it_cannot_write_correctly():
    """Reject rather than half-emit. A pad that cannot be expressed correctly
    generates NO rule and says why — and on Niri the stakes are higher than one
    pad, because a rule niri refuses to parse takes the whole config with it."""
    # Python's re accepts lookaround; niri's Rust regex engine does not.
    problems = []
    text, meta = helper.render_scratchpads_kdl([_pad(classRegex=r"^(?!excluded)(term)$")], problems)
    assert_equal(meta["count"], 0, "a pad with a lookaround pattern is not rendered")
    assert problems and "lookahead" in problems[0]["reason"], \
        "and the rejection names the reason rather than the pad just vanishing"
    assert "window-rule" not in text, "no partial rule is emitted"

    # A pattern that would terminate the KDL raw string early is rejected for
    # the same reason: the alternative is a rule that parses as something
    # narrower and quietly stops matching.
    problems = []
    _, meta = helper.render_scratchpads_kdl([_pad(classRegex='^(a"#b)$')], problems)
    assert_equal(meta["count"], 0, 'a pattern containing \'"#\' is not rendered')
    assert problems and "raw string" in problems[0]["reason"], "and says so"

    problems = []
    _, meta = helper.render_scratchpads_kdl([_pad(titleExclude=r"(?<=x)y")], problems)
    assert_equal(meta["count"], 0, "an unexpressible exclusion rejects the whole pad")
    assert problems and "title exclusion" in problems[0]["reason"]


def test_scratchpad_niri_keybinds_are_converted():
    """Translate Settings keybind syntax into Niri bindings."""
    convert = helper.scratchpad_niri_keybind
    assert_equal(convert("SUPER, T"), "Mod+T", "SUPER becomes Mod and the comma separator goes")
    assert_equal(convert("SUPER + SHIFT, E"), "Mod+Shift+E", "every modifier is translated")
    assert_equal(convert("CTRL + ALT, Delete"), "Ctrl+Alt+Delete", "and a named key is kept")
    assert_equal(convert("T"), "T", "a bind with no modifiers still converts")

    # The capture records a single printable character, so punctuation is what
    # it actually produces; niri wants the xkb keysym name for those.
    assert_equal(convert("SUPER, /"), "Mod+slash", "punctuation becomes its keysym")
    assert_equal(convert("SUPER, ,"), "Mod+comma",
                 "the comma is a bindable KEY, not only the separator — splitting on every "
                 "comma left nothing to bind")
    assert_equal(convert("SUPER, F5"), "Mod+F5", "function keys pass through")
    assert_equal(convert("SUPER, XF86AudioPlay"), "Mod+XF86AudioPlay", "media keys are keysyms already")
    assert_equal(convert("Mod+T"), "Mod+T", "a bind already written niri's way is not mangled")

    # Anything that cannot be spelled confidently returns "" so the caller can
    # report it, rather than a guess that might shadow a bind the user has.
    assert_equal(convert("SUPER"), "", "modifiers with no key are an unfinished chord")
    assert_equal(convert("SUPER, T, Y"), "", "two keys are not one niri bind")
    assert_equal(convert("SUPER, \u00a3"), "", "a key with no keysym name is refused, not invented")
    assert_equal(convert(""), "", "an empty keybind converts to nothing")


def test_scratchpad_niri_unconvertible_keybind_is_reported_not_emitted():
    """A bind that cannot be converted must not be written verbatim, and must
    not take the pad down with it: the pad still works through `vshell
    scratchpad toggle`, so it is generated and the bind alone is reported."""
    text, meta = helper.render_scratchpads_kdl([_pad(keybind="SUPER, \u00a3")])
    assert_equal(meta["count"], 1, "the pad is still generated")
    assert "binds {" not in text, "but no bind block is written for it"
    assert "\u00a3" not in text, "and the unconvertible key never reaches the config"
    keybinds = [item for item in meta["unsupported"] if item.get("field") == "keybind"]
    assert keybinds, "the dropped bind is reported"
    assert_equal(meta["scratchpads"][0]["keybind"], "",
                 "and the payload reports no keybind rather than the Hyprland spelling")

    text, meta = helper.render_scratchpads_kdl([_pad(keybind="SUPER + SHIFT, T")])
    assert '"Mod+Shift+T"' in text, "a convertible bind is emitted the way niri spells it"
    assert "SUPER" not in text, "and the Hyprland spelling does not survive into the KDL"
    assert not [i for i in meta["unsupported"] if i.get("field") == "keybind"], \
        "a bind that converted cleanly is not reported as a problem"


def test_scratchpad_niri_rejects_every_construct_it_can_prove_unsupported():
    """Rust's regex crate guarantees linear time, so it implements nothing that
    needs backtracking. Each of these compiles in Python and would make niri
    reject the WHOLE config file — not just the pad."""
    for pattern, label in [
        (r"^(?!skip)(term)$", "lookahead"),
        (r"^(?<=x)y$", "lookbehind"),
        (r"^(a)\1$", "a backreference"),
        (r"^(?P<n>a)(?P=n)$", "a named backreference"),
        (r"^(?>ab)c$", "an atomic group"),
        (r"^a*+b$", "a possessive quantifier"),
        (r"^(?#note)a$", "an inline comment group"),
        (r"^a\Z", r"\Z"),
    ]:
        problems = []
        _, meta = helper.render_scratchpads_kdl([_pad(classRegex=pattern)], problems)
        assert_equal(meta["count"], 0, f"a pattern using {label} is not rendered")
        assert problems, f"and {label} is named rather than the pad vanishing"

    for good in [r"^(com\.ghostty\.scratchpad)$", r"^(a|b)+$", r"^(1password)$"]:
        problems = []
        _, meta = helper.render_scratchpads_kdl([_pad(classRegex=good)], problems)
        assert_equal(meta["count"], 1, f"{good!r} is a pattern niri accepts")
        assert_equal(problems, [], "so it is not reported")


def test_scratchpad_niri_rejected_pads_do_not_preload():
    """A rejected pad generates no workspace, no rule and no bind — so
    preloading it would launch its app at every login into a session with
    nowhere to put it. A pad refused for being unusable is refused everywhere,
    not only in the half that emits rules."""
    problems = []
    text, meta = helper.render_scratchpads_kdl(
        [_pad(id="bad", classRegex=r"^(?!x)y$", preload=True),
         _pad(id="good", classRegex="^(good)$", preload=True)], problems)
    assert_equal(meta["count"], 1, "only the usable pad is rendered")
    assert problems, "and the rejection is reported"
    assert_equal(meta["preload"], ["good"], "the rejected pad is not preloaded")
    assert '"preload" "bad"' not in text, "and nothing launches it at startup"
    assert '"preload" "good"' in text, "while the usable pad still preloads"


def test_scratchpad_niri_release_owns_only_the_pad_s_own_window():
    """Release must own exactly the window the pad owned. Matching on the class
    alone picks up a same-class window that was never in the pad — a second
    terminal — and yanks it onto the user's active workspace."""
    originals = (helper._niri_session_ready, helper._niri_msg_json,
                 helper._niri_scratchpad_action)
    actions = []
    helper._niri_session_ready = lambda: True
    helper._niri_scratchpad_action = lambda *a: (actions.append(a), True)[1]

    state = {"windows": [], "workspaces": []}
    helper._niri_msg_json = lambda *args: state.get(args[0] if args else "", None)
    try:
        state["workspaces"] = [{"id": 9, "name": "vgs-term", "idx": 3, "is_active": False},
                               {"id": 4, "name": "", "idx": 2, "is_focused": True}]

        state["windows"] = [{"id": 1, "app_id": "com.ghostty.scratchpad",
                             "title": "other", "workspace_id": 4}]
        stray = helper.scratchpad_release_niri("term", r"^(com\.ghostty\.scratchpad)$")
        assert_equal(stray["released"], False, "a window that was never in the pad is not released")
        assert_equal(actions, [], "and nothing is moved")

        # Place a non-owned match first so selection must filter before choosing a window.
        actions.clear()
        state["windows"] = [{"id": 1, "app_id": "com.ghostty.scratchpad",
                             "title": "other", "workspace_id": 4},
                            {"id": 7, "app_id": "com.ghostty.scratchpad",
                             "title": "pad", "workspace_id": 9}]
        ordered = helper.scratchpad_release_niri("term", r"^(com\.ghostty\.scratchpad)$")
        assert_equal(ordered["released"], True,
                     "the pad's own window is found past an earlier stray")
        assert_equal(actions, [("move-window-to-workspace", "--window-id", "7",
                                "--focus", "false", "2")],
                     "and it is the one moved")

        actions.clear()
        state["windows"] = [{"id": 7, "app_id": "com.ghostty.scratchpad",
                             "title": "pad", "workspace_id": 9}]
        released = helper.scratchpad_release_niri("term", r"^(com\.ghostty\.scratchpad)$")
        assert_equal(released["released"], True, "the pad's own window is released")
        assert_equal(actions, [("move-window-to-workspace", "--window-id", "7",
                                "--focus", "false", "2")],
                     "moved by the focused workspace's INDEX: niri reads a numeric reference as "
                     "an index, so passing the global id would name a different workspace")

        # A workspace list that cannot be read is unknown, not empty: refuse
        # rather than move a window chosen only by class.
        actions.clear()
        helper._niri_msg_json = lambda *args: [] if (args and args[0] == "windows") else None
        state["windows"] = []
        blind = helper.scratchpad_release_niri("term", r"^(x)$")
        assert_equal(blind["released"], False, "nothing is released when the session cannot answer")
        assert_equal(actions, [], "and nothing is moved")
    finally:
        (helper._niri_session_ready, helper._niri_msg_json,
         helper._niri_scratchpad_action) = originals


def test_scratchpad_launch_command_is_argv_not_a_shell():
    """Execute user-configured pad commands as argv.

    Preloaded commands can run at login, so implicit shell evaluation would
    interpret configuration metacharacters there too.
    """
    argv, error = helper.scratchpad_launch_argv("ghostty --class=com.ghostty.scratchpad")
    assert_equal(error, "", "an ordinary command parses cleanly")
    assert_equal(argv, ["ghostty", "--class=com.ghostty.scratchpad"], "into an argv array")

    argv, error = helper.scratchpad_launch_argv('ghostty --title="My Pad"')
    assert_equal(error, "", "quoted arguments are still supported")
    assert_equal(argv, ["ghostty", "--title=My Pad"], "and are parsed, not word-split")

    # Shell operators passed as ordinary argv words would silently change the command.
    for command in ["foo && bar", "foo; bar", "foo|bar", "foo > /tmp/x",
                    "foo $(id)", "foo `id`", "foo ${HOME}", "foo $HOME",
                    "app --flag=a&b"]:
        argv, error = helper.scratchpad_launch_argv(command)
        assert_equal(argv, [], f"{command!r} is not executed as argv")
        assert "shell" in error, f"{command!r} is refused with the reason: {error!r}"
        assert "sh -c" in error, "and the refusal says how to opt in deliberately"

    # `foo; bar` only tokenises as a bare `;` because the lexer is told to treat
    # punctuation the way a shell does; plain shlex hides it inside `foo;` and
    # the operator would sail straight through as an argument.
    argv, error = helper.scratchpad_launch_argv("foo; bar")
    assert_equal(argv, [], "an operator with no surrounding spaces is still caught")

    # An explicit shell command must pass after tokenization; raw-text checks can reject it.
    argv, error = helper.scratchpad_launch_argv("sh -c 'foo && bar'")
    assert_equal(error, "", "an explicit shell is allowed")
    assert_equal(argv, ["sh", "-c", "foo && bar"],
                 "with the shell line intact as a single argument")

    for command, expected in [("env FOO=1 app", ["env", "FOO=1", "app"]),
                              ("1password --silent", ["1password", "--silent"])]:
        argv, error = helper.scratchpad_launch_argv(command)
        assert_equal(error, "", f"{command!r} is an ordinary command")
        assert_equal(argv, expected, "parsed as argv")

    argv, error = helper.scratchpad_launch_argv('ghostty --title="unbalanced')
    assert_equal(argv, [], "an unparseable command is refused")
    assert error, "with a reason"
    assert_equal(helper.scratchpad_launch_argv("")[1] != "", True, "so is an empty one")


def test_scratchpad_launch_refusal_reaches_the_toggle():
    """The refusal has to surface where the user sees it: a pad whose command
    cannot be run must fail loudly rather than reporting a reveal that never
    launched anything."""
    originals = (helper.load_scratchpads, helper._scratchpad_visible_monitor,
                 helper._scratchpad_find_window, helper._scratchpad_dispatch,
                 helper._scratchpad_session_ready, helper._hyprctl_json)
    helper.load_scratchpads = lambda *a, **k: [_pad(command="foo && bar")]
    helper._scratchpad_visible_monitor = lambda pad_id: ""
    helper._scratchpad_find_window = lambda pad: None
    helper._scratchpad_dispatch = lambda *args: True
    helper._hyprctl_json = lambda *args: None
    helper._scratchpad_session_ready = lambda: True
    try:
        with _scratchpad_state_sandbox():
            result = helper.scratchpad_toggle("term")
        assert_equal(result["ok"], False, "a pad with a shell command does not silently reveal")
        assert_equal(result["action"], "launch-refused", "and says the launch was refused")
        assert "shell" in result["error"], f"naming the reason: {result['error']!r}"
    finally:
        (helper.load_scratchpads, helper._scratchpad_visible_monitor,
         helper._scratchpad_find_window, helper._scratchpad_dispatch,
         helper._scratchpad_session_ready, helper._hyprctl_json) = originals


def test_scratchpad_niri_pad_name_cannot_break_the_generated_kdl():
    """Keep unrestricted pad names inside generated comments.

    A newline must not let name text become KDL code.
    """
    text, _ = helper.render_scratchpads_kdl(
        [_pad(name="Bad\nwindow-rule { open-fullscreen true }")])
    comment = [line for line in text.splitlines() if line.startswith("// Bad")]
    assert comment, "the pad still gets its comment"
    assert_equal(len(comment), 1, "on exactly one line")
    assert "window-rule { open-fullscreen true }" in comment[0], \
        "with the injected text flattened INTO the comment, where it is inert"

    # Count generated blocks to detect a name that escaped its comment into KDL.
    sys.path.insert(0, str(REPO_ROOT / "bin"))
    import vshell_niri_kdl as kdl
    headers = [header for header, _, _ in kdl.kdl_nodes_in_block(text)]
    assert_equal(headers.count("window-rule"), 1,
                 "a name carrying a window-rule does not become a second rule")


def test_scratchpad_niri_hide_confirms_the_pad_is_off_screen():
    """Check hide confirmation against the active workspace of the relevant output."""
    originals = (helper._niri_session_ready, helper._niri_msg_json,
                 helper._niri_scratchpad_action, helper.load_scratchpads)
    helper._niri_session_ready = lambda: True
    helper._niri_scratchpad_action = lambda *a: True
    helper.load_scratchpads = lambda *a, **k: [_pad(id="term")]

    # `hides` models whether focusing away actually takes the pad off screen.
    # It does not when the window focus is restored to lives on another output:
    # the pad's workspace stays the ACTIVE one on its own output.
    state = {"visible": True, "hides": False}

    def fake_json(*args):
        if args and args[0] == "workspaces":
            return [{"id": 9, "name": "vgs-term", "idx": 3,
                     "is_active": state["visible"], "is_focused": False,
                     "output": "DP-2"}]
        return []

    def fake_action(*args):
        if args and args[0] in ("focus-window", "focus-workspace-previous") and state["hides"]:
            state["visible"] = False
        return True

    helper._niri_msg_json = fake_json
    helper._niri_scratchpad_action = fake_action
    try:
        with _scratchpad_state_sandbox():
            # The pad remains on the active workspace of its output despite moved focus.
            result = helper.scratchpad_toggle_niri("term")
        assert_equal(result["ok"], False, "a pad still displayed is not a successful hide")
        assert_equal(result["action"], "hide-failed", "and says so")
        assert "DP-2" in result["error"], f"naming where it still is: {result['error']!r}"

        state["visible"] = True
        state["hides"] = True
        with _scratchpad_state_sandbox():
            ok = helper.scratchpad_toggle_niri("term")
        assert_equal((ok["ok"], ok["action"], ok["id"]), (True, "hidden", "term"),
                     "a pad that is genuinely off screen reports hidden")
    finally:
        (helper._niri_session_ready, helper._niri_msg_json,
         helper._niri_scratchpad_action, helper.load_scratchpads) = originals


def test_scratchpad_hide_focus_rule_is_shared_by_both_backends():
    """Apply the shared focus-restoration decision on both compositor backends."""
    rule = helper._scratchpad_restore_target
    assert_equal(rule(False, "B", "C"), "B", "a keybind hide returns to the reveal origin")
    assert_equal(rule(True, "B", "C"), "C", "a focus-loss dismissal keeps where the user went")
    assert_equal(rule(True, "B", ""), "B",
                 "unknown focus, or focus still on the pad, falls back to the origin")
    assert_equal(rule(False, "", "C"), "", "no origin and no keep-focus restores nothing")


def test_scratchpad_niri_hide_honours_the_same_flags():
    """Support hide flags on the Niri toggle path used by the CLI."""
    import inspect
    hypr = set(inspect.signature(helper.scratchpad_toggle).parameters)
    niri = set(inspect.signature(helper.scratchpad_toggle_niri).parameters)
    assert_equal(hypr, niri, "both toggles accept the same arguments")

    originals = (helper._niri_session_ready, helper._niri_msg_json,
                 helper._niri_scratchpad_action, helper.load_scratchpads)
    actions = []
    helper._niri_session_ready = lambda: True
    helper._niri_scratchpad_action = lambda *a: (actions.append(a), True)[1]
    helper.load_scratchpads = lambda *a, **k: [_pad(id="term")]

    state = {"visible": True}

    def fake_json(*args):
        if args and args[0] == "workspaces":
            return [{"id": 9, "name": "vgs-term", "idx": 3,
                     "is_active": state["visible"], "is_focused": False, "output": "DP-2"}]
        if args and args[0] == "windows":
            # 7 is the pad's own window; 5 is where the user has since moved.
            return [{"id": 7, "app_id": "x", "workspace_id": 9, "is_focused": False},
                    {"id": 5, "app_id": "y", "workspace_id": 4, "is_focused": True}]
        return None

    helper._niri_msg_json = fake_json
    try:
        state["visible"] = False
        with _scratchpad_state_sandbox():
            quiet = helper.scratchpad_toggle_niri("term", hide_only=True)
        assert_equal(quiet["action"], "already-hidden", "an already-hidden pad is nothing to do")
        assert_equal(actions, [], "and dispatches nothing")

        # Focus-loss dismissal keeps the window the user moved to (5), not the
        # reveal origin (7) recorded in the state file.
        state["visible"] = True
        actions.clear()
        with _scratchpad_state_sandbox() as sandbox:
            (sandbox / "term.niri-focus").write_text("7")
            state["visible"] = True

            def hides(*a):
                actions.append(a)
                if a and a[0] in ("focus-window", "focus-workspace-previous"):
                    state["visible"] = False
                return True

            helper._niri_scratchpad_action = hides
            result = helper.scratchpad_toggle_niri("term", hide_only=True, keep_focus=True)
        assert_equal(result["ok"], True, "the hide succeeds")
        assert_equal(result["focusedBack"], "5",
                     "focus stays on the window the user chose, not the reveal origin")
        assert ("focus-window", "--id", "7") not in actions, \
            "and is never yanked back to the pad's reveal origin"
    finally:
        (helper._niri_session_ready, helper._niri_msg_json,
         helper._niri_scratchpad_action, helper.load_scratchpads) = originals


def test_scratchpad_release_refuses_when_it_could_not_look():
    """A failed window query must not authorize deleting a pad record.

    Settings removes configuration only after release reports success.
    """
    originals = (helper._hyprctl_json, helper._scratchpad_session_ready,
                 helper._scratchpad_dispatch)
    dispatched = []
    helper._scratchpad_session_ready = lambda: True
    helper._scratchpad_dispatch = lambda *a: (dispatched.append(a), True)[1]
    try:
        helper._hyprctl_json = lambda *a: None
        blind = helper.scratchpad_release("pad", r"^(com\.example\.pad)$")
        assert_equal(blind["ok"], False, "a release that could not look has not succeeded")
        assert_equal(blind["released"], False, "and released nothing")
        assert "could not read the window list" in blind["error"], \
            f"naming why the pad was kept: {blind.get('error')!r}"
        assert_equal(dispatched, [], "nothing is moved on the strength of a failed query")

        helper._hyprctl_json = lambda *a: ([] if a and a[0] == "clients"
                                           else {"id": 3} if a and a[0] == "activeworkspace" else None)
        empty = helper.scratchpad_release("pad", r"^(com\.example\.pad)$")
        assert_equal(empty["ok"], True, "an empty window list is a real answer")
        assert_equal(empty["released"], False, "with nothing to release")
    finally:
        (helper._hyprctl_json, helper._scratchpad_session_ready,
         helper._scratchpad_dispatch) = originals

    niri_originals = (helper._niri_session_ready, helper._niri_msg_json,
                      helper._niri_scratchpad_action)
    actions = []
    helper._niri_session_ready = lambda: True
    helper._niri_scratchpad_action = lambda *a: (actions.append(a), True)[1]
    try:
        helper._niri_msg_json = lambda *a: ([{"id": 9, "name": "vgs-term", "idx": 3}]
                                            if a and a[0] == "workspaces" else None)
        blind = helper.scratchpad_release_niri("term", r"^(com\.ghostty\.scratchpad)$")
        assert_equal(blind["ok"], False, "a Niri release that could not look has not succeeded")
        assert "could not read the window list" in blind["error"], "and names why"
        assert_equal(actions, [], "nothing is moved")
    finally:
        (helper._niri_session_ready, helper._niri_msg_json,
         helper._niri_scratchpad_action) = niri_originals

    # The distinction has to exist in the finder itself, or no caller can make
    # it. None is "could not look"; [] is "looked, found nothing".
    saved = helper._hyprctl_json
    try:
        helper._hyprctl_json = lambda *a: None
        assert helper._scratchpad_find_windows(_pad()) is None, \
            "an unreadable client list is None, not an empty list"
        helper._hyprctl_json = lambda *a: []
        assert_equal(helper._scratchpad_find_windows(_pad()), [],
                     "a readable but empty list is []")
    finally:
        helper._hyprctl_json = saved


def test_scratchpad_preload_reports_a_failed_placement():
    """Report a preload that cannot move its window to the pad workspace."""
    originals = (helper._niri_session_ready, helper._niri_msg_json,
                 helper._niri_scratchpad_action, helper.load_scratchpads)
    helper._niri_session_ready = lambda: True
    helper.load_scratchpads = lambda *a, **k: [_pad(id="term")]

    def fake_json(*args):
        if args and args[0] == "workspaces":
            return [{"id": 9, "name": "vgs-term", "idx": 3, "is_active": False}]
        if args and args[0] == "windows":
            return [{"id": 7, "app_id": "com.ghostty.scratchpad", "workspace_id": 4}]
        return None

    helper._niri_msg_json = fake_json
    try:
        helper._niri_scratchpad_action = lambda *a: False
        with _scratchpad_state_sandbox():
            bad = helper.scratchpad_toggle_niri("term", launch_only=True)
        assert_equal(bad["ok"], False, "a preload that could not park the window is not ok")
        assert_equal(bad["action"], "preload-failed", "and says so")
        assert "could not move" in bad["error"], f"naming the reason: {bad.get('error')!r}"

        helper._niri_scratchpad_action = lambda *a: True
        with _scratchpad_state_sandbox():
            good = helper.scratchpad_toggle_niri("term", launch_only=True)
        assert_equal(good["ok"], True, "a preload that parked the window is ok")
        assert_equal(good["action"], "preloaded", "and reports the preload")
    finally:
        (helper._niri_session_ready, helper._niri_msg_json,
         helper._niri_scratchpad_action, helper.load_scratchpads) = originals

    hypr = (helper.load_scratchpads, helper._scratchpad_visible_monitor,
            helper._scratchpad_find_window, helper._scratchpad_dispatch,
            helper._scratchpad_session_ready, helper._hyprctl_json,
            helper._scratchpad_place_workspace, helper._scratchpad_reassert)
    helper.load_scratchpads = lambda *a, **k: [_pad(id="term")]
    helper._scratchpad_visible_monitor = lambda pad_id: ""
    helper._scratchpad_find_window = lambda pad: {"address": "0xaaa", "workspace": {"name": "3"}}
    helper._scratchpad_session_ready = lambda: True
    helper._hyprctl_json = lambda *a: None
    helper._scratchpad_reassert = lambda *a, **k: {"applied": True}
    try:
        helper._scratchpad_dispatch = lambda *a: False
        helper._scratchpad_place_workspace = lambda *a, **k: True
        with _scratchpad_state_sandbox():
            bad = helper.scratchpad_toggle("term", launch_only=True)
        assert_equal(bad["ok"], False, "a Hyprland preload that could not park is not ok")
        assert_equal(bad["action"], "preload-failed", "and says so")

        helper._scratchpad_dispatch = lambda *a: True
        helper._scratchpad_place_workspace = lambda *a, **k: False
        with _scratchpad_state_sandbox():
            unplaced = helper.scratchpad_toggle("term", launch_only=True)
        assert_equal(unplaced["ok"], False, "a workspace that would not move is a failure too")

        helper._scratchpad_place_workspace = lambda *a, **k: True
        with _scratchpad_state_sandbox():
            good = helper.scratchpad_toggle("term", launch_only=True)
        assert_equal(good["ok"], True, "a preload that worked is ok")
    finally:
        (helper.load_scratchpads, helper._scratchpad_visible_monitor,
         helper._scratchpad_find_window, helper._scratchpad_dispatch,
         helper._scratchpad_session_ready, helper._hyprctl_json,
         helper._scratchpad_place_workspace, helper._scratchpad_reassert) = hypr


def _niri_hide_harness(still_active_after, focused_output_after, pad_output="DP-2"):
    """Stub a Niri session for the hide path.

    The pad starts VISIBLE on `pad_output` — otherwise the hide branch is never
    entered — and the workspace state flips to the given post-state when the
    focus action runs, which is what the confirmation reads back."""
    state = {"done": False}
    actions = []

    def action(*a):
        actions.append(a)
        if a and a[0] in ("focus-window", "focus-workspace-previous"):
            state["done"] = True
        return True

    def fake_json(*args):
        if args and args[0] == "windows":
            return [{"id": 7, "app_id": "com.ghostty.scratchpad", "workspace_id": 9}]
        if args and args[0] != "workspaces":
            return None
        if not state["done"]:
            return [{"id": 9, "name": "vgs-term", "idx": 3, "output": pad_output,
                     "is_active": True, "is_focused": True}]
        rows = [{"id": 9, "name": "vgs-term", "idx": 3, "output": pad_output,
                 "is_active": still_active_after,
                 "is_focused": focused_output_after == pad_output}]
        if focused_output_after and focused_output_after != pad_output:
            rows.append({"id": 1, "name": "", "idx": 1, "output": focused_output_after,
                         "is_active": True, "is_focused": True})
        return rows

    helper._niri_session_ready = lambda: True
    helper._niri_scratchpad_action = action
    helper.load_scratchpads = lambda *a, **k: [_pad(id="term")]
    helper._niri_msg_json = fake_json
    return actions


def test_scratchpad_niri_hide_succeeds_when_focus_left_for_another_output():
    """Accept cross-output focus restoration under the Niri hide policy.

    The pad workspace can remain active on its own output. On the focused
    output, a pad that remains visible must still fail confirmation.
    """
    originals = (helper._niri_session_ready, helper._niri_msg_json,
                 helper._niri_scratchpad_action, helper.load_scratchpads)
    try:
        _niri_hide_harness(still_active_after=True, focused_output_after="DP-1")
        with _scratchpad_state_sandbox() as sandbox:
            (sandbox / "term.niri-focus").write_text("7")
            result = helper.scratchpad_toggle_niri("term")
            assert_equal(result["ok"], True, "focus moved to another output is a successful hide")
            assert_equal(result["stillDisplayedOn"], "DP-2",
                         "and says the pad is still on its own output rather than hiding that")
            assert not (sandbox / "term.niri-focus").exists(), \
                "a confirmed hide consumes the origin"

        _niri_hide_harness(still_active_after=True, focused_output_after="DP-2")
        with _scratchpad_state_sandbox() as sandbox:
            (sandbox / "term.niri-focus").write_text("7")
            same = helper.scratchpad_toggle_niri("term")
            assert_equal(same["ok"], False, "a pad still displayed on the focused output is not hidden")
            assert_equal(same["action"], "hide-failed", "and says so")

        _niri_hide_harness(still_active_after=False, focused_output_after="DP-1")
        with _scratchpad_state_sandbox() as sandbox:
            (sandbox / "term.niri-focus").write_text("7")
            gone = helper.scratchpad_toggle_niri("term")
            assert_equal(gone["ok"], True, "a pad off every output is hidden")
            assert "stillDisplayedOn" not in gone, "with nothing left displayed to report"
    finally:
        (helper._niri_session_ready, helper._niri_msg_json,
         helper._niri_scratchpad_action, helper.load_scratchpads) = originals


def test_scratchpad_niri_failed_hide_keeps_the_reveal_origin():
    """Keep the stored origin until hiding succeeds so a failed hide can be retried."""
    originals = (helper._niri_session_ready, helper._niri_msg_json,
                 helper._niri_scratchpad_action, helper.load_scratchpads)
    try:
        _niri_hide_harness(still_active_after=True, focused_output_after="DP-2")
        with _scratchpad_state_sandbox() as sandbox:
            origin = sandbox / "term.niri-focus"
            origin.write_text("7")
            failed = helper.scratchpad_toggle_niri("term")
            assert_equal(failed["ok"], False, "the hide failed")
            assert origin.exists(), "and the origin survives, so a retry still knows where to go"
            assert_equal(origin.read_text(), "7", "unchanged")

        # A hide that cannot be CONFIRMED keeps it too: unknown is not success,
        # and is not a reason to spend the origin either.
        helper._niri_msg_json = lambda *a: ([{"id": 7, "app_id": "x", "workspace_id": 9}]
                                            if a and a[0] == "windows" else None)
        helper._scratchpad_niri_visible_output = lambda pad_id: "DP-2"
        try:
            with _scratchpad_state_sandbox() as sandbox:
                origin = sandbox / "term.niri-focus"
                origin.write_text("7")
                blind = helper.scratchpad_toggle_niri("term")
                assert_equal(blind["ok"], False, "an unconfirmable hide is not a success")
                assert_equal(blind["action"], "hide-unconfirmed", "and says which")
                assert origin.exists(), "the origin is kept for the retry"
        finally:
            del helper._scratchpad_niri_visible_output
    finally:
        (helper._niri_session_ready, helper._niri_msg_json,
         helper._niri_scratchpad_action, helper.load_scratchpads) = originals


def test_scratchpad_niri_generated_kdl_parses():
    """Parse what we wrote. A structural error here is a config niri refuses at
    startup, which on this compositor breaks far more than the scratchpad."""
    sys.path.insert(0, str(REPO_ROOT / "bin"))
    import vshell_niri_kdl as kdl

    pads = [
        _pad(keybind="Mod+T", monitor="DP-1", preload=True),
        _pad(id="notes", classRegex="^(obsidian)$", command="obsidian",
             titleExclude=r'^(Quick\.Switcher)$', keybind="Mod+N"),
        _pad(id="vm", classRegex="^(vm-viewer)$", command="virt-viewer", presentation="fullscreen"),
    ]
    text, _ = helper.render_scratchpads_kdl(pads)

    # An unterminated block is the failing syntax control.
    assert_equal(kdl.kdl_matching_brace("window-rule {\n  match", 12), -1,
                 "the brace matcher must report an unterminated block")

    nodes = kdl.kdl_nodes_in_block(text)
    headers = [header for header, _, _ in nodes]
    assert 'workspace "vgs-term"' in headers, "the workspace block is a well-formed node"
    assert headers.count("window-rule") == 3, "one window rule per pad, all parsed"
    assert "binds" in headers, "and the binds block closes properly"
    for header, body, _ in nodes:
        if header == "binds":
            assert kdl.kdl_matching_brace("{" + body + "}", 0) == len(body) + 1, \
                "every bind inside the block is balanced"


def _with_session_env(env):
    """Run with exactly the given compositor session variables set."""
    keys = ("HYPRLAND_INSTANCE_SIGNATURE", "NIRI_SOCKET", "XDG_CURRENT_DESKTOP")
    saved = {key: os.environ.pop(key, None) for key in keys}
    os.environ.update(env)
    try:
        return helper.scratchpad_compositor_supported()
    finally:
        for key in keys:
            os.environ.pop(key, None)
            if saved.get(key) is not None:
                os.environ[key] = saved[key]


def test_scratchpad_compositor_detection_reads_the_session_not_the_binary():
    """Select the compositor from session evidence, not installed binaries.

    A wrong selection writes configuration for the wrong compositor.
    """
    assert_equal(_with_session_env({"NIRI_SOCKET": "/run/niri.sock"}), (True, "niri"),
                 "a Niri session is supported, and identified as niri even with hyprctl installed")
    assert_equal(_with_session_env({"XDG_CURRENT_DESKTOP": "niri"}), (True, "niri"),
                 "XDG_CURRENT_DESKTOP is enough to identify the session")

    assert_equal(_with_session_env({"HYPRLAND_INSTANCE_SIGNATURE": "sig"}), (True, "hyprland"),
                 "a real Hyprland session is supported")
    assert_equal(_with_session_env({"XDG_CURRENT_DESKTOP": "Hyprland:wlroots"}), (True, "hyprland"),
                 "a compound desktop string still identifies Hyprland")

    assert _with_session_env({"NIRI_SOCKET": "/run/niri.sock"})[1] != "hyprland", \
        "a Niri session must never select the Hyprland generator"
    assert _with_session_env({"HYPRLAND_INSTANCE_SIGNATURE": "sig"})[1] != "niri", \
        "and a Hyprland session must never select the Niri one"

    # A third compositor is still unsupported, and must not be mistaken for
    # "nothing is running" — that would let generation proceed under a
    # compositor that will never read the result.
    for desktop in ("GNOME", "KDE", "sway"):
        supported, name = _with_session_env({"XDG_CURRENT_DESKTOP": desktop})
        assert_equal(supported, False, f"{desktop} is neither Hyprland nor Niri")
        assert_equal(name, desktop.split(":")[0].lower(), f"{desktop} is named in the refusal")

    # With nothing running, generation is still meaningful (writing config from
    # a TTY before starting the compositor); the live paths check separately.
    assert_equal(_with_session_env({}), (True, "none"),
                 "no session still allows offline generation")


def test_scratchpad_target_monitor_resolves_against_connected_outputs():
    """A configured monitor name is an intent, not a guarantee. A laptop out of
    its dock still carries DP-1 in the record, and dispatching at a name no
    output answers to silently does nothing."""
    original = helper._hyprctl_json
    calls = []

    def fake(*args):
        calls.append(args)
        if args and args[0] == "monitors":
            return fake.monitors
        return None

    helper._hyprctl_json = fake
    try:
        connected = [{"name": "eDP-1", "focused": True}, {"name": "HDMI-1", "focused": False}]

        fake.monitors = connected
        assert_equal(helper._scratchpad_target_monitor({"id": "p", "monitor": "HDMI-1"}), "HDMI-1",
                     "a connected configured output is honoured")

        assert_equal(helper._scratchpad_target_monitor({"id": "p", "monitor": "DP-1"}), "eDP-1",
                     "an unplugged output falls back to the focused one")

        assert_equal(helper._scratchpad_target_monitor({"id": "p", "monitor": ""}), "eDP-1",
                     "follow-focus resolves to the focused output")

        # Monitor list unreadable -> keep the record rather than relocating the
        # pad on the strength of a failed query.
        fake.monitors = None
        assert_equal(helper._scratchpad_target_monitor({"id": "p", "monitor": "DP-1"}), "DP-1",
                     "a failed query must not silently relocate the pad")
    finally:
        helper._hyprctl_json = original


def test_scratchpad_release_hands_the_window_back():
    """Deleting a pad removes its keybind and every rule pointing at its special
    workspace. A window already mapped there would be left unreachable without
    hyprctl by hand, so removal releases it to the active workspace first."""
    original_json = helper._hyprctl_json
    original_dispatch = helper._scratchpad_dispatch
    original_ready = helper._scratchpad_session_ready
    dispatched = []

    def fake_json(*args):
        if args and args[0] == "clients":
            return fake_json.clients
        if args and args[0] == "activeworkspace":
            return {"id": 3}
        return None

    helper._hyprctl_json = fake_json
    helper._scratchpad_dispatch = lambda *args: (dispatched.append(args), True)[1]
    # Stub session availability so this path executes without a compositor.
    helper._scratchpad_session_ready = lambda: True
    try:
        # List a non-owned class match first to require filtering before selection.
        fake_json.clients = [
            {"address": "0xstray", "class": "com.example.pad", "title": "Elsewhere",
             "workspace": {"name": "3"}},
            {"address": "0xabc", "class": "com.example.pad", "title": "Pad",
             "workspace": {"name": "special:pad"}},
        ]
        result = helper.scratchpad_release("pad", r"^(com\.example\.pad)$")
        assert_equal(result["ok"], True, "release succeeds")
        assert_equal(result["released"], True, "a mapped window is released")
        assert_equal(result["address"], "0xabc",
                     "the window ON the pad's workspace is the one released, not the "
                     "same-class stray that happened to be listed first")
        assert_equal(dispatched, [
            ("fullscreenstate", "0 -1,address:0xabc"),
            ("movetoworkspace", "3,address:0xabc"),
        ], "fullscreen is dropped before the move, or the window would cover its new workspace")

        dispatched.clear()
        fake_json.clients = []
        quiet = helper.scratchpad_release("pad", r"^(com\.example\.pad)$")
        assert_equal(quiet["ok"], True, "nothing to release is not a failure")
        assert_equal(quiet["released"], False, "and says nothing was released")
        assert_equal(dispatched, [], "no dispatch when there is no window")

        dispatched.clear()
        fake_json.clients = [{"address": "0xstray", "class": "com.example.pad",
                              "title": "Elsewhere", "workspace": {"name": "3"}}]
        stray = helper.scratchpad_release("pad", r"^(com\.example\.pad)$")
        assert_equal(stray["released"], False, "a window the pad never owned is not released")
        assert_equal(dispatched, [], "and nothing is moved")
    finally:
        helper._hyprctl_json = original_json
        helper._scratchpad_dispatch = original_dispatch
        helper._scratchpad_session_ready = original_ready

    assert_equal(helper.scratchpad_release("pad", "^x$")["ok"], True,
                 "release is a no-op without a session, not an error")


def test_scratchpad_membership_is_reasserted_for_a_late_class():
    """Move windows whose class becomes available only after their initial mapping.

    Styling alone would leave the window on a normal workspace.
    """
    original = helper._scratchpad_dispatch
    dispatched = []
    helper._scratchpad_dispatch = lambda *args: (dispatched.append(args), True)[1]
    try:
        stray = {"address": "0xdead", "workspace": {"name": "3"}}
        result = helper._scratchpad_ensure_membership("term", stray)
        assert_equal(result["moved"], True, "a stray window is moved onto the pad's workspace")
        assert_equal(result["from"], "3", "and reports where it came from")
        assert_equal(dispatched, [("movetoworkspacesilent", "special:term,address:0xdead")],
                     "moved SILENTLY: the caller reveals the workspace itself a moment later, "
                     "and the non-silent variant would switch to it here")

        dispatched.clear()
        settled = {"address": "0xbeef", "workspace": {"name": "special:term"}}
        assert_equal(helper._scratchpad_ensure_membership("term", settled)["moved"], False,
                     "a window already on the pad's workspace is left alone")
        assert_equal(dispatched, [], "and costs no dispatch")

        # A client with no address cannot be moved; do not emit a malformed
        # selector for it.
        dispatched.clear()
        assert_equal(helper._scratchpad_ensure_membership("term", {"workspace": {"name": "3"}})["moved"],
                     False, "a client with no address is not moved")
        assert_equal(dispatched, [], "and produces no dispatch")
    finally:
        helper._scratchpad_dispatch = original


def test_scratchpad_title_exclusion_applies_to_every_rule():
    """A window excluded by title must be excluded from ALL of a pad's rules.
    Excluding it from placement but not from event suppression leaves it
    half-owned: not in the pad, but still stripped of its activation and focus
    requests, which is worse than either owning it or leaving it alone."""
    pad = _pad(titleExclude=r"^(1Password)$", classRegex=r"^(1password)$", keybind="SUPER, P")
    text, _ = helper.render_scratchpads_lua([pad], [_monitor("DP-1", focused=True)], True)

    rules = text.split("hl.window_rule({")[1:]
    assert_equal(len(rules), 2, "a pad emits a placement rule and a suppression rule")
    for index, rule in enumerate(rules):
        assert 'title = "negative:^(1Password)$"' in rule, \
            f"window rule {index} must carry the title exclusion"

    suppression = [rule for rule in rules if "suppress_event" in rule]
    assert_equal(len(suppression), 1, "exactly one suppression rule")
    assert 'title = "negative:^(1Password)$"' in suppression[0], \
        "the suppress_event rule must not match every window with the class"

    plain, _ = helper.render_scratchpads_lua([_pad()], [_monitor("DP-1", focused=True)], True)
    assert "negative:" not in plain, "no exclusion configured means no title clause"


def test_scratchpad_rejects_an_uncompilable_title_exclusion():
    """An exclusion that does not compile is not "no exclusion" — it is an
    exclusion the user asked for that silently stops applying, so the pad would
    select, focus and move the very windows it existed to keep out. Same rule
    as classRegex: reject rather than half-emit."""
    assert_equal(helper.normalize_scratchpad({
        "id": "pad", "command": "x", "classRegex": "^x$", "titleExclude": "^(unclosed",
    }), None, "a pad whose titleExclude does not compile is rejected")

    assert_equal(helper.normalize_scratchpad({
        "id": "pad", "command": "x", "classRegex": "^x$", "titleExclude": "^(1Password)$",
    })["titleExclude"], "^(1Password)$", "a valid exclusion is kept verbatim")
    assert_equal(helper.normalize_scratchpad({
        "id": "pad", "command": "x", "classRegex": "^x$",
    })["titleExclude"], "", "no exclusion is the empty string, not a broken pattern")


def test_scratchpad_release_honours_the_title_exclusion():
    """Release must own exactly the windows the placement rule owned. Selecting
    on the class alone would relocate a same-class window the user explicitly
    excluded from the pad, so deleting a scratchpad would yank an unrelated
    window onto their active workspace."""
    original_json = helper._hyprctl_json
    original_dispatch = helper._scratchpad_dispatch
    original_ready = helper._scratchpad_session_ready
    dispatched = []

    # The 1Password case the exclusion exists for: the browser-extension auth
    # prompt shares the main window's class and keeps a generic title.
    clients = [
        {"address": "0xprompt", "class": "1password", "title": "1Password",
         "workspace": {"name": "special:1pw"}},
        {"address": "0xmain", "class": "1password", "title": "Lock Screen — 1Password",
         "workspace": {"name": "special:1pw"}},
    ]

    def fake_json(*args):
        if args and args[0] == "clients":
            return clients
        if args and args[0] == "activeworkspace":
            return {"id": 5}
        return None

    helper._hyprctl_json = fake_json
    helper._scratchpad_dispatch = lambda *args: (dispatched.append(args), True)[1]
    # Stub session availability so this path executes without a compositor.
    helper._scratchpad_session_ready = lambda: True
    try:
        result = helper.scratchpad_release("1pw", r"^(1password)$", r"^(1Password)$")
        assert_equal(result["released"], True, "the pad's own window is released")
        assert_equal(result["address"], "0xmain",
                     "the excluded auth prompt must not be the one moved")
        assert_equal(dispatched, [
            ("fullscreenstate", "0 -1,address:0xmain"),
            ("movetoworkspace", "5,address:0xmain"),
        ], "only the pad's window is dispatched at")

        # Without the exclusion argument, the first class match wins.
        dispatched.clear()
        loose = helper.scratchpad_release("1pw", r"^(1password)$")
        assert_equal(loose["address"], "0xprompt",
                     "no exclusion passed means the first class match, so the "
                     "exclusion must be threaded through by every caller")
    finally:
        helper._hyprctl_json = original_json
        helper._scratchpad_dispatch = original_dispatch
        helper._scratchpad_session_ready = original_ready


def test_scratchpad_toggle_honours_enabled():
    """A disabled pad generates no rules and no keybind, so revealing one is
    never what the user asked for. Without this the per-pad enable toggle claims
    a mechanism it does not have."""
    original_load = helper.load_scratchpads
    original_visible = helper._scratchpad_visibility
    original_find = helper._scratchpad_find_window
    original_dispatch = helper._scratchpad_dispatch
    original_ready = helper._scratchpad_session_ready
    original_json = helper._hyprctl_json
    dispatched = []

    disabled = _pad(id="off", enabled=False)
    helper.load_scratchpads = lambda: [disabled]
    helper._scratchpad_find_window = lambda pad: {"address": "0xaaa", "workspace": {"name": "3"}}
    helper._scratchpad_dispatch = lambda *args: (dispatched.append(args), True)[1]
    # Stub compositor queries as well as session detection; forcing the gate alone
    # would still launch a real subprocess.
    helper._hyprctl_json = lambda *args: None
    helper._scratchpad_session_ready = lambda: True
    try:
      with _scratchpad_state_sandbox():
        helper._scratchpad_visibility = _visibility_from(lambda pad_id: "")
        result = helper.scratchpad_toggle("off")
        assert_equal(result["ok"], False, "a disabled pad does not reveal")
        assert_equal(result["action"], "disabled", "and says why")
        assert_equal(dispatched, [], "a refused toggle touches nothing")

        assert_equal(helper.scratchpad_toggle("off", launch_only=True)["ok"], False,
                     "a disabled pad does not preload either")

        # A disabled pad already on screen must remain dismissible. The visibility
        # stub changes after hiding so the outcome check can confirm it.
        dispatched.clear()
        seen = {"n": 0}

        def visible_then_gone(pad_id):
            seen["n"] += 1
            return "DP-1" if seen["n"] == 1 else ""

        helper._scratchpad_visibility = _visibility_from(visible_then_gone)
        hidden = helper.scratchpad_toggle("off")
        assert_equal(hidden["ok"], True, "a disabled pad that is on screen can still be hidden")
        assert_equal(hidden["action"], "hidden", "and reports the hide")
        assert ("togglespecialworkspace", "off") in dispatched, "the hide actually dispatches"
    finally:
        helper.load_scratchpads = original_load
        helper._scratchpad_visibility = original_visible
        helper._scratchpad_find_window = original_find
        helper._scratchpad_dispatch = original_dispatch
        helper._hyprctl_json = original_json
        helper._scratchpad_session_ready = original_ready


def test_scratchpad_hide_only_never_reveals():
    """Hide is directional and idempotent.

    A focus-loss event can reach the pad lock after the user has hidden it;
    toggling at that point would reveal it again.
    """
    originals = (helper.load_scratchpads, helper._scratchpad_visibility,
                 helper._scratchpad_find_window, helper._scratchpad_dispatch,
                 helper._scratchpad_session_ready, helper._hyprctl_json)
    dispatched = []

    pad = _pad(id="term")
    helper.load_scratchpads = lambda *a, **k: [pad]
    # Deliberately available: if hide_only ever fell through to the reveal path
    # this would be found, launched and shown, and the test would see it.
    helper._scratchpad_find_window = lambda p: {"address": "0xaaa", "workspace": {"name": "3"}}
    helper._scratchpad_dispatch = lambda *args: (dispatched.append(args), True)[1]
    helper._hyprctl_json = lambda *args: None
    # Stub session availability so this path executes without a compositor.
    helper._scratchpad_session_ready = lambda: True
    try:
      with _scratchpad_state_sandbox():
        helper._scratchpad_visibility = _visibility_from(lambda pad_id: "")
        result = helper.scratchpad_toggle("term", hide_only=True)
        assert_equal(result["ok"], True, "hiding an already-hidden pad is not a failure")
        assert_equal(result["action"], "already-hidden", "and says so rather than acting")
        assert_equal(dispatched, [], "a no-op hide dispatches nothing at all")

        dispatched.clear()
        helper._scratchpad_visibility = _hides_on_readback()
        hidden = helper.scratchpad_toggle("term", hide_only=True)
        assert_equal(hidden["ok"], True, "a visible pad is hidden")
        assert_equal(hidden["action"], "hidden", "and reports the hide")
        assert ("togglespecialworkspace", "term") in dispatched, "the hide actually dispatches"

        dispatched.clear()
        off = _pad(id="term", enabled=False)
        helper.load_scratchpads = lambda *a, **k: [off]
        helper._scratchpad_visibility = _hides_on_readback()
        stranded = helper.scratchpad_toggle("term", hide_only=True)
        assert_equal(stranded["ok"], True, "a disabled pad on screen is still hidable")
        assert_equal(stranded["action"], "hidden", "and reports the hide")

        dispatched.clear()
        helper._scratchpad_visibility = _visibility_from(lambda pad_id: "")
        quiet = helper.scratchpad_toggle("term", hide_only=True)
        assert_equal(quiet["action"], "already-hidden",
                     "an already-hidden disabled pad is nothing to do, not a refusal")
        assert_equal(dispatched, [], "and dispatches nothing")
    finally:
        (helper.load_scratchpads, helper._scratchpad_visibility,
         helper._scratchpad_find_window, helper._scratchpad_dispatch,
         helper._scratchpad_session_ready, helper._hyprctl_json) = originals


def test_scratchpad_hide_focus_target_depends_on_who_asked():
    """Two hides, two right answers, one store.

    A KEYBIND hide returns focus to whatever the pad was revealed from: the user
    is dismissing the pad to get back to what they were doing.

    A FOCUS-LOSS dismissal must not. There the user has already chosen where to
    be — that choice is what triggered the hide — so restoring the reveal origin
    yanks focus out of the window they just moved to. The reveal origin is still
    consumed either way; neither path keeps bookkeeping of its own."""
    originals = (helper.load_scratchpads, helper._scratchpad_visibility,
                 helper._scratchpad_dispatch, helper._scratchpad_session_ready,
                 helper._hyprctl_json)
    dispatched = []

    helper.load_scratchpads = lambda *a, **k: [_pad(id="term")]
    # Re-arm the stateful visibility stub before each hide.
    helper._scratchpad_dispatch = lambda *args: (dispatched.append(args), True)[1]
    helper._scratchpad_session_ready = lambda: True

    # B is where the pad was revealed from; C is where the user has since moved.
    def fake_json(*args):
        if args and args[0] == "activewindow":
            return {"address": "0xCCC", "workspace": {"name": "3"}}
        if args and args[0] == "clients":
            return [{"address": "0xBBB"}, {"address": "0xCCC"}]
        return None

    helper._hyprctl_json = fake_json
    try:
        with _scratchpad_state_sandbox() as state:
            (state / "term.focus").write_text("0xBBB")
            helper._scratchpad_visibility = _hides_on_readback()
            result = helper.scratchpad_toggle("term")
            assert_equal(result["focusedBack"], "0xBBB",
                         "a keybind hide returns to the reveal origin")
            assert ("focuswindow", "address:0xBBB") in dispatched, "and actually focuses it"
            assert not (state / "term.focus").exists(), \
                "the reveal origin is consumed: leaving it would restore a stale window next time"

        dispatched.clear()
        with _scratchpad_state_sandbox() as state:
            (state / "term.focus").write_text("0xBBB")
            helper._scratchpad_visibility = _hides_on_readback()
            result = helper.scratchpad_toggle("term", hide_only=True, keep_focus=True)
            assert_equal(result["focusedBack"], "0xCCC",
                         "a focus-loss dismissal keeps the window the user moved to")
            assert ("focuswindow", "address:0xBBB") not in dispatched, \
                "and never yanks focus back to the reveal origin"
            assert ("focuswindow", "address:0xCCC") in dispatched, \
                "focus is restored explicitly, because hiding moves it via focusmonitor"
            assert not (state / "term.focus").exists(), "the origin is consumed here too"

        # Focus still on the pad's own window: restoring to it would leave focus
        # on something about to be hidden, so fall back to the origin.
        dispatched.clear()
        helper._hyprctl_json = lambda *a: (
            {"address": "0xPAD", "workspace": {"name": "special:term"}} if a and a[0] == "activewindow"
            else [{"address": "0xBBB"}, {"address": "0xPAD"}] if a and a[0] == "clients" else None)
        with _scratchpad_state_sandbox() as state:
            (state / "term.focus").write_text("0xBBB")
            helper._scratchpad_visibility = _hides_on_readback()
            result = helper.scratchpad_toggle("term", hide_only=True, keep_focus=True)
            assert_equal(result["focusedBack"], "0xBBB",
                         "focus sitting on the pad itself falls back to the reveal origin")

        # A failed activewindow query is not a reason to strand focus.
        dispatched.clear()
        helper._hyprctl_json = lambda *a: ([{"address": "0xBBB"}] if a and a[0] == "clients" else None)
        with _scratchpad_state_sandbox() as state:
            (state / "term.focus").write_text("0xBBB")
            helper._scratchpad_visibility = _hides_on_readback()
            result = helper.scratchpad_toggle("term", hide_only=True, keep_focus=True)
            assert_equal(result["focusedBack"], "0xBBB",
                         "an unreadable active window falls back to the origin, not to nothing")
    finally:
        (helper.load_scratchpads, helper._scratchpad_visibility,
         helper._scratchpad_dispatch, helper._scratchpad_session_ready,
         helper._hyprctl_json) = originals


def test_scratchpad_rejections_are_named_not_silent():
    """Report unusable pads whose rules cannot be generated."""
    problems = []
    assert_equal(helper.normalize_scratchpad(
        {"id": "bad", "name": "Broken", "command": "x", "classRegex": "^(unclosed"},
        problems), None, "an uncompilable class pattern is still rejected")
    assert_equal(len(problems), 1, "and the rejection is recorded")
    assert_equal(problems[0]["id"], "Broken", "named by the pad's own label")
    assert "does not compile" in problems[0]["reason"], "with the reason"

    cases = [
        ({"id": "x", "name": "No Class", "command": "x"}, "no window class pattern"),
        ({"id": "x", "name": "No Command", "classRegex": "^x$"}, "no launch command"),
        ({"id": "BAD ID", "name": "Bad Id", "command": "x", "classRegex": "^x$"}, "id must be"),
        ({"id": "x", "name": "Bad Title", "command": "x", "classRegex": "^x$",
          "titleExclude": "["}, "title exclusion does not compile"),
    ]
    for raw, expected in cases:
        found = []
        assert_equal(helper.normalize_scratchpad(raw, found), None, f"{raw.get('name')} is rejected")
        assert_equal(len(found), 1, f"{raw.get('name')} records a reason")
        assert expected in found[0]["reason"], \
            f"{raw.get('name')}: expected {expected!r} in {found[0]['reason']!r}"

    clean = []
    assert helper.normalize_scratchpad({"id": "ok", "command": "x", "classRegex": "^x$"}, clean)
    assert_equal(clean, [], "a usable pad produces no problem entry")

    assert_equal(helper.normalize_scratchpad({"id": "bad", "command": "x", "classRegex": "^("}),
                 None, "rejection still works with no collector")


def test_scratchpad_reveal_reports_failed_dispatches():
    """A toggle that did not reveal anything must not report success. Otherwise
    a failed reveal is indistinguishable from a working one, both to the caller
    and to anyone reading --json."""
    originals = (helper.load_scratchpads, helper._scratchpad_visibility,
                 helper._scratchpad_find_window, helper._scratchpad_dispatch,
                 helper._hyprctl_json, helper._scratchpad_place_workspace,
                 helper._scratchpad_reassert)
    original_ready = helper._scratchpad_session_ready

    pad = _pad(id="term")
    helper.load_scratchpads = lambda *a, **k: [pad]
    helper._scratchpad_find_window = lambda p: {"address": "0xaaa", "workspace": {"name": "special:term"}}
    helper._hyprctl_json = lambda *args: None
    helper._scratchpad_place_workspace = lambda *a, **k: True
    helper._scratchpad_reassert = lambda *a, **k: {"applied": True}
    # Stub session availability so this path executes without a compositor.
    helper._scratchpad_session_ready = lambda: True
    try:
      with _scratchpad_state_sandbox():
        helper._scratchpad_dispatch = lambda *args: True
        visible = {"n": 0}

        def visible_after_toggle(pad_id):
            visible["n"] += 1
            return "" if visible["n"] == 1 else "DP-1"

        helper._scratchpad_visibility = _visibility_from(visible_after_toggle)
        good = helper.scratchpad_toggle("term")
        assert_equal(good["ok"], True, "a reveal that works reports success")
        assert_equal(good["action"], "revealed", "and says so")

        helper._scratchpad_dispatch = lambda *args: args[0] != "focuswindow"
        visible["n"] = 0
        helper._scratchpad_visibility = _visibility_from(visible_after_toggle)
        bad = helper.scratchpad_toggle("term")
        assert_equal(bad["ok"], False, "a failed dispatch is not success")
        assert_equal(bad["action"], "reveal-failed", "and is named")
        assert "could not focus the window" in bad["error"], \
            f"the reason is reported, got {bad['error']!r}"

        # Every dispatch claims success but the workspace is still not visible:
        # the outcome is read back, not inferred from the calls.
        helper._scratchpad_dispatch = lambda *args: True
        helper._scratchpad_visibility = _visibility_from(lambda pad_id: "")
        lying = helper.scratchpad_toggle("term")
        assert_equal(lying["ok"], False, "success is confirmed by reading state back")
        assert "still not visible" in lying["error"], \
            f"and says what was wrong, got {lying['error']!r}"
    finally:
        (helper.load_scratchpads, helper._scratchpad_visibility,
         helper._scratchpad_find_window, helper._scratchpad_dispatch,
         helper._hyprctl_json, helper._scratchpad_place_workspace,
         helper._scratchpad_reassert) = originals
        helper._scratchpad_session_ready = original_ready


def test_scratchpad_reassert_clears_fullscreen_for_other_modes():
    """Clear fullscreen before applying float or tile geometry to a mapped pad."""
    originals = (helper._scratchpad_dispatch, helper._scratchpad_visibility,
                 helper._scratchpad_workspace_monitor, helper.scratchpad_monitors,
                 helper._scratchpad_find_window)
    dispatched = []
    helper._scratchpad_dispatch = lambda *args: (dispatched.append(args), True)[1]
    helper._scratchpad_visibility = _visibility_from(lambda pad_id: "DP-1")
    helper._scratchpad_workspace_monitor = lambda pad_id: "DP-1"
    helper.scratchpad_monitors = lambda: ([_monitor("DP-1", focused=True)], True)
    try:
        helper._scratchpad_find_window = lambda pad: {"address": "0xaaa", "size": [1, 1], "at": [1, 1]}
        dispatched.clear()
        helper._scratchpad_reassert(_pad(presentation="float"), "0xaaa")
        verbs = [d[0] for d in dispatched]
        assert "fullscreenstate" in verbs, f"float must clear fullscreen, got {verbs}"
        assert_equal(dispatched[0], ("fullscreenstate", "0 -1,address:0xaaa"),
                     "cleared FIRST, or the size/move below act on a fullscreen window")
        assert verbs.index("fullscreenstate") < verbs.index("setfloating"), \
            f"cleared before setfloating, got {verbs}"

        dispatched.clear()
        helper._scratchpad_reassert(_pad(presentation="tile"), "0xaaa")
        verbs = [d[0] for d in dispatched]
        assert_equal(dispatched[0], ("fullscreenstate", "0 -1,address:0xaaa"),
                     "tile must clear fullscreen first too")
        assert "settiled" in verbs, f"and still tile, got {verbs}"

        dispatched.clear()
        helper._scratchpad_reassert(_pad(presentation="fullscreen"), "0xaaa")
        assert_equal(dispatched, [("fullscreenstate", "2 -1,address:0xaaa")],
                     "a fullscreen pad sets fullscreen and nothing else")
    finally:
        (helper._scratchpad_dispatch, helper._scratchpad_visibility,
         helper._scratchpad_workspace_monitor, helper.scratchpad_monitors,
         helper._scratchpad_find_window) = originals


def test_scratchpad_show_does_not_disturb_focus_restore():
    """Preserve the focus origin when showing an already-visible pad."""
    originals = (helper.load_scratchpads, helper._scratchpad_visibility,
                 helper._scratchpad_find_window, helper._scratchpad_dispatch,
                 helper._hyprctl_json, helper._scratchpad_session_ready,
                 helper._scratchpad_place_workspace, helper._scratchpad_reassert)

    pad = _pad(id="term")
    helper.load_scratchpads = lambda *a, **k: [pad]
    helper._scratchpad_find_window = lambda p: {"address": "0xpad", "workspace": {"name": "special:term"}}
    helper._scratchpad_dispatch = lambda *args: True
    helper._scratchpad_place_workspace = lambda *a, **k: True
    helper._scratchpad_reassert = lambda *a, **k: {"applied": True}
    helper._scratchpad_session_ready = lambda: True
    helper._hyprctl_json = lambda *args: {"address": "0xpad"} if args and args[0] == "activewindow" else None
    # Use temporary pad locks and focus files; the defaults belong to the live session.
    with _scratchpad_state_sandbox():
        try:
            state_file = helper._scratchpad_state_dir() / "term.focus"
            state_file.write_text("0xorigin")

            helper._scratchpad_visibility = _visibility_from(lambda pad_id: "DP-1")
            result = helper.scratchpad_toggle("term", reveal_only=True)
            assert_equal(result["ok"], True, "show on a visible pad still succeeds")
            assert_equal(state_file.read_text(), "0xorigin",
                         "the focus origin from the reveal that opened it must survive")

            # A hidden-pad reveal must still store the origin to preserve focus restoration.
            visible = {"n": 0}

            def visible_after_toggle(pad_id):
                visible["n"] += 1
                return "" if visible["n"] == 1 else "DP-1"

            helper._scratchpad_visibility = _visibility_from(visible_after_toggle)
            state_file.write_text("0xstale")
            helper.scratchpad_toggle("term")
            assert_equal(state_file.read_text(), "0xpad",
                         "a real reveal still records what to hand focus back to")
            state_file.unlink(missing_ok=True)
        finally:
            (helper.load_scratchpads, helper._scratchpad_visibility,
             helper._scratchpad_find_window, helper._scratchpad_dispatch,
             helper._hyprctl_json, helper._scratchpad_session_ready,
             helper._scratchpad_place_workspace, helper._scratchpad_reassert) = originals


def test_monitor_logical_size_degrades_on_unusable_scale():
    """Reject non-finite monitor scales before geometry arithmetic.

    float accepts NaN and infinity, and comparison with zero does not reject NaN.
    """
    for label, scale in [("NaN", float("nan")), ("'nan'", "nan"), ("infinity", float("inf")),
                         ("negative", -2.0), ("garbage", "big"), ("zero", 0), ("empty", "")]:
        size = helper.monitor_logical_size(
            {"name": "DP-1", "width": 1920, "height": 1080, "scale": scale})
        assert_equal(size, (1920, 1080), f"a {label} scale degrades to 1 rather than raising")

    assert_equal(helper.monitor_logical_size({"name": "DP-1", "width": 1920, "height": 1080}),
                 (1920, 1080), "a missing scale is 1")

    assert_equal(helper.monitor_logical_size(
        {"name": "DP-1", "width": 3840, "height": 2160, "scale": 2.0}), (1920, 1080),
        "a real scale still divides")
    assert_equal(helper.monitor_logical_size(
        {"name": "DP-1", "width": 2880, "height": 1800, "scale": 1.5}), (1920, 1200),
        "a fractional scale still divides")

    geometry = helper.resolve_scratchpad_geometry(
        _pad(widthPercent=60, heightPercent=70),
        {"name": "DP-1", "width": 1920, "height": 1080, "scale": float("nan")})
    assert_equal((geometry["width"], geometry["height"]), (1152, 756),
                 "geometry resolves over a NaN-scale monitor")


def test_scratchpad_hide_confirms_the_pad_came_down():
    """Confirm hiding before Settings disables the pad and removes its keybind."""
    originals = (helper.load_scratchpads, helper._scratchpad_visibility,
                 helper._scratchpad_find_window, helper._scratchpad_dispatch,
                 helper._hyprctl_json, helper._scratchpad_session_ready)

    pad = _pad(id="term")
    helper.load_scratchpads = lambda *a, **k: [pad]
    helper._scratchpad_find_window = lambda p: {"address": "0xpad", "workspace": {"name": "special:term"}}
    helper._hyprctl_json = lambda *args: None
    helper._scratchpad_session_ready = lambda: True
    seen = {"n": 0}

    def visible_then_gone(pad_id):
        seen["n"] += 1
        return "DP-1" if seen["n"] == 1 else ""

    # Use temporary pad locks and focus files; the defaults belong to the live session.
    with _scratchpad_state_sandbox():
        try:
            helper._scratchpad_dispatch = lambda *args: True
            helper._scratchpad_visibility = _visibility_from(visible_then_gone)
            good = helper.scratchpad_toggle("term", hide_only=True)
            assert_equal(good["ok"], True, "a hide that worked reports success")
            assert_equal(good["action"], "hidden", "and says so")

            # Every dispatch claims success and the pad is STILL up. Success here
            # would tell Settings to drop the keybind out from under a live window.
            helper._scratchpad_visibility = _visibility_from(lambda pad_id: "DP-1")
            lying = helper.scratchpad_toggle("term", hide_only=True)
            assert_equal(lying["ok"], False, "a pad still on screen is not a successful hide")
            assert_equal(lying["action"], "hide-failed", "and is named")
            assert "still visible" in lying["error"], f"with the reason, got {lying['error']!r}"

            seen["n"] = 0
            helper._scratchpad_visibility = _visibility_from(visible_then_gone)
            helper._scratchpad_dispatch = lambda *args: args[0] != "togglespecialworkspace"
            refused = helper.scratchpad_toggle("term", hide_only=True)
            assert_equal(refused["ok"], False, "a failed dispatch is not success")
            assert "could not toggle" in refused["error"], f"named, got {refused['error']!r}"

            dispatched = []
            helper._scratchpad_dispatch = lambda *args: (dispatched.append(args), True)[1]
            helper._scratchpad_visibility = _visibility_from(lambda pad_id: "")
            idle = helper.scratchpad_toggle("term", hide_only=True)
            assert_equal(idle["action"], "already-hidden", "an already-hidden pad is a no-op")
            assert_equal(dispatched, [], "and dispatches nothing")
        finally:
            (helper.load_scratchpads, helper._scratchpad_visibility,
             helper._scratchpad_find_window, helper._scratchpad_dispatch,
             helper._hyprctl_json, helper._scratchpad_session_ready) = originals


def test_scratchpad_visibility_distinguishes_hidden_from_unknown():
    """Distinguish failed monitor queries from a confirmed hidden pad."""
    original = helper._hyprctl_json
    try:
        visible = [{"name": "DP-1", "specialWorkspace": {"name": "special:term"}}]
        hidden = [{"name": "DP-1", "specialWorkspace": {"name": ""}}]

        helper._hyprctl_json = lambda *a: visible
        assert_equal(helper._scratchpad_visibility("term"), ("visible", "DP-1"), "on screen")
        helper._hyprctl_json = lambda *a: hidden
        assert_equal(helper._scratchpad_visibility("term"), ("hidden", ""), "genuinely down")
        helper._hyprctl_json = lambda *a: None
        assert_equal(helper._scratchpad_visibility("term"), ("unknown", ""),
                     "a query that could not run is neither")
    finally:
        helper._hyprctl_json = original


def test_scratchpad_matching_windows_reports_pattern_breadth():
    """Report the matching breadth of a derived application class before it is saved."""
    original = helper._hyprctl_json
    clients = [
        {"address": "0x1", "class": "com.mitchellh.ghostty", "title": "vgs"},
        {"address": "0x2", "class": "com.mitchellh.ghostty", "title": "drovr"},
        {"address": "0x3", "class": "com.ghostty.scratchpad", "title": "Ghostty"},
        {"address": "0x4", "class": "1password", "title": "Lock Screen"},
        {"address": "0x5", "class": "1password", "title": "1Password"},
    ]
    helper._hyprctl_json = lambda *args: clients if args and args[0] == "clients" else None
    try:
        wide = helper.scratchpad_matching_windows(r"^(com\.mitchellh\.ghostty)$")
        assert_equal(wide["count"], 2, "a plain class match claims every instance")

        narrow = helper.scratchpad_matching_windows(r"^(com\.ghostty\.scratchpad)$")
        assert_equal(narrow["count"], 1, "an overridden class claims exactly one")

        # The title exclusion is honoured here too, so the count matches what
        # the runtime toggle would actually select rather than a wider guess.
        excluded = helper.scratchpad_matching_windows(r"^(1password)$", r"^(1Password)$")
        assert_equal(excluded["count"], 1, "the exclusion narrows the count")
        assert_equal(excluded["windows"][0]["title"], "Lock Screen",
                     "and excludes the right window")

        # A pattern that cannot compile is an error, not "nothing matched". The
        # three states have to stay distinguishable all the way to the caller:
        # rendering an unevaluable pattern as "0 windows match" describes a
        # broken pattern as a working one, which is the failure this surfaces.
        broken = helper.scratchpad_matching_windows("^(unclosed")
        assert_equal(broken["ok"], False, "an uncompilable pattern is an error")
        assert_equal(broken["count"], 0, "and claims nothing")
        assert "does not compile" in broken["error"], "with a reason to show"
        assert_equal(broken.get("known"), None,
                     "an error is not a knowledge claim either way")

        bad_exclude = helper.scratchpad_matching_windows(r"^(x)$", "[")
        assert_equal(bad_exclude["ok"], False, "an uncompilable exclusion is an error")
        assert "title exclusion" in bad_exclude["error"], "and names which pattern"

        good = helper.scratchpad_matching_windows(r"^(1password)$")
        assert_equal((good["ok"], good["known"]), (True, True), "a real answer is ok+known")
        assert_equal(broken["ok"], False, "an error is not ok")

        # No session is NOT zero matches. The page must be able to stay silent
        # rather than claim "0 windows match" on a query that never ran.
        helper._hyprctl_json = lambda *args: None
        unknown = helper.scratchpad_matching_windows(r"^(anything)$")
        assert_equal(unknown["ok"], True, "no session is not a failure")
        assert_equal(unknown["known"], False, "but it is explicitly not knowledge")
    finally:
        helper._hyprctl_json = original


def test_scratchpad_hide_refuses_when_visibility_is_unknown():
    """Only "hidden" counts as a successful hide. On "could not determine" the
    helper must refuse, so Settings never proceeds to drop the keybind."""
    originals = (helper.load_scratchpads, helper._scratchpad_find_window,
                 helper._scratchpad_dispatch, helper._hyprctl_json,
                 helper._scratchpad_session_ready)

    pad = _pad(id="term")
    helper.load_scratchpads = lambda *a, **k: [pad]
    helper._scratchpad_find_window = lambda p: {"address": "0xpad", "workspace": {"name": "special:term"}}
    helper._scratchpad_session_ready = lambda: True
    helper._scratchpad_dispatch = lambda *args: True
    # Use temporary pad locks and focus files; the defaults belong to the live session.
    with _scratchpad_state_sandbox():
        try:
            # Entry: the monitor query fails outright. "Already hidden" would be a
            # claim nothing supports, and Settings would act on it.
            helper._hyprctl_json = lambda *a: None
            unknown = helper.scratchpad_toggle("term", hide_only=True)
            assert_equal(unknown["ok"], False, "an unanswerable query is not 'already hidden'")
            assert_equal(unknown["action"], "hide-unknown", "and is named")
            assert "could not determine" in unknown["error"], f"got {unknown['error']!r}"

            calls = {"n": 0}

            def visible_then_unanswerable(*args):
                if args and args[0] == "monitors":
                    calls["n"] += 1
                    if calls["n"] == 1:
                        return [{"name": "DP-1", "specialWorkspace": {"name": "special:term"}}]
                    return None
                return None

            helper._hyprctl_json = visible_then_unanswerable
            unconfirmed = helper.scratchpad_toggle("term", hide_only=True)
            assert_equal(unconfirmed["ok"], False, "an unconfirmed hide is not a successful hide")
            assert_equal(unconfirmed["action"], "hide-failed", "and is named")
            assert "did not answer" in unconfirmed["error"], f"got {unconfirmed['error']!r}"

            calls["n"] = 0

            def visible_then_hidden(*args):
                if args and args[0] == "monitors":
                    calls["n"] += 1
                    if calls["n"] == 1:
                        return [{"name": "DP-1", "specialWorkspace": {"name": "special:term"}}]
                    return [{"name": "DP-1", "specialWorkspace": {"name": ""}}]
                return None

            helper._hyprctl_json = visible_then_hidden
            good = helper.scratchpad_toggle("term", hide_only=True)
            assert_equal(good["ok"], True, "a confirmed hide still succeeds")
            assert_equal(good["action"], "hidden", "and says so")
        finally:
            (helper.load_scratchpads, helper._scratchpad_find_window,
             helper._scratchpad_dispatch, helper._hyprctl_json,
             helper._scratchpad_session_ready) = originals


def test_tmux_theme_reaches_the_running_server():
    """A tmux server on a socket the shell's environment does not name still
    gets the theme, and a socket with no server is never sourced into --
    sourcing would start an empty server there and report success."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        socket_dir = root / f"tmux-{os.getuid()}"
        socket_dir.mkdir()
        live = socket_dir / "default"
        dead = socket_dir / "spare"
        for path in (live, dead):
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.bind(str(path))
            sock.close()
        (socket_dir / "notes.txt").write_text("not a socket\n")

        stub_dir = root / "bin"
        stub_dir.mkdir()
        calls = root / "calls"
        stub = stub_dir / "tmux"
        stub.write_text(
            "#!/bin/sh\n"
            f'printf "%s\\n" "$*" >> {calls}\n'
            'case "$*" in\n'
            f'  *{dead.name}*list-sessions*) echo "no server running" >&2; exit 1 ;;\n'
            "esac\n"
            "exit 0\n"
        )
        stub.chmod(0o755)

        # A `tmux -S` server puts its socket outside every searched root; $TMUX
        # is the only thing that names it.
        named = root / "custom.sock"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(str(named))
        sock.close()

        old_path = os.environ.get("PATH", "")
        old_tmpdir = os.environ.get("TMUX_TMPDIR")
        old_tmux = os.environ.get("TMUX")
        os.environ["PATH"] = f"{stub_dir}:{old_path}"
        os.environ["TMUX_TMPDIR"] = str(root)
        os.environ["TMUX"] = f"{named},4242,0"
        try:
            result = helper.source_tmux_theme_hook("tmux-source")
        finally:
            os.environ["PATH"] = old_path
            for key, value in (("TMUX_TMPDIR", old_tmpdir), ("TMUX", old_tmux)):
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

        assert_equal(result["ok"], True, "the hook succeeds when a live server took the theme")
        # This host's own tmux socket is scanned too; the assertion is scoped
        # to the sockets this test made.
        sourced = [path for path in result.get("sourced") or [] if path.startswith(str(root))]
        assert_equal(sorted(sourced), sorted([str(named), str(live)]),
                     "both the $TMUX socket and the live default socket are sourced, and the dead one is not")
        logged = calls.read_text().splitlines()
        sourced_dead = [line for line in logged if dead.name in line and "source-file" in line]
        assert_equal(sourced_dead, [], "a socket with no server must never be sourced into")
        assert_equal([line for line in logged if "notes.txt" in line], [],
                     "a plain file in the socket directory is not a socket")


def test_tmux_copy_mode_matches_take_theme_roles():
    """tmux's own match styles paint black on cyan and magenta, which a light
    theme cannot read, so the template sets both from theme roles."""
    # A complete role map, since the renderer refuses a role the map lacks, with
    # the four roles under test set to values no default carries.
    roles = helper.render_roles({}, {**helper.target_roles({}),
                                     "selection_background": "#c68d95", "selection_foreground": "#35302a",
                                     "secondary": "#713a56", "onSecondary": "#f5e6d3"})
    rendered = helper.render_target_template("tmux-vgs", "vgs-theme.conf", roles).splitlines()
    for option, style in (
        ("copy-mode-match-style", "bg=#c68d95,fg=#35302a"),
        ("copy-mode-current-match-style", "bg=#713a56,fg=#f5e6d3"),
    ):
        lines = [line for line in rendered if line.startswith(f"set -g {option} ")]
        assert_equal(lines, [f'set -g {option} "{style}"'], f"tmux {option}")


def test_display_output_controls():
    """Exercise real rendering and preview recovery without touching the seat."""
    mode = {"width": 6016, "height": 3384, "refresh_rate": 60000}
    output = {"make": "Apple Computer Inc", "model": "ProDisplayXDR", "serial": "test",
              "modes": [mode], "current_mode": 0, "enabled": True,
              "logical": {"x": 0, "y": 0, "scale": 2, "transform": "Normal"},
              "hyprlandSettings": {"bitdepth": 10, "colorManagement": "srgb"}}
    live = {"DP-1": output}
    payload = {"outputs": live, "settings": {"DP-1": {"colorManagement": "dp3"}}}
    rendered = helper.render_hyprland_outputs(payload, live)
    assert 'mode = "6016x3384@60.000"' in rendered
    assert 'cm = "dp3"' in rendered and "bitdepth = 10" in rendered
    for fields, identifier, selector, naming in [
        ({}, "desc:Apple Computer Inc ProDisplayXDR test", "desc:Apple Computer Inc ProDisplayXDR test", "model"),
        ({"make": ""}, "DP-1", "DP-1", "model"),
        ({"model": ""}, "DP-1", "DP-1", "model"),
        ({"make": "", "model": "", "serial": ""}, "DP-1", "DP-1", "model"),
        ({"serial": ""}, "desc:Apple Computer Inc ProDisplayXDR Unknown", "DP-1", "model"),
        ({"make": "Apple, Inc"}, "desc:Apple Inc ProDisplayXDR test", "desc:Apple Inc ProDisplayXDR test", "model"),
        ({"explicitIdentifier": True}, "DP-1", "desc:Apple Computer Inc ProDisplayXDR test", "model"),
        ({"explicitIdentifier": True, "serial": ""}, "DP-1", "DP-1", "model"),
        ({}, "DP-1", "DP-1", "system"),
    ]:
        candidate = {**output, **fields}
        for connector in ("DP-1", "DP-5"):
            settings_key = connector if identifier == "DP-1" else identifier
            persisted_selector = connector if selector == "DP-1" else selector
            request = {"outputs": {connector: candidate}, "displayNameMode": naming,
                       "settings": {settings_key: {"colorManagement": "dp3", "vrrFullscreenOnly": True}}}
            options = helper._hyprland_output_settings(request, connector, candidate)
            assert options["colorManagement"] == "dp3" and options["vrrFullscreenOnly"], (fields, naming)
            rendered_rule = helper.render_hyprland_outputs(request, {connector: candidate})
            assert f"output = {helper._lua_string(persisted_selector)}," in rendered_rule, (fields, naming, connector, rendered_rule)
            assert 'cm = "dp3"' in rendered_rule and "vrr = 2" in rendered_rule
            readback = {**candidate, "hyprlandSettings": {**candidate["hyprlandSettings"], "colorManagement": "dp3"}}
            helper.verify_hyprland_outputs(request, {connector: readback})
    applied = json.loads(json.dumps(live))
    applied["DP-1"]["hyprlandSettings"]["colorManagement"] = "dp3"
    helper.verify_hyprland_outputs(payload, applied)
    for scale, changed, accepted in [
        (4 / 3, {"scale": struct.unpack("f", struct.pack("f", 4 / 3))[0]}, True),
        (8 / 3, {"scale": struct.unpack("f", struct.pack("f", 8 / 3))[0]}, True),
        (1.6, {"scale": struct.unpack("f", struct.pack("f", 1.6))[0]}, True),
        (4 / 3, {"scale": 1.5}, False),
        (4 / 3, {"x": 1}, False),
        (4 / 3, {"y": 1}, False),
        (4 / 3, {"transform": "90"}, False),
    ]:
        requested = json.loads(json.dumps(payload))
        requested["outputs"]["DP-1"]["logical"]["scale"] = scale
        helper.render_hyprland_outputs(requested, live)
        actual = json.loads(json.dumps(applied))
        actual["DP-1"]["logical"].update(scale=scale)
        actual["DP-1"]["logical"].update(changed)
        try:
            helper.verify_hyprland_outputs(requested, actual)
        except ValueError:
            assert not accepted, (scale, changed)
        else:
            assert accepted, (scale, changed)
    try:
        helper.verify_hyprland_outputs(payload, live)
    except ValueError as error:
        assert "colour mode" in str(error)
    else:
        raise AssertionError("Readback accepted an unapplied colour mode")

    def rejected(candidate, expected, current=live):
        try:
            helper.render_hyprland_outputs(candidate, current)
        except (ValueError, OSError) as error:
            assert expected in str(error), str(error)
        else:
            raise AssertionError(f"Accepted invalid display setting: {expected}")

    for options, expected in [({"disabled": True}, "remain enabled"),
                              ({"bitdepth": 8, "colorManagement": "hdr"}, "requires 10-bit"),
                              ({"sdrBrightness": float("nan")}, "invalid sdrBrightness"),
                              ({"colorManagement": "bogus"}, "unknown colour"),
                              ({"icc": "relative.icc"}, "absolute ICC")]:
        rejected({"outputs": live, "settings": {"DP-1": options}}, expected)
    bad = json.loads(json.dumps(payload))
    bad["outputs"]["DP-1"]["logical"]["scale"] = 1.25
    rejected(bad, "whole logical pixels")
    bad = json.loads(json.dumps(payload))
    bad["outputs"]["DP-1"]["modes"][0]["width"] = 9999
    rejected(bad, "no longer available")
    rejected(payload, "disconnected", {})

    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / "hyprland.lua"
        fragment = Path(tmp) / "outputs.lua"
        transaction = Path(tmp) / "preview.json"
        config.write_text(helper._HYPRLAND_OUTPUTS_INCLUDE)
        fragment.write_text("-- saved configuration\n")
        profile = Path(tmp) / 'display "profile".icc'
        profile.write_bytes(b"invalid")
        rejected({"outputs": live, "settings": {"DP-1": {"icc": str(profile)}}}, "not an RGB")
        icc_payload = {"outputs": live, "settings": {"DP-1": {"icc": str(profile)}}}
        header = bytearray(128)
        header[12:16], header[16:20], header[36:40] = b"mntr", b"RGB ", b"acsp"
        profile.write_bytes(header)
        with patch.dict(sys.modules, {"PIL": None}):
            rejected(icc_payload, "require Pillow")
        from PIL import ImageCms
        profile.write_bytes(ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
        assert helper._lua_string(str(profile)) in helper.render_hyprland_outputs(icc_payload, live)
        icc_payload["settings"]["DP-1"]["colorManagement"] = "hdr"
        rejected(icc_payload, "cannot be used with HDR")

        monitor = {"name": "DP-1", "width": 6016, "height": 3384, "refreshRate": 60,
                   "x": 0, "y": 0, "scale": 2, "transform": 0,
                   "currentFormat": "XBGR2101010", "colorManagementPreset": "dp3"}
        with patch.object(helper, "_hyprland_outputs_paths", return_value=(config, fragment, transaction)), \
             patch.object(helper, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps([monitor]), "")), \
             patch.object(helper, "_hyprland_outputs_reload") as reload, \
             patch.object(helper.subprocess, "Popen") as spawn:
            target = Path(tmp) / "real-config.lua"
            target.write_text('-- require("vgs.outputs")\n')
            config.unlink()
            config.symlink_to(target)
            assert not helper.hyprland_outputs_command("status", [])["included"]
            helper.hyprland_outputs_command("setup", [])
            assert config.is_symlink() and target.read_text().endswith(helper._HYPRLAND_OUTPUTS_INCLUDE)
            assert fragment.read_text() == "-- saved configuration\n"
            assert helper.hyprland_outputs_command("status", [])["included"]
            fragment.unlink()
            assert not helper.hyprland_outputs_command("status", [])["included"]
            helper.hyprland_outputs_command("setup", [])
            assert fragment.exists()
            fragment.write_text("-- saved configuration\n")
            result = helper.hyprland_outputs_command("preview", [json.dumps(payload)])
            assert fragment.read_text() == rendered and transaction.exists()
            assert spawn.call_args.kwargs["start_new_session"] is True
            helper.hyprland_outputs_command("current", [])
            assert fragment.read_text() == rendered and transaction.exists(), "same-session preview must remain confirmable"
            try:
                helper.hyprland_outputs_command("preview", [json.dumps(payload)])
            except ValueError as error:
                assert "current display preview" in str(error)
            else:
                raise AssertionError("Concurrent preview overwrote rollback state")
            assert not helper.hyprland_outputs_command("expire", [result["token"]])["finished"]
            state = json.loads(transaction.read_text())
            state["deadline"] = 0
            transaction.write_text(json.dumps(state))
            helper.hyprland_outputs_command("expire", [result["token"]])
            assert fragment.read_text() == "-- saved configuration\n"
            assert not transaction.exists()
            for action, deadline, instance in (
                ("current", 0, os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")),
                ("preview", 0, os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")),
                ("write", 0, os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")),
                ("current", time.time() + 20, "previous-compositor-instance"),
            ):
                stale = {"token": "previous-session", "deadline": deadline, "previous": "-- saved configuration\n", "instance": instance}
                transaction.write_text(json.dumps(stale))
                fragment.write_text("-- unconfirmed configuration\n")
                recovered = helper.hyprland_outputs_command(action, [] if action == "current" else [json.dumps(payload)])
                assert recovered["ok"]
                if action == "preview":
                    assert json.loads(transaction.read_text())["previous"] == stale["previous"]
                    helper.hyprland_outputs_command("revert", [recovered["token"]])
                assert fragment.read_text() == (rendered if action == "write" else stale["previous"])
                assert not transaction.exists()
            stale["deadline"] = 0
            transaction.write_text(json.dumps(stale))
            reload.side_effect = ValueError("session recovery failed")
            recovered = helper.hyprland_outputs_command("current", [])
            assert recovered["recoveryError"] == "session recovery failed"
            assert recovered["recoveryToken"] == stale["token"]
            assert json.loads(transaction.read_text())["error"] == "session recovery failed"
            reload.reset_mock()
            recovered = helper.hyprland_outputs_command("current", [])
            assert recovered["recoveryError"] == "session recovery failed"
            assert recovered["recoveryToken"] == stale["token"]
            reload.assert_not_called()
            reload.side_effect = None
            helper.hyprland_outputs_command("revert", [stale["token"]])
            assert not transaction.exists()
            result = helper.hyprland_outputs_command("preview", [json.dumps(payload)])
            helper.hyprland_outputs_command("confirm", [result["token"]])
            assert fragment.read_text() == rendered and not transaction.exists()
            reload.side_effect = [ValueError("apply failed"), ValueError("restore failed")]
            try:
                helper.hyprland_outputs_command("preview", [json.dumps(payload)])
            except ValueError as error:
                assert str(error) == "restore failed"
            else:
                raise AssertionError("Recovery failure disappeared")
            state = json.loads(transaction.read_text())
            assert state["error"] == "restore failed"
            reload.side_effect = None
            helper.hyprland_outputs_command("revert", [state["token"]])
            assert not transaction.exists()
            result = helper.hyprland_outputs_command("preview", [json.dumps(payload)])
            helper.hyprland_outputs_command("revert", [result["token"]])
            assert fragment.read_text() == rendered and not transaction.exists()
            offline_rule = helper.render_hyprland_outputs({"outputs": {"DP-9": output}}, {"DP-9": output}).splitlines(keepends=True)[1]
            offline_rule = offline_rule.replace(" })", ', icc = "/unmounted/display.icc" })')
            for preserve in (["DP-9"], []):
                fragment.write_text(rendered + offline_rule)
                helper.hyprland_outputs_command("write", [json.dumps({**payload, "preserve": preserve})])
                assert (offline_rule in fragment.read_text()) == bool(preserve), "preserve last-used offline settings unless explicitly forgotten"
            reload.side_effect = [ValueError("invalid monitor rule"), None]
            try:
                helper.hyprland_outputs_command("preview", [json.dumps(payload)])
            except ValueError as error:
                assert str(error) == "invalid monitor rule"
            else:
                raise AssertionError("Failed apply was reported as success")
            assert fragment.read_text() == rendered and not transaction.exists()


def test_codex_theme_paints_every_bundled_theme_readably():
    """Codex drops a theme's backgrounds and paints syntax on the terminal's own,
    so every scope in the rendered .tmTheme must read against that background."""
    # WCAG AA for body text, pinned here so relaxing the production constant
    # reddens this test instead of lowering what it asks for.
    minimum = 4.5
    assert_equal(helper.SYNTAX_MIN_CONTRAST, minimum, "the syntax lift targets WCAG AA")
    template = (helper.targets_dir() / "codex-vgs" / "vgs.tmTheme").read_text()
    template_roles = {match.group(1) for match in helper.TEMPLATE_RE.finditer(template)}
    assert_equal(sorted(template_roles), sorted(helper.SYNTAX_ROLE_BASES),
                 "the Codex template consumes exactly the derived syntax roles")
    names = sorted(d.name for d in helper.builtin_themes_dir().iterdir()
                   if (d / "theme.json").is_file())
    if len(names) < 2:
        raise AssertionError("the bundled theme set must hold more than one theme")
    scopes_seen = set()
    for name in names:
        blueprint = helper.load_theme_package(name)
        if not blueprint:
            raise AssertionError(f"bundled theme {name} did not load")
        roles = helper.app_target_roles(blueprint, helper.target_roles(blueprint))
        rendered = helper.render_target_template("codex-vgs", "vgs.tmTheme", roles)
        if helper.TEMPLATE_RE.search(rendered):
            raise AssertionError(f"{name} left an unresolved role token in the Codex theme")
        entries = plistlib.loads(rendered.encode())["settings"]
        background = roles["background"]
        for entry in entries:
            scope = entry.get("scope", "")
            foreground = entry["settings"]["foreground"]
            if not helper.HEX_RE.match(foreground):
                raise AssertionError(f"{name} {scope or 'global'} foreground is not a hex color")
            ratio = helper.contrast_ratio(foreground, background)
            if ratio < minimum:
                raise AssertionError(
                    f"{name} scope {scope or 'global'} reads at {ratio:.2f}:1 on {background}"
                )
            scopes_seen.add(scope)
    if "" not in scopes_seen:
        raise AssertionError("the theme needs a global settings entry for unscoped text")
    for scope in ("markup.inserted, diff.inserted", "markup.deleted, diff.deleted",
                  "markup.heading, entity.name.section", "markup.underline.link"):
        if scope not in scopes_seen:
            raise AssertionError(f"Codex reads {scope}, which the theme does not set")


def test_codex_theme_selection_changes_only_the_tui_theme_key():
    """config.toml holds the user's whole Codex setup, so the hook rewrites the
    one key and refuses a file it cannot edit without damaging the rest."""
    kept = (
        'model = "gpt-5.3-codex"\n'
        "\n"
        '[projects."/home/method/dev/vgs"]\n'
        "trust_level = \"trusted\"\n"
        "\n"
    )
    # (label, config before, ok, config after, the clause a refusal must name)
    rows = [
        (
            "an existing theme value is replaced in place",
            kept + '[tui]\nstatus_line = ["model"]\ntheme = "ansi"\nnotifications = true\n',
            True,
            kept + '[tui]\nstatus_line = ["model"]\ntheme = "vgs"\nnotifications = true\n',
            "",
        ),
        (
            "a [tui] table without the key takes it as its first line",
            kept + '[tui]\nnotifications = true\n',
            True,
            kept + '[tui]\ntheme = "vgs"\nnotifications = true\n',
            "",
        ),
        (
            "a config with no [tui] table gains one at the end",
            kept.rstrip("\n") + "\n",
            True,
            kept.rstrip("\n") + '\n\n[tui]\ntheme = "vgs"\n',
            "",
        ),
        (
            "an empty config becomes the table alone",
            "",
            True,
            '[tui]\ntheme = "vgs"\n',
            "",
        ),
        (
            "an inline tui table would declare [tui] twice",
            'tui = { theme = "ansi" }\n\n' + kept,
            False,
            'tui = { theme = "ansi" }\n\n' + kept,
            "codex-tui-header-unrecognised:",
        ),
        (
            "a dotted tui.theme key would declare [tui] twice",
            'tui.theme = "ansi"\n\n' + kept,
            False,
            'tui.theme = "ansi"\n\n' + kept,
            "codex-tui-header-unrecognised:",
        ),
        (
            "a theme line inside a multi-line value is not the key",
            kept + '[tui]\nnotes = """\nthe old setting was\ntheme = "ansi"\n"""\n',
            False,
            kept + '[tui]\nnotes = """\nthe old setting was\ntheme = "ansi"\n"""\n',
            "in a form VGS cannot rewrite",
        ),
        (
            "a config Codex itself cannot parse is left alone",
            kept + "[tui\ntheme = ansi\n",
            False,
            kept + "[tui\ntheme = ansi\n",
            "codex config is not valid TOML",
        ),
    ]

    for header, newline in (('[tui]  # my ui', '\n'), ('[ tui ]', '\n'),
                            ('["tui"]', '\n'), ("['tui']", '\n'), ('[tui]', '\r\n')):
        initial = (kept + header + '\nstatus_line = ["model"]\ntheme = "ansi"\nnotifications = true\n').replace('\n', newline)
        expected = initial.replace('theme = "ansi"', 'theme = "vgs"')
        rows.append((f"{header} with {newline!r}", initial, True, expected, ""))
    escaped_header = kept + '["\\u0074ui"]\ntheme = "ansi"\n'
    rows.append(("an escaped table key needs a recognised header", escaped_header, False,
                 escaped_header, "codex-tui-header-unrecognised:"))

    def run(temp_home):
        codex = temp_home / ".codex"
        codex.mkdir()
        config = codex / "config.toml"
        for label, initial, expect_ok, expect_text, expect_error in rows:
            config.write_bytes(initial.encode("utf-8"))
            result = helper.run_hook("codex-theme", {}, {})
            assert_equal(result["ok"], expect_ok, label)
            assert_equal(config.read_bytes(), expect_text.encode("utf-8"), f"file contents: {label}")
            if expect_ok:
                assert_equal(result["theme"], "vgs", f"selected theme: {label}")
                assert_equal(helper.run_hook("codex-theme", {}, {}).get("unchanged"), True,
                             f"second apply is a no-op: {label}")
            elif expect_error not in result["error"]:
                raise AssertionError(
                    f"refusal must name its own cause: {label}: expected "
                    f"{expect_error!r} in {result['error']!r}"
                )

        # The file's mode and its symlink are SELECTION_CONFIGS' rules, checked
        # there for every selection writer at once.

        # A missing config.toml is written, since Codex reads its theme from no
        # other file.
        config.unlink()
        assert_equal(helper.run_hook("codex-theme", {}, {})["ok"], True, "a missing config is created")
        assert_equal(config.read_text(), '[tui]\ntheme = "vgs"\n', "created config holds the table alone")

        # An unwritable config is a warning the apply carries, not an exception
        # that strands the twenty hooks ordered after this one. The path is the
        # link target, because the write resolves.
        dotfiles = temp_home / "dotfiles" / "config.toml"
        dotfiles.parent.mkdir()
        config.unlink()
        config.symlink_to(dotfiles)
        dotfiles.write_text('[tui]\ntheme = "ansi"\n')
        os.chmod(dotfiles.parent, 0o500)
        try:
            refused = helper.run_hook("codex-theme", {}, {})
        finally:
            os.chmod(dotfiles.parent, 0o700)
        assert_equal(refused["ok"], False, "an unwritable config fails as a hook result")
        if "codex config write failed" not in refused["error"]:
            raise AssertionError(f"the write failure must name itself: {refused['error']!r}")
        assert_equal(dotfiles.read_text(), '[tui]\ntheme = "ansi"\n', "the refused write changed nothing")

        # A config that is not UTF-8 is read through the same guard.
        config.unlink()
        config.write_bytes(b'[tui]\ntheme = "\xff\xfe"\n')
        unreadable = helper.run_hook("codex-theme", {}, {})
        assert_equal(unreadable["ok"], False, "a non-UTF-8 config fails as a hook result")
        if "codex config unreadable" not in unreadable["error"]:
            raise AssertionError(f"the read failure must name itself: {unreadable['error']!r}")

        shutil.rmtree(codex)
        skipped = helper.run_hook("codex-theme", {}, {})
        assert_equal(skipped["skipped"], True, "no ~/.codex means no Codex to theme")

    with_temp_home(run)


def terminal_slot_templates():
    """Every target template that writes an actual terminal palette, with the
    terminal slots it reads. Derived from the templates, so a target that starts
    or stops painting a terminal moves this set without a second list to update."""
    found = {}
    for cfg_path in sorted(helper.targets_dir().glob("*/config.json")):
        cfg = json.loads(cfg_path.read_text())
        if not cfg.get("template"):
            continue
        text = (cfg_path.parent / cfg["template"]).read_text()
        slots = {match.group(1) for match in helper.TEMPLATE_RE.finditer(text)
                 if match.group(1).startswith("terminal_")}
        if slots:
            found[cfg_path.parent.name] = (cfg["template"], slots)
    return found


def test_terminal_slot_overrides_reach_terminals_only():
    """A terminal-only slot is what a terminal paints and nothing else reads.

    `colors.toml` feeds the shell's derived roles and pi's interface as well as
    the terminal, so a slot whose conventional terminal meaning needs another
    colour cannot be fixed there. terminal-colors.toml carries that value for the
    terminal alone: the shell role map and the pi render must not move at all.
    """
    targets = terminal_slot_templates()
    for required in ("ghostty-vgs", "alacritty-vgs", "kitty-vgs", "foot-vgs",
                     "wezterm-vgs", "vscode-vgs", "zed-vgs"):
        if required not in targets:
            raise AssertionError(
                f"{required} reads no terminal slot; the extractor or the template is broken")

    palette = "\n".join(f'color{index} = "#0000{index:02d}"' for index in range(16))
    override = "#ff0011"
    # (package, terminal-colors.toml, app-colors.toml)
    packages = (
        ("plain", "", ""),
        ("overridden", f'color0 = "{override}"\n', ""),
        # A saved per-app override names the palette's own roles, and wins over
        # the theme's terminal slot for that one app.
        ("app-override", f'color0 = "{override}"\n',
         '[ghostty]\ncolor0 = "#ff0022"\n\n[kitty]\nred = "#ff0033"\n'),
    )

    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        for name, terminal, app_colors in packages:
            package = builtin / name
            package.mkdir(parents=True)
            # A distinct declared name per package, since the theme list keeps one
            # package per name and edit-app finds its theme there.
            (package / "theme.json").write_text(
                json.dumps({"name": name, "mode": "dark", "source": "curated"}) + "\n")
            (package / "colors.toml").write_text(
                f'background = "#101010"\nforeground = "#eeeeee"\n{palette}\n')
            if terminal:
                (package / helper.TERMINAL_COLORS_FILE).write_text(terminal)
            if app_colors:
                (package / "app-colors.toml").write_text(app_colors)
        configs = {target: json.loads((helper.targets_dir() / target / "config.json").read_text())
                   for target in (*targets, "pi-vgs")}
        helper.cfg_dir().mkdir(parents=True, exist_ok=True)
        (helper.cfg_dir() / "settings.json").write_text(
            json.dumps({"themeApps": {cfg["app"]: True for cfg in configs.values()}}) + "\n")
        saved_files = {cfg["curatedFile"]: target for target, cfg in configs.items()
                       if cfg.get("curatedFile") and not cfg.get("curatedDestination")}

        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        try:
            rendered = {}
            for name, _terminal, _app_colors in packages:
                blueprint = helper.load_theme_package(name)
                if not blueprint:
                    raise AssertionError(f"fixture theme {name} did not load")
                shell_roles = helper.target_roles(blueprint)
                app_roles = helper.app_target_roles(blueprint, shell_roles)
                leaked = sorted(role for role in (*shell_roles, *app_roles) if role.startswith("terminal_"))
                assert_equal(leaked, [], f"{name}: no role map carries a terminal slot before render_roles")
                assert_equal(shell_roles["color0"], "#000000",
                             f"{name}: the shell keeps the palette's own slot 0")
                assert_equal(app_roles["color0"], "#000000",
                             f"{name}: app targets keep the palette's own slot 0")
                # Every path that renders a terminal template, each keyed (surface, target).
                surfaces = {}
                for target in (*targets, "pi-vgs", "vgs-shell"):
                    result = helper.apply_theme_obj(blueprint, only_target=target, run_hooks=False)
                    assert_equal(len(result["rendered"]), 1, f"{name}: applying {target} writes one file")
                    surfaces[("apply", target)] = Path(result["rendered"][0]).read_text()
                for filename, content in helper.rendered_apps_for(
                        blueprint, helper.bp_app_overrides(blueprint)).items():
                    if filename in saved_files:
                        surfaces[("saved package", saved_files[filename])] = content
                preview = temp_home / f"preview-{name}"
                preview.mkdir()
                helper.write_preview_tree(blueprint, shell_roles, preview)
                surfaces[("preview", "ghostty-vgs")] = (preview / "ghostty.conf").read_text()
                with contextlib.redirect_stdout(io.StringIO()):
                    assert_equal(helper.cmd_theme(["edit-app", "ghostty", "--theme", name]), 0,
                                 f"{name}: edit-app exit status")
                surfaces[("edit-app seed", "ghostty-vgs")] = (
                    helper.user_themes_dir() / name / "apps" / "ghostty.conf").read_text()
                rendered[name] = surfaces

            terminal_keys = sorted(key for key in rendered["plain"] if key[1] in targets)
            for required in (("saved package", "ghostty-vgs"), ("preview", "ghostty-vgs"),
                             ("edit-app seed", "ghostty-vgs"), ("apply", "vscode-vgs")):
                if required not in terminal_keys:
                    raise AssertionError(f"{required} rendered no terminal template; the fixture is broken")
            # (package, (surface, target), colour the render carries, colour it must not)
            rows = (
                [("plain", key, None, override) for key in terminal_keys]
                + [("overridden", key, override, None) for key in terminal_keys]
                + [
                    ("app-override", ("apply", "ghostty-vgs"), "#ff0022", override),
                    ("app-override", ("apply", "kitty-vgs"), "#ff0033", None),
                    ("app-override", ("apply", "alacritty-vgs"), override, "#ff0022"),
                    ("app-override", ("saved package", "ghostty-vgs"), "#ff0022", override),
                    ("app-override", ("edit-app seed", "ghostty-vgs"), "#ff0022", override),
                ]
            )
            # foot takes its colours without the leading "#", so a render counts as
            # carrying a colour in either spelling.
            for name, key, carried, absent in rows:
                content = rendered[name][key]
                if carried and not any(form in content for form in (carried, helper.strip_hash(carried))):
                    raise AssertionError(f"{name} {key}: the render lacks {carried}")
                if absent and any(form in content for form in (absent, helper.strip_hash(absent))):
                    raise AssertionError(f"{name} {key}: the render carries {absent}")
            # The shell theme carries the declared name, which is the one line the
            # packages differ in by construction.
            for target in ("pi-vgs", "vgs-shell"):
                assert_equal(
                    rendered["overridden"][("apply", target)].replace('"name": "overridden"', '"name": "plain"'),
                    rendered["plain"][("apply", target)],
                    f"{target} must render byte-identically with and without the file")
        finally:
            helper.builtin_themes_dir = original_builtin

    with_temp_home(scenario)

    # Must-fail control for the reader's one rule: only the sixteen ANSI slots
    # travel. A background or a role name here would claim a reach this file does
    # not have, since every other value the terminal paints comes from colors.toml.
    kept = helper.terminal_slot_overrides({
        "color0": "#123456", "color15": "#654321",
        "background": "#000000", "foreground": "#ffffff",
        "accent": "#ff0000", "color16": "#ff00ff", "selection_background": "#00ff00",
    })
    assert_equal(kept, {"color0": "#123456", "color15": "#654321"},
                 "terminal-colors.toml carries ANSI slots and nothing else")

    # A render path that skips render_roles must fail rather than write literal
    # placeholder text; foreign brace syntax, which names no role, passes through.
    # (label, template, role map, rendered text or the refusal)
    refusals = [
        ("a terminal slot the map lacks", "{terminal_color0}", {}, "template-role-missing t/x {terminal_color0}"),
        ("a palette slot the map lacks", "{color0}", {}, "template-role-missing t/x {color0}"),
        ("a mode-prefixed role the map lacks", "{dark_accent}", {}, "template-role-missing t/x {dark_accent}"),
        ("tmux syntax names no role", "#{pane_id}", {}, "#{pane_id}"),
        ("a role the map carries", "{terminal_color0.strip}", {"terminal_color0": "#123456"}, "123456"),
    ]
    for label, template, roles, expected in refusals:
        try:
            outcome = helper.render_template(template, roles, "t/x")
        except ValueError as error:
            outcome = str(error)
        assert_equal(outcome, expected, label)


def test_curated_vscode_theme_takes_the_terminal_palette():
    """VS Code's integrated terminal is a terminal, so a curated VS Code theme's
    own guess at the ANSI slots must not survive: Claude Code and every other
    program printing ANSI there has to read what it reads in ghostty or kitty."""
    names = sorted(d.name for d in helper.builtin_themes_dir().iterdir()
                   if (d / "apps" / "vscode-theme.json").is_file())
    if len(names) < 2:
        raise AssertionError("the bundled set must hold more than one curated VS Code theme")

    def scenario(_temp_home: Path):
        blueprints = {name: helper.load_theme_package(name) for name in names}
        if any(bp is None for bp in blueprints.values()):
            raise AssertionError("every bundled VS Code theme must load its package identity")
        labels = {name: str(blueprints[name]["name"]) for name in names}
        slugs = {name: helper._vgs_theme_slug(labels[name]) for name in names}
        shipped = {slug: (label, content)
                   for slug, label, _ui, content in helper._all_bundled_vscode_themes()}
        assert_equal(set(shipped), set(slugs.values()),
                     "every bundled VS Code theme ships under its package slug")
        for name in names:
            blueprint = blueprints[name]
            roles = helper.render_roles(blueprint, helper.target_roles(blueprint))
            slug = slugs[name]
            label, content = shipped[slug]
            assert_equal(label, labels[name], f"{name}: VS Code label matches the package name")
            colors = json.loads(content)["colors"]
            for index, key in enumerate(helper.VSCODE_ANSI_KEYS):
                assert_equal(colors.get(key), roles[f"terminal_color{index}"],
                             f"{name} VS Code {key}")

        # A saved [vscode] override reaches the bundled copy too: the extension
        # install writes every bundled copy after the apply hook writes the
        # current theme's, so a copy without it reverts the user's colour.
        name = names[0]
        helper.write_user_layer(name, "app-colors.toml", {"vscode": {"terminal_color0": "#ff0000"}})
        shipped = {slug: content for slug, _label, _ui, content in helper._all_bundled_vscode_themes()}
        assert_equal(json.loads(shipped[slugs[name]])["colors"].get("terminal.ansiBlack"), "#ff0000",
                     f"{name}: the bundled VS Code copy takes the saved override")

        # A user package can own the default generated label. The generated
        # active copy must choose another identity instead of replacing it.
        generated_owner = helper.user_themes_dir() / "generated-owner"
        (generated_owner / "apps").mkdir(parents=True)
        (generated_owner / "theme.json").write_text(
            json.dumps({"name": "VGS Generated", "mode": "dark", "source": "curated"}) + "\n")
        (generated_owner / "apps" / "vscode-theme.json").write_text(
            json.dumps({"name": "foreign generated label", "colors": {}}) + "\n")

        # The active copy and bundled manifest use one package identity. Pick a
        # shipped theme whose curated label differs only by spelling, so the old
        # path returned a label that its same-slug bundled entry replaced.
        active = next((candidate for candidate in names
                       if helper._read_vgs_theme_name(
                           helper.compose_theme_files(candidate)["apps/vscode-theme.json"])
                       != labels[candidate]
                       and helper._vgs_theme_slug(helper._read_vgs_theme_name(
                           helper.compose_theme_files(candidate)["apps/vscode-theme.json"]))
                       == slugs[candidate]), "")
        if not active:
            raise AssertionError("the bundled set needs a curated/package spelling mismatch")
        theme_file = helper.generated_dir() / "vscode" / "vgs-theme.json"
        theme_file.parent.mkdir(parents=True)
        theme_file.write_text(helper.compose_theme_files(active)["apps/vscode-theme.json"].read_text())
        ext_dir = _temp_home / ".vscode" / "extensions"
        ext_dir.mkdir(parents=True)
        settings_path = _temp_home / ".config" / "Code" / "User" / "settings.json"
        settings_path.parent.mkdir(parents=True)
        original_variants = helper.VSCODE_VARIANTS
        helper.VSCODE_VARIANTS = [{
            "id": "vscode", "ext": str(ext_dir), "settings": str(settings_path), "cli": ["code"],
        }]
        try:
            active_bp = blueprints[active]
            active_roles = helper.render_roles(active_bp, helper.target_roles(active_bp))
            result = helper.apply_vscode_theme_hook(active_roles, active_bp)
            selected = json.loads(settings_path.read_text()).get("workbench.colorTheme")
            from PIL import Image
            wallpaper = _temp_home / "wallpaper.png"
            Image.new("RGB", (2, 2), (33, 88, 144)).save(wallpaper)
            generated_bp = helper.blueprint_from_wallpaper(
                wallpaper, name=labels[active], mode=helper.blueprint_mode(active_bp))
            generated_result = helper.apply_theme_obj(generated_bp, only_app="vscode")
        finally:
            helper.VSCODE_VARIANTS = original_variants
        assert_equal(result.get("applied"), [str(settings_path)],
                     "the active VS Code theme apply writes the test installation")
        assert_equal(selected, labels[active], "the active VS Code label comes from its package")
        if selected not in helper._vgs_vscode_labels(ext_dir):
            raise AssertionError(f"the selected VS Code label is not registered: {selected}")

        # A wallpaper palette can keep the current package name. Its generated
        # file must not share that package's slug, because the bundled copy is
        # written after the active copy and would replace the extracted colors.
        assert_equal(generated_result.get("success"), True,
                     "the wallpaper palette renders the VS Code target")
        generated_selected = json.loads(settings_path.read_text()).get("workbench.colorTheme")
        bundled = helper._all_bundled_vscode_themes()
        bundled_labels = {label for _slug, label, _ui, _content in bundled}
        if generated_selected in bundled_labels:
            raise AssertionError(
                f"the wallpaper palette selected a bundled package label: {generated_selected}")
        package_json = json.loads(
            (ext_dir / "vgs.vgs-theme-1.0.0" / "package.json").read_text())
        registered = package_json["contributes"]["themes"]
        generated_entry = next(
            (entry for entry in registered if entry.get("label") == generated_selected), None)
        if not generated_entry:
            raise AssertionError(
                f"the generated VS Code label is not registered: {generated_selected}")
        selected_path = (ext_dir / "vgs.vgs-theme-1.0.0"
                         / str(generated_entry["path"]).removeprefix("./"))
        selected_colors = json.loads(selected_path.read_text())["colors"]
        assert_equal(
            selected_colors.get("editor.background"),
            helper.app_target_roles(generated_bp)["background"],
            "the selected VS Code file keeps the wallpaper-generated palette",
        )
        opposite_mode = "dark" if helper.blueprint_mode(active_bp) == "light" else "light"
        current_data = helper.theme_json_from_blueprint(active_bp)
        # The carry resolves the applied package through `applied_theme_package`,
        # which reads the shell state's name, so this stands in for the applied
        # theme and the package comes off disk as production resolves it.
        with patch.object(helper, "current_theme", return_value=current_data):
            carried_same_mode = helper.carry_curated_apps(
                helper.blueprint_from_current_theme(
                    name=labels[active], mode=helper.blueprint_mode(active_bp)))
            carried_palette = dict(carried_same_mode["palette"])
            carried_palette["wallpaper"] = str(wallpaper)
            carried_same_mode["palette"] = carried_palette
            carried_other_mode = helper.carry_curated_apps(
                helper.blueprint_from_current_theme(
                    name=labels[active], mode=opposite_mode))
        identity_rows = [
            ("same-mode wallpaper carry", carried_same_mode),
            ("mode-mismatched wallpaper carry", carried_other_mode),
            ("transformed package mode",
             helper.transformed_mode_blueprint(active_bp, opposite_mode, "")),
        ]
        helper.VSCODE_VARIANTS = [{
            "id": "vscode", "ext": str(ext_dir), "settings": str(settings_path), "cli": ["code"],
        }]
        try:
            for row_label, row_bp in identity_rows:
                row_result = helper.apply_theme_obj(row_bp, only_app="vscode")
                assert_equal(row_result.get("success"), True,
                             f"{row_label}: the VS Code target applies")
                row_selected = json.loads(settings_path.read_text()).get("workbench.colorTheme")
                assert_equal(row_selected, labels[active],
                             f"{row_label}: the curated file uses its package label")
                row_package = json.loads(
                    (ext_dir / "vgs.vgs-theme-1.0.0" / "package.json").read_text())
                row_entry = next((
                    entry for entry in row_package["contributes"]["themes"]
                    if entry.get("label") == row_selected), None)
                if not row_entry:
                    raise AssertionError(
                        f"{row_label}: the selected curated label is not registered")
                row_path = (ext_dir / "vgs.vgs-theme-1.0.0"
                            / str(row_entry["path"]).removeprefix("./"))
                row_file = json.loads(helper._strip_jsonc(row_path.read_text()))
                row_ui = "vs" if row_file.get("type") == "light" else "vs-dark"
                assert_equal(row_entry.get("uiTheme"), row_ui,
                             f"{row_label}: uiTheme matches the installed curated file")
        finally:
            helper.VSCODE_VARIANTS = original_variants

        for package_name in ("slug collision", "slug-collision"):
            package = helper.user_themes_dir() / package_name
            (package / "apps").mkdir(parents=True)
            (package / "theme.json").write_text(
                json.dumps({"name": package_name, "mode": "dark", "source": "curated"}) + "\n")
            (package / "apps" / "vscode-theme.json").write_text(
                json.dumps({"name": "foreign label", "colors": {}}) + "\n")
        try:
            helper._all_bundled_vscode_themes()
        except ValueError as error:
            collision = str(error)
        else:
            collision = ""
        assert_equal(
            collision,
            "vscode-theme-slug-collision: slug-collision: slug collision and slug-collision",
            "a duplicate slug refuses and names both theme packages",
        )

    def caller_with_restyle(_caller_home: Path):
        # Expected blueprints load only after scenario enters its clean home.
        # A Restyle overlay in the caller home must not change those expectations.
        overlay = helper.user_themes_dir() / names[0]
        overlay.mkdir(parents=True)
        metadata = json.loads((helper.builtin_themes_dir() / names[0] / "theme.json").read_text())
        metadata["adjustments"] = {"brightness": 0.4, "saturation": -0.2}
        (overlay / "theme.json").write_text(json.dumps(metadata) + "\n")
        with_temp_home(scenario)

    with_temp_home(caller_with_restyle)

    # Must-fail control: a blueprint that did not load supplies no slot, and the
    # curated theme's own value stands rather than a default painted over it.
    stub = {"accent": "#808080", "theme_type": "light"}
    original = json.loads(helper._strip_jsonc(
        (helper.builtin_themes_dir() / names[0] / "apps" / "vscode-theme.json").read_text()))
    untouched = json.loads(helper.augment_vscode_colors(
        (helper.builtin_themes_dir() / names[0] / "apps" / "vscode-theme.json").read_text(), stub))
    for key in helper.VSCODE_ANSI_KEYS:
        assert_equal(untouched["colors"].get(key), original["colors"].get(key),
                     f"no terminal slot means no change to {key}")


def non_terminal_targets():
    """Every templated target that paints no terminal palette, as (name, config)."""
    terminal_targets = terminal_slot_templates()
    other_targets = []
    for cfg_path in sorted(helper.targets_dir().glob("*/config.json")):
        cfg = json.loads(cfg_path.read_text())
        if cfg.get("template") and cfg.get("destination") and cfg_path.parent.name not in terminal_targets:
            other_targets.append((cfg_path.parent.name, cfg))
    if "helix-vgs" not in {target for target, _cfg in other_targets}:
        raise AssertionError("helix-vgs reads palette slots directly; the target list is broken")
    return other_targets


def assert_terminal_file_reaches_terminals_only(name, blueprint, other_targets):
    """Each target that paints no terminal renders what the theme renders without
    its terminal-colors.toml."""
    def other_renders(blueprint):
        # Each target renders pass by pass the way apply renders it, so a target
        # that writes both modes reads both modes' colours.
        shell = helper.target_roles(blueprint)
        app = helper.render_roles(blueprint, helper.app_target_roles(blueprint, shell))
        mode_maps = {}

        def resolve_mode_maps():
            if not mode_maps:
                mode_maps.update(helper.mode_variant_role_maps(blueprint))
            return mode_maps

        out = {}
        for target, cfg in other_targets:
            roles = helper.render_roles(blueprint, shell) if target == "vgs-shell" else app
            template = (helper.targets_dir() / target / cfg["template"]).read_text()
            passes = helper.target_render_passes(
                cfg, roles, helper.expand_dest(cfg["destination"]), resolve_mode_maps, {})
            out[target] = [helper.render_template(template, pass_roles, f"{target}/{cfg['template']}")
                           for pass_roles, _dest in passes]
        return out

    with_file = other_renders(blueprint)
    without_file = other_renders(dict(blueprint, terminalColors={}))
    for target, _cfg in other_targets:
        assert_equal(with_file[target], without_file[target], f"{name}: {target} reads no terminal slot")


def test_light_themes_read_in_a_terminal():
    """Claude Code's light-ANSI mode draws body text in slot 0, muted text in
    slot 8, and the bands under body text in slots 7 and 15. A light theme that
    uses those slots as a mood palette prints body text at 1.10:1 to 1.82:1.

    Every slot change lives in terminal-colors.toml, so each target that paints no
    terminal renders what the theme renders without that file."""
    # (theme, body text on the background, muted text, body text on each band,
    #  body text on the selection fill in slot 6 or None where the fix leaves slot 6)
    rows = [
        ("catppuccin-latte", 4.5, 3.0, 4.5, None),
        ("flexoki-light", 4.5, 3.0, 4.5, None),
        ("horizon-light", 4.5, 3.0, 4.5, 3.0),
        ("rose-pine", 4.5, 3.0, 4.5, None),
        ("thegreek", 4.5, 3.0, 4.5, None),
        ("white", 4.5, 3.0, 4.5, 4.5),
    ]
    other_targets = non_terminal_targets()

    for name, body_min, muted_min, band_min, selection_min in rows:
        blueprint = helper.load_theme_package(name)
        if not blueprint:
            raise AssertionError(f"bundled theme {name} did not load")
        if not blueprint["terminalColors"]:
            raise AssertionError(f"{name} ships no terminal-colors.toml")
        assert_terminal_file_reaches_terminals_only(name, blueprint, other_targets)
        roles = helper.render_roles(blueprint, helper.app_target_roles(blueprint, helper.target_roles(blueprint)))
        assert_equal(roles["theme_type"], "light", f"{name} is a light theme")
        background = roles["background"]
        body = roles["terminal_color0"]
        measured = [
            ("body text", helper.contrast_ratio(body, background), body_min),
            ("muted text", helper.contrast_ratio(roles["terminal_color8"], background), muted_min),
            ("the band on slot 7", helper.contrast_ratio(body, roles["terminal_color7"]), band_min),
            ("the band on slot 15", helper.contrast_ratio(body, roles["terminal_color15"]), band_min),
        ]
        if selection_min is not None:
            measured.append(("the selection fill in slot 6",
                             helper.contrast_ratio(body, roles["terminal_color6"]), selection_min))
        for label, ratio, minimum in measured:
            if ratio < minimum:
                raise AssertionError(f"{name}: {label} reads at {ratio:.2f}:1, under {minimum}:1")


def test_dark_themes_read_in_a_terminal():
    """Dark ANSI mode draws body text in slot 15 and bands in slots 8 and 0."""
    # (theme, body text on the background, muted text, body text on each band)
    rows = [
        ("horizon", 4.5, 3.0, 4.5),
    ]
    other_targets = non_terminal_targets()

    for name, body_min, muted_min, band_min in rows:
        blueprint = helper.load_theme_package(name)
        if not blueprint:
            raise AssertionError(f"bundled theme {name} did not load")
        if not blueprint["terminalColors"]:
            raise AssertionError(f"{name} ships no terminal-colors.toml")
        assert_terminal_file_reaches_terminals_only(name, blueprint, other_targets)
        roles = helper.render_roles(blueprint, helper.app_target_roles(blueprint, helper.target_roles(blueprint)))
        assert_equal(roles["theme_type"], "dark", f"{name} is a dark theme")
        background = roles["background"]
        body = roles["terminal_color15"]
        measured = [
            ("body text", helper.contrast_ratio(body, background), body_min),
            ("muted text", helper.contrast_ratio(roles["terminal_color7"], background), muted_min),
            ("the band on slot 8", helper.contrast_ratio(body, roles["terminal_color8"]), band_min),
            ("the band on slot 0", helper.contrast_ratio(body, roles["terminal_color0"]), band_min),
        ]
        for label, ratio, minimum in measured:
            if ratio < minimum:
                raise AssertionError(f"{name}: {label} reads at {ratio:.2f}:1, under {minimum}:1")


def test_dark_themes_draw_diffs_in_two_hues():
    """git diff, Codex's ANSI theme and Claude Code's ANSI modes draw removed and
    added lines in slots 1 and 2, and removed and added words in slots 9 and 10.
    Each pair reads as two colours only when its hues sit 60 degrees apart, and
    each slot carries HSL saturation of 0.15 and 3:1 on the background.

    Every bundled dark theme is checked, so a theme added later is too. Every slot
    change lives in terminal-colors.toml, so each target that paints no terminal
    renders what the theme renders without that file. The owner's ruling keeps the
    single-hue palettes as they are and their diffs read by the + and - glyphs:
    most keep red and green in one hue, and fireside's green is near-grey. They
    ship no terminal slots."""
    single_hue = ["amberbyte", "artzen", "brutalism", "fireside", "lumon", "snow", "solitude", "vantablack"]
    other_targets = non_terminal_targets()
    checked = []
    for theme_dir in sorted(helper.builtin_themes_dir().iterdir()):
        if not (theme_dir / "colors.toml").is_file() or theme_dir.name in single_hue:
            continue
        name = theme_dir.name
        blueprint = helper.load_theme_package(name)
        if not blueprint:
            raise AssertionError(f"bundled theme {name} did not load")
        roles = helper.render_roles(blueprint, helper.app_target_roles(blueprint, helper.target_roles(blueprint)))
        if roles["theme_type"] != "dark":
            continue
        checked.append(name)
        if blueprint["terminalColors"]:
            assert_terminal_file_reaches_terminals_only(name, blueprint, other_targets)
        background = roles["background"]
        for removed, added in ((1, 2), (9, 10)):
            for slot in (removed, added):
                value = roles[f"terminal_color{slot}"]
                red, green, blue = [channel / 255.0 for channel in helper.rgb(value)]
                saturation = colorsys.rgb_to_hls(red, green, blue)[2]
                if saturation < 0.15:
                    raise AssertionError(f"{name}: slot {slot} {value} has HSL saturation {saturation:.2f}, under 0.15")
                ratio = helper.contrast_ratio(value, background)
                if ratio < 3.0:
                    raise AssertionError(f"{name}: slot {slot} {value} reads at {ratio:.2f}:1, under 3:1")
            removed_hue = helper.color_hue(roles[f"terminal_color{removed}"])
            added_hue = helper.color_hue(roles[f"terminal_color{added}"])
            distance = helper._hue_distance(removed_hue, added_hue)
            if distance < 60.0:
                raise AssertionError(f"{name}: slots {removed} and {added} sit {distance:.0f} degrees apart, under 60")
    if len(checked) < 60 or not {"akane", "synthwave84"} <= set(checked) or "catppuccin-latte" in checked:
        raise AssertionError(f"the dark theme scan is broken: it found {len(checked)} themes")
    for name in single_hue:
        blueprint = helper.load_theme_package(name)
        if not blueprint:
            raise AssertionError(f"bundled theme {name} did not load")
        assert_equal(blueprint["terminalColors"], {}, f"{name} keeps its single-hue slots")


def test_wallpaper_and_save_keep_terminal_slots():
    """A wallpaper change and save-current rebuild the theme from the shell's
    theme.json, which carries no terminal slots, so each must carry the package's
    terminal-colors.toml forward or the terminal loses its readable slots."""
    slots = {"color0": "#ff0011"}
    shortfalls = [{"slot": "accent", "ratio": 1.0, "floor": 3}]

    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        package = builtin / "termfix"
        package.mkdir(parents=True)
        (package / "theme.json").write_text(
            json.dumps({"name": "termfix", "mode": "light", "source": "curated",
                        "contrastShortfalls": shortfalls}) + "\n")
        (package / "colors.toml").write_text('background = "#fafafa"\nforeground = "#101010"\n')
        (package / helper.TERMINAL_COLORS_FILE).write_text('color0 = "#ff0011"\n')
        wallpaper = temp_home / "wall.png"
        wallpaper.write_bytes(b"\x89PNG\r\n\x1a\n")
        applied = []
        original_builtin, original_apply = helper.builtin_themes_dir, helper.apply_theme_obj
        helper.builtin_themes_dir = lambda: builtin
        # A real apply runs hooks that reach the login session; these rows measure
        # the blueprint the command hands to it.
        helper.apply_theme_obj = lambda bp, *args, **kwargs: applied.append(bp) or {"success": True}
        try:
            blueprint = helper.load_theme_package("termfix")
            helper.cfg_dir().mkdir(parents=True, exist_ok=True)
            (helper.cfg_dir() / "theme.json").write_text(helper.render_target_template(
                "vgs-shell", "vgs-theme.json", helper.target_roles(blueprint)))
            # What an apply leaves behind, from the apply's own writer, so this
            # cannot keep seeding keys a later apply stops recording.
            (helper.cfg_dir() / "theme-current.json").write_text(
                json.dumps(helper.applied_theme_state(blueprint)) + "\n")
            # (command, argv, the terminal slots the command's result carries)
            rows = [
                ("set-wallpaper", ["set-wallpaper", str(wallpaper)],
                 lambda: applied[-1].get("terminalColors")),
                ("clear-wallpaper", ["clear-wallpaper"],
                 lambda: applied[-1].get("terminalColors")),
                ("save-current", ["save-current", "--name", "termfix-saved"],
                 lambda: (helper.load_theme_package("termfix-saved") or {}).get("terminalColors")),
                ("apply-colors", ["apply-colors", "--name", "termfix", "--set", "accent=#123456"],
                 lambda: applied[-1].get("terminalColors")),
                ("apply-colors --save", ["apply-colors", "--name", "termfix-colors", "--set", "accent=#123456", "--save"],
                 lambda: (helper.load_theme_package("termfix-colors") or {}).get("terminalColors")),
            ]
            for label, argv, read in rows:
                with contextlib.redirect_stdout(io.StringIO()):
                    assert_equal(helper.cmd_theme(argv), 0, f"{label} exit status")
                assert_equal(read(), slots, f"{label} keeps the terminal slots")
            # A save states the list, so a package under another name keeps it.
            for saved in ("termfix-saved", "termfix-colors"):
                assert_equal(json.loads((helper.user_themes_dir() / saved / "theme.json").read_text())
                             .get("contrastShortfalls"), shortfalls, f"{saved} keeps the contrast shortfall list")

            # A theme with no terminal slots saved over that package leaves no file
            # behind, or the next load paints the previous theme's slots.
            helper.save_theme_package(dict(blueprint, terminalColors={}), "termfix-saved")
            assert_equal((helper.user_themes_dir() / "termfix-saved" / helper.TERMINAL_COLORS_FILE).exists(),
                         False, "a save with no terminal slots removes the stale file")
            assert_equal((helper.load_theme_package("termfix-saved") or {}).get("terminalColors"), {},
                         "the re-saved package carries no terminal slots")

            # Saved under the built-in theme's own name, the user overlay must mask
            # the built-in terminal file, or the saved palette inherits its slots.
            helper.save_theme_package(dict(blueprint, terminalColors={}), "termfix")
            errors = io.StringIO()
            with contextlib.redirect_stderr(errors):
                masked = helper.load_theme_package("termfix") or {}
            assert_equal(masked.get("terminalColors"), {},
                         "a save with no terminal slots masks the built-in terminal file")
            assert_equal(errors.getvalue(), "", "the masking overlay loads without an error")
        finally:
            helper.builtin_themes_dir, helper.apply_theme_obj = original_builtin, original_apply

    with_temp_home(scenario)


# One merge-style curated file per package revision. A reload naming either one
# says which revision's curated values the save paired its palette with.
REFRESHED_CURATED_REVISIONS = {
    "A": json.dumps({"overrides": {"diffAdded": "#1e3a1e"}}, indent=2) + "\n",
    "B": json.dumps({"overrides": {"diffAdded": "#24482c"}}, indent=2) + "\n",
}
# A replacing curated file: the whole output, with no palette-derived value under
# it to disagree with, so the palette rule never reaches it.
REFRESHED_REPLACING_CURATED = "[main]\ntheme[main_bg]=\"#101010\"\n"


def refreshed_curated_package(name: str, foreground: str, revision: str,
                              source: str = "curated") -> Path:
    """Write theme package `name` into the user theme directory at one revision.

    One directory, as a catalogued download is, so the save writes the layer the
    curated files already sit in and its prune is the one that could delete them.
    Its `theme.json` records the digest of its own palette, which is what the
    loader asks each curated file about.
    """
    package = helper.user_themes_dir() / name
    (package / "apps").mkdir(parents=True, exist_ok=True)
    # Mid-tone ANSI slots, because role derivation re-runs contrast adjustment on
    # the generated branch and is not a fixed point on them: a generated package
    # built from slots the adjustment leaves alone matches itself however many times
    # either side is rebuilt, and says nothing about the depth the comparison
    # equalises.
    (package / "colors.toml").write_text(
        f'background = "#fafafa"\nforeground = "{foreground}"\n'
        + "".join(f'color{index} = "#{0x60 + index * 6:02x}90{0xa8 - index * 4:02x}"\n'
                  for index in range(16)))
    (package / "apps" / "claude-light.json").write_text(REFRESHED_CURATED_REVISIONS[revision])
    (package / "apps" / "btop.theme").write_text(REFRESHED_REPLACING_CURATED)
    meta = {"name": name, "mode": "light", "source": source}
    meta["curatedPalette"] = helper.palette_digest(helper.package_palette(
        helper.package_colors_map(name), meta,
        helper.package_declared_ui_roles(meta, name)))
    (package / "theme.json").write_text(json.dumps(meta) + "\n")
    return package


def curated_revision_of(path: str | None) -> str:
    """Which revision's merge-style curated file sits at `path`, or the empty string."""
    body = Path(path).read_text() if path else ""
    return next((revision for revision, text in REFRESHED_CURATED_REVISIONS.items()
                 if text == body), "")


def test_a_save_never_pairs_its_palette_with_a_curated_file_it_did_not_judge():
    """A merge-style curated file is valid only for the palette it was picked
    against, and the palette a save writes is not always the one the package on disk
    holds. `materialize_theme_package` owns what happens to such a file, and the rows
    below pin its two decisions at four of the routes that reach it: `set-wallpaper
    --save`, including over a package whose `theme.json` an interrupted save left
    behind, `apply-colors --save`, `save-current`, and `theme regenerate`, which is
    handed part of a package. `theme import-colors` and `extract-wallpaper --save`
    reach the same writer and have no row here: both go through
    `save_theme_package`, which reads the destination for its `vouched` list exactly
    as the covered save routes do.

    Each row reads the revision the route's apply painted, the revision the reload
    renders, whether the curated file's own bytes are still there, whether the
    package's hand-written replacing file is still there, and what the save said on
    stderr. The first is empty where the route runs no apply or paints no curated
    file. The bytes column is the one that matters most: this package directory is
    the only copy, as a download or a user-created theme has.

    The untouched rows say each other row measures its own route and not the rule
    itself, and one of them declares `source: generated`, the branch where role
    derivation is not a fixed point and the palette comparison has to rebuild both
    sides the same number of times.

    The control row removes the palette agreement and the stale pair comes back.
    """
    def scenario(temp_home: Path):
        wallpaper = temp_home / "wall.png"
        wallpaper.write_bytes(b"\x89PNG\r\n\x1a\n")
        applied: list = []
        original_apply = helper.apply_theme_obj
        helper.cfg_dir().mkdir(parents=True, exist_ok=True)
        # The btop target renders from a template and otherwise answers to whether
        # the host has btop installed, which decides whether a save with no carry
        # re-renders the package's hand-written `apps/btop.theme` and whether
        # `theme regenerate --app btop` finds a file to regenerate at all. A user
        # toggle wins over detection, so state it and the rows read the fixture
        # rather than the machine.
        (helper.cfg_dir() / "settings.json").write_text(
            json.dumps({"themeApps": {"btop": True}}) + "\n")

        # A real apply runs hooks that reach the login session. This records the
        # blueprint and leaves behind what an apply leaves, through the apply's own
        # writer, so a colour edit with no `--save` moves the applied palette here
        # exactly as it does in the session.
        def stub_apply(bp, *args, **kwargs):
            applied.append(bp)
            (helper.cfg_dir() / "theme.json").write_text(helper.render_target_template(
                "vgs-shell", "vgs-theme.json", helper.target_roles(bp)))
            (helper.cfg_dir() / "theme-current.json").write_text(
                json.dumps(helper.applied_theme_state(bp)) + "\n")
            return {"success": True, "warnings": []}

        helper.apply_theme_obj = stub_apply

        def run(argv, errors=None):
            with contextlib.redirect_stdout(io.StringIO()), \
                 contextlib.redirect_stderr(errors or io.StringIO()):
                status = helper.cmd_theme(argv)
            assert_equal(status, 0, f"{' '.join(argv)} exit status")

        def save_after(name: str, move: str, source: str, save_argv: list,
                       then: list | None, patched, again: bool = False) -> tuple:
            """Apply the package, move the palette one way, then run the save route."""
            package = refreshed_curated_package(name, "#101010", "A", source=source)
            curated = package / "apps" / "claude-light.json"
            replacing = package / "apps" / "btop.theme"
            loaded = helper.load_theme_package(name)
            assert_equal(sorted((loaded or {}).get("apps") or {}),
                         ["btop.theme", "claude-light.json"],
                         f"{name}: the package loads both curated files")
            stub_apply(loaded)
            if move == "refresh":
                refreshed_curated_package(name, "#202020", "B", source=source)
            if move in ("edit", "edit-twice"):
                run(["apply-colors", "--name", name, "--set", "foreground=#303030"])
            if move == "mode":
                stub_apply(helper.transformed_mode_blueprint(helper.find_theme(name), "dark", ""))
            if move == "no-metadata":
                (package / "theme.json").unlink()
            expected_bytes = curated.read_bytes()
            applied.clear()
            errors = io.StringIO()
            with patched:
                run([arg.replace("<name>", name) for arg in save_argv], errors)
                if again:
                    run([arg.replace("<name>", name) for arg in save_argv])
            if then:
                run([arg.replace("<name>", name) for arg in then])
            carried = (applied[-1].get("apps") if applied else {}) or {}
            reloaded = (helper.load_theme_package(name) or {}).get("apps") or {}
            return (curated_revision_of(carried.get("claude-light.json")),
                    curated_revision_of(reloaded.get("claude-light.json")),
                    curated.is_file() and curated.read_bytes() == expected_bytes,
                    replacing.is_file() and replacing.read_text() == REFRESHED_REPLACING_CURATED,
                    errors.getvalue().strip())

        wallpaper_save = ["set-wallpaper", str(wallpaper), "--save"]
        parted_notice = ("save <name>: writing a palette claude-light.json was not "
                         "picked against, so this save vouches for none of them")
        no_agreement = patch.object(helper, "applied_palette_parted", return_value=False)
        try:
            # (what the row measures, the package, how the palette parts, the source
            #  the package declares, the save route, a writer run after it, the
            #  production answer this row removes,
            #  (revision the apply paints, revision the reload renders, the curated
            #   file's own bytes intact, the replacing file intact, save stderr))
            rows = [
                ("an untouched package renders its own revision and says nothing",
                 "carryrest", "none", "curated", wallpaper_save, None,
                 contextlib.nullcontext(), ("A", "A", True, True, "")),
                ("an untouched generated package renders its own revision",
                 "carrygen", "none", "generated", wallpaper_save, None,
                 contextlib.nullcontext(), ("A", "A", True, True, "")),
                ("a refreshed definition pairs with nothing and loses no bytes",
                 "carrymoved", "refresh", "curated", wallpaper_save, None,
                 contextlib.nullcontext(), ("", "", True, True, "")),
                ("an unsaved colour edit pairs with nothing and loses no bytes",
                 "carryedit", "edit", "curated", wallpaper_save, None,
                 contextlib.nullcontext(), ("", "", True, True, "")),
                # The second save has itself moved nothing, so a rule keyed on the
                # write in front of it refreshed the record and handed the file back.
                ("a second save after a parted one leaves the record held",
                 "carrytwice", "edit-twice", "curated", wallpaper_save, None,
                 contextlib.nullcontext(), ("", "", True, True, "")),
                ("a mode rebuild paints the counterpart file, saves none of it and says so",
                 "carrymode", "mode", "curated", wallpaper_save, None,
                 contextlib.nullcontext(), ("A", "", True, True, parted_notice)),
                # A save route with no carry re-renders every enabled app file from
                # the templates, so the package's hand-written replacing file goes.
                # That is the pre-existing shape of those routes; the rule under test
                # is the merge-style column beside it.
                ("apply-colors --save under the theme's own name loses no bytes",
                 "carryedited", "none", "curated",
                 ["apply-colors", "--name", "<name>", "--set", "accent=#123456", "--save"], None,
                 contextlib.nullcontext(), ("", "", True, False, "")),
                # `save-current` writes the applied theme's own palette back into its
                # own package, so nothing parted and the file stays certified.
                ("save-current under the theme's own name keeps its file rendering",
                 "carrysaved", "none", "curated",
                 ["save-current", "--name", "<name>"], None,
                 contextlib.nullcontext(), ("", "A", True, False, "")),
                ("a save over the package an interrupted save left loses no bytes",
                 "carrynometa", "no-metadata", "curated", wallpaper_save, None,
                 contextlib.nullcontext(), ("", "", True, False, "")),
                # `regenerate` is handed one app's file and moves no palette, so it
                # hands the writer the merge-style files the loader kept and records
                # the digest of what it wrote. That keeps a certified curated file
                # certified, which it must: regenerate rewrites `colors.toml` from a
                # blueprint stating derived roles the package left implicit, so a
                # held-back record would drop the file from the renders after it.
                # After a parted save the loader has already dropped the file, so
                # regenerate vouches for nothing and the record stays held.
                ("regenerate on an untouched package keeps its file rendering",
                 "carryregenrest", "none", "curated",
                 ["regenerate", "<name>", "--app", "btop", "--yes"], None,
                 contextlib.nullcontext(),
                 ("", "A", True, False,
                  "note: <name> is curated; regenerating replaces curated files "
                  "with palette renders")),
                ("regenerate after a held-back record does not revive the file",
                 "carryregen", "refresh", "curated", wallpaper_save,
                 ["regenerate", "<name>", "--app", "btop", "--yes"],
                 contextlib.nullcontext(), ("", "", True, False, "")),
                ("without the palette agreement the stale pair comes back",
                 "carrycontrol", "refresh", "curated", wallpaper_save, None,
                 no_agreement, ("B", "B", True, True, "")),
            ]
            for label, name, move, source, save_argv, then, patched, expected in rows:
                assert_equal(save_after(name, move, source, save_argv, then, patched,
                                        again=move == "edit-twice"),
                             tuple(part.replace("<name>", name) if isinstance(part, str) else part
                                   for part in expected),
                             label)

            # The apply names what the carry withheld, in the shape the inert
            # declarations warning uses, so the settings editor and the picker show a
            # curated file gone quiet instead of swapping the bands in silence.
            refreshed_curated_package("carrywarn", "#101010", "A")
            stub_apply(helper.load_theme_package("carrywarn"))
            refreshed_curated_package("carrywarn", "#202020", "B")
            carried = helper.carry_curated_apps(
                helper.blueprint_from_current_theme(name="carrywarn"))
            assert_equal(carried.get(helper.WITHHELD_CURATED_KEY), ["claude-light.json"],
                         "the carry records the file it withheld")
            with contextlib.redirect_stderr(io.StringIO()):
                result = helper._apply_theme_obj_unlocked(
                    carried, only_target="no-such-target", run_hooks=False)
            assert_equal([line for line in result["warnings"] if "claude-light.json" in line],
                         ["curated app files: claude-light.json not read, "
                          "picked against a palette this apply does not paint"],
                         "the apply names the withheld curated file once")
            assert_equal(result["partial"], True, "naming a withheld file makes the apply partial")
            assert_equal(helper.WITHHELD_CURATED_KEY in helper.applied_theme_state(carried), False,
                         "what one rebuild withheld is not recorded as applied state")
        finally:
            helper.apply_theme_obj = original_apply

    with_temp_home(scenario)


def test_wallpapers_all_lists_the_folder_then_every_theme():
    """`theme wallpapers --all` is the All view's list: the folder's images first, then every
    installed theme's set, each entry naming its source."""
    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        for name in ("beta", "alpha"):
            package = builtin / name
            (package / "backgrounds").mkdir(parents=True)
            (package / "theme.json").write_text(json.dumps({"name": name, "mode": "dark", "source": "curated"}) + "\n")
            (package / "colors.toml").write_text('background = "#101010"\nforeground = "#fafafa"\n')
            (package / "backgrounds" / f"{name}.png").write_bytes(b"\x89PNG\r\n\x1a\n")
        folder = temp_home / "Pictures"
        folder.mkdir()
        (folder / "mine.JPG").write_bytes(b"\xff\xd8")
        (folder / "notes.txt").write_text("not an image\n")
        themes = [("alpha", "alpha.png"), ("beta", "beta.png")]
        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        try:
            # (folder argument, listed (source, file) pairs, why)
            rows = [
                (str(folder), [("folder", "mine.JPG")] + themes,
                 "the folder's images come first under source folder, a non-image is skipped, then each theme by name"),
                (str(temp_home / "absent"), themes, "a folder that does not exist lists no images and every theme still lists"),
            ]
            for folder_arg, expected, why in rows:
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    assert_equal(helper.cmd_theme(["wallpapers", "--all", "--folder", folder_arg, "--json"]), 0, f"{why}: exit status")
                listed = [(entry["source"], entry["file"]) for entry in json.loads(out.getvalue())["wallpapers"]]
                assert_equal(listed, expected, why)
        finally:
            helper.builtin_themes_dir = original_builtin

    with_temp_home(scenario)


# Every colour jolaleye/horizon-theme-vscode v2.0.2 publishes in its
# `src/dark/globals.json` and `src/bright/globals.json` (syntax, ui and ansi).
HORIZON_UPSTREAM_COLOURS = {
    "horizon": frozenset({
        "#06060c", "#09f7a0", "#16161c", "#1a1c23", "#1c1e26", "#21bfc2", "#232530", "#25b0bc",
        "#26bbd9", "#27d797", "#29d398", "#2e303e", "#3fc4de", "#3fdaa4", "#59e1e3", "#6be4e6",
        "#6c6f93", "#b877db", "#bbbbbb", "#d5d8da", "#e9436d", "#e95378", "#e95678", "#ec6a88",
        "#ee64ac", "#f075b5", "#f09483", "#f43e5c", "#fab38e", "#fab795", "#fac29a", "#fbc3a7",
    }),
    "horizon-light": frozenset({
        "#06060c", "#07da8c", "#16161c", "#1a1c23", "#1d8991", "#1eaeae", "#1eb980", "#26bbd9",
        "#29d398", "#333333", "#3fc4de", "#3fdaa4", "#59e1e3", "#6be4e6", "#8a31b9", "#af5427",
        "#d5d8da", "#da103f", "#dc3318", "#e73665", "#e84a72", "#e95678", "#ec6a88", "#ee64ac",
        "#f075b5", "#f43e5c", "#f6661e", "#f77d26", "#f9cbbe", "#f9cec3", "#fab795", "#fadad1",
        "#fbc3a7", "#fdf0ed",
    }),
}
# sha256 of the canonical JSON of `{"colors", "tokenColors"}` parsed from the
# upstream `themes/horizon.json` and `themes/horizon-bright.json` at v2.0.2.
HORIZON_UPSTREAM_THEME_DIGESTS = {
    "horizon": "962976b0824665f13b53a8928000b6607f407db376e7e3d1f495d18be827a8e8",
    "horizon-light": "4f5d3eb25fe3e11bfcfd51df90958bb3a2a3fbc60b95896e88e6b321b7ecff01",
}
# The package files whose colours VGS picks. The VS Code file is copied verbatim,
# so it is held to the upstream digest instead; upstream Horizon Bright also
# writes `#000000b3` there, which is not in its globals.
HORIZON_PICKED_FILES = ("colors.toml", "terminal-colors.toml", "ui-roles.toml", "apps/btop.theme")


def horizon_package_colours(package: Path) -> list[tuple[str, str]]:
    """Every `#` colour literal in a Horizon package's picked files, as (file, value).

    An eight-digit or other non-six-digit literal comes back whole, so it is
    never read as an upstream colour it merely starts with.
    """
    found = []
    for relpath in HORIZON_PICKED_FILES:
        path = package / relpath
        if not path.is_file():
            raise AssertionError(f"{package.name} ships no {relpath}")
        for value in re.findall(r"#[0-9A-Fa-f]+\b", path.read_text()):
            found.append((relpath, value.lower()))
    return found


def horizon_invented_colours(package: Path, allowed: frozenset) -> list[str]:
    """Every picked colour in `package` that upstream never published, as sorted `file value`."""
    return sorted({f"{relpath} {value}" for relpath, value in horizon_package_colours(package)
                   if value not in allowed})


def horizon_theme_digest(path: Path) -> str:
    data = json.loads(path.read_text())
    canonical = json.dumps({"colors": data["colors"], "tokenColors": data["tokenColors"]},
                           sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def test_horizon_packages_use_only_upstream_colours():
    """Both Horizon packages carry the vendor's own values and nothing VGS invented.

    Every colour VGS picks for them is a member of the upstream globals, and the
    curated VS Code file's `colors` and `tokenColors` are upstream's exactly. Each
    check also runs on a copy with one planted defect, which it must name."""
    for name, allowed in HORIZON_UPSTREAM_COLOURS.items():
        package = helper.builtin_themes_dir() / name
        colours = horizon_package_colours(package)
        if not any(relpath == "ui-roles.toml" for relpath, _value in colours):
            raise AssertionError(f"{name}: the colour extractor read no ui-roles.toml value; it is broken")
        if ("colors.toml", helper.parse_colors_toml(package / "colors.toml")["accent"]) not in colours:
            raise AssertionError(f"{name}: the colour extractor missed the accent; it is broken")
        assert_equal(horizon_invented_colours(package, allowed), [],
                     f"{name}: every picked colour is an upstream Horizon colour")
        theme_file = package / "apps" / "vscode-theme.json"
        assert_equal(horizon_theme_digest(theme_file), HORIZON_UPSTREAM_THEME_DIGESTS[name],
                     f"{name}: the VS Code theme's colors and tokenColors are upstream's")

        with tempfile.TemporaryDirectory() as tmp:
            planted = Path(tmp) / name
            shutil.copytree(package, planted)
            # (file, planted line, what the check must report): a colour upstream
            # never published, and an upstream colour carrying an alpha channel.
            rows = [
                ("colors.toml", 'color4 = "#18849a"\n', ["colors.toml #18849a"]),
                ("terminal-colors.toml", 'color8 = "#63668d"\n', ["terminal-colors.toml #63668d"]),
                ("ui-roles.toml", 'muted = "#18849a"\n', ["ui-roles.toml #18849a"]),
                ("apps/btop.theme", 'theme[main_bg]="#2e303eff"\n', ["apps/btop.theme #2e303eff"]),
            ]
            for relpath, line, expected in rows:
                path = planted / relpath
                original = path.read_text()
                path.write_text(original + line)
                assert_equal(horizon_invented_colours(planted, allowed), expected,
                             f"{name}: a planted {relpath} colour is named")
                path.write_text(original)

            planted_theme = planted / "apps" / "vscode-theme.json"
            data = json.loads(planted_theme.read_text())
            data["tokenColors"][0]["settings"]["foreground"] = "#18849a"
            planted_theme.write_text(json.dumps(data, indent=4))
            if horizon_theme_digest(planted_theme) == HORIZON_UPSTREAM_THEME_DIGESTS[name]:
                raise AssertionError(f"{name}: a changed token colour must move the VS Code theme digest")


# A curated package's own UI tones, keyed by the role names `target_roles` emits.
# The values are Horizon Bright's published surfaces, which is the palette whose
# flat-grey render this file exists to stop; `muted` is deliberately unreadable
# on the background so the reporter has something to name.
DECLARED_UI_ROLES = {
    "statusBg": "#fadad1",
    "surfaceContainerHighest": "#f9cbbe",
    "muted": "#f9cec3",
}
DECLARED_UI_ROLES_TOML = "".join(f'{role} = "{value}"\n'
                                 for role, value in sorted(DECLARED_UI_ROLES.items()))
# One distinct value per declarable role, taken from the helper's own set so a
# role added there is covered without editing this file. Every one must arrive in
# the role map, or the set admits a role no derivation assignment reads.
EVERY_ROLE_VALUES = {role: f"#{index:02x}c0de"
                     for index, role in enumerate(sorted(helper.DECLARABLE_UI_ROLES))}


def declared_roles_package(root: Path, name: str, ui_roles: str = "",
                           source: str = "curated", mode: str = "light") -> Path:
    """One theme package on disk, optionally declaring its own UI roles."""
    package = root / name
    package.mkdir(parents=True, exist_ok=True)
    (package / "theme.json").write_text(
        json.dumps({"name": name, "mode": mode, "source": source}) + "\n")
    (package / "colors.toml").write_text(
        'background = "#fafafa"\nforeground = "#101010"\n'
        + "".join(f'color{index} = "#{index:02x}00{index:02x}"\n' for index in range(16)))
    if ui_roles:
        (package / helper.UI_ROLES_FILE).write_text(ui_roles)
    return package


def test_declared_ui_roles_replace_the_derivation_without_a_contrast_rewrite():
    """A curated package declaring a UI role renders that role's own value.

    Every declarable role is otherwise derived from the palette with no way for a
    vendor to supply its own: `outline`, `outlineVariant`, `muted` and `dim` are
    a blend of background and foreground pulled toward black or white by the
    contrast guards, the surfaces and `statusBg` are a lightness shift of the
    background, `surface` and the `on*` accent companions are the background
    verbatim, and `secondary`, `tertiary` and the containers are tinted from the
    palette's own cyan, magenta and accent. A vendor that publishes its own UI
    palette could state none of them, so its chrome came out a grey the vendor
    never published.

    A declaration replaces the derivation for that one role: the guards report
    the shortfall on the apply result instead of rewriting the tone, roles
    computed from a declared one follow it, an undeclared role derives exactly as
    before, every key the file states is honoured or named, and a generated
    palette, which has no vendor behind it, ignores the file.
    """

    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        declared_roles_package(builtin, "plainroles")
        declared_roles_package(builtin, "vendorroles", DECLARED_UI_ROLES_TOML)
        declared_roles_package(builtin, "typoroles", 'statusBackground = "#123456"\n')
        # Neither value is a six-digit hex, so neither enters the parsed map and
        # only the parser knows the file named them.
        declared_roles_package(builtin, "badvalueroles",
                               'muted = "#fff"\nsurface = "steelblue"\ndim = "#123456"\n')
        # Every value unreadable, so the strict pass produces nothing at all.
        # The loose matugen fallback would run on that and hand back the
        # eight-digit value truncated, having already named the key unreadable.
        declared_roles_package(builtin, "alpharoles",
                               'statusBg = "#fadad1ff"\nmuted = "#fff"\n')
        declared_roles_package(builtin, "everyroles", "".join(
            f'{role} = "{EVERY_ROLE_VALUES[role]}"\n' for role in sorted(EVERY_ROLE_VALUES)))
        declared_roles_package(builtin, "greybarroles", 'statusBg = "#767676"\n')
        declared_roles_package(builtin, "pairroles",
                               'primaryContainer = "#78799a"\nonPrimaryContainer = "#d4e4fd"\n')
        # A container the shell's own foreground cannot be read on, and three
        # accent companions just off the derived role each is painted on.
        # The ordinary vendor shape: a fill declared, its text left derived. The
        # companion then derives to the foreground verbatim, so both of the
        # container's rules read the same colour.
        declared_roles_package(builtin, "lonecontainerroles", 'primaryContainer = "#2a2a2a"\n')
        declared_roles_package(builtin, "fgpairroles",
                               'primaryContainer = "#101010"\nonPrimaryContainer = "#fff5f0"\n'
                               'onPrimary = "#141414"\nonSecondary = "#141414"\n'
                               'onTertiary = "#141414"\n')
        declared_roles_package(builtin, "genroles", DECLARED_UI_ROLES_TOML, source="generated")
        declared_roles_package(builtin, "genplainroles", source="generated")
        helper.cfg_dir().mkdir(parents=True, exist_ok=True)
        (helper.cfg_dir() / "settings.json").write_text(json.dumps({"themeApps": {"tmux": True}}) + "\n")
        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        try:
            errors = io.StringIO()
            with contextlib.redirect_stderr(errors):
                packages = {name: helper.load_theme_package(name)
                            for name in ("plainroles", "vendorroles", "typoroles", "badvalueroles",
                                         "everyroles", "greybarroles", "pairroles", "genroles",
                                         "genplainroles", "alpharoles", "fgpairroles",
                                         "lonecontainerroles")}
            for name, blueprint in packages.items():
                if not blueprint:
                    raise AssertionError(f"fixture theme {name} did not load")
            assert_equal(packages["vendorroles"].get("uiRoles"), DECLARED_UI_ROLES,
                         "the loader carries every declared role and nothing else")
            assert_equal(packages["plainroles"].get("uiRoles"), {},
                         "a package declaring nothing carries no declared roles")
            # A misspelled role is named, not dropped in silence: the file's whole
            # purpose is that the vendor's tone reaches the chrome, and a silent
            # drop looks exactly like a package that declared nothing.
            assert_equal(packages["typoroles"].get("uiRoles"), {},
                         "a role VGS does not derive reaches no render")
            if "statusBackground" not in errors.getvalue():
                raise AssertionError(f"the undeclarable role was not named: {errors.getvalue()!r}")
            # A value no colour can be read from loses the role just as silently
            # as a misspelled key, and needs the same line.
            assert_equal(packages["badvalueroles"].get("uiRoles"), {"dim": "#123456"},
                         "a role whose value is not a colour reaches no render")
            assert_equal(packages["alpharoles"].get("uiRoles"), {},
                         "no pass revives a value the strict pass named unreadable")
            for package, roles in (("badvalueroles", "muted, surface"),
                                   ("alpharoles", "muted, statusBg")):
                line = f"theme package {package}: {helper.UI_ROLES_FILE} states no readable colour for: {roles}"
                if line not in errors.getvalue():
                    raise AssertionError(f"{package} did not name its unreadable values: {errors.getvalue()!r}")

            # The declarable set and the assignment sites are one list: every
            # member arrives verbatim, so a member with no site cannot hide.
            every = helper.target_roles(packages["everyroles"])
            for role, value in sorted(EVERY_ROLE_VALUES.items()):
                assert_equal(every[role], value, f"{role} is declarable and arrives verbatim")
            assert_equal(sorted(packages["everyroles"].get("uiRoles") or {}),
                         sorted(helper.DECLARABLE_UI_ROLES),
                         "the fixture declares the whole set the helper accepts")
            # The diagnostic behind that guarantee, driven directly because no
            # shipped reader hands the derivation a role outside the set: it is
            # the code's check on its own two lists, not a check on theme data.
            unread_errors = io.StringIO()
            with contextlib.redirect_stderr(unread_errors):
                helper.target_roles(dict(packages["vendorroles"], uiRoles={"errorContainer": "#123456"}))
            if "errorContainer" not in unread_errors.getvalue():
                raise AssertionError(
                    f"a declared role no derivation reads was not named: {unread_errors.getvalue()!r}")
            # Pinned silent as well as firing: every declared role has an
            # assignment site, so an ordinary render says nothing.
            quiet = io.StringIO()
            with contextlib.redirect_stderr(quiet):
                helper.target_roles(packages["everyroles"])
                helper.target_roles(packages["vendorroles"])
            if "no derivation reads" in quiet.getvalue():
                raise AssertionError(f"a declaring package rendered with a diagnostic: {quiet.getvalue()!r}")

            plain, vendor = (helper.target_roles(packages["plainroles"]),
                             helper.target_roles(packages["vendorroles"]))
            # The control the whole feature rests on: the derivation's own answer
            # for this palette is a grey, so an assertion that the declared value
            # arrives cannot pass by accident.
            for role, value in DECLARED_UI_ROLES.items():
                if plain[role] == value:
                    raise AssertionError(f"{role} derives to the declared value; the fixture proves nothing")
                assert_equal(vendor[role], value, f"{role} is written as declared")
            assert_equal(helper.app_target_roles(packages["vendorroles"], vendor)["statusBg"],
                         DECLARED_UI_ROLES["statusBg"],
                         "app targets take the declared role, not the derived one")
            assert_equal(helper.target_roles(packages["genroles"])["statusBg"], plain["statusBg"],
                         "a generated palette derives its roles whatever the file declares")
            assert_equal(packages["genroles"].get("uiRoles"), {},
                         "a generated package folds no declaration into its identity")
            for role in ("outline", "outlineVariant", "dim", "secondary", "surfaceContainerLow"):
                assert_equal(vendor[role], plain[role], f"{role} is undeclared and derives as before")
            # A role computed from a declared one follows it, or the status bar
            # gets text measured against a background it no longer paints.
            if vendor["statusMuted"] == plain["statusMuted"]:
                raise AssertionError("statusMuted was measured against the derived status background")
            if helper.contrast_ratio(vendor["statusFg"], vendor["statusBg"]) < 7.0:
                raise AssertionError("status text is unreadable on the declared status background")

            # The guard reports and does not rewrite: the declared `muted` misses
            # its 4.5:1 rule, is written as declared, and is named once on the apply.
            missed = helper.ui_role_shortfalls(vendor, DECLARED_UI_ROLES)
            assert_equal(len(missed), 1, f"one declared role misses a rule: {missed}")
            if "muted" not in missed[0] or DECLARED_UI_ROLES["muted"] not in missed[0]:
                raise AssertionError(f"the shortfall names neither the role nor its value: {missed[0]}")
            assert_equal(helper.ui_role_shortfalls(plain, {}), [],
                         "a package declaring nothing reports no shortfall")
            with contextlib.redirect_stderr(io.StringIO()):
                applied = helper.apply_theme_obj(packages["vendorroles"], only_target="tmux-vgs",
                                                 run_hooks=False)
            warnings = [line for line in applied["warnings"] if "declared UI roles" in line]
            assert_equal(len(warnings), 1, f"one apply warning names the declared shortfalls: {applied['warnings']}")
            if missed[0] not in warnings[0]:
                raise AssertionError(f"the apply warning drops the shortfall: {warnings[0]}")
            assert_equal(applied["partial"], True, "a declared role below its rule makes the apply partial")
            rendered = Path(applied["rendered"][0]).read_text()
            if f"bg={DECLARED_UI_ROLES['statusBg']}" not in rendered:
                raise AssertionError(f"tmux does not paint the declared status background: {rendered}")

            # A fill and the text on it are judged as the pair the render paints.
            # Against the palette's foreground instead, this container passes and
            # its own declared text sits on it unreadably.
            pair_roles = helper.target_roles(packages["pairroles"])
            pair_missed = helper.ui_role_shortfalls(pair_roles, helper.declared_ui_roles(packages["pairroles"]))
            assert_equal(sorted(line.split()[0] for line in pair_missed),
                         ["onPrimaryContainer", "primaryContainer"],
                         f"each side of a declared pair names the other: {pair_missed}")
            for line in pair_missed:
                if "background" in line or "foreground" in line:
                    raise AssertionError(f"a container pair was judged against the palette: {line}")

            # The vgs-shell target exports no on*Container role and still draws
            # the palette's own foreground on these fills, so a container keeps
            # that rule beside its companion rule. Judged against the companion
            # alone, this fill carries shell text at 1:1 and nothing is named.
            fg_bp = packages["fgpairroles"]
            fg_roles = helper.target_roles(fg_bp)
            fg_missed = helper.ui_role_shortfalls(fg_roles, helper.declared_ui_roles(fg_bp))
            measured = sorted((line.split()[0], line.split(" against ")[1].split()[0])
                              for line in fg_missed)
            assert_equal(measured,
                         [("onPrimary", "primary"), ("onSecondary", "secondary"),
                          ("onTertiary", "tertiary"), ("primaryContainer", "foreground")],
                         f"every rule a declared role carries is measured: {fg_missed}")
            with contextlib.redirect_stderr(io.StringIO()):
                fg_applied = helper.apply_theme_obj(fg_bp, only_target="tmux-vgs", run_hooks=False)
            assert_equal(fg_applied["partial"], True,
                         "a declared role below any of its rules makes the apply partial")

            # One fill-and-text pair, one line: both rules land on the same
            # colour here, and one defect named twice is one defect.
            lone = packages["lonecontainerroles"]
            lone_missed = helper.ui_role_shortfalls(helper.target_roles(lone), helper.declared_ui_roles(lone))
            assert_equal(len(lone_missed), 1,
                         f"a container declared without its companion is named once: {lone_missed}")
            if not lone_missed[0].startswith("primaryContainer #2a2a2a: 1.33:1 against foreground"):
                raise AssertionError(f"the lone container line is wrong: {lone_missed[0]}")

            # A mid-grey status bar carries no readable text at all, which is the
            # one rule measured against black and white rather than a role.
            grey_roles = helper.target_roles(packages["greybarroles"])
            grey_missed = helper.ui_role_shortfalls(grey_roles, helper.declared_ui_roles(packages["greybarroles"]))
            assert_equal(len(grey_missed), 1, f"the grey status background is named once: {grey_missed}")
            if not grey_missed[0].startswith("statusBg #767676: no text reaches"):
                raise AssertionError(f"the statusBg rule did not fire: {grey_missed[0]}")
            with contextlib.redirect_stderr(io.StringIO()):
                grey_applied = helper.apply_theme_obj(packages["greybarroles"], only_target="tmux-vgs",
                                                      run_hooks=False)
            assert_equal(grey_applied["partial"], True,
                         "an unreadable declared status background makes the apply partial")

            # The control on the curated gate: the same file under a generated
            # source paints nothing and so must warn about nothing.
            with contextlib.redirect_stderr(io.StringIO()):
                gen_applied = helper.apply_theme_obj(packages["genroles"], only_target="tmux-vgs",
                                                     run_hooks=False)
            assert_equal([line for line in gen_applied["warnings"] if "below target" in line], [],
                         "a generated palette reports no shortfall for a file it does not read")
            assert_equal(len([line for line in gen_applied["warnings"] if "is not read" in line]), 1,
                         "it names the unread file instead")
        finally:
            helper.builtin_themes_dir = original_builtin

    with_temp_home(scenario)


def test_declared_ui_roles_move_with_a_restyle_and_survive_a_save():
    """Declared roles are part of a package's palette identity.

    They move with a restyle slider the way explicit terminal slots do, so the
    chrome stays coherent with the restyled palette; a rebuild from the applied
    theme carries them, or a wallpaper change or a saved colour edit would write
    the package back without them; and the `curatedPalette` digest covers them,
    because a merge-style curated file's bands are picked against the roles it
    merges over and a declaration replaces one of those roles.
    """

    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        declared_roles_package(builtin, "restyled", DECLARED_UI_ROLES_TOML)
        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        try:
            shipped = helper.load_theme_package("restyled") or {}
            (builtin / "restyled" / "theme.json").write_text(json.dumps(
                {"name": "restyled", "mode": "light", "source": "curated",
                 "adjustments": {"brightness": -60}}) + "\n")
            restyled = helper.load_theme_package("restyled") or {}
            assert_equal(sorted(restyled.get("uiRoles") or {}), sorted(DECLARED_UI_ROLES),
                         "a restyle keeps every declared role")
            moved = [role for role, value in (restyled.get("uiRoles") or {}).items()
                     if value != DECLARED_UI_ROLES[role]]
            assert_equal(sorted(moved), sorted(DECLARED_UI_ROLES),
                         "a restyle moves every declared role with the palette")
            assert_equal(helper.target_roles(restyled)["statusBg"], restyled["uiRoles"]["statusBg"],
                         "the restyled declaration is what the render paints")

            # A merge-style curated file is judged against the palette it was
            # picked for. Declared roles sit inside that palette's identity, so a
            # package whose declarations moved no longer carries the file.
            package = declared_roles_package(helper.user_themes_dir(), "digestroles",
                                             DECLARED_UI_ROLES_TOML)
            (package / "apps").mkdir(exist_ok=True)
            (package / "apps" / "claude-light.json").write_text(json.dumps({"overrides": {}}) + "\n")
            meta = json.loads((package / "theme.json").read_text())
            meta["curatedPalette"] = helper.palette_digest(helper.package_palette(
                helper.package_colors_map("digestroles"), meta,
                helper.package_overlay_values("digestroles", helper.UI_ROLES_FILE)))
            (package / "theme.json").write_text(json.dumps(meta) + "\n")
            assert_equal(sorted((helper.load_theme_package("digestroles") or {}).get("apps") or {}),
                         ["claude-light.json"], "the recorded palette carries the curated file")
            # The mtime of this file orders the theme list, so an edit to it
            # alone has to advance the package's stamp.
            before_stamp = (helper.load_theme_package("digestroles") or {}).get("timestamp")
            os.utime(package / helper.UI_ROLES_FILE,
                     (time.time() + 120, time.time() + 120))
            if (helper.load_theme_package("digestroles") or {}).get("timestamp") == before_stamp:
                raise AssertionError("an edit to the declarations alone left the stamp where it was")

            # A duplicate flattens both layers into one directory and records the
            # digest of the copy's own palette. Built without the declarations,
            # that digest certifies nothing the copy carries and the curated file
            # is left behind, which is the VGS-314 symptom.
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["duplicate", "digestroles", "--as", "digestroles-copy"]), 0,
                             "duplicate exit status")
            assert_equal(sorted((helper.load_theme_package("digestroles-copy") or {}).get("apps") or {}),
                         ["claude-light.json"], "a duplicate keeps the curated file its record vouches for")
            assert_equal((helper.load_theme_package("digestroles-copy") or {}).get("uiRoles"),
                         DECLARED_UI_ROLES, "a duplicate carries the declarations")

            # The save's exemption asks the same question over the package on
            # disk. Asked without the declarations, the file reads as dropped by
            # the palette rather than by the override and the prune deletes it.
            helper.write_user_layer("digestroles", "app-colors.toml", {"claude": {"background": "#0b0b0b"}})
            dropped = helper.load_theme_package("digestroles") or {}
            assert_equal(sorted(dropped.get("apps") or {}), [],
                         "the per-app override alone keeps the curated file out of the render")
            rebuilt = helper.blueprint_from_theme_json(
                helper.theme_json_from_blueprint(dropped), name="digestroles")
            rebuilt.update({"package": True, "path": str(helper.user_themes_dir() / "digestroles")})
            assert_equal(helper.save_curated_terms(rebuilt),
                         (False, ["claude-light.json"]),
                         "the save vouches for a file the override alone dropped")
            # A package whose theme.json does not read says nothing about what its
            # curated files were picked against, so the save hands in none of them
            # and vouches for none.
            unreadable = helper.user_themes_dir() / "digestroles" / "theme.json"
            readable = unreadable.read_text()
            unreadable.write_text("{ not json")
            try:
                assert_equal(helper.save_curated_terms(rebuilt), (True, []),
                             "a package whose metadata does not read is parted with nothing vouched")
            finally:
                unreadable.write_text(readable)

            # Clear the override first, or the next row would pass on the
            # override's own drop and say nothing about the digest.
            helper.write_user_layer("digestroles", "app-colors.toml", {})
            assert_equal(sorted((helper.load_theme_package("digestroles") or {}).get("apps") or {}),
                         ["claude-light.json"], "clearing the override brings the curated file back")
            (package / helper.UI_ROLES_FILE).write_text('statusBg = "#e0b0a0"\n')
            assert_equal(sorted((helper.load_theme_package("digestroles") or {}).get("apps") or {}),
                         [], "a changed declaration drops the file picked for the old one")

            # `save-current` rebuilds the theme from the shell's theme.json, which
            # carries no declared roles, so the rebuild has to carry them forward.
            helper.cfg_dir().mkdir(parents=True, exist_ok=True)
            (helper.cfg_dir() / "theme.json").write_text(helper.render_target_template(
                "vgs-shell", "vgs-theme.json", helper.target_roles(shipped)))
            (helper.cfg_dir() / "theme-current.json").write_text(
                json.dumps(helper.applied_theme_state(shipped)) + "\n")
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["save-current", "--name", "restyled-saved"]), 0,
                             "save-current exit status")
            saved = helper.load_theme_package("restyled-saved") or {}
            assert_equal(saved.get("uiRoles"), DECLARED_UI_ROLES,
                         "a save carries the declared roles onto the saved package")
            assert_equal((helper.user_themes_dir() / "restyled-saved" / helper.UI_ROLES_FILE).is_file(),
                         True, "the saved package writes the file the loader reads")
            # The other half of the invariant: a CURATED save stating no
            # declarations does own the file, and removes or masks it.
            # colors.toml is rewritten on every save, so a stale declaration file
            # would paint the previous theme's chrome over this one.
            helper.save_theme_package(dict(shipped, uiRoles={}), "restyled-saved")
            assert_equal((helper.user_themes_dir() / "restyled-saved" / helper.UI_ROLES_FILE).exists(),
                         False, "a save with no declared roles removes the stale file")
            helper.save_theme_package(dict(shipped, uiRoles={}), "restyled")
            with contextlib.redirect_stderr(io.StringIO()):
                masked = helper.load_theme_package("restyled") or {}
            assert_equal(masked.get("uiRoles"), {},
                         "a save with no declared roles masks the built-in file")

            # `apply-colors --save` rebuilds through palette_from_colors_map,
            # whose source is generated, so its render reads no declaration. The
            # save must write none either, or the file sits inert while the
            # recorded digest counts it and a later edit to it drops the
            # package's curated files.
            declared_roles_package(builtin, "editedroles", DECLARED_UI_ROLES_TOML)
            reference = helper.load_theme_package("editedroles") or {}
            (helper.cfg_dir() / "theme-current.json").write_text(
                json.dumps(helper.applied_theme_state(reference)) + "\n")
            original_apply = helper.apply_theme_obj
            helper.apply_theme_obj = lambda bp, *args, **kwargs: {"success": True}
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    assert_equal(helper.cmd_theme(
                        ["apply-colors", "--name", "editedroles-saved",
                         "--set", "accent=#123456", "--save"]), 0, "apply-colors --save exit status")
            finally:
                helper.apply_theme_obj = original_apply
            saved_root = helper.user_themes_dir() / "editedroles-saved"
            assert_equal((saved_root / helper.UI_ROLES_FILE).exists(), False,
                         "a generated save writes no declarations file")
            saved_meta = json.loads((saved_root / "theme.json").read_text())
            assert_equal(saved_meta["curatedPalette"], helper.palette_digest(helper.palette_identity(
                helper.parse_colors_toml_text((saved_root / "colors.toml").read_text()),
                saved_meta["mode"])),
                "the recorded digest counts no declaration the render does not read")
            assert_equal((helper.load_theme_package("editedroles-saved") or {}).get("uiRoles"), {},
                         "the saved package carries no declarations")
            assert_equal(helper.package_overlay_values("editedroles", helper.UI_ROLES_FILE), DECLARED_UI_ROLES,
                         "the source package keeps its own declarations file")

            # The invariant, at every route that builds a generated blueprint
            # and hands it to the save. A marker carried by one of them closed
            # that one and left the rest: the second own-name save found none,
            # and the wallpaper routes never carried one at all.
            declared_roles_package(helper.user_themes_dir(), "downloadedroles",
                                   DECLARED_UI_ROLES_TOML)
            from PIL import Image
            wallpaper = temp_home / "extract.png"
            Image.new("RGB", (2, 2), (33, 88, 144)).save(wallpaper)
            # (package, the layer directory holding its file, the argv the route runs)
            routes = [
                ("editedroles", builtin,
                 ["apply-colors", "--name", "editedroles", "--set", "foreground=#101010", "--save"]),
                ("editedroles", builtin,
                 ["apply-colors", "--name", "editedroles", "--set", "foreground=#111111", "--save"]),
                ("downloadedroles", helper.user_themes_dir(),
                 ["apply-colors", "--name", "downloadedroles", "--set", "foreground=#101010", "--save"]),
                ("downloadedroles", helper.user_themes_dir(),
                 ["apply-colors", "--name", "downloadedroles", "--set", "foreground=#111111", "--save"]),
                ("downloadedroles", helper.user_themes_dir(),
                 ["set-wallpaper", str(wallpaper), "--extract", "--save", "--name", "downloadedroles"]),
            ]
            for index, (name, layer, argv) in enumerate(routes):
                own = helper.load_theme_package(name) or {}
                (helper.cfg_dir() / "theme.json").write_text(helper.render_target_template(
                    "vgs-shell", "vgs-theme.json", helper.target_roles(own)))
                (helper.cfg_dir() / "theme-current.json").write_text(
                    json.dumps(helper.applied_theme_state(own)) + "\n")
                helper.apply_theme_obj = lambda bp, *args, **kwargs: {"success": True}
                try:
                    with contextlib.redirect_stdout(io.StringIO()):
                        assert_equal(helper.cmd_theme(argv), 0, f"{argv[0]} {index} exit status")
                finally:
                    helper.apply_theme_obj = original_apply
                where = f"{name} through {argv[0]} at step {index}"
                assert_equal((layer / name / helper.UI_ROLES_FILE).is_file(), True,
                             f"{where} keeps its declarations file")
                assert_equal(helper.package_overlay_values(name, helper.UI_ROLES_FILE),
                             DECLARED_UI_ROLES, f"{where} keeps every declared role")
                assert_equal((helper.load_theme_package(name) or {}).get("uiRoles"), {},
                             f"{where} reads no declaration while its palette is generated")

            # Nothing on screen says the chrome is derived rather than declared,
            # so the apply names the unread file once.
            generated = helper.load_theme_package("downloadedroles") or {}
            with contextlib.redirect_stderr(io.StringIO()):
                inert_applied = helper.apply_theme_obj(generated, only_target="tmux-vgs",
                                                       run_hooks=False)
            named = [line for line in inert_applied["warnings"] if "is not read" in line]
            assert_equal(len(named), 1, f"the unread file is named once: {inert_applied['warnings']}")
            if helper.UI_ROLES_FILE not in named[0]:
                raise AssertionError(f"the warning does not name the file: {named[0]}")
            assert_equal(inert_applied["partial"], True, "an unread declarations file makes the apply partial")
            with contextlib.redirect_stderr(io.StringIO()):
                curated_applied = helper.apply_theme_obj(shipped, only_target="tmux-vgs",
                                                         run_hooks=False)
            assert_equal([line for line in curated_applied["warnings"] if "is not read" in line], [],
                         "a curated apply reads its declarations and names nothing")

            # It is a file with declarations in it that goes unread, not any
            # file. The masking overlay this same save path writes, and a file
            # whose every value is unreadable, both state nothing: naming them
            # reported chrome the palette never had, on every colour edit.
            # (package, the user-layer ui-roles.toml body that states nothing)
            silent = (("maskedroles", "# No declared UI roles: this overlay masks the built-in theme's.\n"),
                      ("unreadableroles", 'statusBg = "#fadad1ff"\nmuted = "#fff"\n'))
            for name, body in silent:
                declared_roles_package(builtin, name, DECLARED_UI_ROLES_TOML)
                overlay = helper.user_themes_dir() / name
                overlay.mkdir(parents=True, exist_ok=True)
                (overlay / "theme.json").write_text(json.dumps(
                    {"name": name, "mode": "light", "source": "generated"}) + "\n")
                (overlay / helper.UI_ROLES_FILE).write_text(body)
                with contextlib.redirect_stderr(io.StringIO()):
                    quiet_bp = helper.load_theme_package(name) or {}
                    quiet = helper.apply_theme_obj(quiet_bp, only_target="tmux-vgs", run_hooks=False)
                assert_equal([line for line in quiet["warnings"] if "is not read" in line], [],
                             f"{name} states no declaration, so nothing is named unread")
                assert_equal(quiet["partial"], False,
                             f"{name} does not make every apply partial over a file that states nothing")
                assert_equal(helper.inert_declarations_path(quiet_bp), "",
                             f"{name} has no unread declarations file")

            # The path named is the one the loader reads. A user overlay shadows
            # the built-in copy, and naming the shadowed one sends a user to a
            # file that changes nothing.
            shadow = helper.user_themes_dir() / "downloadedroles"
            (shadow / "theme.json").write_text(json.dumps(
                {"name": "downloadedroles", "mode": "light", "source": "generated"}) + "\n")
            declared_roles_package(builtin, "downloadedroles", 'statusBg = "#010203"\n')
            with contextlib.redirect_stderr(io.StringIO()):
                shadowed = helper.load_theme_package("downloadedroles") or {}
            assert_equal(helper.inert_declarations_path(shadowed),
                         str(shadow / helper.UI_ROLES_FILE),
                         "the unread file named is the overlay the loader reads, not the built-in copy")
        finally:
            helper.builtin_themes_dir = original_builtin

    with_temp_home(scenario)


def test_save_keeps_app_overrides():
    """A saved theme keeps the per-app colours the user set on the theme it was
    saved from, and its editable app files, a regenerated file and an edit-app
    seed render them. A rebuild from the shell state carries the overrides of the
    package named exactly as the applied theme; a blueprint with no package keeps
    the destination's."""
    overrides = {"kitty": {"background": "#ff0000"}, "ghostty": {"black": "#ff0022"}}

    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        for name, app_colors in (("overfix", '[kitty]\nbackground = "#ff0000"\n\n[ghostty]\nblack = "#ff0022"\n'),
                                 ("plainfix", "")):
            package = builtin / name
            package.mkdir(parents=True)
            (package / "theme.json").write_text(
                json.dumps({"name": name, "mode": "dark", "source": "curated"}) + "\n")
            (package / "colors.toml").write_text('background = "#101010"\nforeground = "#eeeeee"\n')
            if app_colors:
                (package / "app-colors.toml").write_text(app_colors)
        helper.cfg_dir().mkdir(parents=True, exist_ok=True)
        (helper.cfg_dir() / "settings.json").write_text(
            json.dumps({"themeApps": {"kitty": True, "ghostty": True}}) + "\n")
        original_builtin, original_apply = helper.builtin_themes_dir, helper.apply_theme_obj
        helper.builtin_themes_dir = lambda: builtin
        # apply-colors applies before it saves, and a real apply runs hooks that
        # reach the login session; these rows measure the saved package.
        helper.apply_theme_obj = lambda bp, *args, **kwargs: {"success": True}
        mine = helper.user_themes_dir() / "mine"

        def apply_state(name, applied_name=None):
            blueprint = dict(helper.load_theme_package(name), name=applied_name or name)
            (helper.cfg_dir() / "theme.json").write_text(helper.render_target_template(
                "vgs-shell", "vgs-theme.json", helper.target_roles(blueprint)))
            (helper.cfg_dir() / "theme-current.json").write_text(json.dumps(
                {key: value for key, value in blueprint.items()
                 if key not in ("path", "builtin", "userDir", "backgrounds", "packagedPreview")}) + "\n")

        def run(argv):
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(argv), 0, f"{' '.join(argv)} exit status")

        try:
            apply_state("overfix")
            imported = temp_home / "imported.toml"
            imported.write_text('background = "#202020"\nforeground = "#dddddd"\n')
            # Each row runs and is checked before the next, since a later save
            # rewrites the files an earlier row wrote.
            # (label, argv, package, app file the step writes, colour that file carries)
            steps = [
                ("save-current from the overridden theme", ["save-current", "--name", "mine"],
                 "mine", "kitty.conf", "#ff0000"),
                ("save-current from the overridden theme", None, "mine", "ghostty.conf", "#ff0022"),
                ("regenerate", ["regenerate", "mine", "--app", "kitty", "--yes"],
                 "mine", "kitty.conf", "#ff0000"),
                ("edit-app seed", ["edit-app", "kitty", "--theme", "overfix"],
                 "overfix", "kitty.conf", "#ff0000"),
                # A palette edit rebuilds from the applied theme, so a new name
                # holding no overrides yet takes the applied package's.
                ("apply-colors --save into a new name",
                 ["apply-colors", "--name", "fresh", "--set", "accent=#123456", "--save"],
                 "fresh", "kitty.conf", "#ff0000"),
                # An import has no package and no applied theme behind it, and must
                # not erase the overrides the package it is saved over holds.
                ("import-colors over the package", ["import-colors", str(imported), "--name", "mine"],
                 "mine", "kitty.conf", "#ff0000"),
                # A blueprint with its own package and nothing carried takes that
                # package's overrides.
                ("a package saved under a new name",
                 lambda: helper.save_theme_package(helper.load_theme_package("overfix"), "copy"),
                 "copy", "kitty.conf", "#ff0000"),
            ]
            for label, step, package, filename, colour in steps:
                path = helper.user_themes_dir() / package / "apps" / filename
                if step:
                    # A file the step leaves alone would pass on what the previous
                    # step wrote.
                    path.unlink(missing_ok=True)
                    run(step) if isinstance(step, list) else step()
                assert_equal(helper.theme_app_overrides(package), overrides, f"{label}: saved overrides")
                if colour not in path.read_text():
                    raise AssertionError(f"{label}: {filename} lacks {colour}")

            # Overrides were chosen against the applied background, so a rebuild
            # into the other mode carries none.
            run(["apply-colors", "--name", "lightcopy", "--mode", "light", "--set", "accent=#123456", "--save"])
            lightcopy = helper.user_themes_dir() / "lightcopy"
            assert_equal(helper.blueprint_mode(helper.load_theme_package("lightcopy")), "light",
                         "apply-colors --mode light saves a light rebuild")
            assert_equal((lightcopy / "app-colors.toml").exists(), False,
                         "a rebuild into the other mode carries no overrides")
            if "#ff0000" in (lightcopy / "apps" / "kitty.conf").read_text():
                raise AssertionError("a rebuild into the other mode still renders #ff0000")

            # Saved from a theme with no overrides, the package keeps none.
            apply_state("plainfix")
            run(["save-current", "--name", "mine"])
            assert_equal((mine / "app-colors.toml").exists(), False,
                         "save-current from a theme with no overrides removes the file")
            if "#ff0000" in (mine / "apps" / "kitty.conf").read_text():
                raise AssertionError("save-current from a theme with no overrides still renders #ff0000")

            # Applied under an unsaved name that is part of an overridden package's
            # name, the theme has no package, so nothing is carried.
            apply_state("plainfix", applied_name="over")
            wallpaper = temp_home / "wall.png"
            wallpaper.write_bytes(b"\x89PNG\r\n\x1a\n")
            # (command, argv, the package it saves)
            for label, argv, package in (
                ("save-current", ["save-current", "--name", "prefixed"], "prefixed"),
                ("set-wallpaper --save", ["set-wallpaper", str(wallpaper), "--save"], "over"),
            ):
                run(argv)
                assert_equal(helper.theme_app_overrides(package), {},
                             f"{label} from an unsaved name takes no other package's overrides")
        finally:
            helper.builtin_themes_dir, helper.apply_theme_obj = original_builtin, original_apply

    with_temp_home(scenario)


def test_theme_overlays_merge_key_by_key():
    """A user overlay of a built-in theme holds only the keys the user set, so a
    later change to the built-in files reaches every other key; `theme init`
    shrinks a whole-file overlay to that difference and leaves a fork whole. A
    save or copy under a built-in theme's name loads its source's terminal slots."""
    palette = {"accent": "#7aa2f7", "cursor": "#c0caf5", "foreground": "#c0caf5",
               "background": "#1a1b26", "selection_foreground": "#c0caf5",
               "selection_background": "#283457",
               **{f"color{i}": f"#{i:02x}{i:02x}{i:02x}" for i in range(16)}}

    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        package = builtin / "keyfix"
        package.mkdir(parents=True)
        (package / "theme.json").write_text(
            json.dumps({"name": "keyfix", "mode": "dark", "source": "curated"}) + "\n")

        def write_builtin(colors=None, slots=None, apps=None):
            (package / "colors.toml").write_text(helper.flat_toml_text(colors or palette))
            (package / helper.TERMINAL_COLORS_FILE).write_text(
                helper.flat_toml_text(slots or {"color1": "#aa0000"}))
            (package / "app-colors.toml").write_text(helper.app_overrides_toml_text(
                apps or {"kitty": {"background": "#101010", "foreground": "#eeeeee"}}))

        write_builtin()
        user = helper.user_themes_dir() / "keyfix"
        original_builtin, original_apply = helper.builtin_themes_dir, helper.apply_theme_obj
        helper.builtin_themes_dir = lambda: builtin
        # A real apply runs hooks that reach the login session; these rows read
        # the files the writers leave and the package the loader composes.
        helper.apply_theme_obj = lambda bp, *args, **kwargs: {"success": True}

        def overlay(filename):
            path = user / filename
            return helper.parse_colors_toml(path, allow_empty=True) if path.exists() else None

        def loaded():
            bp = helper.load_theme_package("keyfix")
            return bp["palette"]["extendedColors"]["accent"], bp["palette"]["colors"][4], bp["terminalColors"]

        try:
            with contextlib.redirect_stdout(io.StringIO()):
                helper.persist_color_edits(["accent=#123456"], "keyfix")
            assert_equal(overlay("colors.toml"), {"accent": "#123456"},
                         "a colour edit writes only the key it set")
            with contextlib.redirect_stdout(io.StringIO()):
                helper.persist_color_edits(["cursor=#654321"], "keyfix")
            assert_equal(overlay("colors.toml"), {"accent": "#123456", "cursor": "#654321"},
                         "a second edit keeps the key the overlay already held")
            write_builtin(colors={**palette, "color4": "#445566", "accent": "#abcdef"})
            assert_equal(loaded()[:2], ("#123456", "#445566"),
                         "a built-in change reaches color4 and leaves the overlay's accent")
            with contextlib.redirect_stdout(io.StringIO()):
                helper.persist_color_edits(["accent=#abcdef", "cursor=#c0caf5", "blue=#222222"], "keyfix")
            assert_equal(overlay("colors.toml"), {"color4": "#222222"},
                         "an edit back to the built-in value drops the key; an ANSI name lands as colorN")
            write_builtin()

            builtin_meta = {"name": "keyfix", "mode": "dark", "pair": "keylight", "source": "curated",
                            "curatedPalette": "builtin-digest"}
            (package / "theme.json").write_text(json.dumps(builtin_meta) + "\n")

            def user_meta():
                path = user / "theme.json"
                return json.loads(path.read_text()) if path.exists() else None

            def set_pair(pair):
                with contextlib.redirect_stdout(io.StringIO()):
                    assert_equal(helper.cmd_theme(["set-pair", "keyfix", pair]), 0, "set-pair exit status")

            set_pair("keyother")
            stored_pair = user_meta()
            (package / "theme.json").write_text(json.dumps({**builtin_meta, "source": "generated"}) + "\n")
            merged_after_update = helper.package_meta("keyfix")
            (package / "theme.json").write_text(json.dumps(builtin_meta) + "\n")
            set_pair("keylight")
            pair_cleared = user_meta()
            (user / "theme.json").write_text(json.dumps({"curatedPalette": "user-digest", "pair": "keyother"}) + "\n")
            set_pair("keylight")
            own_record = user_meta()
            (user / "apps").mkdir()
            (user / "apps" / "claude-dark.json").write_text("{}\n")
            (user / "theme.json").write_text(json.dumps({**builtin_meta, "pair": "keyother"}) + "\n")
            set_pair("keylight")
            record_for_apps = user_meta()
            shutil.rmtree(user / "apps")
            # (what, actual, expected)
            meta_rows = [
                ("a metadata edit stores only the key it set, and no built-in record",
                 stored_pair, {"pair": "keyother"}),
                ("a built-in source change reaches a paired theme beside the user's pair",
                 {key: merged_after_update[key] for key in ("pair", "source")},
                 {"pair": "keyother", "source": "generated"}),
                ("the merged metadata carries no layer's curatedPalette",
                 "curatedPalette" in merged_after_update, False),
                ("an edit back to the built-in value removes the overlay", pair_cleared, None),
                ("an edit keeps the user layer's own record", own_record, {"curatedPalette": "user-digest"}),
                ("a record equal to the built-in one stays while a user apps file needs it",
                 record_for_apps, {"curatedPalette": "builtin-digest"}),
            ]
            for what, actual, expected in meta_rows:
                assert_equal(actual, expected, what)
            (user / "theme.json").unlink()

            helper.write_user_layer("keyfix", "app-colors.toml", {"kitty": {"background": "#101010", "cursor": "#abcdef"}})
            assert_equal(helper.read_user_app_overrides("keyfix"), {"kitty": {"cursor": "#abcdef"}},
                         "an app override equal to the built-in role is not stored")
            write_builtin(apps={"kitty": {"background": "#101010", "foreground": "#dddddd"}})
            assert_equal(helper.theme_app_overrides("keyfix"),
                         {"kitty": {"background": "#101010", "foreground": "#dddddd", "cursor": "#abcdef"}},
                         "a built-in app role change reaches the merged overrides beside the user's role")

            # (what, user terminal file, loaded slots)
            terminal_rows = [
                ("a marked terminal file merges slot by slot",
                 helper.OVERLAY_MERGE_LINE + 'color2 = "#00bb00"\n', {"color1": "#cc0000", "color2": "#00bb00"}),
                ("an unmarked terminal file replaces the built-in slots",
                 'color2 = "#00bb00"\n', {"color2": "#00bb00"}),
            ]
            write_builtin(slots={"color1": "#cc0000"})
            for what, text, expected in terminal_rows:
                (user / helper.TERMINAL_COLORS_FILE).write_text(text)
                assert_equal(loaded()[2], expected, what)
            write_builtin()

            # Whole-file overlays as the writers left them before the merge, and a
            # fork with no built-in layer under it.
            (user / "theme.json").write_text(json.dumps({**builtin_meta, "pair": "keyother"}) + "\n")
            (user / "colors.toml").write_text(helper.flat_toml_text({**palette, "accent": "#123456"}))
            (user / helper.TERMINAL_COLORS_FILE).write_text(helper.flat_toml_text({"color1": "#aa0000"}))
            (user / "app-colors.toml").write_text(helper.app_overrides_toml_text(
                {"kitty": {"background": "#101010", "foreground": "#eeeeee", "cursor": "#abcdef"}}))
            fork = helper.user_themes_dir() / "forkfix"
            fork.mkdir(parents=True)
            (fork / "theme.json").write_text(json.dumps({"name": "forkfix", "mode": "dark"}) + "\n")
            fork_colors = helper.flat_toml_text(palette)
            (fork / "colors.toml").write_text(fork_colors)
            digest_before = helper.palette_digest(helper.package_palette(
                helper.package_colors_map("keyfix"), {"mode": "dark"}))
            # An applied theme, so init runs the shrink and applies nothing.
            helper.cfg_dir().mkdir(parents=True, exist_ok=True)
            (helper.cfg_dir() / "theme.json").write_text('{"name": "keyfix", "mode": "dark"}\n')
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["init", "--json"]), 0, "theme init exit status")
            # (what, actual, expected)
            rows = [
                ("a theme.json overlay shrinks to its difference, without the copied built-in record",
                 user_meta(), {"pair": "keyother"}),
                ("the colours overlay shrinks to its difference", overlay("colors.toml"), {"accent": "#123456"}),
                ("a terminal overlay equal to the built-in file is removed",
                 (user / helper.TERMINAL_COLORS_FILE).exists(), False),
                ("an app-colors overlay shrinks to its differing role",
                 helper.read_user_app_overrides("keyfix"), {"kitty": {"cursor": "#abcdef"}}),
                ("a fork is left whole", (fork / "colors.toml").read_text(), fork_colors),
                ("the merged palette digest is unchanged", helper.palette_digest(helper.package_palette(
                    helper.package_colors_map("keyfix"), {"mode": "dark"})), digest_before),
            ]
            for what, actual, expected in rows:
                assert_equal(actual, expected, what)
            set_pair("keylight")
            assert_equal(user_meta(), None, "undoing a shrunk overlay's last edit removes its theme.json")

            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["duplicate", "keyfix", "--as", "keycopy"]), 0, "duplicate exit status")
            # (what, copy, source)
            copy_rows = [
                ("a copy carries the merged palette",
                 helper.package_colors_map("keycopy"), helper.package_colors_map("keyfix")),
                ("a copy carries the terminal slots",
                 helper.load_theme_package("keycopy")["terminalColors"], helper.package_overlay_values("keyfix", helper.TERMINAL_COLORS_FILE)),
                ("a copy carries the merged app overrides",
                 helper.theme_app_overrides("keycopy"), helper.theme_app_overrides("keyfix")),
            ]
            for what, actual, expected in copy_rows:
                assert_equal(actual, expected, what)

            # Saves under the built-in theme's own name, with no theme init after.
            base = helper.load_theme_package("keyfix")
            helper.save_theme_package(base, "keyfix")
            write_builtin(colors={**palette, "color4": "#445566"})
            assert_equal((overlay("colors.toml"), loaded()[1]), ({"accent": "#123456"}, "#445566"),
                         "a save under the built-in name stores its difference, so a built-in change reaches it")
            assert_equal(sorted(set(user_meta()) & {"name", "mode", "pair", "source"}), [],
                         "a save under the built-in name stores no metadata equal to the built-in file")
            (package / "backgrounds").mkdir()
            (package / "backgrounds" / "built.jpg").write_bytes(b"built")
            (package / "theme.json").write_text(json.dumps(
                {**builtin_meta, "wallpaper": "built.jpg",
                 "contrastShortfalls": [{"slot": "color1", "ratio": 2.0, "floor": 3.0}]}) + "\n")
            chosen = temp_home / "chosen.jpg"
            chosen.write_bytes(b"chosen")
            helper.save_theme_package(dict(base, contrastShortfalls=[],
                                           palette={**base["palette"], "wallpaper": str(chosen)}), "keyfix")
            resaved = helper.load_theme_package("keyfix")
            assert_equal((Path(resaved["palette"]["wallpaper"]).name, resaved["contrastShortfalls"]),
                         ("chosen.jpg", []),
                         "a save under the built-in name keeps its own wallpaper and shortfall list")
            (package / "theme.json").write_text(json.dumps(builtin_meta) + "\n")
            write_builtin()
            # (what, saved slots, the user terminal file's slots and whether they merge)
            save_rows = [
                ("a different theme's slots saved under the built-in name load exactly",
                 {"color2": "#00bb00"}, ({"color2": "#00bb00"}, False)),
                ("an edit of the built-in theme's own slots stores its difference",
                 {"color1": "#aa0000", "color3": "#333333"}, ({"color3": "#333333"}, True)),
            ]
            for what, slots, stored in save_rows:
                helper.save_theme_package(dict(base, terminalColors=slots), "keyfix")
                layer = helper.overlay_layer(user / helper.TERMINAL_COLORS_FILE, helper.TERMINAL_COLORS_FILE)
                assert_equal((loaded()[2], (layer.values, layer.merges)), (slots, stored), what)

            # Declared UI roles merge role by role over the built-in file.
            (package / helper.UI_ROLES_FILE).write_text('outline = "#445566"\nstatusBg = "#232530"\n')
            helper.save_theme_package(dict(helper.load_theme_package("keyfix"),
                                           uiRoles={"outline": "#445566", "statusBg": "#303030"}), "keyfix")
            (package / helper.UI_ROLES_FILE).write_text('outline = "#667788"\nstatusBg = "#343434"\n')
            errors = io.StringIO()
            with contextlib.redirect_stderr(errors):
                declared = helper.load_theme_package("keyfix")["uiRoles"]
            user_roles = helper.overlay_layer(user / helper.UI_ROLES_FILE, helper.UI_ROLES_FILE)
            # (what, actual, expected)
            role_rows = [
                ("a built-in declared role the overlay did not set reaches the loaded package",
                 declared.get("outline"), "#667788"),
                ("an overlay-declared role survives a built-in change to that role",
                 declared.get("statusBg"), "#303030"),
                ("a merging ui-roles overlay loads without a warning", errors.getvalue(), ""),
                ("a merging ui-roles overlay names no unreadable key, so shrink can rewrite it",
                 (user_roles.merges, user_roles.unreadable), (True, [])),
            ]
            for what, actual, expected in role_rows:
                assert_equal(actual, expected, what)
            (package / helper.UI_ROLES_FILE).unlink()

            other = builtin / "keyother"
            other.mkdir()
            (other / "theme.json").write_text(json.dumps({"name": "keyother", "mode": "dark", "source": "curated"}) + "\n")
            (other / "colors.toml").write_text(helper.flat_toml_text(palette))
            (other / helper.TERMINAL_COLORS_FILE).write_text(helper.flat_toml_text({"color5": "#550055"}))
            helper.save_theme_package(dict(base, terminalColors={}), "keyfix")
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(["duplicate", "keyfix", "--as", "keyother"]), 0, "masked duplicate exit status")
            assert_equal(helper.load_theme_package("keyother")["terminalColors"], {},
                         "a copy of a masked theme under a built-in name loads no terminal slots")
        finally:
            helper.builtin_themes_dir, helper.apply_theme_obj = original_builtin, original_apply

    with_temp_home(scenario)


def test_package_colours_normalize_once_over_the_merged_layers():
    """A package's `colors.toml` layers are read under the keys their files wrote
    and folded so that the slots a key names outright arbitrate apart from the
    slots a compound key's last tokens infer.

    Resolving each layer on its own let an overlay that edits only the selection
    slots -- which omits `background` and `foreground`, because `write_user_layer`
    drops what equals the built-in file -- infer both from its own selection
    slots and overwrite the built-in layer's real ones. Folding the layers under
    one pass over their raw keys then arbitrated by spelling instead of by layer,
    so a built-in `background` stood over a matugen-shaped overlay's
    `colors_background` for the same slot.
    """
    builtin_colors = {"background": "#fafafa", "foreground": "#101010",
                      "accent": "#8c1f4a", "cursor": "#101010", "red": "#aa0000",
                      "selection_background": "#d0d0d0", "selection_foreground": "#101010"}
    edited = {**builtin_colors, "selection_background": "#3769f1",
              "selection_foreground": "#fafafa"}

    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        package = builtin / "mergefix"
        package.mkdir(parents=True)
        (package / "colors.toml").write_text(helper.flat_toml_text(builtin_colors))
        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        user = helper.user_themes_dir() / "mergefix"
        try:
            helper.write_user_layer("mergefix", "colors.toml", edited)
            stored = helper.parse_colors_toml(user / "colors.toml",
                                              kind=helper.ColorsRead.PALETTE_LAYER)
            merged = helper.package_colors_map("mergefix")
            helper.write_user_layer("mergefix", "colors.toml",
                                    {**edited, "background": "#202020"})
            stated = helper.package_colors_map("mergefix")["background"]
            # (what, actual, expected)
            rows = [
                ("a save of edited selection slots stores no background or foreground",
                 sorted(stored), ["selection_background", "selection_foreground"]),
                ("the merged map keeps the built-in layer's background and foreground",
                 (merged["background"], merged["foreground"]), ("#fafafa", "#101010")),
                ("the merged map takes the overlay's selection slots",
                 (merged["selection_background"], merged["selection_foreground"]),
                 ("#3769f1", "#fafafa")),
                ("the merged map is the palette the save meant",
                 merged, helper.normalize_color_map(edited)),
                ("an overlay that states background replaces the built-in value",
                 stated, "#202020"),
            ]
            for what, actual, expected in rows:
                assert_equal(actual, expected, what)

            # An overlay whose keys carry each prefix the reader strips and the
            # camelCase spelling. The built-in layer states every one of these
            # four slots outright, so each row fails unless the overlay's key
            # reaches the same tier the built-in key did.
            (user / "colors.toml").write_text(
                'colors_background = "#000099"\nansi_red = "#00ff00"\n'
                'palette_cursor = "#ff00ff"\nselectionBackground = "#3769f1"\n')
            spelled = helper.package_colors_map("mergefix")
            # (what, actual, expected)
            spelling_rows = [
                ("an overlay's colors-prefixed key wins the slot it names",
                 spelled["background"], "#000099"),
                ("an overlay's ansi-prefixed key wins the slot it names",
                 spelled["red"], "#00ff00"),
                ("an overlay's palette-prefixed key wins the slot it names",
                 spelled["cursor"], "#ff00ff"),
                ("an overlay's camelCase key wins the slot it names",
                 spelled["selection_background"], "#3769f1"),
            ]
            for what, actual, expected in spelling_rows:
                assert_equal(actual, expected, what)

            # The last-token fallback still runs, once, over the fold: a package
            # whose layers between them state no background infers one.
            (user / "colors.toml").unlink()
            (package / "colors.toml").write_text(helper.flat_toml_text(
                {key: value for key, value in builtin_colors.items()
                 if key not in {"background", "foreground"}}))
            inferred = helper.package_colors_map("mergefix")
            assert_equal((inferred.get("background"), inferred.get("foreground")),
                         ("#d0d0d0", "#101010"),
                         "a fold stating no background infers one from the selection slots")

            # A file's other name for the mode, carried by the same alias table
            # as the second spellings of a slot.
            (package / "colors.toml").write_text(
                helper.flat_toml_text(builtin_colors) + 'variant = "light"\n')
            assert_equal(helper.package_colors_map("mergefix").get("mode"), "light",
                         "a layer stating variant instead of mode names the mode")
        finally:
            helper.builtin_themes_dir = original_builtin

    with_temp_home(scenario)


def test_colour_edit_keys_resolve_through_the_alias_table():
    """`apply-colors --set` takes the second spellings of a slot through
    `COLOR_KEY_ALIASES`, the same table the layer fold reads, so one table answers
    what a slot's second spellings are. A spelling outside `COLOR_KEYS` never
    reaches a tier, so `selection_bg` and `selection_fg` are reached by an edit
    alone. An edit naming a key the table resolves to something outside the
    editable roles, such as `variant` for the mode, is refused under the spelling
    the edit used rather than under what it resolved to."""
    # (what, edit key, canonical slot)
    rows = [
        ("the underscore-free spelling", "selectionBackground", "selection_background"),
        ("the hyphenated spelling", "selection-foreground", "selection_foreground"),
        ("the short background spelling", "selection_bg", "selection_background"),
        ("the short foreground spelling", "selection_fg", "selection_foreground"),
    ]
    for what, key, slot in rows:
        assert_equal(helper.parse_color_edits([f"{key}=#112233"]), {slot: "#112233"}, what)
    try:
        helper.parse_color_edits(["variant=#112233"])
        refusal = ""
    except ValueError as exc:
        refusal = str(exc)
    assert_equal(refusal, "unsupported color role: variant",
                 "a mode key is refused under the name the edit used")


def test_unsaved_applied_theme_keeps_terminal_slots():
    """`apply-colors --name X` without `--save` applies a theme no package carries,
    so its terminal slots survive only in theme-current.json. The next wallpaper
    change or colour edit must take them from that applied state; taking them from
    a package found by name finds nothing and restores the palette's own ANSI
    slots, which on a light theme is unreadable terminal body text. The two sources
    are given different values so the rows also pin which one answers."""
    shipped_slots = {"color0": "#ff0011"}
    edited_slots = {"color0": "#00ff22"}

    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        package = builtin / "termfix"
        package.mkdir(parents=True)
        (package / "theme.json").write_text(
            json.dumps({"name": "termfix", "mode": "light", "source": "curated"}) + "\n")
        (package / "colors.toml").write_text('background = "#fafafa"\nforeground = "#101010"\n')
        (package / helper.TERMINAL_COLORS_FILE).write_text('color0 = "#ff0011"\n')
        wallpaper = temp_home / "wall.png"
        wallpaper.write_bytes(b"\x89PNG\r\n\x1a\n")
        applied = []
        original_builtin, original_apply = helper.builtin_themes_dir, helper.apply_theme_obj
        helper.builtin_themes_dir = lambda: builtin

        def apply_without_hooks(bp, only_app=None, only_target=None, run_hooks=True):
            # The real apply writes theme.json and theme-current.json, which is the
            # state under test. Its hooks reach the login session, so they stay off.
            applied.append(bp)
            return original_apply(bp, only_app=only_app, only_target=only_target, run_hooks=False)

        def run(argv, label):
            with contextlib.redirect_stdout(io.StringIO()):
                assert_equal(helper.cmd_theme(argv), 0, f"{label} exit status")

        helper.apply_theme_obj = apply_without_hooks
        try:
            blueprint = helper.load_theme_package("termfix")
            if not blueprint:
                raise AssertionError("termfix package did not load")
            helper.apply_theme_obj(blueprint)

            # The package's file edited on disk with no re-apply: the two sources now
            # disagree, and the applied blueprint is the one a rebuild must read.
            (package / helper.TERMINAL_COLORS_FILE).write_text('color0 = "#00ff22"\n')
            run(["set-wallpaper", str(wallpaper)], "set-wallpaper against an edited package")
            assert_equal(applied[-1].get("terminalColors"), shipped_slots,
                         "the applied blueprint's slots win over the package's newer file")

            # Shell state present, theme-current.json gone: the applied blueprint holds
            # no slots, so the saved package under the shell state's name answers, with
            # the value on disk rather than the one that was applied.
            (helper.cfg_dir() / "theme-current.json").unlink()
            run(["set-wallpaper", str(wallpaper)], "set-wallpaper with no applied state")
            assert_equal(applied[-1].get("terminalColors"), edited_slots,
                         "with no applied state the saved package's slots carry")

            def last_applied():
                return applied[-1].get("terminalColors")

            # That rebuild applied edited_slots, so both sources hold it from here.
            # (label, argv, what carries the rebuilt blueprint's slots, expected)
            rows = [
                ("apply-colors --name, unsaved",
                 ["apply-colors", "--name", "termfix-tweak", "--set", "accent=#123456"],
                 last_applied, edited_slots),
                ("set-wallpaper after the unsaved apply",
                 ["set-wallpaper", str(wallpaper)], last_applied, edited_slots),
                ("a second apply-colors edit on the unsaved name",
                 ["apply-colors", "--name", "termfix-tweak", "--set", "accent=#654321"],
                 last_applied, edited_slots),
                ("clear-wallpaper after the unsaved apply",
                 ["clear-wallpaper"], last_applied, edited_slots),
                # save-current writes a package instead of applying, so the slots it
                # kept are read off disk; the loss there is permanent.
                ("save-current from the unsaved name",
                 ["save-current", "--name", "termfix-tweak-saved"],
                 lambda: (helper.load_theme_package("termfix-tweak-saved") or {}).get("terminalColors"),
                 edited_slots),
                # Last: it leaves a dark applied state the rows above assume is light.
                ("apply-colors into the other mode",
                 ["apply-colors", "--name", "termfix-tweak", "--mode", "dark",
                  "--set", "accent=#123456"], last_applied, {}),
            ]
            for index, (label, argv, read, expected) in enumerate(rows):
                run(argv, label)
                assert_equal(read(), expected, f"{label} carries the terminal slots")
                if index == 0:
                    assert_equal(helper.find_theme("termfix-tweak"), None,
                                 "the unsaved apply leaves no package under its name")
        finally:
            helper.builtin_themes_dir, helper.apply_theme_obj = original_builtin, original_apply

    with_temp_home(scenario)


def test_terminal_app_overrides_show_on_their_editor_row():
    """The App Theming editor lists a terminal's `terminal_*` rows, and an override
    saved under the palette's `colorN` or ANSI name paints that slot. The row must
    show that colour as overridden, or the editor displays the theme's colour
    while the terminal paints another and offers no way to replace it."""
    override = "#ff0022"
    # (app, the key an override was saved under, the editor row that slot shows on)
    rows = [
        ("ghostty", "black", "terminal_black"),
        ("kitty", "color1", "terminal_color1"),
    ]

    def scenario(temp_home: Path):
        builtin = temp_home / "builtin"
        package = builtin / "rowfix"
        package.mkdir(parents=True)
        (package / "theme.json").write_text(
            json.dumps({"name": "rowfix", "mode": "dark", "source": "curated"}) + "\n")
        palette = "\n".join(f'color{index} = "#0000{index:02d}"' for index in range(16))
        (package / "colors.toml").write_text(f'background = "#101010"\nforeground = "#eeeeee"\n{palette}\n')
        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        try:
            for app, saved_key, row in rows:
                helper.write_user_layer("rowfix", "app-colors.toml", {app: {saved_key: override}})
                blueprint = helper.load_theme_package("rowfix")
                view = {item["role"]: item for item in helper.app_role_view(app, blueprint)["roles"]}
                if row not in view:
                    raise AssertionError(f"{app}: the editor lists no {row} row")
                painted = helper.render_roles(blueprint, helper.app_target_roles(blueprint),
                                              helper.bp_app_overrides(blueprint)[app])[row]
                assert_equal((view[row]["value"], view[row]["overridden"]), (override, True),
                             f"{app}: {row} shows the saved {saved_key}")
                assert_equal(painted, override, f"{app}: {row} paints the saved {saved_key}")
                others = [role for role in view if role.startswith("terminal_")
                          and helper.TERMINAL_SLOT_INDEX[role] != helper.TERMINAL_SLOT_INDEX[row]]
                if not others:
                    raise AssertionError(f"{app}: the editor lists no other terminal row to compare")
                for role in others:
                    assert_equal(view[role]["overridden"], False, f"{app}: {role} carries no override")

                with contextlib.redirect_stdout(io.StringIO()):
                    assert_equal(helper.cmd_theme(["app-colors", app, "--theme", "rowfix",
                                                   "--set", f"{row}=#123456"]), 0,
                                 f"{app}: setting the {row} row")
                assert_equal(helper.read_user_app_overrides("rowfix").get(app), {row: "#123456"},
                             f"{app}: setting the row replaces the saved {saved_key}")
        finally:
            helper.builtin_themes_dir = original_builtin

    with_temp_home(scenario)


def test_restyle_moves_terminal_slots():
    """Restyle Palette adjustments transform the palette, so a theme's explicit
    terminal slots must move with it: a slot the file holds lands where the
    palette's identical colour lands, or brightness leaves body text fixed while
    the band under it darkens."""
    name = "flexoki-light"
    adjustments = {"brightness": -100}

    def scenario(_temp_home: Path):
        package = helper.builtin_themes_dir() / name
        from_file = helper.terminal_slot_overrides(
            helper.parse_colors_toml(package / helper.TERMINAL_COLORS_FILE, allow_empty=True))
        if not from_file:
            raise AssertionError(f"{name} must ship terminal slots for this fixture")
        plain = helper.load_theme_package(name)
        assert_equal(plain["terminalColors"], from_file, "with no adjustments the slots are the file's")

        palette = helper.parse_colors_toml(package / "colors.toml")
        palette["mode"] = json.loads((package / "theme.json").read_text())["mode"]
        moved_palette = helper.apply_adjustments(palette, adjustments)
        helper.set_theme_adjustments(name, adjustments)
        restyled = helper.load_theme_package(name)
        # (slot, a palette key holding the same colour as the slot's file value)
        rows = []
        for slot, value in from_file.items():
            twin = next((key for key, colour in palette.items() if key != "background"
                         and isinstance(colour, str) and colour.lower() == value.lower()), None)
            if twin:
                rows.append((slot, twin))
        if not rows:
            raise AssertionError(f"{name} holds no terminal slot matching a palette colour; pick another fixture")
        for slot, twin in rows:
            assert_equal(restyled["terminalColors"][slot], moved_palette[twin],
                         f"{name} {slot} moves with the palette's {twin}")
            if restyled["terminalColors"][slot] == from_file[slot]:
                raise AssertionError(f"{name} {slot} stayed at {from_file[slot]} under brightness -100")

    with_temp_home(scenario)


def main():
    test_system_font_family_targets()
    test_system_font_size_targets()
    test_display_output_controls()
    # Catalog transfer must leave the theme lock available for applies and restyles.
    # The download locks only the placement of the files it verified.
    for catalog_argv in (["catalog", "install", "ayu"], ["catalog", "install", "--all"],
                         ["catalog", "update", "ayu"], ["catalog", "update", "--all"],
                         ["catalog", "remove", "ayu"], ["catalog", "list"]):
        assert_equal(helper._theme_command_mutates(catalog_argv), False,
                     f"`theme {' '.join(catalog_argv)}` must not hold the theme lock for its whole run")
    assert_equal(helper._theme_command_mutates(["chromium-policy"]), True,
                 "Chromium policy refresh must serialize with theme applies")
    assert_equal(helper._theme_command_mutates(["init"]), True,
                 "the first-run apply must serialize with theme applies")
    test_system_font_normalization()
    test_tmux_theme_reaches_the_running_server()
    test_tmux_copy_mode_matches_take_theme_roles()
    test_perceptual_theme_adjustments()
    test_curated_app_role_passthrough()
    test_codex_theme_paints_every_bundled_theme_readably()
    test_codex_theme_selection_changes_only_the_tui_theme_key()
    test_write_file_gives_the_temporary_file_the_requested_mode_before_writing()
    test_write_file_leaves_no_temporary_behind_when_the_write_fails()
    test_write_file_reports_whether_the_destination_moved()
    test_theme_apply_runs_only_the_reload_hooks_whose_target_changed()
    test_theme_apply_runs_a_failed_hook_again_on_the_next_apply()
    test_theme_apply_commits_a_curated_target_as_one_unit()
    test_theme_apply_lands_every_other_target_when_one_target_fails()
    test_a_btop_selection_failure_is_reported_without_costing_the_rest()
    test_every_target_config_declares_known_keys_only()
    test_every_target_hook_is_dispatched_and_classified()
    test_the_shipped_wallpaper_templates_are_the_ones_the_documented_invariant_names()
    test_selection_hooks_refuse_a_home_the_test_did_not_create()
    test_agent_cli_themes_render_for_every_bundled_theme()
    test_agent_cli_theme_targets_reach_the_apply_path()
    test_agent_cli_theme_modes_destination_must_name_the_mode()
    test_agent_cli_theme_role_overrides_reach_both_modes()
    test_agent_cli_theme_counterpart_prefers_the_paired_theme()
    test_agent_cli_theme_selection_writes_only_the_theme_key()
    test_agent_cli_theme_selection_reads_the_users_own_spelling_of_the_value()
    test_agent_cli_theme_selection_adds_an_absent_block_without_reflowing_the_file()
    test_agent_cli_theme_selection_ignores_a_deeper_key_of_the_same_name()
    test_agent_cli_theme_selection_creates_its_config_owner_only()
    test_agent_cli_theme_selection_keeps_the_settings_file_permissions()
    test_agent_cli_theme_selection_writes_through_a_symlinked_config()
    test_agent_cli_theme_selection_edits_the_omp_config_that_omp_reads()
    test_agent_cli_theme_selection_waits_for_the_opencode_migration()
    test_agent_cli_theme_selection_acts_only_on_a_rendered_theme()
    test_agent_cli_theme_selection_refuses_a_config_shape_it_cannot_edit()
    test_terminal_slot_overrides_reach_terminals_only()
    test_curated_vscode_theme_takes_the_terminal_palette()
    test_light_themes_read_in_a_terminal()
    test_dark_themes_read_in_a_terminal()
    test_dark_themes_draw_diffs_in_two_hues()
    test_horizon_packages_use_only_upstream_colours()
    test_wallpaper_and_save_keep_terminal_slots()
    test_a_save_never_pairs_its_palette_with_a_curated_file_it_did_not_judge()
    test_wallpapers_all_lists_the_folder_then_every_theme()
    test_declared_ui_roles_replace_the_derivation_without_a_contrast_rewrite()
    test_declared_ui_roles_move_with_a_restyle_and_survive_a_save()
    test_save_keeps_app_overrides()
    test_theme_overlays_merge_key_by_key()
    test_package_colours_normalize_once_over_the_merged_layers()
    test_colour_edit_keys_resolve_through_the_alias_table()
    test_unsaved_applied_theme_keeps_terminal_slots()
    test_terminal_app_overrides_show_on_their_editor_row()
    test_restyle_moves_terminal_slots()
    test_restyle_integer_sweeps()
    test_fastfetch_portable_seed_and_logo_fallback()
    test_compositor_dependency_selection()
    test_capability_probe_reporting()
    test_compositor_detection_fallback()
    test_gtk_settings_merge_and_reset()
    test_apply_system_fonts_temp_home()
    test_hyprland_layout_payload()
    test_hyprland_layout_apply_reads_the_highest_monitor_scale()
    test_hyprland_blur_script()
    test_chromium_policy_refuses_a_sandbox_home()
    test_theme_hooks_stay_out_of_the_login_session()
    test_vshell_blur_cli_contract()
    test_generated_theme_consumer_wiring()
    test_shell_only_theme_preview()
    test_current_theme_reads_without_applying()
    test_theme_init_applies_only_without_state()
    test_icon_index_picks_each_name_through_the_inherit_chain()
    test_icon_picker_lists_every_base_dir_and_samples_each_set()
    test_a_real_icon_set_install_wins_over_the_bundled_copy_and_counts_as_installed()
    test_cache_prune_bounds_imagecache_and_drops_unreferenced_notification_images()
    test_lint_checks_color0_in_light_mode_only()
    test_lint_reports_listed_shortfalls_as_known()
    test_lint_all_fails_only_on_an_unlisted_warning()
    test_every_shipped_theme_package_lints_clean()
    test_theme_list_reports_the_preview_and_the_thumbnail_apart()
    test_theme_list_reports_installed_wallpapers_and_the_star()
    test_hyprland_preview_native_lua()
    test_preview_stage_retires_its_window_rule()
    test_theme_preview_stop_signal_tears_down_its_capture()
    test_preview_stage_lua_keeps_one_live_rule()
    test_greeter_primary_monitor_validation()
    test_helper_import_loads_no_image_or_http_stack()
    test_helper_entrypoint_runs_the_helper()
    test_greeter_runtime_helper_dependencies()
    test_greeter_sync_survives_a_missing_wallpaper()
    test_launcher_search_unicode_ranges_and_preview()
    test_launcher_folder_opener_agreement()
    test_launcher_zoxide_results()
    test_instance_listing()
    test_sudo_toggle_dropin_lifecycle()
    test_sudo_toggle_status_reads_flag_mirror()
    test_sudo_toggle_status_reports_other_passwordless_sources()
    test_sudo_toggle_set_refuses_stale_direction()
    test_sudo_toggle_enable_never_takes_quiet_sudo_path()
    test_sudo_toggle_flag_write_refuses_symlinks()
    test_sudo_toggle_revoke_retires_legacy_flag_without_state_dir()
    test_launch_terminal_rejects_immediately_failing_terminal()
    test_sudo_toggle_revoke_never_needs_a_terminal()
    test_terminal_candidates_match_dependency_manifest()
    test_notification_ownership_detects_a_foreign_daemon()
    test_notification_ownership_recognises_the_shell_itself()
    test_notification_unowned_bus_is_not_a_conflict()
    test_notification_probe_failure_is_not_an_unowned_bus()
    test_notification_unowned_error_phrasings()
    test_notification_takeover_preserves_a_user_activation_file()
    test_notification_takeover_reports_an_unrecordable_state()
    test_notification_daemon_label_handles_scope_units()
    test_notification_takeover_never_touches_an_inherited_unit()
    test_notification_restore_starts_what_takeover_stopped()
    test_notification_takeover_records_who_asked()
    test_notification_status_respects_the_server_opt_out()
    test_requires_features_propagates_to_availability()
    test_sudo_toggle_status_stays_available_without_a_terminal()
    test_terminal_resolution_prefers_the_vgs_setting()
    test_terminal_argv_shapes_per_terminal()
    test_app_scope_is_probed_rather_than_assumed()
    test_terminal_never_reruns_an_unwrapped_command()
    test_missing_terminal_reaches_the_user()
    test_terminal_wait_blocks_until_the_terminal_exits()
    test_preferred_terminal_is_tried_first()
    test_theme_catalog_offers_a_builtin_theme_with_no_imagery()
    test_theme_catalog_wallpaper_add_keeps_the_download_offered()
    test_theme_wallpaper_remove_keeps_the_file_and_the_download_installed()
    test_theme_wallpaper_delete_removes_the_file_and_its_set_names()
    test_theme_catalog_update_keeps_the_users_wallpapers()
    test_theme_catalog_download_verifies_its_archive()
    test_theme_asset_publisher()
    test_theme_asset_publish_records_what_is_on_the_release()
    test_theme_asset_release_selection()
    test_theme_asset_publication_gate()
    test_theme_catalog_generator()
    test_theme_preview_set_check()
    test_preview_stage_rule_tiles_the_capture_window()
    test_theme_catalog_manifest_matches_the_repo()
    test_remote_desktop_reports_streaming_separately_from_listening()
    test_remote_desktop_start_creates_the_output_before_starting_the_unit()
    test_remote_desktop_start_refuses_when_the_output_cannot_be_checked()
    test_remote_desktop_start_does_not_recreate_an_existing_output()
    test_remote_desktop_paired_clients_reads_only_names()
    test_remote_desktop_watch_tokens_cover_every_event()
    test_remote_desktop_failed_start_removes_the_output_it_created()
    test_remote_desktop_failed_start_keeps_an_output_it_did_not_create()
    test_remote_desktop_stop_removes_only_an_output_vgs_created()
    test_remote_desktop_stop_ignores_a_record_from_another_compositor_instance()
    test_remote_desktop_stop_drops_the_record_when_the_output_vanished()
    test_remote_desktop_start_is_idempotent_when_the_host_is_already_running()
    test_remote_desktop_start_reports_an_unrecordable_ownership_claim()
    test_remote_desktop_start_verifies_the_output_it_created()
    test_remote_desktop_journal_window_never_falls_back_to_unbounded_history()
    test_remote_desktop_unit_query_failure_is_not_a_missing_unit()
    test_remote_desktop_start_refuses_when_the_unit_query_fails()
    test_remote_desktop_malformed_state_degrades_rather_than_raising()
    test_remote_desktop_unknown_compositor_is_probed_not_assumed()
    test_remote_desktop_decode_marks_real_replacement_characters()
    test_remote_desktop_undecodable_device_names_are_reported_not_mangled()
    if os.environ.get("HOME") != _HOME_AT_IMPORT:
        raise AssertionError(
            "a test leaked its temporary HOME: expected "
            f"{_HOME_AT_IMPORT!r}, found {os.environ.get('HOME')!r}. "
            "check-vshell-niri.py reads HOME, so this would have failed there instead."
        )
    test_scratchpad_size_is_a_percentage_of_the_monitor()
    test_scratchpad_anchor_resolves_to_coordinates()
    test_scratchpad_records_that_cannot_work_are_rejected()
    test_scratchpad_lua_generation()
    test_scratchpad_generated_lua_parses()
    test_scratchpad_niri_generation()
    test_scratchpad_niri_reports_what_it_cannot_express()
    test_scratchpad_niri_rejects_rules_it_cannot_write_correctly()
    test_scratchpad_niri_keybinds_are_converted()
    test_scratchpad_niri_unconvertible_keybind_is_reported_not_emitted()
    test_scratchpad_niri_rejects_every_construct_it_can_prove_unsupported()
    test_scratchpad_niri_rejected_pads_do_not_preload()
    test_scratchpad_niri_release_owns_only_the_pad_s_own_window()
    test_scratchpad_launch_command_is_argv_not_a_shell()
    test_scratchpad_launch_refusal_reaches_the_toggle()
    test_scratchpad_niri_pad_name_cannot_break_the_generated_kdl()
    test_scratchpad_niri_hide_confirms_the_pad_is_off_screen()
    test_scratchpad_hide_focus_rule_is_shared_by_both_backends()
    test_scratchpad_niri_hide_honours_the_same_flags()
    test_scratchpad_release_refuses_when_it_could_not_look()
    test_scratchpad_preload_reports_a_failed_placement()
    test_scratchpad_niri_hide_succeeds_when_focus_left_for_another_output()
    test_scratchpad_niri_failed_hide_keeps_the_reveal_origin()
    test_scratchpad_niri_generated_kdl_parses()
    test_scratchpad_compositor_detection_reads_the_session_not_the_binary()
    test_scratchpad_target_monitor_resolves_against_connected_outputs()
    test_scratchpad_release_hands_the_window_back()
    test_scratchpad_membership_is_reasserted_for_a_late_class()
    test_scratchpad_title_exclusion_applies_to_every_rule()
    test_scratchpad_rejects_an_uncompilable_title_exclusion()
    test_scratchpad_release_honours_the_title_exclusion()
    test_scratchpad_toggle_honours_enabled()
    test_scratchpad_hide_only_never_reveals()
    test_scratchpad_hide_focus_target_depends_on_who_asked()
    test_scratchpad_rejections_are_named_not_silent()
    test_scratchpad_reveal_reports_failed_dispatches()
    test_scratchpad_reassert_clears_fullscreen_for_other_modes()
    test_scratchpad_show_does_not_disturb_focus_restore()
    test_monitor_logical_size_degrades_on_unusable_scale()
    test_scratchpad_hide_confirms_the_pad_came_down()
    test_scratchpad_visibility_distinguishes_hidden_from_unknown()
    test_scratchpad_hide_refuses_when_visibility_is_unknown()
    test_scratchpad_matching_windows_reports_pattern_breadth()
    if _GSETTINGS_WRITES:
        raise AssertionError(
            f"gsettings-write-reached: {len(_GSETTINGS_WRITES)}\n"
            + "\n".join(f"{test}: {' '.join(argv)}" for test, argv in _GSETTINGS_WRITES)
        )
    subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "check-vshell-niri.py")],
        check=True,
    )
    print("VGS helper smoke tests passed.")


if __name__ == "__main__":
    main()
