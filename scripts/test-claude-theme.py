#!/usr/bin/env python3
"""Controls for the Claude Code theme target: the colour rules every bundled
theme has to meet, the token names Claude Code carries, and the hook that writes
the two files and selects one.

The helper loads against a temporary HOME, so only the repository's theme
packages are read and nothing touches the user's own Claude Code configuration.
"""
from __future__ import annotations

import ast
import contextlib
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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

# Tokens Claude Code fills a surface with rather than drawing text in, plus the
# two it draws on a coloured fill. Body text is the rest: a token added to the
# vendor set above lands under the strictest rule until it is classified here.
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
TEXT_TOKENS = tuple(sorted(CLAUDE_CODE_TOKENS - {
    "background", "inverseText", "selectionBg", "rate_limit_empty",
    "clawd_background", "diffAddedWord", "diffRemovedWord",
    *BAND_TOKENS, *DIFF_BANDS, *SUBAGENT_TOKENS}))

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
# The best body-text ratio a dimmed band can reach on a flat mid-grey background
# in light mode, where no band meets the diff rule at all. Below the diff ratio by
# construction, and well above what picking the wrong side of that background
# gives, so it separates the two.
CLOSEST_DIMMED_BAND = 6.5
# One row per contrast rule: the tokens it governs, the token they are measured
# against, the ratio, and whether it holds on every case or only on the cases the
# helper reports no shortfall for. A palette can put a diff rule out of reach and
# the helper then names it, so those rows are scoped "clean".
CONTRAST_RULES = (
    ("text on the background", TEXT_TOKENS, "background", TEXT_CONTRAST, "every"),
    ("a subagent colour on the background", SUBAGENT_TOKENS, "background",
     SUBAGENT_CONTRAST, "every"),
    ("body text on a band", BAND_TOKENS, "text", TEXT_CONTRAST, "every"),
    ("body text on the selection fill", ("selectionBg",), "text", SELECTION_CONTRAST, "every"),
    ("body text on a diff band", DIFF_BANDS, "text", DIFF_BAND_CONTRAST, "clean"),
    ("a dimmed band against the background", DIMMED_BANDS, "background",
     DIMMED_BAND_SEPARATION, "clean"),
)
THEME_NAMES = sorted(helper.theme_package_names())
THEMES = helper.list_themes()
# Restyle is a shipped control that transforms the palette before role
# derivation, and a curated package's palette is not contrast-enforced, so the
# rules have to hold on restyled palettes too. These three steps are the ones
# reviewers reproduced a refusal at; 0 is the palette as it ships.
RESTYLE_STEPS = ({}, {"brightness": -25}, {"brightness": 100}, {"contrast": -100})


@contextlib.contextmanager
def temp_home(claude: bool = False, home: Path | None = None):
    """`helper.home` pointed at a throwaway HOME for the body, restored after.

    Four sites saved, reassigned and restored `helper.home` by hand. The restore
    is the half a new site forgets, and one leak sends every later case at the
    wrong directory. `claude` creates ~/.claude, which is what the hook tests
    whether it writes at all.
    """
    home = Path(tempfile.mkdtemp()) if home is None else home
    if claude:
        (home / ".claude").mkdir(exist_ok=True)
    original = helper.home
    helper.home = lambda: home
    try:
        yield home
    finally:
        helper.home = original


def write_package(home: Path, dir_name: str, colors: str, mode: str = "dark",
                  adjustments: dict | None = None, apps: dict | None = None) -> Path:
    """A user theme package on disk under `home`, for the loader to read back."""
    root = home / ".config" / "vshell" / "themes" / dir_name
    (root / "apps").mkdir(parents=True, exist_ok=True)
    meta = {"name": dir_name, "mode": mode, "pair": "", "source": "curated"}
    if adjustments:
        meta["adjustments"] = adjustments
    (root / "theme.json").write_text(json.dumps(meta))
    (root / "colors.toml").write_text(colors)
    for filename, content in (apps or {}).items():
        (root / "apps" / filename).write_text(content)
    return root


def restyled(name: str, adjustments: dict) -> dict:
    """The bundled package `name` as a restyle slider leaves it.

    The adjustments are written as the overlay a slider writes and read back
    through `load_theme_package`, so every fixture in this file is whatever
    production assembles. A harness that re-stated that assembly would keep
    mirroring it after the loader's inputs changed, and the oracle would then
    grade blueprints the helper never builds: the drop now reads a persisted
    colour edit as well as the sliders, which is exactly such a change.
    """
    if not adjustments:
        return helper.find_theme(name, THEMES)
    with temp_home():
        helper.ensure_dirs()
        helper.set_theme_adjustments(name, adjustments)
        return helper.load_theme_package(name)


