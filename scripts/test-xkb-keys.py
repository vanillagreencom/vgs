#!/usr/bin/env python3
"""Exercise XKB mapping without a desktop, device, authentication or network.

Children receive a complete environment with a scratch HOME and no desktop
socket names. libxkbcommon reads only system keyboard data. Each independent
refusal has a defect planted in a helper copy and a named test that must fail.
The expected physical codes and canonical names are explicit fixture values.
"""

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

HELPER = Path(__file__).resolve().parent.parent / "bin/lib/xkb-keys.py"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("xkb_keys", HELPER)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


def request(keys, **keyboard):
    """A neutral system keyboard description, changed only by its case."""
    return {"keyboard": {"layout": "us", "variant": "", "options": "", "activeLayoutIndex": 0,
                         **keyboard}, "keys": keys}


class Mapping(unittest.TestCase):
    """End-to-end values and direct ABI failure cases."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.environment = {"HOME": str(self.root), "PATH": "/usr/bin:/bin", "LC_ALL": "C"}

    def run_helper(self, value, **environment):
        text = value if isinstance(value, str) else json.dumps(value)
        process = subprocess.run([sys.executable, "-I", str(HELPER)], input=text, text=True,
                                 capture_output=True, env={**self.environment, **environment}, check=False)
        answer = json.loads(process.stdout)
        self.assertEqual(process.returncode, 0 if answer["ok"] else 1, process.stderr)
        return answer

    def refused(self, value, error):
        self.assertEqual(self.run_helper(value), {"ok": False, "error": error})

    def test_us_symbols_aliases_and_modifiers(self):
        self.assertEqual(self.run_helper(request(["SUPER+CTRL+ALT+SHIFT+A", "PAGE_UP", "PRIOR",
                                                "XF86AUDIOMUTE", "PLUS", "AT"])), {
            "ok": True, "keys": [
                {"modifiers": ["SUPER", "CTRL", "ALT", "SHIFT"], "keycode": 38, "keysym": "a"},
                {"modifiers": [], "keycode": 112, "keysym": "Prior"},
                {"modifiers": [], "keycode": 112, "keysym": "Prior"},
                {"modifiers": [], "keycode": 121, "keysym": "XF86AudioMute"},
                {"modifiers": [], "keycode": 21, "keysym": "plus"},
                {"modifiers": [], "keycode": 11, "keysym": "at"},
            ]})

    def test_codes_use_xkb_numbering(self):
        rows = (("us", "Alt_R"), ("de", "ISO_Level3_Shift"))
        for layout, name in rows:
            with self.subTest(layout=layout):
                self.assertEqual(self.run_helper(request(["code:108"], layout=layout)), {
                    "ok": True, "keys": [{"modifiers": [], "keycode": 108, "keysym": name}]})

    def test_active_layout_and_variant(self):
        self.assertEqual(self.run_helper(request(["Z", "Y", "PLUS", "AT", "code:108"],
                                               layout="us,de", activeLayoutIndex=1)), {
            "ok": True, "keys": [
                {"modifiers": [], "keycode": 29, "keysym": "z"},
                {"modifiers": [], "keycode": 52, "keysym": "y"},
                {"modifiers": [], "keycode": 35, "keysym": "plus"},
                {"modifiers": [], "keycode": 24, "keysym": "at"},
                {"modifiers": [], "keycode": 108, "keysym": "ISO_Level3_Shift"},
            ]})
        self.assertEqual(self.run_helper(request(["Q"], variant="dvorak")), {
            "ok": True, "keys": [{"modifiers": [], "keycode": 53, "keysym": "q"}]})

    def test_nonstandard_options(self):
        self.assertEqual(self.run_helper(request(["code:108", "code:134", "code:66"],
                                               options="altwin:swap_ralt_rwin,caps:escape")), {
            "ok": True, "keys": [
                {"modifiers": [], "keycode": 108, "keysym": "Super_R"},
                {"modifiers": [], "keycode": 134, "keysym": "Alt_R"},
                {"modifiers": [], "keycode": 66, "keysym": "Escape"},
            ]})

    def test_unknown_options(self):
        self.refused(request(["A"], options="unknown:option"), "keyboard-options")

    def test_ambiguous_symbols(self):
        self.refused(request(["A", "ESCAPE"], options="caps:escape"), "keysym-ambiguous")

    def test_unresolvable_symbols(self):
        for name in ("NOT_A_KEYSYM", "CYRILLIC_YA"):
            with self.subTest(name=name):
                self.refused(request([name]), "keysym-unresolved")

    def test_zero_symbol_is_refused_before_scan(self):
        lib = SimpleNamespace(xkb_keymap_min_keycode=lambda keymap: 38,
                              xkb_keymap_max_keycode=lambda keymap: 38,
                              xkb_keysym_from_name=lambda name, flags: 0,
                              xkb_keymap_num_levels_for_key=lambda *args: 1)
        with mock.patch.object(helper, "symbols", return_value=(0,)) as scan, \
                mock.patch.object(helper, "symbol_name", return_value="NoSymbol"):
            with self.assertRaisesRegex(helper.Refusal, "^keysym-unresolved$"):
                helper.map_keys(lib, None, 0, [([], "NOT_A_KEYSYM")])
            scan.assert_not_called()

    def test_multi_symbol_level(self):
        lib = SimpleNamespace(xkb_keymap_min_keycode=lambda keymap: 38,
                              xkb_keymap_max_keycode=lambda keymap: 38,
                              xkb_keysym_from_name=lambda name, flags: 0x61,
                              xkb_keymap_num_levels_for_key=lambda *args: 1)
        with mock.patch.object(helper, "symbols", return_value=(0x61, 0x62)), \
                mock.patch.object(helper, "symbol_name", return_value="a"):
            with self.assertRaisesRegex(helper.Refusal, "^keysym-ambiguous$"):
                helper.map_keys(lib, None, 0, [([], "A")])

    def test_symbol_name_bounds(self):
        def name(symbol, buffer, size):
            buffer.value = b"a"
            return length
        for length in (-1, 0, 128):
            with self.subTest(length=length):
                with self.assertRaisesRegex(helper.Refusal, "^xkb-keysym$"):
                    helper.symbol_name(SimpleNamespace(xkb_keysym_get_name=name), 0x61)

    def test_invalid_codes(self):
        for name in ("code:0", "code:4294967295", "code:4294967296", "code:100000000000",
                     "code:00000000000038", "code:-1", "code:xyz"):
            with self.subTest(name=name):
                self.refused(request([name]), "keycode-range")

    def test_absent_code(self):
        self.refused(request(["code:97"]), "keycode-unresolved")

    def test_empty_keys(self):
        self.assertEqual(self.run_helper(request([])), {"ok": True, "keys": []})

    def test_json(self):
        for text in ("", "{", '{"keyboard":{},"keyboard":{},"keys":[]}'):
            with self.subTest(text=text):
                self.refused(text, "input-json")

    def test_input_shape(self):
        for value in ([], {}, {**request([]), "extra": True}):
            with self.subTest(value=value):
                self.refused(value, "input-shape")

    def test_keyboard_shape(self):
        rows = ([], {}, {**request([])["keyboard"], "extra": True})
        for keyboard in rows:
            with self.subTest(keyboard=keyboard):
                self.refused({"keyboard": keyboard, "keys": []}, "keyboard-shape")

    def test_keyboard_names(self):
        rows = (("layout", None), ("layout", ""), ("layout", "us,,de"), ("layout", "../../us"),
                ("variant", []), ("variant", "dvorak,neo"), ("variant", "x:y"),
                ("options", {}), ("options", "caps:escape\x00ignored"))
        for field, value in rows:
            with self.subTest(field=field, value=value):
                self.refused(request(["A"], **{field: value}), "keyboard-" + field)

    def test_active_layout_index(self):
        for index in (-1, 1, True, 0.5, None):
            with self.subTest(index=index):
                self.refused(request(["A"], activeLayoutIndex=index), "active-layout")

    def test_compiled_layout_index(self):
        lib = helper.load_library()
        with mock.patch.object(helper, "load_library", return_value=lib), \
                mock.patch.object(lib, "xkb_keymap_num_layouts", return_value=1):
            with self.assertRaisesRegex(helper.Refusal, "^active-layout$"):
                helper.resolve(request(["A"], layout="us,de", activeLayoutIndex=1))

    def test_key_shape(self):
        for keys, error in ((None, "keys-shape"), ({}, "keys-shape"), ([None], "key-shape"),
                            ([""], "key-shape"), (["CTRL+SUPER+A"], "key-shape"),
                            (["SUPER+SUPER+A"], "key-shape"), (["UNKNOWN+A"], "key-shape"),
                            (["A\x00junk"], "key-shape"), (["é"], "key-shape")):
            with self.subTest(keys=keys):
                self.refused(request(keys), error)

    def test_unsupported_layout(self):
        self.refused(request(["A"], layout="not_a_layout"), "xkb-keymap")
        self.refused(request(["A"], variant="not_a_variant"), "xkb-keymap")

    def test_missing_library(self):
        with mock.patch.object(helper.ctypes, "CDLL", side_effect=OSError("missing")):
            with self.assertRaisesRegex(helper.Refusal, "^xkb-library$"):
                helper.resolve(request(["A"]))

    def test_missing_abi(self):
        with mock.patch.object(helper.ctypes, "CDLL", return_value=object()):
            with self.assertRaisesRegex(helper.Refusal, "^xkb-library$"):
                helper.resolve(request(["A"]))

    def test_missing_context(self):
        lib = SimpleNamespace(xkb_context_new=lambda flags: 0,
                              xkb_context_include_path_append=lambda *args: 1,
                              xkb_keymap_new_from_names=lambda *args: 1,
                              xkb_keymap_num_layouts=lambda *args: 1,
                              xkb_keymap_unref=mock.Mock(), xkb_context_unref=mock.Mock())
        with mock.patch.object(helper, "load_library", return_value=lib), \
                mock.patch.object(helper, "map_keys", return_value=[]):
            with self.assertRaisesRegex(helper.Refusal, "^xkb-context$"):
                helper.resolve(request(["A"]))

    def test_missing_data(self):
        with mock.patch.object(helper, "SYSTEM_XKB_ROOT", str(self.root / "missing")):
            with self.assertRaisesRegex(helper.Refusal, "^xkb-data$"):
                helper.resolve(request(["A"]))

    def test_missing_option_catalog(self):
        for value in ("", "! layout\n  us US\n"):
            with self.subTest(value=value), mock.patch.object(helper.Path, "read_text", return_value=value):
                with self.assertRaisesRegex(helper.Refusal, "^xkb-option-catalog$"):
                    helper.resolve(request(["A"], options="caps:escape"))
        with mock.patch.object(helper.Path, "read_text", side_effect=OSError("missing")):
            with self.assertRaisesRegex(helper.Refusal, "^xkb-option-catalog$"):
                helper.resolve(request(["A"], options="caps:escape"))

    def test_environment_cannot_supply_names_or_includes(self):
        # A valid hostile layout proves a misplaced user include can change
        # the result. An invalid file could also fail with the guard removed.
        symbols = self.root / ".config/xkb/symbols"
        symbols.mkdir(parents=True)
        (symbols / "us").write_text('default xkb_symbols "basic" { key <RALT> { [ F13 ] }; };\n')
        self.assertEqual(self.run_helper(request(["code:108"]), XKB_DEFAULT_LAYOUT="de",
                                        XKB_CONFIG_ROOT=str(self.root / ".config/xkb"),
                                        XDG_CONFIG_HOME=str(self.root / ".config")), {
            "ok": True, "keys": [{"modifiers": [], "keycode": 108, "keysym": "Alt_R"}]})

    def test_resources_released_after_refusal(self):
        lib = helper.load_library()
        with mock.patch.object(helper, "load_library", return_value=lib), \
                mock.patch.object(lib, "xkb_context_unref", wraps=lib.xkb_context_unref) as context_unref, \
                mock.patch.object(lib, "xkb_keymap_unref", wraps=lib.xkb_keymap_unref) as keymap_unref:
            with self.assertRaisesRegex(helper.Refusal, "^keysym-ambiguous$"):
                helper.resolve(request(["ESCAPE"], options="caps:escape"))
            context_unref.assert_called_once()
            keymap_unref.assert_called_once()


class Controls(unittest.TestCase):
    """Keep each rule's matched text and remove its behavior in a copy."""

    PLANTS = (
        ("input fields", 'set(value) != {"keyboard", "keys"}', "False", "test_input_shape"),
        ("keyboard fields", 'set(keyboard) != {"layout", "variant", "options", "activeLayoutIndex"}',
         "False", "test_keyboard_shape"),
        ("names", 'not isinstance(text, str) or not re.fullmatch(r"[A-Za-z0-9_,:-]*", text)',
         "False", "test_keyboard_names"),
        ("layout names", 'any(not re.fullmatch(r"[A-Za-z0-9_-]+", name) for name in layouts)',
         "False", "test_keyboard_names"),
        ("variant arity", "len(variants) > len(layouts)", "False", "test_keyboard_names"),
        ("variant names", 'any(not re.fullmatch(r"[A-Za-z0-9_-]*", name) for name in variants)',
         "False", "test_keyboard_names"),
        ("active index type", "type(index) is not int", "False", "test_active_layout_index"),
        ("active index bounds", "not 0 <= index < len(layouts)", "False", "test_active_layout_index"),
        ("keys array", "not isinstance(keys, list)", "False", "test_key_shape"),
        ("key wire shape", 'not isinstance(key, str) or not key or not key.isascii() or "\\x00" in key',
         "False", "test_key_shape"),
        ("modifier wire order", 'modifiers != [mod for mod in MODIFIERS if mod in modifiers]',
         "False", "test_key_shape"),
        ("empty catalog", "if not supported:", "if False:", "test_missing_option_catalog"),
        ("catalog failure", "except (OSError, UnicodeError) as error:", "except RuntimeError as error:",
         "test_missing_option_catalog"),
        ("unknown options", 'any(option not in supported for option in options.split(","))',
         "False", "test_unknown_options"),
        ("code decimal", 'not re.fullmatch(r"[0-9]+", text)', "False", "test_invalid_codes"),
        ("code length", "len(text) > 10", "False", "test_invalid_codes"),
        ("code bounds", "if not minimum <= code <= maximum:", "if False:", "test_invalid_codes"),
        ("code symbol", "if len(found) != 1 or found[0] == 0:", "if False:", "test_absent_code"),
        ("symbol exists", "if symbol == 0:", "if False:", "test_zero_symbol_is_refused_before_scan"),
        ("symbol on layout", "if not matches:", "if False:", "test_unresolvable_symbols"),
        ("one physical code", "if len(matches) != 1:", "if False:", "test_ambiguous_symbols"),
        ("one symbol per level", "if len(found) != 1:", "if False:", "test_multi_symbol_level"),
        ("symbol name failure", "length <= 0", "False", "test_symbol_name_bounds"),
        ("symbol name truncation", "length >= len(buffer)", "False", "test_symbol_name_bounds"),
        ("library failure", "except (OSError, AttributeError) as error:", "except RuntimeError as error:",
         "test_missing_library"),
        ("context failure", "if not context:", "if False:", "test_missing_context"),
        ("include failure", 'lib.xkb_context_include_path_append(context, SYSTEM_XKB_ROOT.encode("utf-8")) != 1',
         "False", "test_missing_data"),
        ("keymap failure", "if not keymap:", "if False:", "test_unsupported_layout"),
        ("compiled layout bound", "layout >= lib.xkb_keymap_num_layouts(keymap)",
         "False", "test_compiled_layout_index"),
        ("JSON duplicates", "if len(value) != len(pairs):", "if False:", "test_json"),
        ("system includes", "context = lib.xkb_context_new(3)", "context = lib.xkb_context_new(2)",
         "test_environment_cannot_supply_names_or_includes"),
        ("XKB numbering", "code = int(text)", "code = int(text) + 8", "test_codes_use_xkb_numbering"),
        ("active group", 'layout = keyboard["activeLayoutIndex"]', "layout = 0", "test_active_layout_and_variant"),
        ("canonical names", 'return buffer.value.decode("ascii")', 'return buffer.value.decode("ascii").upper()',
         "test_us_symbols_aliases_and_modifiers"),
        ("level scan", "for level in range(levels):", "for level in range(min(levels, 1)):",
         "test_us_symbols_aliases_and_modifiers"),
        ("keymap cleanup", "lib.xkb_keymap_unref(keymap)", "None", "test_resources_released_after_refusal"),
        ("context cleanup", "lib.xkb_context_unref(context)", "None", "test_resources_released_after_refusal"),
    )

    def run_copy(self, source, tests):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            copied = root / "bin/lib/xkb-keys.py"
            copied.parent.mkdir(parents=True)
            copied.write_text(source)
            suite = root / "scripts/test-xkb-keys.py"
            suite.parent.mkdir()
            shutil.copyfile(Path(__file__), suite)
            return subprocess.run([sys.executable, "-I", str(suite), *["Mapping." + test for test in tests]],
                                  text=True, capture_output=True, check=False,
                                  env={"HOME": str(root), "PATH": "/usr/bin:/bin", "LC_ALL": "C"})

    def test_unplanted_copy(self):
        process = self.run_copy(HELPER.read_text(), sorted({plant[3] for plant in self.PLANTS}))
        self.assertEqual(process.returncode, 0, process.stderr)

    def test_each_rule_turns_red(self):
        source = HELPER.read_text()
        for name, old, new, test in self.PLANTS:
            with self.subTest(rule=name):
                self.assertEqual(source.count(old), 1, name)
                changed = source.replace(old, new)
                self.assertNotEqual(changed, source)
                process = self.run_copy(changed, [test])
                self.assertNotEqual(process.returncode, 0, f"{name} left {test} green")
                self.assertIn("FAILED", process.stderr, process.stderr)


if __name__ == "__main__":
    unittest.main()
