#!/usr/bin/env python3
"""Resolve normalized Hyprland keys against the supplied keyboard layout.

stdin: {keyboard: {layout, variant, options, activeLayoutIndex}, keys: [str]}.
stdout: {ok: true, keys: [{modifiers: [str], keycode: int, keysym: str}]}
or {ok: false, error: str}; failure exits 1. A dual request adds
translation: {keyboard, keys}; its success also includes translation: [row].
Both requests must resolve before the helper writes a success response.
Codes use the XKB convention
that Hyprland uses for code: binds. A symbol names its canonical keysym;
a code names the symbol at the active layout's base level. No input is sent.
The caller owns key normalization in PluginLogic.hyprlandKey.

API sources: https://xkbcommon.org/doc/current/group__context.html,
https://xkbcommon.org/doc/current/group__include-path.html,
https://xkbcommon.org/doc/current/group__keymap.html,
https://xkbcommon.org/doc/current/group__keymap-iterator.html and
https://xkbcommon.org/doc/current/group__keysyms.html.
The established new_from_names API serves the installed libxkbcommon ABI.
Only the packaged system rules are included. XKB silently ignores unknown
options, so their names must occur in the system rules' public evdev.lst
catalog before compilation. Layout and variant support comes from XKB.
"""

import ctypes
import json
from pathlib import Path
import re
import sys

SYSTEM_XKB_ROOT = "/usr/share/X11/xkb"
SYSTEM_XKB_LIBRARY = "libxkbcommon.so.0"
MODIFIERS = ("SUPER", "CTRL", "ALT", "SHIFT")


class Refusal(Exception):
    """A stable error key for a mapping the helper cannot establish."""


class RuleNames(ctypes.Structure):
    """The public xkb_rule_names structure, in its ABI field order."""

    _fields_ = [(field, ctypes.c_char_p)
                for field in ("rules", "model", "layout", "variant", "options")]


def load_library():
    """Load the system ABI and declare every function used across ctypes."""
    try:
        lib = ctypes.CDLL(SYSTEM_XKB_LIBRARY)
        pointer, uint = ctypes.c_void_p, ctypes.c_uint32
        signatures = {
            "xkb_context_new": (pointer, [ctypes.c_int]),
            "xkb_context_unref": (None, [pointer]),
            "xkb_context_include_path_append": (ctypes.c_int, [pointer, ctypes.c_char_p]),
            "xkb_keymap_new_from_names": (pointer, [pointer, ctypes.POINTER(RuleNames), ctypes.c_int]),
            "xkb_keymap_unref": (None, [pointer]),
            "xkb_keymap_num_layouts": (uint, [pointer]),
            "xkb_keymap_min_keycode": (uint, [pointer]),
            "xkb_keymap_max_keycode": (uint, [pointer]),
            "xkb_keymap_num_levels_for_key": (uint, [pointer, uint, uint]),
            "xkb_keymap_key_get_syms_by_level":
                (ctypes.c_int, [pointer, uint, uint, uint, ctypes.POINTER(ctypes.POINTER(uint))]),
            "xkb_keysym_from_name": (uint, [ctypes.c_char_p, ctypes.c_int]),
            "xkb_keysym_get_name": (ctypes.c_int, [uint, ctypes.c_char_p, ctypes.c_size_t]),
        }
        for name, (result, arguments) in signatures.items():
            function = getattr(lib, name)
            function.restype, function.argtypes = result, arguments
        return lib
    except (OSError, AttributeError) as error:
        raise Refusal("xkb-library") from error


def parse_input(value):
    """Check the wire shape without changing the caller's normalized keys."""
    if not isinstance(value, dict) or set(value) != {"keyboard", "keys"}:
        raise Refusal("input-shape")
    keyboard, keys = value["keyboard"], value["keys"]
    if not isinstance(keyboard, dict) or set(keyboard) != {"layout", "variant", "options", "activeLayoutIndex"}:
        raise Refusal("keyboard-shape")
    for field in ("layout", "variant", "options"):
        text = keyboard[field]
        if not isinstance(text, str) or not re.fullmatch(r"[A-Za-z0-9_,:-]*", text):
            raise Refusal("keyboard-" + field)
    layouts = keyboard["layout"].split(",")
    if any(not re.fullmatch(r"[A-Za-z0-9_-]+", name) for name in layouts):
        raise Refusal("keyboard-layout")
    variants = keyboard["variant"].split(",")
    if len(variants) > len(layouts) or any(not re.fullmatch(r"[A-Za-z0-9_-]*", name) for name in variants):
        raise Refusal("keyboard-variant")
    index = keyboard["activeLayoutIndex"]
    if type(index) is not int or not 0 <= index < len(layouts):
        raise Refusal("active-layout")
    if not isinstance(keys, list):
        raise Refusal("keys-shape")
    parsed = []
    for key in keys:
        if not isinstance(key, str) or not key or not key.isascii() or "\x00" in key:
            raise Refusal("key-shape")
        parts = key.split("+")
        modifiers, name = parts[:-1], parts[-1]
        if modifiers != [mod for mod in MODIFIERS if mod in modifiers] or not name:
            raise Refusal("key-shape")
        parsed.append((modifiers, name))
    return keyboard, parsed