def rendered_file(blueprint: dict, mode: str) -> tuple[dict, list]:
    return helper.claude_theme_file(
        helper.mode_variant_blueprint(blueprint, mode, THEMES), mode)


def ratio(a: str, b: str) -> float:
    return helper.contrast_ratio(a, b)


class BundledThemeColours(unittest.TestCase):
    """Every rule in one pass per case, so a failure names the case and rule.

    A case is one bundled package at one restyle step in one mode, because every
    apply writes both modes and a slider can move either one out of reach.
    """

    @classmethod
    def setUpClass(cls):
        cls.rendered = {}
        cls.shortfalls = {}
        for name in THEME_NAMES:
            for adjustments in RESTYLE_STEPS:
                blueprint = restyled(name, adjustments)
                for mode in ("dark", "light"):
                    case = (name, tuple(sorted(adjustments.items())), mode)
                    content, missed = rendered_file(blueprint, mode)
                    cls.rendered[case] = content["overrides"]
                    cls.shortfalls[case] = missed
        # The diff rules are the ones a palette can put out of reach, so they are
        # measured where the helper claims to have met them. A case it reports a
        # shortfall for is pinned by the two rows below instead.
        cls.clean = {case: values for case, values in cls.rendered.items()
                     if not cls.shortfalls[case]}

    def test_the_repository_bundles_themes_to_check(self):
        """A rule loop over an empty case list passes without checking anything."""
        self.assertEqual((len(THEME_NAMES) > 1, len(self.rendered)),
                         (True, len(THEME_NAMES) * len(RESTYLE_STEPS) * 2))

    def test_a_rule_a_palette_cannot_reach_is_named_rather_than_refused(self):
        """A refusal would leave Claude Code on the theme the user just left, so a
        palette out of reach has to report and still render a complete file."""
        short = {case for case, missed in self.shortfalls.items() if missed}
        self.assertNotEqual(short, set(), "no case reaches a shortfall")
        self.assertEqual([case for case in short
                          if set(self.rendered[case]) != CLAUDE_CODE_TOKENS], [])
        self.assertEqual([case for case, missed in self.shortfalls.items() if missed
                          and not all("diff" in line for line in missed)], [])

    def test_no_palette_puts_a_changed_word_out_of_reach(self):
        """Unlike the band separation, which a strongly hued background can make
        unreachable, a word fill always has a gamut end that differs from its
        band. A shortfall here means the fill stopped looking for one."""
        self.assertEqual([(case, line) for case, missed in self.shortfalls.items()
                          for line in missed if line.startswith("diff word")], [])

    @classmethod
    def missed(cls, scope: str) -> list:
        """Every rule in `scope` that a case breaks, as (rule, case, token, ratio)."""
        cases = cls.rendered if scope == "every" else cls.clean
        return [(label, case, token, round(ratio(values[token], values[against]), 3))
                for label, tokens, against, floor, rule_scope in CONTRAST_RULES
                if rule_scope == scope
                for case, values in cases.items() for token in tokens
                if ratio(values[token], values[against]) < floor]

    @classmethod
    def collisions(cls, cases: dict) -> list:
        """Every case whose added and removed bands read as one colour."""
        out = []
        for case, values in cases.items():
            added_l, _r, _c, added_h = helper._relative_oklch(values["diffAdded"])
            removed_l, _r2, _c2, removed_h = helper._relative_oklch(values["diffRemoved"])
            gap = helper._hue_distance(added_h, removed_h)
            if gap < DIFF_HUE_SEPARATION and abs(added_l - removed_l) < DIFF_LIGHTNESS_SEPARATION:
                out.append((case, round(gap, 1), round(abs(added_l - removed_l), 3)))
        return out

    @classmethod
    def word_misses(cls, cases: dict) -> list:
        """Every changed-word fill that its own band or body text defeats."""
        return [(case, word, other, round(ratio(values[word], values[other]), 2))
                for case, values in cases.items() for word, band in DIFF_WORDS
                for other, floor in ((band, WORD_BAND_SEPARATION), ("text", TEXT_CONTRAST))
                if ratio(values[word], values[other]) < floor]

    def test_exactly_the_cases_that_miss_a_diff_rule_report_a_shortfall(self):
        """Without this the shortfall list could name cases that are fine while a
        real miss went unreported, and every clean-scoped rule would skip it."""
        broken = {case for _label, case, _token, _ratio in self.missed("clean")}
        broken |= {case for case, _hue, _lightness in self.collisions(self.rendered)}
        broken |= {case for case, _word, _other, _ratio in self.word_misses(self.rendered)}
        self.assertEqual(broken, {case for case, missed in self.shortfalls.items() if missed})

    def test_every_contrast_rule_holds_where_the_helper_claims_it(self):
        self.assertEqual((self.missed("every"), self.missed("clean")), ([], []))

    def test_added_and_removed_bands_are_told_apart_without_the_glyphs(self):
        self.assertEqual(self.collisions(self.clean), [])

    def test_every_changed_word_reads_inside_its_own_changed_line(self):
        self.assertEqual(self.word_misses(self.clean), [])

    def test_every_rendered_token_is_one_claude_code_carries(self):
        emitted = {token for values in self.rendered.values() for token in values}
        self.assertEqual(emitted, CLAUDE_CODE_TOKENS)

    def test_the_two_modes_of_one_theme_carry_different_colours(self):
        """A counterpart file rendered from the applied blueprint would repaint a
        light-mode switch in the dark palette's colours under a light header."""
        same = [(name, adjustments)
                for name in THEME_NAMES for adjustments in RESTYLE_STEPS
                for key in [tuple(sorted(adjustments.items()))]
                if self.rendered[(name, key, "dark")] == self.rendered[(name, key, "light")]]
        self.assertEqual(same, [])

    def test_every_bundled_theme_ships_both_modes_with_every_diff_rule_met(self):
        """The shipped packages, with no slider moved, are what a user sees on a
        theme apply. Six of them reach this only through a curated file, so
        dropping one paints that theme's added and removed rows in one colour."""
        self.assertEqual({case: missed for case, missed in self.shortfalls.items()
                          if case[1] == () and missed}, {})

    def test_every_rendered_value_is_a_hex_colour(self):
        malformed = [(case, token, value)
                     for case, values in self.rendered.items()
                     for token, value in values.items()
                     if not helper.HEX_RE.match(value)]
        self.assertEqual(malformed, [])


