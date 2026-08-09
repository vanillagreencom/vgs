#!/usr/bin/env python3
"""Focused helper smoke tests for VGS settings-owned integration paths."""
from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = REPO_ROOT / "bin" / "vshell-helper"


def load_helper():
    loader = importlib.machinery.SourceFileLoader("vshell_helper_test_module", str(HELPER_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helper = load_helper()

# Several tests swap HOME to a TemporaryDirectory, and check-vshell-niri.py --
# which main() runs as a subprocess at the end -- reads os.environ["HOME"] and
# passes it to children. A test that leaked a deleted temp HOME would surface
# as an unexplained failure in the NIRI suite, pointing at the wrong file
# entirely. Recorded here so main() can name the real cause instead.
_HOME_AT_IMPORT = os.environ.get("HOME")


def assert_equal(actual, expected, message):
    if actual != expected:
        raise AssertionError(f"{message}: expected {expected!r}, got {actual!r}")


def with_temp_home(fn):
    old_home = os.environ.get("HOME")
    old_sudo = os.environ.pop("SUDO_USER", None)
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["HOME"] = tmp
        try:
            fn(Path(tmp))
        finally:
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home
            if old_sudo is not None:
                os.environ["SUDO_USER"] = old_sudo


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

    # Brightness is perceptual L only. A sweep must be monotonic without the
    # saturation/hue drift caused by the former HSV-value implementation.
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

    # Contrast spreads L around the palette mean but does not rotate colors.
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


def test_restyle_integer_sweeps():
    # Every integer brightness value is a state the UI can publish. Exercise the
    # complete range on representative dark/light palettes and the themes that
    # exposed the former clamp, HLS-surface, semantic, and accent discontinuities.
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

    # Named regressions document the exact transitions reported in the field.
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

    # The other four controls need the same every-integer continuity contract.
    # One dark and one light curated theme cover both fixed polarity paths while
    # keeping this focused check fast enough for normal development.
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
    original_image = helper.Image
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

        helper.Image = None
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
        shipped_cat = REPO_ROOT / "themes" / "coppernight" / "backgrounds" / "4-cats-anime.jpg"
        assert_equal(guaranteed.get("fallbackWallpaper"), True,
                     "failed first Fastfetch conversion uses the shipped fallback")
        assert_equal(logo.read_bytes(), shipped_cat.read_bytes(),
                     "new Fastfetch config always has a decodable fallback logo")

    try:
        with_temp_home(run_case)
    finally:
        helper.Image = original_image
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
    """A declared minimum that nothing checks is a comment pretending to be a
    constraint (VGS-89). The probe mechanism is what turns it into a check, so
    the mechanism itself has to be checked — including the two ways it must NOT
    fire: on a command that is absent, and on a probe that could not be run.
    """
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
        # Present but unusable: reported, and phrased so it cannot be mistaken
        # for "not installed".
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

        # Usable: silent. The probe must not add noise on a healthy system.
        helper.CAPABILITY_PROBES = {
            "probed": {"argv": ["true"], "requirement": "needs the thing"},
        }
        helper._CAPABILITY_PROBE_CACHE = {}
        assert_equal(helper.feature_status()["features"]["base"]["missing"], [],
                     "a satisfied probe adds nothing")

        # Absent: reported once, as missing, never twice. Telling someone to
        # upgrade a command they have not installed is worse than saying nothing.
        helper.command_exists = lambda command: command != "probed"
        helper.CAPABILITY_PROBES = {
            "probed": {"argv": ["false"], "requirement": "needs the thing"},
        }
        helper._CAPABILITY_PROBE_CACHE = {}
        base = helper.feature_status()["features"]["base"]
        assert_equal(base["missing"], ["probed"],
                     "an absent command is reported as missing, not as unusable")
        assert_equal(base["unusable"], [], "an absent command is not probed")

        # Unrunnable probe: treated as satisfied. Reporting a working system as
        # broken because the probe itself failed to execute is the false
        # negative this mechanism exists to avoid.
        helper.command_exists = lambda command: True
        helper.CAPABILITY_PROBES = {
            "probed": {"argv": ["/nonexistent/probe/binary"], "requirement": "needs the thing"},
        }
        helper._CAPABILITY_PROBE_CACHE = {}
        assert_equal(helper.feature_status()["features"]["base"]["unusable"], [],
                     "a probe that cannot run is not evidence of an unusable command")

        # The shipped jq probe, against the jq actually installed here.
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


def test_hyprland_layout_payload():
    script, meta = helper._hyprland_layout_payload({
        "surfaceGeometryTarget": "sync",
        "cornerRadius": 99,
        "surfaceBorderWidth": 12,
        "hyprlandLayoutGapsOverride": 6,
        "hyprlandLayoutGapsOutOverride": 8,
        "hyprlandResizeOnBorder": False,
        "configVersion": 15,
    })
    assert_equal(meta["target"], "sync", "layout target")
    assert_equal(meta["radius"], 20, "layout radius clamp")
    assert_equal(meta["border"], 10, "layout border clamp")
    assert_equal(meta["gaps"], {"gaps_in": 6, "gaps_out": 8}, "layout gaps")
    assert_equal(meta["resizeOnBorder"], False, "resize_on_border v15 false")
    if "rounding = 20" not in script or "border_size = 10" not in script:
        raise AssertionError("layout script should include clamped shape")

    script, meta = helper._hyprland_layout_payload({
        "surfaceGeometryTarget": "quickshell",
        "cornerRadius": 11,
        "surfaceBorderWidth": 2,
    })
    assert_equal(meta["manageHyprlandShape"], False, "quickshell target should not manage Hyprland shape")
    assert_equal(meta["radius"], None, "quickshell target radius")
    if "rounding =" in script or "border_size =" in script:
        raise AssertionError("quickshell target should not render Hyprland shape settings")

    _, meta = helper._hyprland_layout_payload({
        "surfaceGeometryTarget": "hyprland",
        "cornerRadius": 12,
        "hyprlandLayoutRadiusOverride": 4,
        "hyprlandResizeOnBorder": False,
        "configVersion": 14,
    })
    assert_equal(meta["radius"], 4, "hyprland override radius")
    assert_equal(meta["resizeOnBorder"], True, "legacy resize_on_border false should be upgraded")


def test_hyprland_blur_script():
    script = helper._hyprland_blur_script(True, 1.5, True, 0.01)
    for namespace in (
        "slideout",
        "vshell:background",
        "control-center",
        "notification-center-popout",
        "launcher-context-menu",
        "clipboard-context-menu",
        "dock-context-menu",
        "dnd-duration-menu",
        "tray-menu-window",
        "tray-overflow-menu",
    ):
        if namespace in script:
            raise AssertionError("Hyprland blur namespace rule should exclude full-screen/screen-height surfaces")
    for namespace in ("vgs-menu", "modal", "popout", "notification-popup"):
        if namespace not in script:
            raise AssertionError("Hyprland blur namespace rule should include content-sized surfaces")
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


def test_vshell_blur_cli_contract():
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        fake_bin = tmp_path / "bin"
        fake_bin.mkdir()
        record_path = tmp_path / "hyprctl-eval.txt"
        fake_hyprctl = fake_bin / "hyprctl"
        fake_hyprctl.write_text("""#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == eval ]]; then
  printf '%s' "${2:-}" > "$HYPRCTL_RECORD"
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

        script = record_path.read_text()
        if "vgs-menu" not in script:
            raise AssertionError("blur CLI should route content-sized namespaces into hyprctl eval")
        if "launcher-context-menu" in script or "control-center" in script:
            raise AssertionError("blur CLI should not route full-screen namespaces into hyprctl eval")


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
        failed = helper.run_hook("foot-config", {})
        assert_equal(failed["ok"], False, "consumer hook failure result")
        if "read-only test config" not in failed.get("error", ""):
            raise AssertionError("consumer hook failure must remain observable")
    finally:
        helper.ensure_foot_theme_config = original_foot_hook


def test_shell_only_theme_preview():
    def run(temp_home: Path):
        blueprint = helper.load_theme_package("coppernight")
        if not blueprint:
            raise AssertionError("Coppernight package missing")
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
        if shutil.which("Hyprland"):
            verified = subprocess.run(
                ["Hyprland", "--verify-config", "--config", str(config)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )
            if verified.returncode != 0:
                raise AssertionError(
                    "Hyprland rejected generated preview Lua: "
                    + (verified.stderr or verified.stdout).strip()
                )


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
        if shutil.which("Hyprland"):
            config = cache / "greeter.lua"
            config.write_text(rendered)
            verified = subprocess.run(
                ["Hyprland", "--verify-config", "--config", str(config)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )
            if verified.returncode != 0:
                raise AssertionError(
                    "Hyprland rejected generated greeter Lua: "
                    + (verified.stderr or verified.stdout).strip()
                )

        (cache / "settings.json").write_text(json.dumps({
            "greeterPrimaryMonitor": "DP-1\nexec-once = unsafe",
        }))
        assert_equal(helper.greeter_primary_monitor(cache), "",
                     "greeter primary monitor config injection guard")

        (cache / "settings.json").write_text("{}")
        assert_equal(helper.greeter_primary_monitor(cache), "",
                     "automatic greeter primary monitor")


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


def test_duplicate_shell_guard():
    """A second VGS shell must yield; the session shell must never be unseated."""
    shell_path = str(REPO_ROOT / "quickshell" / "vshell" / "shell.qml")
    session = {
        "pid": 100,
        "id": "aaa",
        "shell_id": "shell-1",
        "config_path": shell_path,
        "launch_time": "2026-08-01T10:00:00",
    }
    duplicate = {
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
        helper.qs_list_instances = lambda: {"ok": True, "instances": []}
        report = helper.vgs_instance_report(pid=200)
        assert_equal(report["duplicate"], False, "no peers means no duplicate")
        assert_equal(report["reason"], "sole instance", "sole-instance reason")

        helper.qs_list_instances = lambda: {"ok": True, "instances": [session, other_app]}
        report = helper.vgs_instance_report(pid=200, shell_id="shell-1")
        assert_equal(report["duplicate"], True, "unregistered younger shell yields")
        assert_equal(report["owner"]["pid"], 100, "oldest instance owns the session")
        assert_equal([entry["pid"] for entry in report["instances"]], [100],
                     "unrelated Quickshell applications are never counted")

        helper.qs_list_instances = lambda: {"ok": True, "instances": [session, duplicate]}
        report = helper.vgs_instance_report(pid=100, shell_id="shell-1")
        assert_equal(report["duplicate"], False, "session shell keeps ownership")
        report = helper.vgs_instance_report(pid=200, shell_id="shell-1")
        assert_equal(report["duplicate"], True, "registered younger shell yields")

        # A dead registry entry must not unseat a live shell.
        alive = {200}
        report = helper.vgs_instance_report(pid=200, shell_id="shell-1")
        assert_equal(report["duplicate"], False, "dead peers are ignored")
        alive = {100, 200, 300}

        # Config-path matching covers `qs -c vshell` vs `qs -p quickshell/vshell`.
        report = helper.vgs_instance_report(pid=200, config_path=shell_path)
        assert_equal(report["duplicate"], True, "config-path match detects duplicates")

        # A registry that reports no launch time for the session shell must not
        # invert ownership: an unknown launch time is not proof of age, so the
        # session shell keeps running rather than terminating itself.
        undated_session = {**session, "launch_time": ""}
        helper.qs_list_instances = lambda: {"ok": True, "instances": [undated_session, duplicate]}
        report = helper.vgs_instance_report(pid=100, shell_id="shell-1")
        assert_equal(report["duplicate"], False,
                     "session shell with an unknown launch time never yields")
        assert_equal(report["owner"]["pid"], 100, "session shell stays the owner")
        report = helper.vgs_instance_report(pid=200, shell_id="shell-1")
        assert_equal(report["duplicate"], False,
                     "an unprovable peer age abstains instead of guessing")

        # An undated *peer* must not unseat a dated shell either. With no kernel
        # start times available for these synthetic pids, neither side can be
        # proven older, so both abstain rather than guess.
        undated_duplicate = {**duplicate, "launch_time": ""}
        helper.qs_list_instances = lambda: {"ok": True, "instances": [session, undated_duplicate]}
        report = helper.vgs_instance_report(pid=100, shell_id="shell-1")
        assert_equal(report["duplicate"], False, "dated session shell keeps ownership")
        report = helper.vgs_instance_report(pid=200, shell_id="shell-1")
        assert_equal(report["duplicate"], False, "an undated pair abstains rather than guessing")

        # Same launch time: the lower pid owns the session.
        tied = {**duplicate, "launch_time": session["launch_time"]}
        helper.qs_list_instances = lambda: {"ok": True, "instances": [session, tied]}
        report = helper.vgs_instance_report(pid=200, shell_id="shell-1")
        assert_equal(report["duplicate"], True, "tied launch times break by pid")
        report = helper.vgs_instance_report(pid=100, shell_id="shell-1")
        assert_equal(report["duplicate"], False, "lower pid wins a tie")

        # Fail open: an unreadable registry must never block a shell from starting.
        helper.qs_list_instances = lambda: {"ok": False, "error": "qs missing", "instances": []}
        report = helper.vgs_instance_report(pid=200, shell_id="shell-1")
        assert_equal(report["duplicate"], False, "unavailable registry fails open")
        assert_equal(report["supported"], False, "unavailable registry is reported")
    finally:
        helper.qs_list_instances = original_list
        helper._vgs_peer_alive = original_alive


def test_duplicate_shell_guard_uses_kernel_start_times():
    """Real process ages decide ownership even when the registry has no metadata."""
    shell_path = str(REPO_ROOT / "quickshell" / "vshell" / "shell.qml")
    first = subprocess.Popen(["sleep", "30"])
    # Kernel start times are jiffy-resolution; make the ordering unambiguous.
    time.sleep(0.2)
    second = subprocess.Popen(["sleep", "30"])
    original_list = helper.qs_list_instances
    original_alive = helper._vgs_peer_alive
    try:
        entries = [
            {"pid": pid, "id": str(pid), "shell_id": "shell-1",
             "config_path": shell_path, "launch_time": ""}
            for pid in (second.pid, first.pid)
        ]
        helper.qs_list_instances = lambda: {"ok": True, "instances": entries}
        # Real pids with real kernel start times, but they are `sleep`, not
        # Quickshell: the ordering under test is _proc_start_ticks, so only
        # liveness is stubbed.
        helper._vgs_peer_alive = lambda pid: pid in {first.pid, second.pid}

        report = helper.vgs_instance_report(pid=first.pid, shell_id="shell-1")
        assert_equal(report["duplicate"], False, "the older process keeps ownership")
        report = helper.vgs_instance_report(pid=second.pid, shell_id="shell-1")
        assert_equal(report["duplicate"], True, "the younger process yields")
        assert_equal(report["owner"]["pid"], first.pid, "owner is the older process")
    finally:
        helper.qs_list_instances = original_list
        helper._vgs_peer_alive = original_alive
        for process in (first, second):
            process.terminate()
            process.wait(timeout=5)


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

        # Re-enabling over an existing drop-in is idempotent, not an error.
        ok, _ = helper.sudo_toggle_apply(dropin, "tester", True, visudo)
        assert_equal(ok, True, "Re-enable must be idempotent")

        ok, _ = helper.sudo_toggle_apply(dropin, "tester", False, visudo)
        assert_equal(ok, True, "Disable must succeed")
        assert_equal(dropin.exists(), False, "Disable must remove the drop-in")

        # Disabling when nothing is installed is a no-op, not a failure.
        ok, _ = helper.sudo_toggle_apply(dropin, "tester", False, visudo)
        assert_equal(ok, True, "Disable on an absent drop-in must be a no-op")

        # An invalid rule must never land: prove the validation gate can fail.
        bad, message = helper.sudo_toggle_apply(dropin, "not a valid user spec !!", True, visudo)
        assert_equal(bad, False, "visudo must reject a malformed user spec")
        assert_equal(dropin.exists(), False, "Rejected candidate must not be installed")
        assert_equal(sorted(p.name for p in Path(tmp).iterdir()), [],
                     "Rejected candidate must leave no staging file behind")

        # A symlinked drop-in path is a redirect target; refuse it.
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

        # A pre-VGS-11 install still has the mirror at the old path.
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.touch()
        assert_equal(helper.sudo_toggle_status("tester", probe_sudo=False)["enabled"], True,
                     "Legacy mirror path must still read as enabled (migration)")
        legacy.unlink()

        # available/reason must be a real probe, not a constant.
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
    """A stale mirror must never be able to turn a revoke into a grant (VGS-11).

    The mirror says enabled, the drop-in is gone (admin removed it, restored
    home backup). The user clicks what reads as 'revoke'. The old code inferred
    `enable = not dropin.is_file()` root-side and installed NOPASSWD: ALL.
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
                # Stale mirror: claims enabled, no drop-in on disk.
                flag.parent.mkdir(parents=True, exist_ok=True)
                flag.touch()
                code = helper.sudo_toggle_set("tester", False)
                assert_equal(code, helper.SUDO_TOGGLE_EXIT_STALE,
                             "A revoke against a stale mirror must report the mismatch")
                assert_equal(dropin.exists(), False,
                             "A revoke must NEVER create the drop-in")
                assert_equal(flag.exists(), False,
                             "The stale mirror must be re-synced to reality")

                # Honest enable, from an agreed-disabled state.
                code = helper.sudo_toggle_set("tester", True)
                assert_equal(code, 0, "Enable from an agreed state must succeed")
                assert_equal(dropin.is_file(), True, "Enable must install the drop-in")
                assert_equal(flag.is_file(), True, "Enable must write the mirror")

                # Inverse drift: drop-in present, mirror missing, user clicks
                # what reads as 'grant'. Benign, but still a mismatch.
                flag.unlink()
                code = helper.sudo_toggle_set("tester", True)
                assert_equal(code, helper.SUDO_TOGGLE_EXIT_STALE,
                             "A grant against a stale mirror must report the mismatch")
                assert_equal(dropin.is_file(), True, "Drop-in must be left as it was")
                assert_equal(flag.is_file(), True, "Mirror must be re-synced to reality")

                # Agreed revoke.
                code = helper.sudo_toggle_set("tester", False)
                assert_equal(code, 0, "Revoke from an agreed state must succeed")
                assert_equal(dropin.exists(), False, "Revoke must remove the drop-in")
                assert_equal(flag.exists(), False, "Revoke must clear the mirror")
            finally:
                helper.sudo_toggle_dropin = original

    with_temp_home(check)


def test_sudo_toggle_enable_never_takes_quiet_sudo_path():
    """Enabling must always go through a terminal (VGS-11).

    Where `sudo -n` already succeeds — an admin wheel NOPASSWD rule, a live
    credential cache — the quiet path would install a permanent NOPASSWD: ALL
    from one bar click with no prompt, no window and no confirmation.
    """
    calls = []

    original_ensure = helper.ensure_root_for
    original_avail = helper.sudo_toggle_availability
    original_enable_avail = helper.sudo_toggle_enable_availability
    original_euid = helper.os.geteuid
    helper.sudo_toggle_availability = lambda: (True, "")
    # Must be stubbed, not inherited from the host: it probes for a terminal
    # emulator, so leaving it live made this test pass on a developer machine
    # (terminal installed, enable path reached) and fail on a bare CI runner
    # (refused before `ensure_root_for` was ever called). The terminal-refusal
    # behaviour is worth pinning, so it gets its own case below rather than
    # being an ambient property of whoever ran the suite.
    helper.sudo_toggle_enable_availability = lambda: (True, "")
    helper.os.geteuid = lambda: 1000  # never take the privileged branch here

    def fake_ensure_root_for(argv, terminal=False):
        calls.append((list(argv), terminal))
        # Stand in for a machine where `sudo -n` succeeds.
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

        # No terminal: enabling must refuse outright rather than fall back to
        # the quiet path, and revoking must still work — gating both directions
        # on a terminal is what once stranded an existing grant in place.
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

        # A symlinked flag file must be refused too.
        (state / "vshell").mkdir()
        (state / "vshell" / "sudo-passwordless-toggle").symlink_to(target)
        ok, message = helper.sudo_toggle_write_flag(True)
        assert_equal(ok, False, "A symlinked mirror file must be refused")
        assert_equal(target.exists(), False, "A refused write must not create the link target")
        (state / "vshell" / "sudo-passwordless-toggle").unlink()

        # The ordinary path still works.
        ok, message = helper.sudo_toggle_write_flag(True)
        assert_equal(ok, True, f"A clean mirror write must succeed: {message}")
        assert_equal((state / "vshell" / "sudo-passwordless-toggle").is_file(), True,
                     "A clean mirror write must create a real file")

        # Writing the mirror retires the pre-VGS-11 file.
        legacy = state / "sudo-passwordless-toggle"
        legacy.touch()
        ok, _ = helper.sudo_toggle_write_flag(True)
        assert_equal(ok, True, "Mirror write must succeed with a legacy file present")
        assert_equal(legacy.exists(), False, "Mirror write must retire the legacy flag")

    with_temp_home(check)


def test_sudo_toggle_revoke_retires_legacy_flag_without_state_dir():
    """A revoke must clear the old mirror even when the new tree is absent.

    Otherwise the legacy flag keeps asserting "enabled" after the drop-in is
    gone, which is exactly the stale-mirror state the direction guard exists to
    catch — reintroduced by the writer itself.
    """
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
    """A machine with no terminal must still be able to REVOKE (VGS-11).

    Gating both directions on a terminal stranded the escalated state: the
    drop-in stayed installed and the widget refused to act on it.
    """
    calls = []

    original_ensure = helper.ensure_root_for
    original_terminals = helper.terminal_candidates
    original_avail = helper.sudo_toggle_availability
    original_euid = helper.os.geteuid
    helper.terminal_candidates = lambda prefer=None: []          # no terminal anywhere
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

        # Granting is the direction that genuinely needs one, and must say so.
        calls.clear()
        code = helper.cmd_sudo_toggle(["set", "on"])
        assert_equal(code, 1, "Granting with no terminal must fail")
        assert_equal(calls, [], "Granting with no terminal must not elevate at all")

        # An already-root caller never uses a terminal, so it must not need one.
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

        # The distinction has to be reportable, not just enforced.
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
    # `xdg-terminal-exec` launches a terminal; it is not one. Counting it here
    # would report the group available on a machine with no terminal installed,
    # which is exactly the VGS-54 defect.
    assert_equal("xdg-terminal-exec" in any_commands[0], False,
                 "a terminal launcher must not count as a terminal")
    # Terminals are declared once, by the group that owns them. Anything that
    # needs one says so by requiring that group, so there is no second list to
    # drift (VGS-32).
    for feature in ("sudo-toggle", "launcher-folder-open-yazi"):
        assert_equal(features[feature].get("anyCommands"), None,
                     f"{feature} must not restate the terminal list")
    assert_equal("terminal" in (features["launcher-folder-open-yazi"].get("requiresFeatures") or []),
                 True, "the Yazi opener must require the terminal feature")
    # Revoking passwordless sudo needs no terminal (VGS-11), so gating the whole
    # group on one would have `deps status` report the safety valve unavailable
    # to exactly the people who most need it. The grant half, which really does
    # need somewhere to prompt, is its own group.
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
    """A detached caller sees no stderr, so "no terminal" must be reported.

    Every call site launches through Quickshell.execDetached, which discards
    output and status; without this a click on Update all does nothing and says
    nothing, which is worse than the command-not-found toast VGS-54 reports.
    """
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
            return 7  # the command's own status, once the window closes

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
                # The compositor is the unit's main process, not mako.
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
    """The undo record carries provenance, because the shell cannot.

    `NotificationService._firstRunTakeoverFired` dies with the shell process,
    while the masks, the stopped units and the record all persist. Keying the
    opt-out reversal on the runtime flag alone meant a restart between the
    takeover and the opt-out skipped the reversal and left the user's daemon
    masked and stopped -- no notification daemon at all, from nothing worse
    than a restart. Reading the record instead is what makes it durable, so
    every claim that reading makes is pinned here.
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

        # Re-reading the record from disk IS the restart: no in-process state
        # survives a shell exit, and this is the only thing that does.
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
        # The user takes the name themselves first.
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

        # No settings file at all. load_settings() falls back to the shipped
        # seed, so the seed's own value is load-bearing here: were it true, an
        # absent config would answer "already spent" and the shell would refuse
        # the takeover it is supposed to perform on exactly that config.
        seed = json.loads((REPO_ROOT / "config" / "vshell" / "settings.default.json").read_text())
        assert_equal(seed["notificationFirstRunTakeoverDone"], False,
                     "the shipped seed must leave the one-shot unspent")
        assert_equal(helper.vgs_first_run_takeover_done(), False,
                     "an absent settings.json must not read as a spent one-shot")
        assert_equal(helper.notification_status()["vgsFirstRunTakeoverDone"], False,
                     "status must surface the on-disk answer")

        # Unparseable: likewise not evidence.
        settings.write_text("{ this is not json")
        assert_equal(helper.vgs_first_run_takeover_done(), False,
                     "an unreadable settings.json must not read as a spent one-shot")

        # Present but false, and present but not a boolean.
        settings.write_text(json.dumps({"notificationFirstRunTakeoverDone": False}))
        assert_equal(helper.vgs_first_run_takeover_done(), False, "false is false")
        settings.write_text(json.dumps({"notificationFirstRunTakeoverDone": "yes"}))
        assert_equal(helper.vgs_first_run_takeover_done(), False,
                     "a non-boolean must not be coerced into a spent one-shot")

        # Only an actual persisted true counts.
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
        # The conflicting activation file lives in the user's own data home.
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


def test_theme_catalog_download_verifies_every_file():
    """A catalog download must land verbatim, and must refuse anything it cannot verify."""
    import hashlib

    def scenario(tmp: Path):
        source = tmp / "source" / "demo"
        (source / "apps").mkdir(parents=True)
        (source / "theme.json").write_text('{"name":"demo","mode":"dark","source":"curated"}\n')
        (source / "colors.toml").write_text('background = "#101010"\nforeground = "#eeeeee"\n')
        (source / "apps" / "btop.theme").write_text("theme\n")
        files = []
        for rel in ("theme.json", "colors.toml", "apps/btop.theme"):
            blob = (source / rel).read_bytes()
            files.append({"path": rel, "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest()})

        builtin = tmp / "builtin"
        builtin.mkdir()
        (builtin / "catalog.json").write_text(json.dumps({
            "version": 1,
            "source": {"ref": "vTest", "baseUrl": "https://example.invalid/themes"},
            "themes": [{"name": "demo", "mode": "dark", "files": files,
                        "size": sum(f["size"] for f in files)}],
        }))

        original_builtin = helper.builtin_themes_dir
        helper.builtin_themes_dir = lambda: builtin
        os.environ["VGS_THEME_CATALOG_BASE_URL"] = "file://" + str(tmp / "source")
        try:
            catalog = helper.load_theme_catalog()
            base_urls, allow_local = helper.theme_catalog_base_urls(catalog)
            entry = helper.catalog_theme_entry(catalog, "demo")

            result = helper.catalog_download_theme(entry, base_urls, allow_local)
            assert_equal(result["status"], "installed", "catalog download status")
            dest = helper.user_themes_dir() / "demo"
            for rel in ("theme.json", "colors.toml", "apps/btop.theme"):
                assert_equal((dest / rel).read_bytes(), (source / rel).read_bytes(),
                             f"downloaded {rel} must be byte-identical")
            assert_equal(helper.catalog_marker("demo").get("ref"), "vTest", "download marker records the ref")

            listed = [e for e in helper.catalog_entries() if e["name"] == "demo"][0]
            assert_equal((listed["installed"], listed["downloaded"]), (True, True), "catalog list state")

            again = helper.catalog_download_theme(entry, base_urls, allow_local)
            assert_equal(again["status"], "skipped", "an installed theme is not re-downloaded")

            # A force re-download must never destroy the installed copy before
            # its replacement is in place: a failure mid-way leaves it intact.
            tampered_force = json.loads(json.dumps(entry))
            tampered_force["files"][1]["sha256"] = "1" * 64
            try:
                helper.catalog_download_theme(tampered_force, base_urls, allow_local, force=True)
                raise AssertionError("a tampered force re-download must fail")
            except ValueError:
                pass
            assert_equal((dest / "theme.json").is_file(), True,
                         "a failed force re-download must leave the installed theme in place")
            assert_equal(sorted(p.name for p in helper.user_themes_dir().glob(".catalog-*")), [],
                         "a failed force re-download leaves no staging or replaced dirs")

            # Reading the current theme for the safety check must not apply the
            # default theme: current_theme() writes files and runs hooks when
            # ~/.config/vshell/theme.json is absent.
            assert_equal((helper.cfg_dir() / "theme.json").exists(), False, "no theme state before remove")
            assert_equal(helper.catalog_remove_theme("demo")["status"], "removed", "catalog remove")
            assert_equal(dest.exists(), False, "removed theme dir is gone")
            assert_equal((helper.cfg_dir() / "theme.json").exists(), False,
                         "catalog remove must not apply the default theme as a side effect")

            # A removal that cannot proceed must fail loudly and leave the theme
            # whole, not report success or half-delete it.
            helper.catalog_download_theme(entry, base_urls, allow_local)
            themes_root = helper.user_themes_dir()
            themes_root.chmod(0o555)
            try:
                helper.catalog_remove_theme("demo")
                raise AssertionError("an undeletable theme must not report removal")
            except ValueError:
                pass
            finally:
                themes_root.chmod(0o755)
            assert_equal((dest / "theme.json").is_file(), True, "theme survives a failed removal")
            assert_equal(helper.catalog_remove_theme("demo")["status"], "removed", "removal after the block")

            # The theme lock must be free while bytes are moving: a `Download
            # All` is ~1.1 GiB, and holding it would block every apply, the
            # light/dark keybinding, wallpapers and restyles for that whole time.
            import fcntl

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
            assert_equal(lock_free_during_transfer, [True, True, True],
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
            assert_equal((copy / "theme.json").is_file(), True, "the user's copy survives")
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
            # bytes are accepted, so a stale first location cannot serve wrong
            # content and cannot stop a good location from working either.
            stale = tmp / "stale" / "demo"
            stale.mkdir(parents=True)
            (stale / "theme.json").write_text('{"name":"demo","mode":"light"}\n')
            (stale / "colors.toml").write_text("background = \"#ffffff\"\n")
            (stale / "apps").mkdir()
            (stale / "apps" / "btop.theme").write_text("stale\n")
            stale_url = "file://" + str(tmp / "stale")
            result = helper.catalog_download_theme(entry, [stale_url, base_urls[0]], allow_local)
            assert_equal(result["status"], "installed", "a stale first location must fall through")
            assert_equal((dest / "theme.json").read_bytes(), (source / "theme.json").read_bytes(),
                         "the accepted bytes are the catalogued ones, never the stale location's")
            helper.catalog_remove_theme("demo")
            try:
                helper.catalog_download_theme(entry, [stale_url], allow_local)
                raise AssertionError("no matching location must fail the download")
            except ValueError as exc:
                assert_equal("no source served" in str(exc), True, "failure names the exhausted locations")

            # Tampered checksum: nothing may land, not even partially.
            tampered = json.loads(json.dumps(entry))
            tampered["files"][0]["sha256"] = "0" * 64
            try:
                helper.catalog_download_theme(tampered, base_urls, allow_local)
                raise AssertionError("checksum mismatch must fail the download")
            except ValueError:
                pass
            assert_equal(dest.exists(), False, "a failed download leaves no theme dir")
            assert_equal(list(helper.user_themes_dir().glob(".catalog-*")), [],
                         "a failed download leaves no staging dir")

            for bad in ("../evil", "/etc/passwd", "apps/../../evil", ".ssh/id_rsa", "notes.txt",
                        "apps/.hidden", "backgrounds/.env", "apps/../theme.json", "apps/", "apps//x",
                        "backgrounds/season/img.png", "apps\\evil", "theme.json\x00.sh"):
                try:
                    helper._catalog_check_relpath(bad)
                    raise AssertionError(f"catalog path {bad!r} must be rejected")
                except ValueError:
                    pass

            # https is the only scheme accepted without the test-only override.
            try:
                helper._catalog_fetch("file:///etc/passwd", False)
                raise AssertionError("non-https downloads must be refused")
            except ValueError:
                pass
        finally:
            helper.builtin_themes_dir = original_builtin
            os.environ.pop("VGS_THEME_CATALOG_BASE_URL", None)

    with_temp_home(scenario)


def test_theme_catalog_manifest_matches_the_repo():
    """The committed catalog must describe the themes actually in the tree."""
    catalog = json.loads((REPO_ROOT / "themes" / "catalog.json").read_text())
    names = sorted(e["name"] for e in catalog["themes"])
    on_disk = sorted(p.parent.name for p in (REPO_ROOT / "themes").glob("*/theme.json"))
    assert_equal(names, on_disk, "catalog themes must match themes/ on disk")
    assert_equal(catalog["source"]["baseUrl"].startswith("https://"), True, "catalog must download over https")
    # The generator validates through the installer's own checker, so a catalogued
    # path the installer would refuse cannot exist. Assert the invariant directly.
    for theme in catalog["themes"]:
        for spec in theme["files"]:
            helper._catalog_check_relpath(spec["path"])


def test_theme_catalog_generator_rejects_uninstallable_packages():
    """A package the installer could not fetch must fail generation, not ship."""
    import importlib.machinery
    import importlib.util

    loader = importlib.machinery.SourceFileLoader(
        "gen_theme_catalog_test_module", str(REPO_ROOT / "scripts" / "gen-theme-catalog.py"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    generator = importlib.util.module_from_spec(spec)
    loader.exec_module(generator)

    with tempfile.TemporaryDirectory() as tmp:
        theme_dir = Path(tmp) / "deep"
        (theme_dir / "backgrounds" / "season").mkdir(parents=True)
        (theme_dir / "theme.json").write_text("{}\n")
        (theme_dir / "backgrounds" / "season" / "img.png").write_bytes(b"x")
        try:
            generator.catalog_relpaths(helper, theme_dir)
            raise AssertionError("a nested backgrounds/ path must fail catalog generation")
        except SystemExit:
            pass
        # Files outside the downloadable shape are skipped, not fatal.
        shutil.rmtree(theme_dir / "backgrounds" / "season")
        (theme_dir / "NOTES.md").write_text("scratch\n")
        assert_equal(generator.catalog_relpaths(helper, theme_dir), ["theme.json"],
                     "stray files are skipped without failing generation")


# --- remote desktop (Sunshine host) -----------------------------------------
#
# The whole point of routing the host through the helper is that starting the
# unit and creating the virtual output are one operation. Sunshine picks its
# capture target at startup, so getting the order or the guard wrong streams a
# REAL monitor with no error anywhere -- there is no observable symptom to
# catch it later, which is why it is pinned here.

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
    helper.run = lambda argv, **kwargs: subprocess.CompletedProcess(
        argv, returncode, "\n".join(lines or []), stderr
    )
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
    # hyprctl unavailable or unanswering. Starting anyway would capture a real
    # monitor and report success -- the exact silent failure this guards.
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
    # N1. A failed start that leaves HEADLESS-1 behind hands the user a phantom
    # monitor AND no host -- precisely the state the disabled-by-default design
    # exists to avoid, and the user has no affordance to undo it.
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
    # The other half of N1: roll back only what THIS call created. An output
    # that was already there belongs to somebody else even when the start fails.
    with _rd_lifecycle(output_present=True, systemctl_ok=False) as (calls, state):
        result = helper.remote_desktop_start()
    assert_equal(result["ok"], False, "a failed systemctl start is still a failure")
    assert_equal(state["present"], True, "an output this call found must survive the rollback")
    assert_equal(_rd_hyprctl_calls(calls), [], "nothing is created and nothing is removed")


def test_remote_desktop_stop_removes_only_an_output_vgs_created():
    # N2. Stop used to remove any present HEADLESS-1, so stopping Sunshine
    # could delete a virtual output the user made for something else. That is
    # the worst outcome available here: destroying display configuration as a
    # side effect of stopping a service.
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

    # Same shape, but the output was already there when start ran.
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
        state["present"] = False  # the user removed it themselves
        calls.clear()
        result = helper.remote_desktop_stop()
        assert_equal(result["ok"], True, "a vanished output is not an error")
        assert_equal(_rd_hyprctl_calls(calls), [], "there is nothing to remove")
        assert_equal(
            helper._rd_output_record_file().exists(), False,
            "a record whose output is gone must not survive to authorise a later removal",
        )


def test_remote_desktop_start_is_idempotent_when_the_host_is_already_running():
    # N4. `toggle` decides from a state read; the unit can change before the
    # action runs. The losing path must touch no output -- a running host has
    # already picked its capture target, so a second virtual output would be a
    # phantom monitor and nothing else.
    with _rd_lifecycle(output_present=False, unit_running=True) as (calls, state):
        result = helper.remote_desktop_start()
    assert_equal(result["ok"], True, "starting an already-running host is not a failure")
    assert_equal(_rd_hyprctl_calls(calls), [], "no output is created for a host already running")
    assert_equal([c for c in calls if c[0] == "systemctl"], [], "and the unit is not restarted")
    if not any("already running" in note for note in result["manual"]):
        raise AssertionError(f"the no-op must be reported: {result['manual']!r}")


def test_remote_desktop_start_reports_an_unrecordable_ownership_claim():
    # If the record cannot be written, stop will not recognise the output as
    # VGS's and will leave it. That is the safe direction -- a leaked monitor is
    # one click to remove, a deleted one cannot be undone -- but it must be said
    # rather than silently traded away.
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
    # N6. `hyprctl` exiting 0 is not the output existing. If it is absent,
    # Sunshine picks a real monitor at startup and streams the user's own
    # screen with nothing anywhere to say so -- the same silent fallback the
    # unverifiable-presence refusal guards, reached from the other side.
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

    # The presence check answering "cannot tell" is its own case, and it must
    # not be collapsed into "absent" -- nothing is removed on this path,
    # because removing what we cannot see is the guess the record exists to
    # avoid.
    with _rd_lifecycle(output_present=False, create_takes_effect=None) as (calls, state):
        result = helper.remote_desktop_start()
    assert_equal(result["ok"], False, "an unverifiable output must not start the host either")
    assert_equal(
        [c for c in calls if c[0] == "systemctl"], [], "and still no unit start",
    )
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
    # S1, and it is the worse direction of the readable/active split. An
    # unbounded read replays a CLIENT CONNECTED from a previous run, so the
    # widget shows LIVE with nobody connected -- which trains the user to
    # ignore the one indicator that says somebody is watching their screen.
    good = subprocess.CompletedProcess([], 0, "Thu 2026-08-06 16:44:12 CEST\n", "")
    with _rd_systemctl({"ActiveEnterTimestamp": good}):
        assert_equal(
            helper._rd_journal_window(), ["--since", "2026-08-06 16:44:12"],
            "a parseable start time anchors the read to the current run",
        )

    for label, reply in {
        "the query failed": subprocess.CompletedProcess([], 1, "", "Failed to connect to bus"),
        "the value is empty": subprocess.CompletedProcess([], 0, "\n", ""),
        "the value is unparseable": subprocess.CompletedProcess([], 0, "n/a\n", ""),
        "the shape is unexpected": subprocess.CompletedProcess([], 0, "Thu 06/08/2026 16:44:12 CEST\n", ""),
    }.items():
        with _rd_systemctl({"ActiveEnterTimestamp": reply}):
            assert_equal(
                helper._rd_journal_window(), None,
                f"no anchor when {label} -- and specifically not a boot-wide replay",
            )

    # And the session read must REFUSE rather than read unbounded, reporting
    # unknown. Not idle either: `active` stays false but `readable` is false
    # too, which is what the shell renders as "could not tell".
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
    # S2. `systemctl show` failing and the unit genuinely being absent came
    # back identically, so a transient failure made the widget announce that
    # Sunshine is not installed.
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

    # X1: a PARTIAL reply is not an answer either. Both fields carry a verdict,
    # and each is read with a default that looks definite -- an absent
    # ActiveState silently makes `running` false, so a truncated reply that
    # happened to contain LoadState reported the host as STOPPED when its state
    # was unknown. This is the fourth instance of the shape on this plugin, so
    # it gets the same treatment as its three siblings: pinned, with the case
    # that would otherwise silently regress.
    partial = {
        "ActiveState missing": subprocess.CompletedProcess([], 0, "LoadState=loaded\n", ""),
        "LoadState missing": subprocess.CompletedProcess([], 0, "ActiveState=active\n", ""),
        # A field with no value is a field, not an answer.
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

    # The specific regression: LoadState=loaded alone previously read as a
    # definite "installed and stopped".
    with _rd_systemctl({"LoadState": partial["ActiveState missing"]}):
        state = helper._rd_unit_state()
    if state["known"] and not state["running"]:
        raise AssertionError(
            "a reply carrying only LoadState must not read as 'installed and stopped'"
        )

    for label, reply in {"the query failed": broken, "the query said nothing": silent}.items():
        with _rd_systemctl({"LoadState": reply}):
            state = helper._rd_unit_state()
        assert_equal(state["known"], False, f"{label}: that is not an answer")
        assert_equal(state["exists"], False, f"{label}: and it must not read as installed either")
        if not state["error"]:
            raise AssertionError(f"{label}: the reason must survive to the caller")

    # The status payload routes it to unknown, never to unavailable.
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
    # The lifecycle half of S2: acting on a failed query would start a host
    # that may already be running, and create an output for it.
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
            "username": "method",
            "salt": "SALTVALUE",
            "password": "HASHVALUE",
            "root": {
                "uniqueid": "UNIQUE",
                "named_devices": [
                    {"name": "mbp-1", "cert": "-----BEGIN CERTIFICATE-----"},
                    {"name": "  ", "cert": "x"},
                    {"cert": "no name here"},
                ],
            },
        }))
        old_xdg = os.environ.pop("XDG_CONFIG_HOME", None)
        try:
            result = helper._rd_paired_clients()
        finally:
            if old_xdg is not None:
                os.environ["XDG_CONFIG_HOME"] = old_xdg
        # Only names, and only usable ones. The same file holds the Web UI
        # credential hash and salt; nothing but `name` may leave this function.
        assert_equal(result["names"], ["mbp-1"], "only non-blank device names are returned")
        assert_equal(result["known"], True, "a well-formed file is an answer")
        for name in result["names"]:
            if "SALT" in name or "HASH" in name:
                raise AssertionError("credential material must never reach the payload")

    with_temp_home(check)

    # A machine with no Sunshine config is not an error, just an empty list --
    # and it is an ANSWER, not an unknown.
    def check_absent(home):
        result = helper._rd_paired_clients()
        assert_equal(result["names"], [], "no state file means no paired clients")
        assert_equal(result["known"], True, "and an absent file is still an answer")

    with_temp_home(check_absent)


def test_remote_desktop_malformed_state_degrades_rather_than_raising():
    # U2. `remote_desktop_status()` used to raise straight out of here on a
    # state file that decoded as JSON but had another shape, so ONE malformed
    # field took the host and session state down with it and the widget lost
    # everything. Unparseable state is unknown by this subsystem's own model,
    # not fatal.
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

            # Shapes that are legitimately empty are ANSWERS, not unknowns: a
            # state file with no paired devices yet is well-formed.
            for label, body in {
                "no root yet": '{"username": "method"}',
                "no named_devices yet": '{"root": {"uniqueid": "X"}}',
                "an empty device list": '{"root": {"named_devices": []}}',
            }.items():
                state.write_text(body)
                result = helper._rd_paired_clients()
                assert_equal(result["names"], [], f"{label}: no devices")
                assert_equal(result["known"], True, f"{label}: but that IS the answer")

            # A malformed entry inside a well-formed list is skipped without
            # discarding its neighbours.
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

    # And the whole status payload survives it: the other fields are still
    # there, which is the actual regression.
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
    # U1. detect_compositor() answers from THIS process's environment, and an
    # ssh session has none of it -- so it says "unknown". Treating that as "not
    # Hyprland" skipped the virtual output on exactly the path a remote-desktop
    # host is most likely to be started from, and the capture fell back to a
    # real monitor with nothing to say so.
    originals = {n: getattr(helper, n) for n in
                 ("detect_compositor", "command_exists", "_rd_hypr_env", "run")}
    try:
        # A detected compositor is taken at its word, both ways.
        helper.detect_compositor = lambda: {"compositor": "hyprland", "source": "test"}
        assert_equal(helper._rd_manages_output()["manages"], True, "detected Hyprland manages the output")

        helper.detect_compositor = lambda: {"compositor": "niri", "source": "test"}
        managed = helper._rd_manages_output()
        assert_equal(managed["manages"], False, "niri manages no virtual output")
        assert_equal(managed["blocked"], False, "and that is a definite answer, not a refusal")

        helper.detect_compositor = lambda: {"compositor": "unknown", "source": "none"}

        # Unknown + no hyprctl at all -> definitely not Hyprland. Proceed.
        helper.command_exists = lambda name: False
        managed = helper._rd_manages_output()
        assert_equal(managed["manages"], False, "no hyprctl means no Hyprland")
        assert_equal(managed["blocked"], False, "and the host may still start")

        # Unknown + hyprctl but no running instance -> same.
        helper.command_exists = lambda name: True
        helper._rd_hypr_env = lambda: {}
        managed = helper._rd_manages_output()
        assert_equal(managed["manages"], False, "no instance means no running Hyprland")
        assert_equal(managed["blocked"], False, "and the host may still start")

        # Unknown + an instance resolvable from the runtime dir + hyprctl
        # answers -> this IS Hyprland, reached over ssh. THE FIX.
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

    # start honours the refusal without touching the compositor.
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
    # The mechanism AI2 asked for: every rendering of a genuine U+FFFD is
    # swapped for a marker BEFORE the lenient decode, so what is left is
    # unambiguous -- a U+FFFD can only be a byte we could not decode, and a
    # marker can only be one the file really contained.
    literal = '{"a": "real\ufffdname"}'.encode("utf-8")
    text, marker = helper._rd_decode_marking_real_fffd(literal)
    assert_equal(marker in text, True, "a literal U+FFFD is marked")
    assert_equal("\ufffd" in text, False, "and no bare U+FFFD is left to misread")

    # The escaped rendering counts too: a JSON writer may or may not escape
    # non-ASCII, and Sunshine's own state file escapes solidus, so assuming
    # either one would be a guess.
    escaped = b'{"a": "real\\ufffdname"}'
    text, marker = helper._rd_decode_marking_real_fffd(escaped)
    assert_equal(json.loads(text)["a"], "real" + marker + "name", "an escaped U+FFFD is marked too")

    # Case is not significant in a JSON hex escape.
    text, marker = helper._rd_decode_marking_real_fffd(b'{"a": "real\\uFFFDname"}')
    assert_equal(json.loads(text)["a"], "real" + marker + "name", "an uppercase escape is the same character")

    # A byte that cannot be decoded still becomes U+FFFD, which is now the only
    # thing U+FFFD can mean.
    text, marker = helper._rd_decode_marking_real_fffd(b'{"a": "bad-\x80-x"}')
    assert_equal(json.loads(text)["a"], "bad-\ufffd-x", "an undecodable byte is the only source of U+FFFD left")

    # A clean file is returned untouched apart from the marking, and the JSON
    # still parses -- one bad name must never cost the list.
    text, marker = helper._rd_decode_marking_real_fffd(b'{"a": "plain"}')
    assert_equal(json.loads(text)["a"], "plain", "a clean file decodes normally")

    # No usable marker is a refusal, not a guess: the caller withholds every
    # suspicious name instead.
    crowded = ("".join(helper._RD_DECODE_MARKERS)).encode("utf-8")
    text, marker = helper._rd_decode_marking_real_fffd(crowded)
    assert_equal(text, None, "a file containing every candidate marker yields no safe marking")
    assert_equal(marker, "", "and no marker to restore with")


def test_remote_desktop_undecodable_device_names_are_reported_not_mangled():
    # VGS-87 item 5. Decoding with errors="replace" put U+FFFD INSIDE device
    # names, so a client appeared under a mangled name indistinguishable from
    # the device genuinely being called that. The substitution is now reported
    # and the touched name is withheld rather than presented as fact.
    def check(home: Path):
        config = home / ".config" / "sunshine"
        config.mkdir(parents=True)
        state = config / "sunshine_state.json"
        old_xdg = os.environ.pop("XDG_CONFIG_HOME", None)
        try:
            # A clean file is never second-guessed, including one whose names
            # carry perfectly ordinary non-ASCII.
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

            # Z5: the suspicion is scoped PER NAME. A device legitimately
            # named with U+FFFD must keep its name even when an unrelated
            # neighbour in the same file failed to decode -- a file-wide flag
            # punished it for somebody else's bad bytes.
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

            # The same, with the JSON writer escaping non-ASCII rather than
            # emitting it literally -- Sunshine's own state file escapes, so
            # assuming either rendering would be a guess.
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

            # AI2, and the reason the substring mechanism had to go: asking
            # "does this name's byte sequence appear ANYWHERE in the file"
            # answers a different question from "did THIS field decode
            # cleanly". Here the mangled name's decoded form also appears in an
            # unrelated field, so the old check found it and kept the name
            # mangled. Marking real U+FFFD before decoding removes the question
            # rather than approximating it.
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

            # Invalid bytes OUTSIDE any name must not withhold anything.
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

    # The count reaches the status payload, which is what the widget renders.
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
    # Real lines, copied from this host's journal. The widget never sees
    # Sunshine's wording -- it sees these tokens -- so this is where the log
    # format is pinned.
    cases = [
        ("2026-08-06 11:10:43 Info: CLIENT CONNECTED", "connected"),
        ("2026-08-06 11:45:30 Info: CLIENT DISCONNECTED", "disconnected"),
        ("Started Self-hosted game stream host for Moonlight.", "lifecycle"),
        ("Stopping Self-hosted game stream host for Moonlight...", "lifecycle"),
        ("Stopped Self-hosted game stream host for Moonlight.", "lifecycle"),
        ("Info: Creating encoder [hevc_nvenc]", "session"),
        ("Info: Streaming bitrate is 27788000", "session"),
        # Noise the follow must NOT wake the shell for: Sunshine logs hundreds
        # of these per start, and a resync on each would be a poll with extra
        # steps.
        ("Info: [wayland] Found interface: wl_output(71) version 4", ""),
        ("Info: Color range: JPEG", ""),
        ("", ""),
    ]
    for line, expected in cases:
        assert_equal(helper._rd_watch_token(line), expected, f"watch token for {line!r}")


@contextlib.contextmanager
def _scratchpad_state_sandbox():
    """Point the pad lock and focus-state files at a temp dir.

    `scratchpad_toggle` takes a per-pad flock under `_scratchpad_state_dir()`,
    which is $XDG_RUNTIME_DIR/vshell-scratchpad — the LIVE session's directory.
    Without this the tests created and locked `term.lock` next to the running
    shell's own state, so a test run reached into the session it is supposed to
    be independent of."""
    original = helper._scratchpad_state_dir
    with tempfile.TemporaryDirectory(prefix="vgs-scratchpad-state-") as tmp:
        helper._scratchpad_state_dir = lambda: Path(tmp)
        try:
            yield Path(tmp)
        finally:
            helper._scratchpad_state_dir = original


def _hides_on_readback(monitor="DP-1"):
    """A visibility stub for a hide that WORKS: visible when the toggle checks
    at entry, hidden when it reads the outcome back afterwards.

    A stub reporting "visible" forever would fail the post-dispatch
    confirmation, because a hide now proves its own outcome instead of assuming
    it. Each call site takes a fresh one, since it carries a counter."""
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

    # Scale is not cosmetic here. Window rules and dispatches both speak logical
    # coordinates, so a 4K panel at scale 2 must size like a 1080p one — sizing
    # against the mode would produce a pad twice the intended size.
    hidpi = helper.resolve_scratchpad_geometry(pad, _monitor(width=3840, height=2160, scale=2.0))
    assert_equal((hidpi["width"], hidpi["height"]), (1152, 756),
                 "a 4K monitor at scale 2 is logically 1080p")

    # An odd transform rotates the logical box; a portrait monitor is taller
    # than it is wide and the percentages have to follow.
    portrait = helper.resolve_scratchpad_geometry(pad, _monitor(width=2560, height=1440, transform=1))
    assert_equal((portrait["monitorWidth"], portrait["monitorHeight"]), (1440, 2560),
                 "transform 1 swaps the logical axes")

    # Pixels remain available for apps with a hard minimum size.
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
        print("  (skipped: luac not installed; generated Lua was not parse-checked)")
        return

    def parses(source: str) -> bool:
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as handle:
            handle.write(source)
            path = handle.name
        try:
            return subprocess.run([luac, "-p", path], capture_output=True).returncode == 0
        finally:
            os.unlink(path)

    # Prove the instrument can fail before trusting that it passes.
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
    """The Niri backend (VGS-83). Not a translation of the Lua one: Niri has no
    special workspaces, so a pad is a persistent named workspace plus window
    rules. The same pad RECORD drives both backends — that is what storing an
    anchor and a percentage instead of pixels bought."""
    pads = [
        _pad(keybind="Mod+T", monitor="DP-1", preload=True, anchor="top-center", offsetY=36),
        _pad(id="notes", classRegex="^(obsidian)$", command="obsidian",
             titleExclude="^(Quick Switcher)$", anchor="bottom-right", offsetX=24, offsetY=24,
             sizeMode="pixels", widthPixels=1200, heightPixels=800),
        _pad(id="vm", classRegex="^(vm-viewer)$", command="virt-viewer", presentation="fullscreen"),
        _pad(id="tiled", classRegex="^(tiled)$", command="tiled", presentation="tile"),
    ]
    text, meta = helper.render_scratchpads_kdl(pads)

    # The workspace is the model. Prefixed so a pad can never collide with a
    # workspace the user named themselves.
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

    # Anchors map onto niri's `relative-to`, and the offsets carry over
    # unchanged because niri already measures inward from the named edge.
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

    # The keybind and preload both run the same CLI paths the Hyprland backend
    # does, so there is one toggle implementation per compositor and not two.
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

    # ...and a centre pad with no offset is not reported at all, because
    # nothing was lost: niri centres new floating windows by itself.
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

    # The exclusion gets the same treatment as the class pattern, exactly as on
    # Hyprland: a malformed exclusion is not "no exclusion".
    problems = []
    _, meta = helper.render_scratchpads_kdl([_pad(titleExclude=r"(?<=x)y")], problems)
    assert_equal(meta["count"], 0, "an unexpressible exclusion rejects the whole pad")
    assert problems and "title exclusion" in problems[0]["reason"]


def test_scratchpad_niri_keybinds_are_converted():
    """A keybind is stored Hyprland-shaped (`SUPER + SHIFT, T`) because that is
    what the Settings capture writes. Emitting it verbatim into the KDL left a
    bind niri either rejects or silently never fires, so the pad's one keybind
    did nothing on the compositor the config was generated for."""
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

    # ...while a convertible one really does reach the file, in niri's syntax.
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

    # The patterns VGS itself generates must survive all of that.
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

        # A same-class window that is NOT on the pad's workspace must be left
        # exactly where it is.
        state["windows"] = [{"id": 1, "app_id": "com.ghostty.scratchpad",
                             "title": "other", "workspace_id": 4}]
        stray = helper.scratchpad_release_niri("term", r"^(com\.ghostty\.scratchpad)$")
        assert_equal(stray["released"], False, "a window that was never in the pad is not released")
        assert_equal(actions, [], "and nothing is moved")

        # ...and a stray listed BEFORE the pad's own window must not win the
        # selection. Checking ownership after picking the first match let the
        # stray fail the check and hide the real window behind it, so release
        # did nothing at all.
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

        # The pad's own window is released, to the FOCUSED workspace's index.
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
    """AGENTS.md: exec external tools with argv arrays. A pad's command is
    user-supplied configuration, and it was reaching `sh -c` — so shell
    metacharacters in it were INTERPRETED. On Niri a preloaded pad runs its
    command at login, not only when the keybind is pressed."""
    argv, error = helper.scratchpad_launch_argv("ghostty --class=com.ghostty.scratchpad")
    assert_equal(error, "", "an ordinary command parses cleanly")
    assert_equal(argv, ["ghostty", "--class=com.ghostty.scratchpad"], "into an argv array")

    # Quoting still works, because shlex does it — what is gone is the shell.
    argv, error = helper.scratchpad_launch_argv('ghostty --title="My Pad"')
    assert_equal(error, "", "quoted arguments are still supported")
    assert_equal(argv, ["ghostty", "--title=My Pad"], "and are parsed, not word-split")

    # A command that WANTS a shell is refused, not quietly mangled. Passing
    # `&&` to execvp as a literal argument would do the wrong thing silently,
    # and keeping `sh -c` for these would keep the rule broken exactly where it
    # matters.
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

    # The opt-in the refusal recommends has to actually work. Classifying the
    # RAW string instead of the parsed tokens refused this too — the one
    # command shape that is meant to be allowed.
    argv, error = helper.scratchpad_launch_argv("sh -c 'foo && bar'")
    assert_equal(error, "", "an explicit shell is allowed")
    assert_equal(argv, ["sh", "-c", "foo && bar"],
                 "with the shell line intact as a single argument")

    # Ordinary commands that merely look punctuated must keep working.
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
    helper._scratchpad_find_window = lambda pad: None       # nothing running: it must launch
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
    """`normalize_scratchpad` restricts the ID so it can be written unescaped;
    the NAME is unrestricted user text. A newline in it did not corrupt the
    `//` comment, it ENDED it — and the rest of the name became config KDL
    would try to parse."""
    text, _ = helper.render_scratchpads_kdl(
        [_pad(name="Bad\nwindow-rule { open-fullscreen true }")])
    comment = [line for line in text.splitlines() if line.startswith("// Bad")]
    assert comment, "the pad still gets its comment"
    assert_equal(len(comment), 1, "on exactly one line")
    assert "window-rule { open-fullscreen true }" in comment[0], \
        "with the injected text flattened INTO the comment, where it is inert"

    # Prove it did not simply escape into the config: the only window-rule
    # blocks are the ones the generator wrote.
    sys.path.insert(0, str(REPO_ROOT / "bin"))
    import vshell_niri_kdl as kdl
    headers = [header for header, _, _ in kdl.kdl_nodes_in_block(text)]
    assert_equal(headers.count("window-rule"), 1,
                 "a name carrying a window-rule does not become a second rule")


def test_scratchpad_niri_hide_confirms_the_pad_is_off_screen():
    """The hide path reported success without confirming. On Niri a workspace
    that is still ACTIVE on its output is still displayed even when focus has
    moved away — which is what happens when focus is restored to a window on a
    different output — so checking focus alone called it hidden with the pad
    still on screen."""
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
            # Focus moved away, but the workspace is still the active one on
            # DP-2 — so the pad is still on screen and this is not a hide.
            result = helper.scratchpad_toggle_niri("term")
        assert_equal(result["ok"], False, "a pad still displayed is not a successful hide")
        assert_equal(result["action"], "hide-failed", "and says so")
        assert "DP-2" in result["error"], f"naming where it still is: {result['error']!r}"

        # Same call, but focusing away really does take it off screen.
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
    """One rule, two backends. Each gathers the origin and the current focus
    through its own IPC — they have no choice — but the DECISION is shared, so
    it cannot be right on one compositor and wrong on the other. That is what
    let three variations of one defect accumulate on this path."""
    rule = helper._scratchpad_restore_target
    assert_equal(rule(False, "B", "C"), "B", "a keybind hide returns to the reveal origin")
    assert_equal(rule(True, "B", "C"), "C", "a focus-loss dismissal keeps where the user went")
    assert_equal(rule(True, "B", ""), "B",
                 "unknown focus, or focus still on the pad, falls back to the origin")
    assert_equal(rule(False, "", "C"), "", "no origin and no keep-focus restores nothing")


def test_scratchpad_niri_hide_honours_the_same_flags():
    """`vshell scratchpad hide` reaches BOTH backends, so the Niri toggle has to
    take the same flags. Without them the CLI raised TypeError on Niri the
    moment VGS-82's hide path landed — the semantic half of that rebase."""
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
        # Hiding something already hidden is a no-op, not a failure — the same
        # race the Hyprland backend answers this way.
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
    """A failed window query must never authorise deleting the pad.

    Settings deletes the scratchpad record only when release reports success,
    so collapsing "the compositor did not answer" into "nothing to release"
    costs the user their configuration because an IPC call failed. That is the
    session's most repeated defect — a failed query becoming a confident
    negative — with the worst consequence any instance of it has had."""
    # Hyprland.
    originals = (helper._hyprctl_json, helper._scratchpad_session_ready,
                 helper._scratchpad_dispatch)
    dispatched = []
    helper._scratchpad_session_ready = lambda: True
    helper._scratchpad_dispatch = lambda *a: (dispatched.append(a), True)[1]
    try:
        # `clients` unreadable: unknown, not empty.
        helper._hyprctl_json = lambda *a: None
        blind = helper.scratchpad_release("pad", r"^(com\.example\.pad)$")
        assert_equal(blind["ok"], False, "a release that could not look has not succeeded")
        assert_equal(blind["released"], False, "and released nothing")
        assert "could not read the window list" in blind["error"], \
            f"naming why the pad was kept: {blind.get('error')!r}"
        assert_equal(dispatched, [], "nothing is moved on the strength of a failed query")

        # An answer that really is empty still authorises removal: there is
        # genuinely nothing parked, so the pad can go.
        helper._hyprctl_json = lambda *a: ([] if a and a[0] == "clients"
                                           else {"id": 3} if a and a[0] == "activeworkspace" else None)
        empty = helper.scratchpad_release("pad", r"^(com\.example\.pad)$")
        assert_equal(empty["ok"], True, "an empty window list is a real answer")
        assert_equal(empty["released"], False, "with nothing to release")
    finally:
        (helper._hyprctl_json, helper._scratchpad_session_ready,
         helper._scratchpad_dispatch) = originals

    # Niri, same rule.
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
    """Preload that could not park the window reports success while the app
    sits VISIBLY on the user's current workspace — the map-time race this whole
    subsystem exists to handle, reported as handled."""
    # Niri.
    originals = (helper._niri_session_ready, helper._niri_msg_json,
                 helper._niri_scratchpad_action, helper.load_scratchpads)
    helper._niri_session_ready = lambda: True
    helper.load_scratchpads = lambda *a, **k: [_pad(id="term")]

    def fake_json(*args):
        if args and args[0] == "workspaces":
            return [{"id": 9, "name": "vgs-term", "idx": 3, "is_active": False}]
        if args and args[0] == "windows":
            # On workspace 4, not the pad's 9: it needs moving.
            return [{"id": 7, "app_id": "com.ghostty.scratchpad", "workspace_id": 4}]
        return None

    helper._niri_msg_json = fake_json
    try:
        helper._niri_scratchpad_action = lambda *a: False   # the move fails
        with _scratchpad_state_sandbox():
            bad = helper.scratchpad_toggle_niri("term", launch_only=True)
        assert_equal(bad["ok"], False, "a preload that could not park the window is not ok")
        assert_equal(bad["action"], "preload-failed", "and says so")
        assert "could not move" in bad["error"], f"naming the reason: {bad.get('error')!r}"

        helper._niri_scratchpad_action = lambda *a: True    # the move works
        with _scratchpad_state_sandbox():
            good = helper.scratchpad_toggle_niri("term", launch_only=True)
        assert_equal(good["ok"], True, "a preload that parked the window is ok")
        assert_equal(good["action"], "preloaded", "and reports the preload")
    finally:
        (helper._niri_session_ready, helper._niri_msg_json,
         helper._niri_scratchpad_action, helper.load_scratchpads) = originals

    # Hyprland, same rule.
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
        helper._scratchpad_dispatch = lambda *a: False       # the move fails
        helper._scratchpad_place_workspace = lambda *a, **k: True
        with _scratchpad_state_sandbox():
            bad = helper.scratchpad_toggle("term", launch_only=True)
        assert_equal(bad["ok"], False, "a Hyprland preload that could not park is not ok")
        assert_equal(bad["action"], "preload-failed", "and says so")

        # The workspace placement is checked too, not just the membership move.
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
            # Before: the pad is up and focused on its own output.
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
    """A pad whose workspace stays active on ITS output while focus moves to a
    different one has been hidden as far as Niri allows: there is no overlay to
    pull away, so the pad's own output goes on showing its active workspace.

    Reporting failure there told every multi-monitor user that every hide had
    failed — and Settings now gates on this result, so a false failure is no
    longer harmless. The single-output case must still fail, because there the
    user is looking straight at the pad they asked to dismiss."""
    originals = (helper._niri_session_ready, helper._niri_msg_json,
                 helper._niri_scratchpad_action, helper.load_scratchpads)
    try:
        # Cross-output: pad still on DP-2, focus now on DP-1.
        _niri_hide_harness(still_active_after=True, focused_output_after="DP-1")
        with _scratchpad_state_sandbox() as sandbox:
            (sandbox / "term.niri-focus").write_text("7")
            result = helper.scratchpad_toggle_niri("term")
            assert_equal(result["ok"], True, "focus moved to another output is a successful hide")
            assert_equal(result["stillDisplayedOn"], "DP-2",
                         "and says the pad is still on its own output rather than hiding that")
            assert not (sandbox / "term.niri-focus").exists(), \
                "a confirmed hide consumes the origin"

        # Same output: the pad is still in front of the user. Still a failure.
        _niri_hide_harness(still_active_after=True, focused_output_after="DP-2")
        with _scratchpad_state_sandbox() as sandbox:
            (sandbox / "term.niri-focus").write_text("7")
            same = helper.scratchpad_toggle_niri("term")
            assert_equal(same["ok"], False, "a pad still displayed on the focused output is not hidden")
            assert_equal(same["action"], "hide-failed", "and says so")

        # Gone from every output: the ordinary success.
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
    """The origin is what a retry needs. Deleting it before the hide is
    confirmed means each failed attempt permanently loses where the pad came
    from — and the two defects compounded: cross-output hides always reported
    failure, so every one of them destroyed the origin.

    Same rule as release: act on the record only after the thing it describes
    has succeeded."""
    originals = (helper._niri_session_ready, helper._niri_msg_json,
                 helper._niri_scratchpad_action, helper.load_scratchpads)
    try:
        # A hide that fails: the pad is still on the focused output.
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

    # Prove the instrument can fail before trusting that it passes: an
    # unterminated block must not come back as a clean parse.
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
    """`hyprctl` and `niri` coexist in most distro repos, so an INSTALLED
    hyprctl says nothing about which compositor owns the session.

    This mattered when Niri refused, and it matters MORE now that it has its own
    backend (VGS-83): the returned name is what selects the generator, so
    mistaking a Niri session for Hyprland no longer merely refuses wrongly, it
    writes Lua rules into a session that reads KDL."""
    # The reported case: a Niri session on a machine that also has hyprctl.
    assert_equal(_with_session_env({"NIRI_SOCKET": "/run/niri.sock"}), (True, "niri"),
                 "a Niri session is supported, and identified as niri even with hyprctl installed")
    assert_equal(_with_session_env({"XDG_CURRENT_DESKTOP": "niri"}), (True, "niri"),
                 "XDG_CURRENT_DESKTOP is enough to identify the session")

    assert_equal(_with_session_env({"HYPRLAND_INSTANCE_SIGNATURE": "sig"}), (True, "hyprland"),
                 "a real Hyprland session is supported")
    assert_equal(_with_session_env({"XDG_CURRENT_DESKTOP": "Hyprland:wlroots"}), (True, "hyprland"),
                 "a compound desktop string still identifies Hyprland")

    # Neither session may be mistaken for the other; the name is the router.
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

        # Configured output present -> used verbatim.
        fake.monitors = connected
        assert_equal(helper._scratchpad_target_monitor({"id": "p", "monitor": "HDMI-1"}), "HDMI-1",
                     "a connected configured output is honoured")

        # Configured output gone -> falls back to the focused one, which is what
        # "follow focus" already means, rather than to a dead dispatch.
        assert_equal(helper._scratchpad_target_monitor({"id": "p", "monitor": "DP-1"}), "eDP-1",
                     "an unplugged output falls back to the focused one")

        # No configured output -> follow focus.
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
    # The session gate is stubbed rather than satisfied with a real hyprctl:
    # these assertions are wanted most on a CI runner, which has neither the
    # binary nor a session, and a test that returns early there is a check
    # that passes without checking.
    helper._scratchpad_session_ready = lambda: True
    try:
        # A stray same-class window listed FIRST, then the pad's own. Release
        # must skip the stray rather than let it win the selection: filtering by
        # ownership after picking the first match is what let it hide the real
        # window behind it.
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

        # No matching window is the ordinary case (the pad was never opened) and
        # must not be reported as a failure.
        dispatched.clear()
        fake_json.clients = []
        quiet = helper.scratchpad_release("pad", r"^(com\.example\.pad)$")
        assert_equal(quiet["ok"], True, "nothing to release is not a failure")
        assert_equal(quiet["released"], False, "and says nothing was released")
        assert_equal(dispatched, [], "no dispatch when there is no window")

        # A same-class window that the pad never owned is left alone entirely.
        # It is already on a normal workspace, so it needs no rescue, and
        # moving it would be a surprise rather than a fix.
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

    # Outside a Hyprland session there is nothing to release, and removal must
    # still be allowed to proceed.
    assert_equal(helper.scratchpad_release("pad", "^x$")["ok"], True,
                 "release is a no-op without a session, not an error")


def test_scratchpad_membership_is_reasserted_for_a_late_class():
    """The map-time race, in full. Hyprland applies the `workspace` rule once,
    when the window maps. An app whose class settles afterwards never matched
    it and mapped onto whatever workspace was active — so re-asserting only
    float/size/move would style that window perfectly while leaving it where it
    should not be, and the reveal would show an empty special workspace."""
    original = helper._scratchpad_dispatch
    dispatched = []
    helper._scratchpad_dispatch = lambda *args: (dispatched.append(args), True)[1]
    try:
        # Late-settling class: the window is on a normal workspace.
        stray = {"address": "0xdead", "workspace": {"name": "3"}}
        result = helper._scratchpad_ensure_membership("term", stray)
        assert_equal(result["moved"], True, "a stray window is moved onto the pad's workspace")
        assert_equal(result["from"], "3", "and reports where it came from")
        assert_equal(dispatched, [("movetoworkspacesilent", "special:term,address:0xdead")],
                     "moved SILENTLY: the caller reveals the workspace itself a moment later, "
                     "and the non-silent variant would switch to it here")

        # Already correct: no dispatch at all, so an ordinary reveal does not
        # churn the window every single press.
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

    # [1:] drops the text before the first rule; each remaining chunk starts
    # inside one window rule.
    rules = text.split("hl.window_rule({")[1:]
    assert_equal(len(rules), 2, "a pad emits a placement rule and a suppression rule")
    for index, rule in enumerate(rules):
        assert 'title = "negative:^(1Password)$"' in rule, \
            f"window rule {index} must carry the title exclusion"

    # The suppression rule is the one that regressed; name it explicitly.
    suppression = [rule for rule in rules if "suppress_event" in rule]
    assert_equal(len(suppression), 1, "exactly one suppression rule")
    assert 'title = "negative:^(1Password)$"' in suppression[0], \
        "the suppress_event rule must not match every window with the class"

    # A pad without an exclusion must not grow a stray title match.
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

    # A valid one survives, and an absent one is simply empty.
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
    # The session gate is stubbed rather than satisfied with a real hyprctl:
    # these assertions are wanted most on a CI runner, which has neither the
    # binary nor a session, and a test that returns early there is a check
    # that passes without checking.
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

        # Without the exclusion the first class match wins — which is the bug.
        # Pinned so a future refactor cannot quietly drop the argument.
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
    # Stubbed alongside the session gate: with the gate forced true and no real
    # hyprctl on PATH, an unstubbed query would escape into a subprocess that
    # does not exist. Every compositor call this test can reach is mocked.
    helper._hyprctl_json = lambda *args: None
    # The session gate is stubbed rather than satisfied with a real hyprctl:
    # these assertions are wanted most on a CI runner, which has neither the
    # binary nor a session, and a test that returns early there is a check
    # that passes without checking.
    helper._scratchpad_session_ready = lambda: True
    try:
      with _scratchpad_state_sandbox():
        # Hidden: revealing is refused, and nothing is dispatched.
        helper._scratchpad_visibility = _visibility_from(lambda pad_id: "")
        result = helper.scratchpad_toggle("off")
        assert_equal(result["ok"], False, "a disabled pad does not reveal")
        assert_equal(result["action"], "disabled", "and says why")
        assert_equal(dispatched, [], "a refused toggle touches nothing")

        assert_equal(helper.scratchpad_toggle("off", launch_only=True)["ok"], False,
                     "a disabled pad does not preload either")

        # Visible: hiding is still allowed. A pad disabled while on screen would
        # otherwise be stranded visible with no keybind left to dismiss it.
        #
        # The stub reports visible once and gone afterwards, because the hide now
        # reads its own outcome back. A stub that stayed visible forever would
        # only assert that a hide was ATTEMPTED, which is what this used to do.
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
    """`hide` states a direction; `toggle` infers one. Focus-loss dismissal
    (VGS-82) fires on an event and reaches the per-pad lock a moment later, by
    which time the user may already have dismissed the pad — a toggle evaluated
    then would REVEAL what they just put away. Hiding something already hidden
    is also an ordinary race, so it is a success, not an error."""
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
    # Stubbed for the same reason as the tests above: these assertions matter
    # most on a runner with no compositor, and returning early there would be a
    # check that passes without checking.
    helper._scratchpad_session_ready = lambda: True
    try:
      with _scratchpad_state_sandbox():
        # Already hidden: nothing to do, and above all nothing revealed.
        helper._scratchpad_visibility = _visibility_from(lambda pad_id: "")
        result = helper.scratchpad_toggle("term", hide_only=True)
        assert_equal(result["ok"], True, "hiding an already-hidden pad is not a failure")
        assert_equal(result["action"], "already-hidden", "and says so rather than acting")
        assert_equal(dispatched, [], "a no-op hide dispatches nothing at all")

        # Visible: it hides, exactly as the keybind's toggle would.
        dispatched.clear()
        helper._scratchpad_visibility = _hides_on_readback()
        hidden = helper.scratchpad_toggle("term", hide_only=True)
        assert_equal(hidden["ok"], True, "a visible pad is hidden")
        assert_equal(hidden["action"], "hidden", "and reports the hide")
        assert ("togglespecialworkspace", "term") in dispatched, "the hide actually dispatches"

        # A disabled pad on screen can still be hidden this way — same reason
        # the keybind may hide one: the alternative is a pad stranded visible.
        dispatched.clear()
        off = _pad(id="term", enabled=False)
        helper.load_scratchpads = lambda *a, **k: [off]
        helper._scratchpad_visibility = _hides_on_readback()
        stranded = helper.scratchpad_toggle("term", hide_only=True)
        assert_equal(stranded["ok"], True, "a disabled pad on screen is still hidable")
        assert_equal(stranded["action"], "hidden", "and reports the hide")

        # ...and a disabled pad that is already hidden is a no-op, not the
        # "disabled" refusal. The watcher must not turn a race into an error.
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
    # Re-armed before each hide below: the stub carries a counter, because a
    # hide now confirms its own outcome (visible at entry, gone on read-back).
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
        # Keybind hide: back to B, the window the pad was revealed from.
        with _scratchpad_state_sandbox() as state:
            (state / "term.focus").write_text("0xBBB")
            helper._scratchpad_visibility = _hides_on_readback()
            result = helper.scratchpad_toggle("term")
            assert_equal(result["focusedBack"], "0xBBB",
                         "a keybind hide returns to the reveal origin")
            assert ("focuswindow", "address:0xBBB") in dispatched, "and actually focuses it"
            assert not (state / "term.focus").exists(), \
                "the reveal origin is consumed: leaving it would restore a stale window next time"

        # Focus-loss dismissal: stay on C, the window the user just chose.
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
    """Rejecting an unusable pad is right; doing it silently is not. A pad with
    an uncompilable regex generated no rules at all, so the user's scratchpad
    stopped working while Settings went on showing it as configured."""
    problems = []
    assert_equal(helper.normalize_scratchpad(
        {"id": "bad", "name": "Broken", "command": "x", "classRegex": "^(unclosed"},
        problems), None, "an uncompilable class pattern is still rejected")
    assert_equal(len(problems), 1, "and the rejection is recorded")
    assert_equal(problems[0]["id"], "Broken", "named by the pad's own label")
    assert "does not compile" in problems[0]["reason"], "with the reason"

    # Every rejection path reports, not just the regex one — a pad that vanishes
    # for any reason is equally invisible to the user.
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

    # A usable pad records nothing.
    clean = []
    assert helper.normalize_scratchpad({"id": "ok", "command": "x", "classRegex": "^x$"}, clean)
    assert_equal(clean, [], "a usable pad produces no problem entry")

    # The collector is optional, so existing callers keep working.
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
    # The session gate is stubbed rather than satisfied with a real hyprctl:
    # these assertions are wanted most on a CI runner, which has neither the
    # binary nor a session, and a test that returns early there is a check
    # that passes without checking.
    helper._scratchpad_session_ready = lambda: True
    try:
      with _scratchpad_state_sandbox():
        # Everything works and the workspace really is visible afterwards.
        helper._scratchpad_dispatch = lambda *args: True
        visible = {"n": 0}

        def visible_after_toggle(pad_id):
            # Hidden on the first read (so the toggle fires), visible after.
            visible["n"] += 1
            return "" if visible["n"] == 1 else "DP-1"

        helper._scratchpad_visibility = _visibility_from(visible_after_toggle)
        good = helper.scratchpad_toggle("term")
        assert_equal(good["ok"], True, "a reveal that works reports success")
        assert_equal(good["action"], "revealed", "and says so")

        # A dispatch fails: the toggle must NOT report success.
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
    """VGS-90: switching a mapped pad from fullscreen to float or tile left the
    fullscreen state set, so the pad went on covering its workspace and every
    size/move dispatch was applied to a window whose geometry fullscreen
    overrides — the setting changed and nothing visible did."""
    originals = (helper._scratchpad_dispatch, helper._scratchpad_visibility,
                 helper._scratchpad_workspace_monitor, helper.scratchpad_monitors,
                 helper._scratchpad_find_window)
    dispatched = []
    helper._scratchpad_dispatch = lambda *args: (dispatched.append(args), True)[1]
    helper._scratchpad_visibility = _visibility_from(lambda pad_id: "DP-1")
    helper._scratchpad_workspace_monitor = lambda pad_id: "DP-1"
    helper.scratchpad_monitors = lambda: ([_monitor("DP-1", focused=True)], True)
    try:
        # Float: fullscreen must be cleared, and before the geometry dispatches.
        helper._scratchpad_find_window = lambda pad: {"address": "0xaaa", "size": [1, 1], "at": [1, 1]}
        dispatched.clear()
        helper._scratchpad_reassert(_pad(presentation="float"), "0xaaa")
        verbs = [d[0] for d in dispatched]
        assert "fullscreenstate" in verbs, f"float must clear fullscreen, got {verbs}"
        assert_equal(dispatched[0], ("fullscreenstate", "0 -1,address:0xaaa"),
                     "cleared FIRST, or the size/move below act on a fullscreen window")
        assert verbs.index("fullscreenstate") < verbs.index("setfloating"), \
            f"cleared before setfloating, got {verbs}"

        # Tile: same requirement.
        dispatched.clear()
        helper._scratchpad_reassert(_pad(presentation="tile"), "0xaaa")
        verbs = [d[0] for d in dispatched]
        assert_equal(dispatched[0], ("fullscreenstate", "0 -1,address:0xaaa"),
                     "tile must clear fullscreen first too")
        assert "settiled" in verbs, f"and still tile, got {verbs}"

        # Fullscreen: sets it, and must not clear it.
        dispatched.clear()
        helper._scratchpad_reassert(_pad(presentation="fullscreen"), "0xaaa")
        assert_equal(dispatched, [("fullscreenstate", "2 -1,address:0xaaa")],
                     "a fullscreen pad sets fullscreen and nothing else")
    finally:
        (helper._scratchpad_dispatch, helper._scratchpad_visibility,
         helper._scratchpad_workspace_monitor, helper.scratchpad_monitors,
         helper._scratchpad_find_window) = originals


def test_scratchpad_show_does_not_disturb_focus_restore():
    """VGS-90: `show` on an ALREADY-VISIBLE pad reached the reveal path and
    overwrote the stored focus-restore target — very often with the pad's own
    window, since it is visible and focused. The next hide then "restored" focus
    to the window it had just hidden."""
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
    # The pad's own window is what is focused while the pad is on screen.
    helper._hyprctl_json = lambda *args: {"address": "0xpad"} if args and args[0] == "activewindow" else None
    # The pad flock and focus-state files live under
    # $XDG_RUNTIME_DIR/vshell-scratchpad — the LIVE session's directory.
    # Sandbox them so this test cannot reach into the running shell's state.
    with _scratchpad_state_sandbox():
        try:
            state_file = helper._scratchpad_state_dir() / "term.focus"
            state_file.write_text("0xorigin")

            # show on a visible pad: the remembered origin must survive untouched.
            helper._scratchpad_visibility = _visibility_from(lambda pad_id: "DP-1")
            result = helper.scratchpad_toggle("term", reveal_only=True)
            assert_equal(result["ok"], True, "show on a visible pad still succeeds")
            assert_equal(state_file.read_text(), "0xorigin",
                         "the focus origin from the reveal that opened it must survive")

            # A genuine reveal (pad hidden) does record the origin — otherwise the
            # fix would have removed focus restore altogether.
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
    """VGS-90: NaN and infinity survive float() — `float("nan")` raises nothing
    and `nan <= 0` is False — so a monitor reporting a non-numeric scale carried
    NaN into `int(round(width / nan))`, which raises and took the geometry path
    down with it. A failed query is not a negative answer."""
    for label, scale in [("NaN", float("nan")), ("'nan'", "nan"), ("infinity", float("inf")),
                         ("negative", -2.0), ("garbage", "big"), ("zero", 0), ("empty", "")]:
        size = helper.monitor_logical_size(
            {"name": "DP-1", "width": 1920, "height": 1080, "scale": scale})
        assert_equal(size, (1920, 1080), f"a {label} scale degrades to 1 rather than raising")

    # An absent scale is the ordinary case and must behave identically.
    assert_equal(helper.monitor_logical_size({"name": "DP-1", "width": 1920, "height": 1080}),
                 (1920, 1080), "a missing scale is 1")

    # Usable scales are still honoured — the guard must not flatten everything.
    assert_equal(helper.monitor_logical_size(
        {"name": "DP-1", "width": 3840, "height": 2160, "scale": 2.0}), (1920, 1080),
        "a real scale still divides")
    assert_equal(helper.monitor_logical_size(
        {"name": "DP-1", "width": 2880, "height": 1800, "scale": 1.5}), (1920, 1200),
        "a fractional scale still divides")

    # A geometry resolution over such a monitor must complete, not raise: that
    # is the path the crash actually took out.
    geometry = helper.resolve_scratchpad_geometry(
        _pad(widthPercent=60, heightPercent=70),
        {"name": "DP-1", "width": 1920, "height": 1080, "scale": float("nan")})
    assert_equal((geometry["width"], geometry["height"]), (1152, 756),
                 "geometry resolves over a NaN-scale monitor")


def test_scratchpad_hide_confirms_the_pad_came_down():
    """Settings hides a pad BEFORE writing `enabled: false`, because that write
    regenerates config and removes the keybind. The ordering only buys anything
    if the hide is confirmed: reporting success without checking would let the
    bind go while the window was still on screen — the exact outcome hiding
    first exists to prevent, and the same defect `release()` had when its result
    was discarded before the record was deleted."""
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

    # The pad flock and focus-state files live under
    # $XDG_RUNTIME_DIR/vshell-scratchpad — the LIVE session's directory.
    # Sandbox them so this test cannot reach into the running shell's state.
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

            # A failed dispatch is reported too, not only the end state.
            seen["n"] = 0
            helper._scratchpad_visibility = _visibility_from(visible_then_gone)
            helper._scratchpad_dispatch = lambda *args: args[0] != "togglespecialworkspace"
            refused = helper.scratchpad_toggle("term", hide_only=True)
            assert_equal(refused["ok"], False, "a failed dispatch is not success")
            assert "could not toggle" in refused["error"], f"named, got {refused['error']!r}"

            # Already hidden stays a cheap idempotent success with no dispatch.
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
    """A failed `hyprctl -j monitors` used to be indistinguishable from a pad
    that is genuinely down: both produced an empty monitor name. Settings hides
    a pad before writing `enabled: false`, and that write removes the keybind —
    so a hide reporting success on a query that never ran drops the bind out
    from under a window that may still be up."""
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
    """VGS-86: a derived StartupWMClass is an exact class match, so it claims
    every current and future instance of the application. Nothing surfaced that,
    so a user running one terminal as a scratchpad and another tiled had both
    captured with no indication why. This query is what makes the breadth
    visible before the pattern is saved."""
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
        # The over-matching case, quantified: the derived pattern claims both.
        wide = helper.scratchpad_matching_windows(r"^(com\.mitchellh\.ghostty)$")
        assert_equal(wide["count"], 2, "a plain class match claims every instance")

        # A launch-time class override narrows to the pad's own window.
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

        # A bad title exclusion is an error for the same reason.
        bad_exclude = helper.scratchpad_matching_windows(r"^(x)$", "[")
        assert_equal(bad_exclude["ok"], False, "an uncompilable exclusion is an error")
        assert "title exclusion" in bad_exclude["error"], "and names which pattern"

        # The three states are mutually exclusive, so a caller can switch on
        # them without ambiguity.
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
    # The pad flock and focus-state files live under
    # $XDG_RUNTIME_DIR/vshell-scratchpad — the LIVE session's directory.
    # Sandbox them so this test cannot reach into the running shell's state.
    with _scratchpad_state_sandbox():
        try:
            # Entry: the monitor query fails outright. "Already hidden" would be a
            # claim nothing supports, and Settings would act on it.
            helper._hyprctl_json = lambda *a: None
            unknown = helper.scratchpad_toggle("term", hide_only=True)
            assert_equal(unknown["ok"], False, "an unanswerable query is not 'already hidden'")
            assert_equal(unknown["action"], "hide-unknown", "and is named")
            assert "could not determine" in unknown["error"], f"got {unknown['error']!r}"

            # Confirmation: visible at entry, then the read-back cannot be answered.
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

            # And the honest success still works: visible, then confirmed down.
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


def main():
    # A catalog download is minutes to hours of network transfer. Holding the
    # exclusive theme lock for that long would block applies, the light/dark
    # keybinding, wallpapers and restyles; the download takes the lock itself
    # for the directory swap, which is the only step that mutates theme state.
    for catalog_argv in (["catalog", "install", "ayu"], ["catalog", "install", "--all"],
                         ["catalog", "remove", "ayu"], ["catalog", "list"]):
        assert_equal(helper._theme_command_mutates(catalog_argv), False,
                     f"`theme {' '.join(catalog_argv)}` must not hold the theme lock for its whole run")
    assert_equal(helper._theme_command_mutates(["chromium-policy"]), True,
                 "Chromium policy refresh must serialize with theme applies")
    test_system_font_normalization()
    test_perceptual_theme_adjustments()
    test_curated_app_role_passthrough()
    test_restyle_integer_sweeps()
    test_fastfetch_portable_seed_and_logo_fallback()
    test_compositor_dependency_selection()
    test_capability_probe_reporting()
    test_compositor_detection_fallback()
    test_gtk_settings_merge_and_reset()
    test_apply_system_fonts_temp_home()
    test_hyprland_layout_payload()
    test_hyprland_blur_script()
    test_vshell_blur_cli_contract()
    test_generated_theme_consumer_wiring()
    test_shell_only_theme_preview()
    test_hyprland_preview_native_lua()
    test_greeter_primary_monitor_validation()
    test_greeter_runtime_helper_dependencies()
    test_launcher_search_unicode_ranges_and_preview()
    test_launcher_folder_opener_agreement()
    test_launcher_zoxide_results()
    test_duplicate_shell_guard()
    test_duplicate_shell_guard_uses_kernel_start_times()
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
    test_theme_catalog_download_verifies_every_file()
    test_theme_catalog_manifest_matches_the_repo()
    test_theme_catalog_generator_rejects_uninstallable_packages()
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
    # Fail here, with the reason, rather than in the Niri suite with none.
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
    subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "check-vshell-niri.py")],
        check=True,
    )
    print("VGS helper smoke tests passed.")


if __name__ == "__main__":
    main()
