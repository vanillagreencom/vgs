#!/usr/bin/env python3
"""Controls for the Claude Code theme target: the colour rules every bundled
theme has to meet, the token names Claude Code carries, and the hook that writes
the two files and selects one.

The helper loads against a temporary HOME, so only the repository's theme
packages are read and nothing touches the user's own Claude Code configuration.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
_SANDBOX_HOME = tempfile.mkdtemp(prefix="vgs-claude-theme-")
os.environ["HOME"] = _SANDBOX_HOME


def load_helper():
    loader = importlib.machinery.SourceFileLoader(
        "vshell_helper_claude_theme", str(REPO / "bin" / "vshell-helper"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helper = load_helper()

# Claude Code's own colour tokens, read out of the built-in theme tables in the
# 2.1.267 bundle. Claude Code drops an override it does not carry without saying
# so, so a rename on either side has to fail here rather than go unpainted:
#   grep -ao '{[^{}]*autoAcceptShimmer:"rgb(208,180,255)"[^{}]*}' claude \
#     | head -1 | grep -o '[a-zA-Z_][a-zA-Z0-9_]*:' | tr -d ':'
CLAUDE_CODE_TOKENS = {
    "autoAccept", "autoAcceptShimmer", "skill", "bashBorder", "claude",
    "claudeShimmer", "claudeBlue_FOR_SYSTEM_SPINNER",
    "claudeBlueShimmer_FOR_SYSTEM_SPINNER", "permission", "permissionShimmer",
    "planMode", "ide", "promptBorder", "promptBorderShimmer", "text",
    "inverseText", "inactive", "inactiveShimmer", "subtle", "suggestion",
    "remember", "background", "success", "error", "warning", "merged",
    "warningShimmer", "diffAdded", "diffRemoved", "diffAddedDimmed",
    "diffRemovedDimmed", "diffAddedWord", "diffRemovedWord",
    "red_FOR_SUBAGENTS_ONLY", "blue_FOR_SUBAGENTS_ONLY",
    "green_FOR_SUBAGENTS_ONLY", "yellow_FOR_SUBAGENTS_ONLY",
    "purple_FOR_SUBAGENTS_ONLY", "orange_FOR_SUBAGENTS_ONLY",
    "pink_FOR_SUBAGENTS_ONLY", "cyan_FOR_SUBAGENTS_ONLY", "professionalBlue",
    "chromeYellow", "clawd_body", "clawd_background", "userMessageBackground",
    "userMessageBackgroundHover", "composerSidebarBackground", "selectionBg",
    "bashMessageBackgroundColor", "memoryBackgroundColor", "rate_limit_fill",
    "rate_limit_empty", "fastMode", "fastModeShimmer", "effortUltra",
    "briefLabelYou", "briefLabelClaude", "rainbow_red", "rainbow_orange",
    "rainbow_yellow", "rainbow_green", "rainbow_blue", "rainbow_indigo",
    "rainbow_violet", "rainbow_red_shimmer", "rainbow_orange_shimmer",
    "rainbow_yellow_shimmer", "rainbow_green_shimmer", "rainbow_blue_shimmer",
    "rainbow_indigo_shimmer", "rainbow_violet_shimmer",
}

# Tokens Claude Code draws as text on the session background.
TEXT_TOKENS = (
    "text", "subtle", "inactive", "inactiveShimmer", "claude", "claudeShimmer",
    "clawd_body", "briefLabelClaude", "rate_limit_fill", "permission",
    "briefLabelYou", "professionalBlue", "permissionShimmer", "ide",
    "claudeBlue_FOR_SYSTEM_SPINNER", "claudeBlueShimmer_FOR_SYSTEM_SPINNER",
    "suggestion", "planMode", "autoAccept", "autoAcceptShimmer", "skill",
    "merged", "remember", "bashBorder", "effortUltra", "promptBorder",
    "promptBorderShimmer", "success", "error", "warning", "warningShimmer",
    "fastMode", "fastModeShimmer", "chromeYellow", "rainbow_red",
    "rainbow_orange", "rainbow_yellow", "rainbow_green", "rainbow_blue",
    "rainbow_indigo", "rainbow_violet", "rainbow_red_shimmer",
    "rainbow_orange_shimmer", "rainbow_yellow_shimmer",
    "rainbow_green_shimmer", "rainbow_blue_shimmer", "rainbow_indigo_shimmer",
    "rainbow_violet_shimmer",
)
# Tokens Claude Code fills a row or a block with and then draws body text on.
BAND_TOKENS = (
    "userMessageBackground", "userMessageBackgroundHover",
    "composerSidebarBackground", "bashMessageBackgroundColor",
    "memoryBackgroundColor",
)
# Subagent labels are picked to be told apart, not read as body copy.
SUBAGENT_TOKENS = tuple(
    f"{name}_FOR_SUBAGENTS_ONLY" for name in
    ("red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan"))
DIFF_BANDS = ("diffAdded", "diffRemoved", "diffAddedDimmed", "diffRemovedDimmed")
DIMMED_BANDS = ("diffAddedDimmed", "diffRemovedDimmed")
DIFF_WORDS = (("diffAddedWord", "diffAdded"), ("diffRemovedWord", "diffRemoved"))

# The rules the target has to meet, pinned here rather than read from the helper:
# a threshold the helper also owns moves with the code it is meant to hold.
TEXT_CONTRAST = 4.5
SUBAGENT_CONTRAST = 3.0
SELECTION_CONTRAST = 3.0
DIFF_BAND_CONTRAST = 7.0
DIMMED_BAND_SEPARATION = 1.3
WORD_BAND_SEPARATION = 1.5
DIFF_HUE_SEPARATION = 20.0
DIFF_LIGHTNESS_SEPARATION = 0.08
THEME_NAMES = sorted(helper.theme_package_names())


def overrides_for(name: str) -> dict:
    blueprint = helper.find_theme(name)
    return helper.claude_theme_overrides(helper.target_roles(blueprint))


def ratio(a: str, b: str) -> float:
    return helper.contrast_ratio(a, b)


class BundledThemeColours(unittest.TestCase):
    """Every rule in one pass per theme, so a failure names the theme and rule."""

    @classmethod
    def setUpClass(cls):
        cls.rendered = {name: overrides_for(name) for name in THEME_NAMES}

    def test_the_repository_bundles_themes_to_check(self):
        """A rule loop over an empty theme list passes without checking anything."""
        self.assertGreater(len(THEME_NAMES), 1, THEME_NAMES)

    def test_every_text_token_is_readable_on_the_background(self):
        short = [(name, token, round(ratio(values[token], values["background"]), 2))
                 for name, values in self.rendered.items()
                 for token in TEXT_TOKENS
                 if ratio(values[token], values["background"]) < TEXT_CONTRAST]
        self.assertEqual(short, [])

    def test_every_subagent_colour_is_distinguishable_on_the_background(self):
        short = [(name, token, round(ratio(values[token], values["background"]), 2))
                 for name, values in self.rendered.items()
                 for token in SUBAGENT_TOKENS
                 if ratio(values[token], values["background"]) < SUBAGENT_CONTRAST]
        self.assertEqual(short, [])

    def test_every_band_carries_body_text(self):
        short = [(name, token, round(ratio(values["text"], values[token]), 2))
                 for name, values in self.rendered.items()
                 for token in BAND_TOKENS
                 if ratio(values["text"], values[token]) < TEXT_CONTRAST]
        self.assertEqual(short, [])

    def test_every_diff_band_carries_body_text_at_the_enhanced_ratio(self):
        """Including the dimmed bands: the panel fills a screenful of context rows."""
        short = [(name, token, round(ratio(values["text"], values[token]), 2))
                 for name, values in self.rendered.items()
                 for token in DIFF_BANDS
                 if ratio(values["text"], values[token]) < DIFF_BAND_CONTRAST]
        self.assertEqual(short, [])

    def test_every_dimmed_band_stays_off_the_background(self):
        """Without this the panel loses the boundary of a changed file."""
        short = [(name, token, round(ratio(values[token], values["background"]), 3))
                 for name, values in self.rendered.items()
                 for token in DIMMED_BANDS
                 if ratio(values[token], values["background"]) < DIMMED_BAND_SEPARATION]
        self.assertEqual(short, [])

    def test_added_and_removed_bands_are_told_apart_without_the_glyphs(self):
        collisions = []
        for name, values in self.rendered.items():
            added_l, _r, _c, added_h = helper._relative_oklch(values["diffAdded"])
            removed_l, _r2, _c2, removed_h = helper._relative_oklch(values["diffRemoved"])
            if (helper._hue_distance(added_h, removed_h) < DIFF_HUE_SEPARATION
                    and abs(added_l - removed_l) < DIFF_LIGHTNESS_SEPARATION):
                collisions.append((name, round(helper._hue_distance(added_h, removed_h), 1),
                                   round(abs(added_l - removed_l), 3)))
        self.assertEqual(collisions, [])

    def test_every_changed_word_reads_inside_its_own_changed_line(self):
        short = []
        for name, values in self.rendered.items():
            for word, band in DIFF_WORDS:
                if ratio(values["text"], values[word]) < TEXT_CONTRAST:
                    short.append((name, word, "text", round(ratio(values["text"], values[word]), 2)))
                if ratio(values[word], values[band]) < WORD_BAND_SEPARATION:
                    short.append((name, word, band, round(ratio(values[word], values[band]), 2)))
        self.assertEqual(short, [])

    def test_every_selection_fill_carries_body_text(self):
        short = [(name, round(ratio(values["text"], values["selectionBg"]), 2))
                 for name, values in self.rendered.items()
                 if ratio(values["text"], values["selectionBg"]) < SELECTION_CONTRAST]
        self.assertEqual(short, [])

    def test_every_rendered_token_is_one_claude_code_carries(self):
        emitted = {token for values in self.rendered.values() for token in values}
        self.assertEqual(emitted, CLAUDE_CODE_TOKENS)

    def test_every_rendered_value_is_a_hex_colour(self):
        malformed = [(name, token, value)
                     for name, values in self.rendered.items()
                     for token, value in values.items()
                     if not helper.HEX_RE.match(value)]
        self.assertEqual(malformed, [])


class ModeCounterparts(unittest.TestCase):
    def test_a_theme_renders_its_own_mode_from_itself(self):
        blueprint = helper.find_theme("catppuccin")
        self.assertIs(helper.claude_mode_blueprint(blueprint, "dark"), blueprint)

    def test_a_paired_theme_renders_its_counterpart_from_the_pair(self):
        blueprint = helper.find_theme("catppuccin")
        counterpart = helper.claude_mode_blueprint(blueprint, "light")
        self.assertEqual((counterpart["name"], helper.blueprint_mode(counterpart)),
                         ("catppuccin-latte", "light"))

    def test_an_unpaired_theme_renders_its_counterpart_from_the_mode_transform(self):
        blueprint = helper.find_theme("bauhaus")
        self.assertIsNone(helper.paired_blueprint(blueprint, "light"))
        counterpart = helper.claude_mode_blueprint(blueprint, "light")
        self.assertEqual(helper.blueprint_mode(counterpart), "light")

    def test_every_bundled_theme_has_a_counterpart_in_both_modes(self):
        missing = [(name, mode) for name in THEME_NAMES for mode in ("dark", "light")
                   if helper.blueprint_mode(
                       helper.claude_mode_blueprint(helper.find_theme(name), mode)) != mode]
        self.assertEqual(missing, [])


class ThemeSelection(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.settings = self.home / "settings.json"

    def test_an_absent_settings_file_is_created_with_the_theme(self):
        changed = helper.select_claude_theme(self.settings, "custom:vgs-dark")
        self.assertEqual((changed, json.loads(self.settings.read_text())),
                         (True, {"theme": "custom:vgs-dark"}))

    def test_the_selection_keeps_the_settings_the_file_already_holds(self):
        self.settings.write_text(json.dumps({"theme": "dark-ansi", "model": "opus"}))
        changed = helper.select_claude_theme(self.settings, "custom:vgs-light")
        self.assertEqual((changed, json.loads(self.settings.read_text())),
                         (True, {"theme": "custom:vgs-light", "model": "opus"}))

    def test_an_unchanged_selection_reports_no_change(self):
        self.settings.write_text(json.dumps({"theme": "custom:vgs-dark"}))
        self.assertIs(helper.select_claude_theme(self.settings, "custom:vgs-dark"), False)

    def test_a_symlinked_settings_file_is_still_a_symlink_afterwards(self):
        """Three account directories can link their settings.json to this one file."""
        real = self.home / "real-settings.json"
        real.write_text(json.dumps({"theme": "dark-ansi"}))
        self.settings.symlink_to(real)
        helper.select_claude_theme(self.settings, "custom:vgs-dark")
        self.assertEqual((self.settings.is_symlink(), self.settings.resolve(),
                          json.loads(real.read_text())),
                         (True, real.resolve(), {"theme": "custom:vgs-dark"}))


class HookBehaviour(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.blueprint = helper.find_theme("catppuccin")
        self.roles = helper.target_roles(self.blueprint)

    def run_hook(self):
        original = helper.home
        helper.home = lambda: self.home
        try:
            return helper.run_hook("claude-theme", self.roles, self.blueprint)
        finally:
            helper.home = original

    def test_no_claude_directory_skips_without_writing(self):
        result = self.run_hook()
        self.assertEqual((result["ok"], result["skipped"], (self.home / "themes").exists()),
                         (True, True, False))

    def test_an_apply_writes_both_files_and_selects_the_applied_mode(self):
        (self.home / ".claude").mkdir()
        result = self.run_hook()
        files = {mode: json.loads((self.home / ".claude" / "themes" / f"vgs-{mode}.json").read_text())
                 for mode in ("dark", "light")}
        settings = json.loads((self.home / ".claude" / "settings.json").read_text())
        self.assertEqual(
            (result["ok"], result["theme"], settings["theme"],
             files["dark"]["name"], files["dark"]["base"],
             files["light"]["name"], files["light"]["base"]),
            (True, "custom:vgs-dark", "custom:vgs-dark",
             "vgs-dark", "dark", "vgs-light", "light"))

    def test_a_light_theme_selects_the_light_file(self):
        (self.home / ".claude").mkdir()
        self.blueprint = helper.find_theme("catppuccin-latte")
        self.roles = helper.target_roles(self.blueprint)
        result = self.run_hook()
        self.assertEqual(result["theme"], "custom:vgs-light")

    def test_a_curated_file_overrides_only_the_tokens_it_names(self):
        curated = Path(tempfile.mkdtemp()) / "claude-dark.json"
        curated.write_text(json.dumps({"overrides": {"claude": "#abcdef"}}))
        blueprint = dict(self.blueprint, apps={"claude-dark.json": str(curated)})
        rendered = helper.claude_theme_file(blueprint, "dark")
        generated = helper.claude_theme_overrides(helper.target_roles(self.blueprint))
        self.assertEqual(
            (rendered["overrides"]["claude"], len(rendered["overrides"]),
             rendered["overrides"]["text"]),
            ("#abcdef", len(generated), generated["text"]))

    def test_a_curated_file_naming_a_token_claude_code_drops_is_refused(self):
        """An unknown key is ignored silently by Claude Code, so it is caught here."""
        curated = Path(tempfile.mkdtemp()) / "claude-dark.json"
        curated.write_text(json.dumps({"overrides": {"claudeAccent": "#abcdef"}}))
        blueprint = dict(self.blueprint, apps={"claude-dark.json": str(curated)})
        with self.assertRaises(ValueError) as raised:
            helper.claude_theme_file(blueprint, "dark")
        self.assertIn("claudeAccent", str(raised.exception))

    def test_a_broken_curated_file_fails_the_hook_instead_of_the_apply(self):
        (self.home / ".claude").mkdir()
        curated = Path(tempfile.mkdtemp()) / "claude-dark.json"
        curated.write_text("{not json")
        self.blueprint = dict(self.blueprint, apps={"claude-dark.json": str(curated)})
        result = self.run_hook()
        self.assertEqual((result["ok"], "error" in result), (False, True))


class TargetWiring(unittest.TestCase):
    def test_the_target_runs_the_hook_and_is_detected_by_the_claude_directory(self):
        config = json.loads((REPO / "themes" / "targets" / "claude-vgs" / "config.json").read_text())
        self.assertEqual((config["app"], config["hook"], config["detect"]["paths"]),
                         ("claude", "claude-theme", ["~/.claude"]))

    def test_the_shell_hook_target_no_longer_carries_the_claude_hook(self):
        """Two targets running it would write the files twice per apply."""
        config = json.loads((REPO / "themes" / "targets" / "vgs-hook" / "config.json").read_text())
        self.assertNotIn("claude-theme", json.dumps(config["hook"]))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
