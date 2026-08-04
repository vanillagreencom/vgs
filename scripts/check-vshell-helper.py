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
    binaries = ["yazi", "nautilus", "xdg-terminal-exec", "gio"]
    original_which = helper.shutil.which
    original_popen = helper.subprocess.Popen

    with tempfile.TemporaryDirectory() as tmp:
        for mask in range(1 << len(binaries)):
            present = {name for index, name in enumerate(binaries) if mask & (1 << index)}
            # Accept the absolute form too: _launcher_open_folder() re-checks
            # command[0], which by then is the resolved path.
            helper.shutil.which = lambda name, _p=present: (
                f"/usr/bin/{os.path.basename(name)}" if os.path.basename(name) in _p else None
            )
            helper.subprocess.Popen = lambda *a, **k: None
            try:
                for opener in helper._launcher_folder_openers():
                    if opener["id"] == "default":
                        # "Preferred app" is always offered and falls through to
                        # `gio open`; it is not probe-gated, so it is not a claim
                        # about an installed binary the way the others are.
                        continue
                    result = helper._launcher_open_folder(tmp, "", opener["id"])
                    assert_equal(
                        result.get("ok"), True,
                        f"advertised opener {opener['id']!r} must launch with {sorted(present)}"
                        f" (got {result.get('error')!r})",
                    )
            finally:
                helper.shutil.which = original_which
                helper.subprocess.Popen = original_popen


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
    helper.terminal_candidates = lambda: [["/bin/false"]]
    try:
        assert_equal(helper.launch_terminal(["true"]), helper.TERMINAL_EXIT_FAILED,
                     "A terminal that exits non-zero immediately must be a failure")
    finally:
        helper.terminal_candidates = original

    helper.terminal_candidates = lambda: []
    try:
        assert_equal(helper.launch_terminal(["true"]), 1,
                     "No terminal at all must report a distinct status")
    finally:
        helper.terminal_candidates = original

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
    helper.terminal_candidates = lambda: []          # no terminal anywhere
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
    any_commands = manifest["features"]["sudo-toggle"]["anyCommands"]
    assert_equal(len(any_commands), 1, "sudo-toggle must declare exactly one terminal alternative set")
    assert_equal(sorted(any_commands[0]), sorted(helper.TERMINAL_CANDIDATES),
                 "dependencies.json terminals must match helper TERMINAL_CANDIDATES")


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


def main():
    assert_equal(helper._theme_command_mutates(["chromium-policy"]), True,
                 "Chromium policy refresh must serialize with theme applies")
    test_system_font_normalization()
    test_perceptual_theme_adjustments()
    test_curated_app_role_passthrough()
    test_restyle_integer_sweeps()
    test_fastfetch_portable_seed_and_logo_fallback()
    test_compositor_dependency_selection()
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
    test_notification_status_respects_the_server_opt_out()
    subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "check-vshell-niri.py")],
        check=True,
    )
    print("VGS helper smoke tests passed.")


if __name__ == "__main__":
    main()