class ModeCounterparts(unittest.TestCase):
    def test_a_theme_renders_its_own_mode_from_itself(self):
        blueprint = helper.find_theme("catppuccin")
        self.assertIs(helper.mode_variant_blueprint(blueprint, "dark"), blueprint)

    def test_a_paired_theme_renders_its_counterpart_from_the_pair(self):
        blueprint = helper.find_theme("catppuccin")
        counterpart = helper.mode_variant_blueprint(blueprint, "light")
        self.assertEqual((counterpart["name"], helper.blueprint_mode(counterpart)),
                         ("catppuccin-latte", "light"))

    def test_an_unpaired_theme_renders_its_counterpart_from_the_mode_transform(self):
        blueprint = helper.find_theme("bauhaus")
        self.assertIsNone(helper.paired_blueprint(blueprint, "light"))
        counterpart = helper.mode_variant_blueprint(blueprint, "light")
        self.assertEqual(helper.blueprint_mode(counterpart), "light")

    def test_a_counterpart_file_carries_its_own_blueprint_colours(self):
        """Rendering both files from the applied blueprint leaves a correct header
        over the wrong palette, which no header or mode assertion catches."""
        blueprint = helper.find_theme("catppuccin")
        content, _missed = rendered_file(blueprint, "light")
        expected, _ = helper.claude_theme_file(helper.find_theme("catppuccin-latte"), "light")
        applied, _ = helper.claude_theme_file(blueprint, "dark")
        self.assertEqual(content["overrides"], expected["overrides"])
        self.assertNotEqual(content["overrides"], applied["overrides"])

    def test_a_curated_file_reaches_the_mode_transform_path(self):
        """blueprint_mode_variant rebuilds the palette alone, so a package's own
        curated file for its counterpart mode is dropped unless it is carried."""
        curated = Path(tempfile.mkdtemp()) / "claude-light.json"
        curated.write_text(json.dumps({"overrides": {"claude": "#abcdef"}}))
        blueprint = dict(helper.find_theme("bauhaus"), apps={"claude-light.json": str(curated)})
        content, _missed = rendered_file(blueprint, "light")
        self.assertEqual(content["overrides"]["claude"], "#abcdef")

    def test_a_curated_file_is_what_closes_a_rule_the_palette_cannot_reach(self):
        """The exact set of shipped cases that need a curated file to meet a rule.

        These counterparts come from the mode transform onto strongly hued
        backgrounds, which pull both diff bands onto that one hue: a band is a
        weak tint and no anchor the generator has parts them. The curated file is
        the only thing that does, and the rules are measured after it merges, so
        closing the rule also closes the warning.

        Asserting the exact set rather than one theme is what binds the list in
        docs/architecture/theme.md to the tree: a seventh theme that starts
        needing a file, or one of these six that stops, reddens here and sends
        the author to that document.
        """
        needs_curation, still_short = set(), {}
        for name in THEME_NAMES:
            blueprint = helper.find_theme(name, THEMES)
            for mode in ("dark", "light"):
                curated = f"claude-{mode}.json"
                if curated not in (blueprint.get("apps") or {}):
                    continue
                _shipped, missed = rendered_file(blueprint, mode)
                bare = dict(blueprint, apps={
                    filename: path for filename, path in blueprint["apps"].items()
                    if filename != curated})
                _plain, without = rendered_file(bare, mode)
                if missed:
                    still_short[(name, mode)] = missed
                if without:
                    needs_curation.add((name, mode))
        self.assertEqual(
            (needs_curation, still_short),
            ({(name, "light") for name in
              ("akane", "archwave", "frankenstein", "moon-orbit", "reddcs", "vice-city")},
             {}))

    def test_an_app_override_for_claude_reaches_the_rendered_files(self):
        """Every other target consumes the loop's merged map; this one builds its
        own, so an override a user sets would be accepted and never painted."""
        blueprint = helper.find_theme("bauhaus")
        with mock.patch.object(helper, "bp_app_overrides",
                               return_value={"claude": {"accent": "#c71585"}}):
            overridden, _missed = helper.claude_theme_file(blueprint, "dark")
        plain, _missed = helper.claude_theme_file(blueprint, "dark")
        self.assertEqual((overridden["overrides"]["claude"],
                          plain["overrides"]["claude"] != "#c71585"),
                         ("#c71585", True))

    def test_the_lossy_transform_keeps_the_package_its_curated_files_live_in(self):
        """`theme mode --transform` asks for the lossy variant even where a pair
        exists, so it cannot go through mode_variant_blueprint, which would hand
        back the pair. Both resolve through transformed_mode_blueprint instead: a
        second copy of the carry let the flag answer with no curated files, and
        the six themes then rendered the colliding bands their files replace."""
        blueprint = helper.find_theme("akane", THEMES)
        variant = helper.transformed_mode_blueprint(blueprint, "light", "")
        content, missed = helper.claude_theme_file(variant, "light")
        curated = json.loads(
            (REPO / "themes" / "akane" / "apps" / "claude-light.json").read_text())["overrides"]
        self.assertEqual(
            (helper.blueprint_mode(variant), variant["apps"], variant["path"],
             content["overrides"]["diffAdded"], missed),
            ("light", blueprint["apps"], blueprint["path"], curated["diffAdded"], []))

    def test_the_lossy_variant_has_one_caller_carrying_the_package(self):
        """The carry lives in transformed_mode_blueprint, so a caller that reaches
        blueprint_mode_variant itself gets the palette without the package and
        every curated file goes missing. That is what `theme mode --transform`
        did. Naming the one permitted caller reddens the next such call written
        inside a function, which asserting on the wrapper alone cannot do. A call
        at module or class scope is attributed to no caller and passes; the helper
        has no such call site today, so widening the walk would buy nothing.
        """
        source = ast.parse((REPO / "bin" / "vshell-helper").read_text())
        callers = {
            node.name for node in ast.walk(source)
            if isinstance(node, ast.FunctionDef)
            and any(isinstance(call.func, ast.Name)
                    and call.func.id == "blueprint_mode_variant"
                    for call in ast.walk(node) if isinstance(call, ast.Call))}
        self.assertEqual(callers, {"transformed_mode_blueprint"})

    def test_every_bundled_theme_has_a_counterpart_in_both_modes(self):
        missing = [(name, mode) for name in THEME_NAMES for mode in ("dark", "light")
                   if helper.blueprint_mode(
                       helper.mode_variant_blueprint(helper.find_theme(name), mode)) != mode]
        self.assertEqual(missing, [])


