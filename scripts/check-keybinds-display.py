#!/usr/bin/env python3
"""How the keybinds cheatsheet names the key a shortcut fires on.

A bind written on a raw keycode is the case under test throughout: hyprctl
reports key=""/keycode=0 for one whose keycode the active layout leaves
unmapped, so the name has to come from the config source and from the user,
and every path that guesses instead of knowing is a wrong key on screen.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = REPO_ROOT / "bin" / "vshell-helper"


def load_helper():
    loader = importlib.machinery.SourceFileLoader("vshell_helper_keybinds_test", str(HELPER_PATH))
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
    # XDG_CONFIG_HOME travels with HOME, or a helper resolving config through
    # it reads the real ~/.config out of a test that thought it was isolated.
    old_home = os.environ.get("HOME")
    old_xdg = os.environ.get("XDG_CONFIG_HOME")
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["HOME"] = tmp
        os.environ["XDG_CONFIG_HOME"] = str(Path(tmp) / ".config")
        try:
            fn(Path(tmp))
        finally:
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home
            if old_xdg is None:
                os.environ.pop("XDG_CONFIG_HOME", None)
            else:
                os.environ["XDG_CONFIG_HOME"] = old_xdg


def test_keycode_binds_get_a_key_name_instead_of_a_raw_code():
    """A bind written by raw keycode is all hyprctl can report back, and
    `code:191` names nothing to the person reading the cheatsheet. X11 keycodes
    are evdev + 8, so 191 is KEY_F13 -- the block standard layouts leave
    without a keysym, which is exactly why such binds get written by code."""
    assert_equal(helper._keycode_display_name("code:191"), "F13",
                 "keycode 191 is KEY_F13")
    assert_equal(helper._keycode_display_name("code:202"), "F24",
                 "the F13-F24 block resolves at both ends")
    assert_equal(helper._keycode_display_name("code:9"), "code:9",
                 "a keycode with no well-known name is left as written")
    assert_equal(helper._keycode_display_name("code:notanumber"), "code:notanumber",
                 "a malformed keycode is left alone rather than raising")
    assert_equal(helper._keycode_display_name("Escape"), "Escape",
                 "a keysym bind is not a keycode and passes through")


def test_keybind_labels_name_a_key_the_layout_cannot():
    """A remapper can put a key on the wire that no layout names and that no
    longer resembles what was physically pressed; only the person who set it
    up knows. The label is theirs to supply, by either spelling."""
    labels = {"F13": "Right Alt"}
    assert_equal(helper._display_combo("code:191", labels), "Right Alt",
                 "a label keyed by the resolved name applies to the raw code")
    assert_equal(helper._display_combo("code:191", {"code:191": "Dictate key"}), "Dictate key",
                 "a label keyed by the raw code applies too")
    assert_equal(helper._display_combo("Shift+code:191", labels), "Shift+Right Alt",
                 "only the key is relabelled; modifiers are left alone")
    assert_equal(helper._display_combo("Super+F", labels), "Super+F",
                 "an ordinary combo is untouched")
    assert_equal(helper._display_combo("Super+F", {"Super+F": "Fullscreen key"}), "Fullscreen key",
                 "a whole-combo label wins over the per-key path")
    assert_equal(helper._display_combo("", labels), "",
                 "a bind with no key stays empty rather than becoming a label")


def test_keybind_labels_survive_a_broken_or_hostile_file():
    def check(home):
        config = home / ".config" / "vshell"
        config.mkdir(parents=True)
        target = config / "keybind-labels.json"

        assert_equal(helper._keybind_labels(), {}, "no file means no labels")

        target.write_text("{ not json")
        assert_equal(helper._keybind_labels(), {}, "unparseable JSON degrades to no labels")

        target.write_text('["F13", "Right Alt"]')
        assert_equal(helper._keybind_labels(), {}, "a non-object document is refused")

        target.write_text('{"F13": "Right Alt", "F14": 5, "F15": "", "F16": null}')
        assert_equal(helper._keybind_labels(), {"F13": "Right Alt"},
                     "only non-empty string labels are kept")

    with_temp_home(check)


def test_hyprland_recovers_a_keycode_bind_key_from_the_config_source():
    """hyprctl reports key=""/keycode=0 for a bind made on a keycode the
    layout leaves unmapped -- verified against a live session -- so the JSON
    alone cannot say what was bound. The source text still can."""
    def check(home):
        config = home / ".config" / "hypr" / "config"
        config.mkdir(parents=True)
        (config / "keybinds.lua").write_text(
            'bindd("code:191", hl.dsp.exec_cmd("voxtype record toggle"), "Dictate (voxtype)")\n'
            '    bindd("code:202", hl.dsp.exec_cmd("mute"), "Mute")\n'
            'bindd(mainMod .. " + SHIFT + B", hl.dsp.exec_cmd("browser"), "Browser")\n'
        )
        found = helper._hypr_raw_bind_keys()
        assert_equal(found.get("Dictate (voxtype)"), "code:191",
                     "the literal key argument is recovered by description")
        assert_equal(found.get("Mute"), "code:202",
                     "a bind indented inside a submap is recovered too")
        assert_equal("Browser" in found, False,
                     "a key built from a Lua expression is not guessed at")

    with_temp_home(check)


def test_hyprland_key_recovery_refuses_every_ambiguous_source():
    """The description is the only handle the JSON and the source share, and
    it is not a unique one. Each case here would hand a bind someone else's
    key, which is worse than the blank the recovery exists to replace."""
    def check(home):
        config = home / ".config" / "hypr" / "config"
        config.mkdir(parents=True)

        # Rebinding by comment-out-and-retype leaves the dead line above the
        # live one, and an unanchored match would take the dead key.
        (config / "keybinds.lua").write_text(
            '-- bindd("code:190", hl.dsp.exec_cmd("old"), "Dictate (voxtype)")\n'
            'bindd("code:191", hl.dsp.exec_cmd("voxtype"), "Dictate (voxtype)")\n'
        )
        assert_equal(helper._hypr_raw_bind_keys().get("Dictate (voxtype)"), "code:191",
                     "a commented-out bind never supplies the key")

        # hyprctl reports keysym binds itself, so matching them would only let
        # one bind lend its key to another that shares a description.
        (config / "plain.lua").write_text('bindd("SUPER, F", x, "Shared name")\n')
        (config / "coded.lua").write_text('bindd("code:200", y, "Shared name")\n')
        assert_equal(helper._hypr_raw_bind_keys().get("Shared name"), "code:200",
                     "only keycode binds enter the map, so the keysym bind cannot win")

        # Two keycodes under one description: there is no way to tell which
        # bind is which, so neither is claimed.
        (config / "dupe.lua").write_text(
            'bindd("code:210", x, "Twice over")\nbindd("code:211", y, "Twice over")\n'
        )
        assert_equal("Twice over" in helper._hypr_raw_bind_keys(), False,
                     "a description bound to two keycodes is dropped, not guessed")

    with_temp_home(check)


def test_hyprland_key_recovery_survives_an_undecodable_config_file():
    """The walk reads every .lua under the config dir. One that is not UTF-8
    would raise past `except OSError`, and the blanket handler in main() turns
    that into an empty stdout -- every bind gone from the cheatsheet, over a
    file that has nothing to do with keybinds."""
    def check(home):
        config = home / ".config" / "hypr" / "config"
        config.mkdir(parents=True)
        (config / "keybinds.lua").write_text(
            'bindd("code:191", hl.dsp.exec_cmd("voxtype"), "Dictate (voxtype)")\n')
        (config / "binary.lua").write_bytes(b"\xff\xfe not utf-8 at all\n")

        assert_equal(helper._hypr_raw_bind_keys().get("Dictate (voxtype)"), "code:191",
                     "an undecodable neighbour costs nothing")

    with_temp_home(check)

def test_the_reported_binds_carry_every_recovered_and_labelled_key():
    """Drives `keybinds show hyprland` itself with a stubbed hyprctl, so the
    wiring is under test and not just the pieces. hyprctl reports the
    modifiers of a keycode bind and withholds only the key, so a recovery
    keyed on the whole combo never fires for one and the shortcut renders as
    its modifiers alone."""
    def check(home):
        config = home / ".config" / "hypr"
        config.mkdir(parents=True)
        (config / "binds.lua").write_text(
            'bindd("SUPER, code:195", hl.dsp.exec_cmd("x"), "Modified")\n'
            'bindd("code:191", hl.dsp.exec_cmd("y"), "Dictate")\n'
        )
        vshell = home / ".config" / "vshell"
        vshell.mkdir(parents=True)
        (vshell / "keybind-labels.json").write_text('{"F13": "Right Alt"}')

        # What hyprctl answers: a keycode bind with modifiers, one without,
        # and an ordinary bind it can name itself.
        payload = json.dumps([
            {"modmask": 64, "key": "", "keycode": 0, "description": "Modified",
             "dispatcher": "__lua", "arg": "1"},
            {"modmask": 0, "key": "", "keycode": 0, "description": "Dictate",
             "dispatcher": "__lua", "arg": "2"},
            {"modmask": 64, "key": "F", "keycode": 0, "description": "Fullscreen",
             "dispatcher": "fullscreen", "arg": ""},
        ])
        original_run, original_which = helper.run, helper.shutil.which
        helper.run = lambda *a, **k: subprocess.CompletedProcess([], 0, payload, "")
        helper.shutil.which = lambda name: "/usr/bin/hyprctl" if name == "hyprctl" else original_which(name)
        try:
            result = helper.hypr_binds_json()
        finally:
            helper.run, helper.shutil.which = original_run, original_which

        keys = {b["desc"]: b["key"] for binds in result["binds"].values() for b in binds}
        assert_equal(keys.get("Modified"), "Super+F17",
                     "a keycode bind keeps the modifiers hyprctl reported and gains its key")
        assert_equal(keys.get("Dictate"), "Right Alt",
                     "a bare keycode bind is recovered, named, then labelled")
        assert_equal(keys.get("Fullscreen"), "Super+F",
                     "a bind hyprctl can name is left exactly as reported")
        assert_equal([cat for cat, binds in result["binds"].items() if not binds], [],
                     "a category nothing landed in is not returned")

    with_temp_home(check)


def main():
    test_keycode_binds_get_a_key_name_instead_of_a_raw_code()
    test_keybind_labels_name_a_key_the_layout_cannot()
    test_keybind_labels_survive_a_broken_or_hostile_file()
    test_hyprland_recovers_a_keycode_bind_key_from_the_config_source()
    test_hyprland_key_recovery_refuses_every_ambiguous_source()
    test_hyprland_key_recovery_survives_an_undecodable_config_file()
    test_the_reported_binds_carry_every_recovered_and_labelled_key()
    print("VGS keybind display tests passed.")


if __name__ == "__main__":
    sys.exit(main() or 0)
