from __future__ import annotations

import math
import re
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Tuple


@dataclass(frozen=True)
class ThemeColorRuntime:
    clean_hex: Callable[..., str]
    rgb: Callable[[str], Tuple[int, int, int]]
    hexc: Callable[[float, float, float], str]
    clamp: Callable[[float, float, float], float]
    contrast_ratio: Callable[[str, str], float]
    ensure_contrast: Callable[..., str]


_runtime: ThemeColorRuntime | None = None
HEX_RE = re.compile(r"^#?[0-9a-fA-F]{6}$")
ADJUST_KEYS = ("brightness", "vibrancy", "contrast", "hue", "temperature")
ADJUST_RANGE = {
    "brightness": 100,
    "vibrancy": 100,
    "contrast": 100,
    "hue": 180,
    "temperature": 100,
}
BASE_COLOR_KEYS = [
    "background", "foreground", "accent", "cursor",
    "selection_background", "selection_foreground",
    *(f"color{i}" for i in range(16)),
]


def configure(runtime: ThemeColorRuntime) -> None:
    global _runtime
    _runtime = runtime


def runtime() -> ThemeColorRuntime:
    if _runtime is None:
        raise RuntimeError("vshell_theme_color runtime is not configured")
    return _runtime


def _srgb_to_linear(channel: float) -> float:
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def _linear_to_srgb(channel: float) -> float:
    return 12.92 * channel if channel <= 0.0031308 else 1.055 * (max(0.0, channel) ** (1.0 / 2.4)) - 0.055


def color_to_oklab(value: str) -> Tuple[float, float, float]:
    r, g, b = [_srgb_to_linear(channel / 255.0) for channel in runtime().rgb(value)]
    ll = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    mm = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    ss = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_root = math.copysign(abs(ll) ** (1.0 / 3.0), ll)
    m_root = math.copysign(abs(mm) ** (1.0 / 3.0), mm)
    s_root = math.copysign(abs(ss) ** (1.0 / 3.0), ss)
    return (
        0.2104542553 * l_root + 0.7936177850 * m_root - 0.0040720468 * s_root,
        1.9779984951 * l_root - 2.4285922050 * m_root + 0.4505937099 * s_root,
        0.0259040371 * l_root + 0.7827717662 * m_root - 0.8086757660 * s_root,
    )


def _oklab_to_srgb_raw(lightness: float, a: float, b: float) -> Tuple[float, float, float]:
    l_root = lightness + 0.3963377774 * a + 0.2158037573 * b
    m_root = lightness - 0.1055613458 * a - 0.0638541728 * b
    s_root = lightness - 0.0894841775 * a - 1.2914855480 * b
    ll, mm, ss = l_root ** 3, m_root ** 3, s_root ** 3
    red = +4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss
    green = -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss
    blue = -0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss
    return _linear_to_srgb(red), _linear_to_srgb(green), _linear_to_srgb(blue)


def _oklch_in_gamut(lightness: float, chroma: float, hue_degrees: float) -> bool:
    radians = math.radians(hue_degrees % 360.0)
    channels = _oklab_to_srgb_raw(
        lightness,
        chroma * math.cos(radians),
        chroma * math.sin(radians),
    )
    return all(-1e-7 <= channel <= 1.0000001 for channel in channels)


def _oklch_max_chroma(lightness: float, hue_degrees: float) -> float:
    lightness = runtime().clamp(lightness, 0.00001, 0.99999)
    low, high = 0.0, 0.4
    while high < 1.6 and _oklch_in_gamut(lightness, high, hue_degrees):
        low, high = high, high * 2.0
    for _ in range(20):
        mid = (low + high) / 2.0
        if _oklch_in_gamut(lightness, mid, hue_degrees):
            low = mid
        else:
            high = mid
    return low