def check_options(options):
    """Refuse options that the system rules would otherwise silently ignore."""
    if not options:
        return
    try:
        lines = (Path(SYSTEM_XKB_ROOT) / "rules/evdev.lst").read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise Refusal("xkb-option-catalog") from error
    section, supported = "", set()
    for line in lines:
        if line.startswith("!"):
            section = line[1:].strip()
        elif section == "option" and line.strip():
            supported.add(line.split()[0])
    if not supported:
        raise Refusal("xkb-option-catalog")
    if any(option not in supported for option in options.split(",")):
        raise Refusal("keyboard-options")


def symbols(lib, keymap, code, layout, level):
    """Copy the XKB-owned symbol array before the next library operation."""
    found = ctypes.POINTER(ctypes.c_uint32)()
    count = lib.xkb_keymap_key_get_syms_by_level(keymap, code, layout, level, ctypes.byref(found))
    return tuple(found[i] for i in range(count))


def symbol_name(lib, symbol):
    """Return an untruncated canonical name suitable for wtype's -k argument."""
    buffer = ctypes.create_string_buffer(128)
    length = lib.xkb_keysym_get_name(symbol, buffer, len(buffer))
    if length <= 0 or length >= len(buffer):
        raise Refusal("xkb-keysym")
    return buffer.value.decode("ascii")


def map_keys(lib, keymap, layout, keys):
    """Resolve one physical code per key; refuse absent or ambiguous symbols."""
    minimum, maximum = lib.xkb_keymap_min_keycode(keymap), lib.xkb_keymap_max_keycode(keymap)
    result = []
    for modifiers, name in keys:
        if name.startswith("code:"):
            text = name[5:]
            if not re.fullmatch(r"[0-9]+", text) or len(text) > 10:
                raise Refusal("keycode-range")
            code = int(text)
            if not minimum <= code <= maximum:
                raise Refusal("keycode-range")
            found = symbols(lib, keymap, code, layout, 0)
            if len(found) != 1 or found[0] == 0:
                raise Refusal("keycode-unresolved")
            symbol = found[0]
        else:
            symbol = lib.xkb_keysym_from_name(name.encode("ascii"), 1)
            if symbol == 0:
                raise Refusal("keysym-unresolved")
            matches = set()
            for candidate in range(minimum, maximum + 1):
                levels = lib.xkb_keymap_num_levels_for_key(keymap, candidate, layout)
                for level in range(levels):
                    found = symbols(lib, keymap, candidate, layout, level)
                    if symbol in found:
                        if len(found) != 1:
                            raise Refusal("keysym-ambiguous")
                        matches.add(candidate)
            if not matches:
                raise Refusal("keysym-unresolved")
            if len(matches) != 1:
                raise Refusal("keysym-ambiguous")
            code = next(iter(matches))
        result.append({"modifiers": modifiers, "keycode": code, "keysym": symbol_name(lib, symbol)})
    return result


def resolve(value):
    """Own the context and keymap for one request, including refusal cleanup."""
    keyboard, keys = parse_input(value)
    check_options(keyboard["options"])
    lib = load_library()
    context = lib.xkb_context_new(3)
    if not context:
        raise Refusal("xkb-context")
    try:
        if lib.xkb_context_include_path_append(context, SYSTEM_XKB_ROOT.encode("utf-8")) != 1:
            raise Refusal("xkb-data")
        names = RuleNames(b"evdev", b"pc105", *(keyboard[field].encode("ascii")
                                               for field in ("layout", "variant", "options")))
        keymap = lib.xkb_keymap_new_from_names(context, ctypes.byref(names), 0)
        if not keymap:
            raise Refusal("xkb-keymap")
        try:
            layout = keyboard["activeLayoutIndex"]
            if layout >= lib.xkb_keymap_num_layouts(keymap):
                raise Refusal("active-layout")
            return {"ok": True, "keys": map_keys(lib, keymap, layout, keys)}
        finally:
            lib.xkb_keymap_unref(keymap)
    finally:
        lib.xkb_context_unref(context)


def unique_object(pairs):
    """Reject duplicate JSON fields rather than silently replacing a value."""
    value = dict(pairs)
    if len(value) != len(pairs):
        raise Refusal("input-json")
    return value


def resolve_request(value):
    """Resolve the native and optional translation maps as one response."""
    if not isinstance(value, dict) or "translation" not in value:
        return resolve(value)
    if set(value) != {"keyboard", "keys", "translation"}:
        raise Refusal("input-shape")
    native = resolve({"keyboard": value["keyboard"], "keys": value["keys"]})
    translated = resolve(value["translation"])
    return {"ok": True, "keys": native["keys"], "translation": translated["keys"]}


def main():
    """Write one complete answer; an unresolved key never yields a partial set."""
    try:
        value = json.load(sys.stdin, object_pairs_hook=unique_object)
        answer = resolve_request(value)
    except (ValueError, UnicodeError):
        answer = {"ok": False, "error": "input-json"}
    except Refusal as error:
        answer = {"ok": False, "error": str(error)}
    print(json.dumps(answer, separators=(",", ":")))
    return 0 if answer["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