class UnreachableDiffBands(unittest.TestCase):
    """A background no band can sit on, which no bundled palette reaches.

    Without a case here the diff-band and diff-word branches that report a
    shortfall never run, and deleting either report leaves the suite green.
    """

    def overrides(self, mode: str = "dark") -> tuple:
        # A mid-tone grey carries neither a readable band above it nor a visible
        # one below: body text on it tops out far under the diff ratio.
        grey = {f"color{index}": "#808080" for index in range(16)}
        grey.update(background="#808080", foreground="#8a8a8a", mode=mode)
        blueprint = helper.palette_from_colors_map(grey, name="flat-grey", wallpaper="",
                                                   source="curated")
        values = helper.claude_theme_overrides(helper.target_roles(blueprint))
        return values, helper.claude_diff_shortfalls(values)

    def test_a_background_no_band_can_sit_on_reports_the_band_it_wrote(self):
        """Every line names both ratios, so the report says which rule was missed
        rather than only that something was."""
        _values, missed = self.overrides()
        bands = [line for line in missed if line.startswith("diff band")]
        self.assertNotEqual(bands, [])
        self.assertEqual([line for line in bands if ":1 off the background" not in line
                          or ":1 on it" not in line], [])

    def test_a_band_it_cannot_place_is_never_the_background_itself(self):
        """Returning the background would hide the changed rows completely."""
        values, _missed = self.overrides()
        self.assertEqual([token for token in DIFF_BANDS
                          if values[token] == values["background"]], [])

    def test_the_band_it_writes_is_the_closest_of_the_sides_it_tried(self):
        """The two sides of this background are not equally bad, and in light mode
        the first one tried is the worse: taking it writes a dimmed band carrying
        body text at 4.09:1 where scoring the sides gives 6.92:1. The floor is the
        closest this palette allows, so it reddens at the take-first value and
        holds for any pick of the closer side; what stays open is a pick better
        than either side."""
        values, missed = self.overrides("light")
        self.assertNotEqual([line for line in missed if line.startswith("diff band")], [])
        self.assertEqual([(token, round(ratio(values["text"], values[token]), 2))
                          for token in DIMMED_BANDS
                          if ratio(values["text"], values[token]) < CLOSEST_DIMMED_BAND], [])

    def test_the_band_it_reports_is_the_band_it_wrote(self):
        """A report naming a candidate the caller did not get sends an author after
        the wrong colour."""
        values, missed = self.overrides()
        reported = {line.split(": ", 1)[1].split(":1 off", 1)[0]
                    for line in missed if line.startswith("diff band")}
        self.assertEqual(reported, {f"{ratio(values[token], values['background']):.2f}"
                                    for token in DIMMED_BANDS})