def _bounded_lightness(lightness: float, shift: float, lower: float = 0.04,
                       upper: float = 0.96) -> float:
    if not shift:
        return lightness
    clamp = runtime().clamp
    lower = clamp(lower, 0.0, 0.99998)
    upper = clamp(upper, lower + 0.00001, 1.0)
    normalized = clamp((lightness - lower) / (upper - lower), 0.00001, 0.99999)
    logit = math.log(normalized / (1.0 - normalized))
    shifted = 1.0 / (1.0 + math.exp(-(logit + shift * 1.65)))
    return lower + clamp(shifted, 0.00001, 0.99999) * (upper - lower)


def _relative_oklch(value: str, stabilize_edges: bool = True) -> Tuple[float, float, float, float]:
    lightness, a, b = color_to_oklab(value)
    chroma = math.hypot(a, b)
    hue_degrees = math.degrees(math.atan2(b, a)) if chroma > 1e-8 else 0.0
    maximum = _oklch_max_chroma(lightness, hue_degrees)
    relative = runtime().clamp(chroma / maximum, 0.0, 1.0) if maximum > 1e-8 else 0.0
    if stabilize_edges:
        edge_reliability = runtime().clamp(
            min(lightness, 1.0 - lightness) / 0.12, 0.0, 1.0
        )
        relative *= edge_reliability * edge_reliability
    return lightness, relative, chroma, hue_degrees


def _map_oklch_lightness(value: str, lightness: float, hue_degrees: float | None = None,
                         relative_chroma: float | None = None) -> str:
    _old_l, old_relative, _old_chroma, old_hue = _relative_oklch(value)
    target_hue = old_hue if hue_degrees is None else hue_degrees
    target_relative = (
        old_relative if relative_chroma is None
        else runtime().clamp(relative_chroma, 0.0, 1.0)
    )
    target_chroma = target_relative * _oklch_max_chroma(lightness, target_hue)
    return oklch_to_hex(lightness, target_chroma, target_hue)


def oklch_to_hex(lightness: float, chroma: float, hue_degrees: float) -> str:
    clamp = runtime().clamp
    lightness = clamp(lightness, 0.0, 1.0)
    chroma = max(0.0, chroma)
    radians = math.radians(hue_degrees % 360.0)

    def raw(candidate_chroma: float) -> Tuple[float, float, float]:
        return _oklab_to_srgb_raw(
            lightness,
            candidate_chroma * math.cos(radians),
            candidate_chroma * math.sin(radians),
        )

    channels = raw(chroma)
    if not _oklch_in_gamut(lightness, chroma, hue_degrees):
        low, high = 0.0, chroma
        for _ in range(18):
            mid = (low + high) / 2.0
            if all(-1e-7 <= channel <= 1.0000001 for channel in raw(mid)):
                low = mid
            else:
                high = mid
        channels = raw(low)
    return runtime().hexc(*(clamp(channel, 0.0, 1.0) * 255.0 for channel in channels))


def _oklab_contrast_adjust(value: str, bg: str, min_ratio: float, prefer: str) -> str:
    value = runtime().clean_hex(value)
    if runtime().contrast_ratio(value, bg) >= min_ratio:
        return value
    lightness, relative_chroma, _chroma, hue_degrees = _relative_oklch(value)
    preferred_end = 0.00001 if runtime().clean_hex(prefer) == "#000000" else 0.99999
    for endpoint in (preferred_end, 1.0 - preferred_end):
        end_color = _map_oklch_lightness(value, endpoint, hue_degrees, relative_chroma)
        if runtime().contrast_ratio(end_color, bg) < min_ratio:
            continue
        low, high = 0.0, 1.0
        for _ in range(18):
            fraction = (low + high) / 2.0
            candidate_l = lightness + (endpoint - lightness) * fraction
            candidate = _map_oklch_lightness(value, candidate_l, hue_degrees, relative_chroma)
            if runtime().contrast_ratio(candidate, bg) >= min_ratio:
                high = fraction
            else:
                low = fraction
        return _map_oklch_lightness(
            value, lightness + (endpoint - lightness) * high,
            hue_degrees, relative_chroma,
        )
    return runtime().ensure_contrast(value, bg, min_ratio, prefer)


def normalize_adjustments(raw: Any) -> Dict[str, int]:
    data = raw if isinstance(raw, dict) else {}
    out: Dict[str, int] = {}
    for key in ADJUST_KEYS:
        try:
            raw_value = float(data.get(key, 0) or 0)
            value = int(round(raw_value)) if math.isfinite(raw_value) else 0
        except (TypeError, ValueError, OverflowError):
            value = 0
        limit = ADJUST_RANGE[key]
        out[key] = int(runtime().clamp(value, -limit, limit))
    return out


def adjustments_all_zero(adj: Dict[str, int]) -> bool:
    return all(int(adj.get(key, 0) or 0) == 0 for key in ADJUST_KEYS)


def apply_adjustments(colors: Dict[str, str], adj: Dict[str, int]) -> Dict[str, str]:
    adj = normalize_adjustments(adj)
    if adjustments_all_zero(adj):
        return dict(colors)
    brightness = adj["brightness"] / 100.0
    vibrancy = adj["vibrancy"] / 100.0
    contrast = adj["contrast"] / 100.0
    hue_shift = float(adj["hue"])
    temperature = adj["temperature"] / 100.0
    lightness_values: List[float] = []
    for key in BASE_COLOR_KEYS:
        value = colors.get(key)
        if isinstance(value, str) and HEX_RE.match(value.strip()):
            lightness_values.append(color_to_oklab(value)[0])
    mean_lightness = sum(lightness_values) / len(lightness_values) if lightness_values else 0.5
    shifted_mean = _bounded_lightness(mean_lightness, brightness)
    palette_mode = str(colors.get("mode") or colors.get("theme_type") or "").lower()
    clamp = runtime().clamp

    def transform(value: str, key: str = "") -> str:
        original_l, relative_chroma, _chroma, original_hue = _relative_oklch(
            value, stabilize_edges=False
        )
        bounds = (
            0.00001 if original_l <= 0.04 else 0.04,
            0.99999 if original_l >= 0.96 else 0.96,
        )
        if key in {"background", "bg"}:
            if palette_mode == "dark" and original_l < 0.45:
                bounds = (0.055, 0.45)
            elif palette_mode == "light" and original_l > 0.70:
                bounds = (0.70, 0.98)
        lightness = _bounded_lightness(original_l, brightness, *bounds)
        if contrast:
            epsilon = 0.00001
            center = clamp(shifted_mean, epsilon, 1.0 - epsilon)
            tone = clamp(lightness, epsilon, 1.0 - epsilon)
            center_logit = math.log(center / (1.0 - center))
            tone_logit = math.log(tone / (1.0 - tone))
            tone_logit = center_logit + (
                tone_logit - center_logit
            ) * (1.0 + contrast * 0.65)
            lightness = clamp(1.0 / (1.0 + math.exp(-tone_logit)), *bounds)
        if vibrancy >= 0:
            relative_chroma = 1.0 - (1.0 - relative_chroma) ** (1.0 + vibrancy)
        else:
            relative_chroma *= 1.0 + vibrancy
        hue_degrees = original_hue + hue_shift
        chroma = relative_chroma * _oklch_max_chroma(lightness, hue_degrees)
        radians = math.radians(hue_degrees)
        a = chroma * math.cos(radians)
        b = chroma * math.sin(radians)
        if temperature:
            a += temperature * 0.012
            b += temperature * 0.045
        chroma = math.hypot(a, b)
        hue_degrees = math.degrees(math.atan2(b, a)) if chroma > 1e-8 else 0.0
        chroma = min(chroma, _oklch_max_chroma(lightness, hue_degrees))
        return oklch_to_hex(lightness, chroma, hue_degrees)

    out = dict(colors)
    for key, value in colors.items():
        if isinstance(value, str) and HEX_RE.match(value.strip()):
            out[key] = transform(value, key)
    return out