class HookBehaviour(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.blueprint = helper.find_theme("catppuccin")
        self.roles = helper.target_roles(self.blueprint)

    def run_hook(self):
        with temp_home(home=self.home):
            return helper.run_hook("claude-theme", self.roles, self.blueprint)

    def test_no_claude_directory_skips_without_writing(self):
        result = self.run_hook()
        self.assertEqual((result["ok"], result["skipped"], (self.home / ".claude").exists()),
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
        rendered, _missed = helper.claude_theme_file(blueprint, "dark")
        generated = helper.claude_theme_overrides(helper.target_roles(self.blueprint))
        self.assertEqual(
            (rendered["overrides"]["claude"], len(rendered["overrides"]),
             rendered["overrides"]["text"]),
            ("#abcdef", len(generated), generated["text"]))

    def curated(self, body: str) -> dict:
        """`self.blueprint` carrying a curated dark file holding `body`."""
        path = Path(tempfile.mkdtemp()) / "claude-dark.json"
        path.write_text(body)
        return dict(self.blueprint, apps={"claude-dark.json": str(path)})

    def test_a_curated_band_that_breaks_a_rule_is_reported_like_a_palette_that_cannot(self):
        """A curated file is judged by the rules the generator is judged by, so a
        hand-picked band equal to the background warns rather than shipping a
        /diff panel whose changed rows are invisible. catppuccin's background is
        the value used here."""
        _content, missed = helper.claude_theme_file(
            self.curated('{"overrides": {"diffAddedDimmed": "#1e1e2e"}}'), "dark")
        self.assertEqual([line for line in missed if line.startswith("diff band #1e1e2e")] != [],
                         True)

    def test_a_curated_strong_fill_body_text_cannot_read_is_reported(self):
        """The strong fill carries the body-text rule the dimmed band carries, and
        this PR ships six curated files that set diffAdded, so a hand-picked fill
        too close to the text is reachable. The oracle in BundledThemeColours
        cannot cover it: it measures the clean cases, and a fill miss makes a case
        non-clean, so the case drops out before the rule is applied to it.
        catppuccin's dark text is near-white, so a near-white fill hides the
        added rows' text on the rows themselves."""
        _content, missed = helper.claude_theme_file(
            self.curated('{"overrides": {"diffAdded": "#fdfdfd"}}'), "dark")
        self.assertEqual([line for line in missed if line.startswith("diff fill #fdfdfd")] != [],
                         True)

    def test_a_curated_file_claude_code_would_not_paint_is_refused_by_name(self):
        """Claude Code ignores a key it does not carry and reports nothing, so each
        of these reads as a successful apply that painted none of the file."""
        for label, body, named in (
            ("unknown token", '{"overrides": {"claudeAccent": "#abcdef"}}', "claudeAccent"),
            ("mistyped wrapper", '{"override": {"claude": "#abcdef"}}', "override"),
            ("array document", '["text"]', "list"),
            ("empty array document", '[]', "list"),
            ("string overrides", '{"overrides": "claude"}', "str"),
            ("number value", '{"overrides": {"text": 5}}', "text"),
            ("null value", '{"overrides": {"text": null}}', "text"),
            ("prose value", '{"overrides": {"text": "not-a-colour"}}', "text"),
            ("an ansi value VGS does not write", '{"overrides": {"text": "ansi:red"}}', "text"),
        ):
            with self.subTest(label):
                with self.assertRaises(ValueError) as raised:
                    helper.claude_theme_file(self.curated(body), "dark")
                message = str(raised.exception)
                self.assertIn(named, message)
                self.assertIn("catppuccin claude-dark.json", message)

    def test_a_curated_value_claude_code_could_read_leaves_in_one_form(self):
        """Claude Code reads a bare or upper-case hex, so refusing them would be
        pedantic; writing them would leave the file in three spellings of one
        colour. clean_hex is the single form every other source already arrives in."""
        for label, body in (("no leading hash", '{"overrides": {"text": "abcdef"}}'),
                            ("upper case", '{"overrides": {"text": "#ABCDEF"}}'),
                            ("upper case, no hash", '{"overrides": {"text": "ABCDEF"}}')):
            with self.subTest(label):
                rendered, _missed = helper.claude_theme_file(self.curated(body), "dark")
                self.assertEqual(rendered["overrides"]["text"], "#abcdef")

    def test_every_value_in_a_rendered_file_is_in_the_canonical_form(self):
        """One spelling per colour across the whole file, whatever wrote it."""
        rendered, _missed = helper.claude_theme_file(
            self.curated('{"overrides": {"text": "ABCDEF"}}'), "dark")
        self.assertEqual([value for value in rendered["overrides"].values()
                          if value != helper.clean_hex(value)], [])

    def test_a_broken_curated_file_fails_the_hook_instead_of_the_apply(self):
        """An uncaught shape mistake kills the apply at the fourth of 32 targets,
        so twelve later hooks never run and the live desktop keeps the old theme."""
        (self.home / ".claude").mkdir()
        for label, body in (("invalid JSON", "{not json"),
                            ("array document", "[]"),
                            ("string overrides", '{"overrides": "claude"}'),
                            ("a value Claude Code cannot read", '{"overrides": {"text": 5}}')):
            with self.subTest(label):
                self.blueprint = self.curated(body)
                result = self.run_hook()
                # Every cause names the theme and the file, so a theme author
                # reading the error knows which package to open.
                self.assertEqual((result["ok"], "vgs-dark.json" in result.get("error", ""),
                                  "catppuccin claude-dark.json" in result.get("error", "")),
                                 (False, True, True))

    def test_a_broken_counterpart_mode_still_writes_and_selects_the_applied_one(self):
        """The applied mode is what the user is looking at; withholding it leaves
        Claude Code on the colours of the theme they just left."""
        (self.home / ".claude").mkdir()
        broken = Path(tempfile.mkdtemp()) / "claude-light.json"
        broken.write_text("[]")
        # bauhaus is dark with no pair, so its light file comes from the mode
        # transform and carries the package's own curated file.
        self.blueprint = dict(helper.find_theme("bauhaus"),
                              apps={"claude-light.json": str(broken)})
        self.roles = helper.target_roles(self.blueprint)
        result = self.run_hook()
        settings = json.loads((self.home / ".claude" / "settings.json").read_text())
        themes = self.home / ".claude" / "themes"
        self.assertEqual(
            (result["ok"], "vgs-light.json" in result["error"], settings["theme"],
             (themes / "vgs-dark.json").is_file(), (themes / "vgs-light.json").is_file()),
            (False, True, "custom:vgs-dark", True, False))

    def test_an_unreadable_settings_file_is_contained_with_both_themes_written(self):
        """The selection reads settings.json, and an exception there once unwound the
        whole apply: seventeen later hooks were skipped and theme-current.json was
        never written, so the compositor and GTK kept the old theme."""
        (self.home / ".claude").mkdir()
        (self.home / ".claude" / "settings.json").write_text('{"theme": "dark-ansi",}')
        result = self.run_hook()
        themes = self.home / ".claude" / "themes"
        self.assertEqual(
            (result["ok"], result["error"].startswith("settings.json: "),
             (themes / "vgs-dark.json").is_file(), (themes / "vgs-light.json").is_file()),
            (False, True, True, True))

    def test_a_theme_file_vgs_cannot_read_back_is_overwritten_not_refused(self):
        """The skip-identical comparison is an optimisation. Failing it withheld the
        write and the selection, leaving Claude Code on the theme it had."""
        (self.home / ".claude").mkdir()
        stale = self.home / ".claude" / "themes" / "vgs-dark.json"
        stale.parent.mkdir(parents=True)
        stale.write_bytes(b"\xff\xfe not utf-8")
        result = self.run_hook()
        self.assertEqual((result["ok"], json.loads(stale.read_text())["name"]),
                         (True, "vgs-dark"))

    def test_a_second_apply_of_one_theme_rewrites_and_reports_nothing(self):
        """write_file replaces unconditionally and Claude Code reloads what changes,
        so an identical rewrite repaints every open session for nothing. The report
        is pinned beside it: a hook that always claimed it rewrote the selection
        would make every apply look like a change to whoever reads the result."""
        (self.home / ".claude").mkdir()
        first = self.run_hook()
        light = self.home / ".claude" / "themes" / "vgs-light.json"
        stamped = light.stat().st_mtime_ns
        result = self.run_hook()
        self.assertEqual(
            (first["unchanged"], result["unchanged"], result["unchangedThemes"],
             light.stat().st_mtime_ns == stamped),
            (False, True,
             sorted(str(self.home / ".claude" / "themes" / f"vgs-{mode}.json")
                    for mode in ("dark", "light")), True))

    def test_a_restyle_a_palette_cannot_carry_is_reported_and_still_written(self):
        (self.home / ".claude").mkdir()
        self.blueprint = restyled("pmndrs", {"brightness": -25})
        self.roles = helper.target_roles(self.blueprint)
        result = self.run_hook()
        self.assertEqual(
            (result["ok"], "diff" in result.get("warning", ""),
             (self.home / ".claude" / "themes" / "vgs-light.json").is_file()),
            (True, True, True))


class RestyledPackages(unittest.TestCase):
    """The loader drops the curated files a restyled palette no longer fits.

    Built from a real package on disk so load_theme_package does the work: the
    rule lives where bp["apps"] is set, and every consumer inherits it rather
    than judging again.
    """

    COLORS = "\n".join(
        ['accent = "#9279aa"', 'cursor = "#F4B999"', 'foreground = "#F4B999"',
         'background = "#0E1E36"', 'selection_foreground = "#F4B999"',
         'selection_background = "#9279AA"']
        + [f'color{index} = "#4A2036"' for index in range(16)]) + "\n"

    APPS = {"claude-dark.json": json.dumps({"overrides": {"claude": "#abcdef"}}),
            "icons.theme": "[Icon Theme]\nName=probe\n"}

    def package(self, adjustments: dict) -> dict:
        """A user package carrying one merge-style and one replacing curated file."""
        with temp_home() as home:
            write_package(home, "probe", self.COLORS, adjustments=adjustments, apps=self.APPS)
            return helper.load_theme_package("probe")

    def test_a_package_at_rest_keeps_every_curated_file(self):
        self.assertEqual(sorted(self.package({})["apps"]),
                         ["claude-dark.json", "icons.theme"])

    def test_a_restyled_package_drops_only_the_merge_style_file(self):
        """icons.theme has no template behind it, so dropping it would delete the
        installed artifact on the next apply and leave nothing in its place. Only
        the file that merges over a generated render goes."""
        self.assertEqual(sorted(self.package({"brightness": 100})["apps"]),
                         ["icons.theme"])

    def test_a_restyled_package_renders_without_the_curated_values(self):
        """The consumer inherits the loader's answer rather than asking again."""
        content, _missed = helper.claude_theme_file(self.package({"brightness": 100}), "dark")
        self.assertNotEqual(content["overrides"]["claude"], "#abcdef")

    def test_a_persisted_colour_edit_drops_the_curated_file(self):
        """A slider is not the only control that replaces the palette a curated
        file was picked against. `persist_color_edits` writes a user overlay
        colors.toml over the package's own and reloads with the adjustments still
        at zero, so a rule reading only the sliders kept the frozen bands over
        colours the user had just changed. Measured on akane: with the file kept,
        both curated light bands sit 1.03:1 off the edited background, which is a
        diff panel whose changed rows cannot be seen, where the generated render
        misses no rule at all. The replacing file stays, because dropping it would
        delete the installed artifact and leave nothing in its place.
        """
        with temp_home():
            helper.ensure_dirs()
            with mock.patch.object(helper, "apply_theme_obj", return_value={}):
                helper.persist_color_edits(["foreground=#101010"], "akane")
            edited = helper.load_theme_package("akane")
        _content, missed = rendered_file(edited, "light")
        self.assertEqual(
            ("claude-light.json" in edited["apps"], "icons.theme" in edited["apps"], missed),
            (False, True, []))

    def test_a_saved_restyled_package_carries_what_the_loader_left(self):
        """save_theme_package copies curated files verbatim, so the loader's rule
        is what keeps a mismatch from being baked into a package on disk.

        Naming only the dropped file cannot fail for this function: the fixture
        already went through the loader, which removed it before the save saw it.
        What the save alone decides is the carry, so the case reads both halves.
        Without the copy loop the saved package loses icons.theme, a target with
        no template behind it, so the next apply of the saved theme installs no
        icon theme and leaves nothing in its place.
        """
        blueprint = self.package({"brightness": 100})
        with temp_home():
            root = helper.save_theme_package(blueprint, name="saved-probe")
        saved = {path.name for path in (root / "apps").iterdir()}
        self.assertEqual((set(blueprint["apps"]) - saved, "claude-dark.json" in saved),
                         (set(), False))


class TargetWiring(unittest.TestCase):
    def apply(self, blueprint: dict) -> tuple:
        """One apply of `blueprint` against a fresh HOME holding ~/.claude."""
        with temp_home(claude=True) as home:
            return helper._apply_theme_obj_unlocked(blueprint, only_app="claude"), home

    def test_an_apply_reaches_the_hook_from_a_target_with_no_template(self):
        """The hook moved onto a target with no template and no destination, so the
        apply loop has to collect a hook from a hook-only target or nothing is
        written on any apply."""
        result, home = self.apply(helper.find_theme("catppuccin"))
        themes = home / ".claude" / "themes"
        self.assertEqual(
            (result["warnings"], (themes / "vgs-dark.json").is_file(),
             (themes / "vgs-light.json").is_file(),
             json.loads((home / ".claude" / "settings.json").read_text())["theme"]),
            ([], True, True, "custom:vgs-dark"))

    def test_a_degraded_theme_reaches_the_apply_result_as_a_warning(self):
        """The settings UI builds its message from the apply result's warnings and
        reads stderr only on a non-zero exit, so a shortfall the hook keeps to
        itself shows as a clean success over a /diff panel painted in one colour."""
        result, home = self.apply(restyled("pmndrs", {"brightness": -25}))
        self.assertEqual(
            (result["partial"], [line for line in result["warnings"] if "diff" in line] != [],
             (home / ".claude" / "themes" / "vgs-light.json").is_file()),
            (True, True, True))

    def test_an_apply_carries_both_a_failed_mode_and_a_degraded_one(self):
        """Each mode is its own unit of work, so one can fail while the other is
        degraded. Reading the warning only on a passing hook tells the user the
        light file is malformed and not that the dark theme it just selected paints
        added and removed rows in one colour."""
        broken = Path(tempfile.mkdtemp()) / "claude-light.json"
        broken.write_text("[]")
        # A restyled package would not do: a slider drops the curated file by
        # design, so the malformed one would never be read. This palette is
        # degraded where it ships, which is the case that keeps both reports live.
        grey = {f"color{index}": "#808080" for index in range(16)}
        grey.update(background="#808080", foreground="#8a8a8a", mode="dark")
        blueprint = helper.palette_from_colors_map(grey, name="flat-grey", wallpaper="",
                                                   source="curated")
        result, _home = self.apply(dict(blueprint, apps={"claude-light.json": str(broken)}))
        self.assertEqual(
            (result["partial"],
             [line for line in result["warnings"] if "claude-light.json" in line] != [],
             [line for line in result["warnings"] if "diff rule(s) below target" in line] != []),
            (True, True, True))

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
