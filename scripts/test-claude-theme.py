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
import io
import json
import os
import shutil
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


def pin_theme_apps(home: Path, **enabled: bool) -> None:
    """Pin `themeApps` toggles in `home`, so a render set cannot read the host.

    `target_enabled` takes a toggle where one exists and otherwise asks
    `detect_target`, which answers whether the app is installed on this machine.
    A fixture that leaves the toggle unset therefore renders a different set on a
    developer's machine than on a runner with fewer apps installed, which is how
    a case that passes locally fails in CI having found nothing wrong.
    """
    settings = home / ".config" / "vshell" / "settings.json"
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(json.dumps({"themeApps": dict(enabled)}))


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
                  adjustments: dict | None = None, apps: dict | None = None,
                  record_palette: bool = True) -> Path:
    """A user theme package on disk under `home`, for the loader to read back.

    The `curatedPalette` digest is recorded the way every writer that authors or
    copies a merge-style curated file records it. `record_palette=False` writes
    the package a legacy writer left, which recorded nothing.
    """
    root = home / ".config" / "vshell" / "themes" / dir_name
    (root / "apps").mkdir(parents=True, exist_ok=True)
    meta = {"name": dir_name, "mode": mode, "pair": "", "source": "curated"}
    if record_palette:
        meta["curatedPalette"] = helper.palette_digest(
            dict(helper.parse_colors_toml_text(colors), mode=mode))
    if adjustments:
        meta["adjustments"] = adjustments
    (root / "theme.json").write_text(json.dumps(meta))
    (root / "colors.toml").write_text(colors)
    for filename, content in (apps or {}).items():
        (root / "apps" / filename).write_text(content)
    return root


@contextlib.contextmanager
def installed_layout(*builtin: str):
    """A HOME plus a built-in themes directory holding only `builtin`.

    `packaging/install-system.sh` copies bauhaus, roseofdune and targets and
    nothing else, so on a packaged install every other theme, the six this
    branch curates included, exists only as a catalog download under HOME. A
    fixture that leaves `builtin_themes_dir` pointed at this checkout tests the
    one shape a real install never has, which is how a guard that could not fire
    in production passed a suite of fifty cases.
    """
    root = Path(tempfile.mkdtemp())
    for name in ("targets", *builtin):
        shutil.copytree(REPO / "themes" / name, root / name)
    original = helper.builtin_themes_dir
    helper.builtin_themes_dir = lambda: root
    try:
        with temp_home() as home:
            helper.ensure_dirs()
            yield home
    finally:
        helper.builtin_themes_dir = original


def download_package(name: str) -> Path:
    """A catalogued theme published into HOME the way `catalog_download_theme` does.

    The marker comes from `catalog_marker_payload`, the downloader's own
    composer, so this fixture cannot drift into testing a marker production no
    longer writes. Hand-writing the fields today's readers consult is how a
    fixture stays green while the thing it stands in for changes shape.
    """
    dest = helper.user_themes_dir() / name
    shutil.copytree(REPO / "themes" / name, dest)
    unpacked = sorted(path.relative_to(dest).as_posix() for path in dest.rglob("*")
                      if path.is_file() and path.name != helper.CATALOG_MARKER)
    written = sum((dest / rel).stat().st_size for rel in unpacked)
    (dest / helper.CATALOG_MARKER).write_text(json.dumps(
        helper.catalog_marker_payload(
            name, dest, {"release": "themes-v5", "rev": 2, "sha256": "0" * 64},
            unpacked, written, ref="v0.5.0"),
        indent=2) + "\n")
    return dest


def write_applied_state(bp: dict) -> dict:
    """The shell state an apply leaves for `bp`, written by production's own composers.

    Both halves come from the apply's own writers: `applied_theme_state` trims
    `theme-current.json` and the `vgs-shell` template renders `theme.json`. A
    fixture that assembled either by hand would seed a state richer than the
    apply writes, and `path`, one of the two keys the save's exemption gates on,
    is among those the apply drops; `carry_curated_apps` is what puts it back,
    from the package it resolves by name.

    Used both to seed an applied theme and as the stand-in for `apply_theme_obj`
    inside a colour edit. Returns the empty result its caller assigns keys onto.
    """
    helper.write_file(helper.cfg_dir() / "theme-current.json",
                      json.dumps(helper.applied_theme_state(bp), indent=2) + "\n")
    helper.write_file(helper.cfg_dir() / "theme.json", helper.render_target_template(
        "vgs-shell", "vgs-theme.json", helper.target_roles(bp)))
    return {}


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

    def overridden(self, app: str, roles: dict) -> dict:
        """The same package after `theme app-colors <app> --set role=#hex` on it.

        The overrides go through `write_user_app_overrides`, the writer that CLI
        path ends in, so this cannot drift into a file shape production no longer
        writes.
        """
        with temp_home() as home:
            write_package(home, "probe", self.COLORS, apps=self.APPS)
            helper.write_user_app_overrides("probe", {app: roles})
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

    def test_a_claude_override_drops_only_the_merge_style_file(self):
        """`theme app-colors claude --set background=...` replaces a colour the
        curated values were picked against, and that layer sits between the
        palette and the render the file merges over. A digest taken over the
        palette map alone read past it: the two digests stayed equal, the file was
        kept, and bands picked for the old background were merged over the new one.
        icons.theme has no template behind it and stays whatever the palette does.
        """
        self.assertEqual(sorted(self.overridden("claude", {"background": "#0b0b0b"})["apps"]),
                         ["icons.theme"])

    def test_an_override_whose_role_name_a_palette_key_spells_drops_it_too(self):
        """The folded roles are namespaced because role names and colors.toml keys
        are separate namespaces that spell some names the same. `accent` is one:
        the class palette declares #9279aa and `target_roles` derives #937bab
        through `ensure_usable_accent`, so the two hold different values under one
        name. The override value here is the colors.toml accent itself, not an
        arbitrary hex: that is what makes a bare fold produce a digest byte for
        byte identical to the recorded one while the override still moves five
        Claude Code tokens, so a reader who swaps it for any other colour removes
        the control this case is. `theme app-colors claude --set accent=#9279aa`
        reaches it, since `accent` is in `theme_role_universe`.
        """
        self.assertEqual(sorted(self.overridden("claude", {"accent": "#9279aa"})["apps"]),
                         ["icons.theme"])

    def test_an_override_for_another_app_leaves_the_claude_file_alone(self):
        """The digest folds in the owning app's section and no other. Folding the
        whole override table in instead would drop a theme's hand-picked diff
        bands the moment a user set a btop colour, which reaches none of the roles
        those bands sit on."""
        self.assertEqual(sorted(self.overridden("btop", {"background": "#0b0b0b"})["apps"]),
                         ["claude-dark.json", "icons.theme"])

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


class InstalledLayout(unittest.TestCase):
    """The curated-file rule as a packaged install reaches it.

    Every case here runs with `builtin_themes_dir` holding only what
    `install-system.sh` copies, because the six curated themes are catalog-only
    there. The rule is one comparison: the palette about to be rendered against
    the `curatedPalette` digest the package recorded for the palette its curated
    values were picked against.
    """

    def light(self, blueprint: dict) -> list:
        return rendered_file(blueprint, "light")[1]

    def test_a_pristine_download_keeps_its_curated_file_and_misses_no_rule(self):
        """The download writes colors.toml into the user directory, so a rule that
        asked where that file sat read every untouched download as edited and
        dropped the file that closes akane's light diff bands."""
        with installed_layout():
            download_package("akane")
            blueprint = helper.load_theme_package("akane")
            self.assertEqual(
                (blueprint["catalogOwned"], blueprint["catalogPristine"],
                 "claude-light.json" in blueprint["apps"], self.light(blueprint)),
                (True, True, True, []))

    def test_a_colour_edit_on_a_download_drops_the_curated_file(self):
        """No built-in directory exists for a catalog-only theme, so a rule that
        required one never fired here: the frozen bands stayed over the edited
        colours and the light theme rendered them 1.03:1 off the background."""
        with installed_layout():
            download_package("akane")
            with mock.patch.object(helper, "apply_theme_obj", return_value={}):
                helper.persist_color_edits(["foreground=#101010"], "akane")
            blueprint = helper.load_theme_package("akane")
            self.assertEqual(
                ("claude-light.json" in blueprint["apps"], self.light(blueprint)),
                (False, []))

    def test_a_claude_override_drops_the_curated_file_and_misses_no_rule(self):
        """The reproduced case: `theme app-colors claude --set background=#0b0b0b`
        on akane. The override merges into the roles the curated file sits on top
        of, so it moves the palette those values were picked for while leaving
        colors.toml untouched. Judged on the palette map alone the file was kept
        and the light render named six shortfalls, body text at 1.04:1 on one diff
        fill, 1.09:1 on the other and 1.07:1 on each diff band, over a /diff panel
        a user cannot read."""
        with installed_layout():
            download_package("akane")
            helper.write_user_app_overrides("akane", {"claude": {"background": "#0b0b0b"}})
            blueprint = helper.load_theme_package("akane")
            self.assertEqual(
                ("claude-light.json" in blueprint["apps"], self.light(blueprint)),
                (False, []))

    def saved_under_own_name(self, overrides: dict, edits: tuple = (), transform: str = "") -> tuple:
        """akane downloaded, optionally overridden, optionally colour-edited
        without `--save`, then saved the way `set-wallpaper --save` saves:
        `carry_curated_apps` over a rebuild from the applied theme, which is the
        only shipped call that reaches this exemption.

        A blueprint straight from `load_theme_package` is a shape production never
        hands the save. `carry_curated_apps` copies `apps`, `package`, `path`,
        `builtin` and `userDir` and nothing else, so a fixture that skips it tests
        an exemption carried on a key the real caller drops, and passes while the
        file is deleted in production.

        `edits` runs `apply_color_edits` with no `--save`, which is what moves the
        applied palette while leaving the package's `colors.toml` and its recorded
        digest untouched. The save then writes the edited palette over the package
        the exemption asks about.

        `transform` runs `theme mode --transform <mode>` and a save ahead of all
        that, which rewrites the package from a transformed palette and so leaves
        it declaring `source: generated`. Role derivation adjusts contrast on that
        branch and so is not idempotent there, and a package on this side matches
        itself only when both sides of the comparison are rebuilt the same number
        of times.

        Returns the package's declared source, whether the save left the file on
        disk, whether the loader takes it back once the override is cleared, and
        that reload's light shortfalls. Every read happens inside the layout,
        because the render resolves akane through `builtin_themes_dir` and `home`,
        which the fixture restores on exit.
        """
        with installed_layout():
            dest = download_package("akane")
            write_applied_state(helper.load_theme_package("akane"))
            if transform:
                write_applied_state(helper.transformed_mode_blueprint(
                    helper.find_theme("akane"), transform,
                    str(helper.current_theme().get("wallpaper") or "")))
                self.set_wallpaper_save()
            helper.write_user_app_overrides("akane", overrides)
            if edits:
                with mock.patch.object(helper, "apply_theme_obj", side_effect=write_applied_state):
                    helper.apply_color_edits(list(edits), "akane")
            self.set_wallpaper_save()
            on_disk = {path.name for path in (dest / "apps").iterdir()}
            helper.write_user_app_overrides("akane", {})
            cleared = helper.load_theme_package("akane")
            return (json.loads((dest / "theme.json").read_text()).get("source"),
                    "claude-light.json" in on_disk, "claude-light.json" in cleared["apps"],
                    self.light(cleared))

    def set_wallpaper_save(self) -> None:
        """`set-wallpaper --save` on the applied theme: carry, apply, save."""
        carried = helper.carry_curated_apps(helper.blueprint_from_current_theme(name="akane"))
        write_applied_state(carried)
        helper.save_theme_package(carried, name="akane")

    def test_a_save_under_an_override_keeps_the_file_the_override_can_give_back(self):
        """`set-wallpaper --save` saves under the theme's own name, and the prune
        removes every merge-style file the map it is handed does not carry. The
        override drop put this file outside that map while leaving `colors.toml`
        untouched, so the prune deleted the only copy a download has and `theme
        app-colors claude --reset` could not bring it back.

        The no-override row says the same save spares the file when no override is
        set, so what the first row measures is the exemption and not a difference
        in what the save was handed.

        The third row is the must-fail control that the prune reaches this file at
        all, and the one that says the exemption asks about the palette as well as
        the override. `apply-colors` with no `--save` moves the applied palette
        while the package's `colors.toml` keeps the colours its recorded digest
        names, so the override question alone still reads the file as merely
        overridden. Sparing it there let the save certify colours the file was
        never picked for, and the reload painted akane's diff bands at 1.05:1 and
        1.06:1 against the new background.

        The fourth row is the same first row over a package that declares
        `source: generated`, which `theme mode --transform` plus a save is the
        shipped way to reach. Role derivation adjusts contrast on that branch and
        so is not idempotent there: one more trip through it moves the six bright
        ANSI slots, so comparing the package against a copy of itself rebuilt a
        different number of times never matched. The exemption was refused and the
        save deleted the file the first row proves it must keep. The declared
        source is asserted in every row so this one cannot quietly stop reaching
        the branch it is named for.
        """
        self.assertEqual(
            (self.saved_under_own_name({"claude": {"background": "#0b0b0b"}}),
             self.saved_under_own_name({}),
             self.saved_under_own_name({"claude": {"background": "#0b0b0b"}},
                                       ("foreground=#101010",)),
             self.saved_under_own_name({"claude": {"background": "#0b0b0b"}},
                                       transform="light")),
            (("curated", True, True, []), ("curated", True, True, []),
             ("generated", False, False, []), ("generated", True, True, [])))

    def test_a_save_under_another_name_grants_the_override_no_exemption(self):
        """The exemption asks about the package the save is writing over. Under a
        different name the destination is another package, and a merge-style file
        already sitting there was picked for colours this save never saw, which is
        the unjudged certification the digest exists to prevent.

        The destination is a complete package carrying its own curated file and
        its own claude override, because that is the only shape in which the name
        comparison decides anything: a bare directory is refused earlier, for
        holding no `theme.json`. Its palette is a faithful copy of the source's,
        so the palette comparison passes and the name is the sole thing left to
        refuse the exemption.

        The source is a loader blueprint rather than a carried one, which gives
        the exemption every key it could read. The save under the theme's own name
        is where the carried shape has to be exact.
        """
        with installed_layout():
            download_package("akane")
            copy = helper.save_theme_package(helper.load_theme_package("akane"), name="akane-copy")
            helper.write_user_app_overrides("akane-copy", {"claude": {"background": "#0b0b0b"}})
            helper.write_user_app_overrides("akane", {"claude": {"background": "#0b0b0b"}})
            overridden = helper.load_theme_package("akane")
            before = {path.name for path in (copy / "apps").iterdir()}
            helper.save_theme_package(overridden, name="akane-copy")
            after = {path.name for path in (copy / "apps").iterdir()}
            self.assertEqual(
                ("claude-light.json" in before, "claude-light.json" in after), (True, False))

    def test_a_package_whose_colours_do_not_parse_reports_once_and_still_loads(self):
        """A user overlay `colors.toml` is hand-written, so a typo in it is how a
        user meets this. The loader needs an adjusted and an unadjusted identity
        map and once read the file for each, so the diagnostic arrived twice, and
        it named the `theme.json` `name` key, which a package need not carry: the
        pair printed as `theme package : no recognized colors`.

        The package still loads rather than disappearing from the list. Every role
        comes from the defaults, and the recorded digest still answers for the
        curated files, so the only thing lost is the palette the user mistyped.
        """
        with installed_layout():
            root = helper.user_themes_dir() / "probe"
            (root / "apps").mkdir(parents=True)
            (root / "theme.json").write_text(json.dumps({"mode": "dark", "source": "curated"}))
            (root / "colors.toml").write_text("# a typo no parser reads\nbackgrund = notahex\n")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                blueprint = helper.load_theme_package("probe")
            reported = [line for line in stderr.getvalue().splitlines()
                        if "no recognized colors" in line]
            self.assertEqual(
                (len(reported), reported[0].split(":")[0],
                 blueprint["palette"]["colors"]),
                (1, "theme package probe", helper.DEFAULT_COLORS))

    def test_a_colour_edit_keeps_the_replacing_file_it_drops_the_merge_style_one(self):
        """A user package owns its palette outright, so nothing about where its
        files sit distinguishes it from one that was edited. icons.theme has no
        template behind it and stays whatever the palette does."""
        with installed_layout() as home:
            write_package(home, "probe", RestyledPackages.COLORS, apps=RestyledPackages.APPS)
            before = helper.load_theme_package("probe")
            with mock.patch.object(helper, "apply_theme_obj", return_value={}):
                helper.persist_color_edits(["foreground=#101010"], "probe")
            after = helper.load_theme_package("probe")
            self.assertEqual(
                (sorted(before["apps"]), sorted(after["apps"])),
                (["claude-dark.json", "icons.theme"], ["icons.theme"]))

    def test_a_saved_copy_answers_the_same_as_the_package_it_came_from(self):
        """save_theme_package records the digest of the colors.toml it writes, so
        an untouched copy keeps what its source kept and an edited copy drops it.
        Without that record a copy says nothing about its own palette and every
        curated file it carried would have to be dropped on sight."""
        with installed_layout():
            download_package("akane")
            source = helper.load_theme_package("akane")
            helper.save_theme_package(source, name="akane-copy")
            copied = helper.load_theme_package("akane-copy")
            with mock.patch.object(helper, "apply_theme_obj", return_value={}):
                helper.persist_color_edits(["foreground=#101010"], "akane-copy")
            edited = helper.load_theme_package("akane-copy")
            self.assertEqual(
                ("claude-light.json" in source["apps"], "claude-light.json" in copied["apps"],
                 self.light(copied), "claude-light.json" in edited["apps"]),
                (True, True, [], False))

    def test_a_save_under_the_theme_name_removes_the_file_it_just_dropped(self):
        """`set-wallpaper --save` and `apply-colors --save` call save_theme_package
        with the theme's own name, and for a downloaded theme that is the
        download's own directory. A merge-style file left there from the download
        was not written by this save and was never judged against the palette it
        records, so the new digest certified it and the next load took it back.
        The replacing file has no such claim to answer and stays."""
        with installed_layout():
            dest = download_package("akane")
            helper.set_theme_adjustments("akane", {"brightness": 100})
            restyled_download = helper.load_theme_package("akane")
            helper.save_theme_package(restyled_download, name="akane")
            on_disk = {path.name for path in (dest / "apps").iterdir()}
            reloaded = helper.load_theme_package("akane")
            self.assertEqual(
                ("claude-light.json" in restyled_download["apps"],
                 "claude-light.json" in on_disk, "icons.theme" in on_disk,
                 "claude-light.json" in reloaded["apps"], self.light(reloaded)),
                (False, False, True, False, []))

    def test_an_overlay_written_before_the_digest_keeps_the_built_in_record(self):
        """A package is two directories and each vouches only for the files it
        supplied. This curated file comes from the built-in layer, so the built-in
        `theme.json` answers for it however the overlay is written. Reading one
        digest for the whole package instead lost it: `compose_theme_files`
        composes at file level, an overlay written before this key existed shadows
        the built-in record whole, and setting a default wallpaper wrote one of
        those, so the six lost their hand-picked diff bands on upgrade. An overlay
        that supplies its own palette moves the effective digest, and then the
        built-in record no longer matches."""
        with temp_home() as home:
            overlay = home / ".config" / "vshell" / "themes" / "archwave"
            overlay.mkdir(parents=True)
            (overlay / "theme.json").write_text(json.dumps(
                {"name": "archwave", "mode": "dark", "pair": "", "source": "curated",
                 "wallpaper": "some.jpg"}))
            inherited = helper.load_theme_package("archwave")
            edited = dict(helper.parse_colors_toml(REPO / "themes" / "archwave" / "colors.toml"),
                          foreground="#101010")
            (overlay / "colors.toml").write_text(helper.colors_toml_from_map(edited))
            replaced = helper.load_theme_package("archwave")
        self.assertEqual(
            ("claude-light.json" in inherited["apps"], self.light(inherited),
             "claude-light.json" in replaced["apps"]),
            (True, [], False))

    def test_a_save_over_a_built_in_theme_leaves_its_curated_values_behind(self):
        """`compose_theme_files` is a union, so a save under a built-in theme's own
        name writes the user layer while the built-in layer keeps supplying the
        curated file the save never saw. Judging the package by one digest, the
        user `theme.json` the save had just written matched the saved palette and
        certified a file picked against the palette that save replaced. The saver
        cannot fix this by deleting: the file is not in the directory it writes,
        and `save-current` hands it a palette-only blueprint with no apps at all.
        """
        with temp_home():
            helper.set_theme_adjustments("akane", {"brightness": 100})
            restyled_builtin = helper.load_theme_package("akane")
            helper.save_theme_package(restyled_builtin, name="akane")
            reloaded = helper.load_theme_package("akane")
            content, missed = rendered_file(reloaded, "light")
        curated = json.loads(
            (REPO / "themes" / "akane" / "apps" / "claude-light.json").read_text())["overrides"]
        self.assertEqual(
            ("claude-light.json" in restyled_builtin["apps"],
             "claude-light.json" in reloaded["apps"],
             content["overrides"]["diffAdded"] == curated["diffAdded"], missed),
            (False, False, False, []))

    def test_a_theme_in_both_layers_loses_its_curated_values_on_a_save(self):
        """A theme can exist in both layers at once: shipped built in and also
        present in the user directory, which is what a download of a built-in
        theme leaves. The save then writes the user layer while the built-in layer
        keeps supplying its own curated file, so deleting in the destination
        cannot reach it and only the per-layer digest test can. No other case in
        this file builds that layout, which is why a version answering correctly
        on one layer alone still passed the whole suite.
        """
        with installed_layout("akane") as home:
            download_package("akane")
            self.assertTrue((helper.builtin_themes_dir() / "akane" / "apps"
                             / "claude-light.json").is_file())
            self.assertTrue((home / ".config" / "vshell" / "themes" / "akane" / "apps"
                             / "claude-light.json").is_file())
            helper.set_theme_adjustments("akane", {"brightness": 100})
            restyled_both = helper.load_theme_package("akane")
            helper.save_theme_package(restyled_both, name="akane")
            reloaded = helper.load_theme_package("akane")
            content, missed = rendered_file(reloaded, "light")
        curated = json.loads(
            (REPO / "themes" / "akane" / "apps" / "claude-light.json").read_text())["overrides"]
        carried = [token for token, value in curated.items()
                   if content["overrides"].get(token) == value]
        self.assertEqual(
            ("claude-light.json" in restyled_both["apps"],
             "claude-light.json" in reloaded["apps"], carried, missed),
            (False, False, [], []))

    def test_regenerating_one_app_leaves_a_curated_file_it_was_not_given(self):
        """Only save_theme_package hands the writer the complete intended contents.
        Every other caller arrives with a rendered_apps_for map, which can never
        hold a claude file because that target has no template, so a prune that
        read any short map as intent deleted a file the caller was never asked
        about. `theme regenerate <name> --app btop` did that, and for a download
        or a user-created package the user directory holds the only copy.
        """
        with temp_home() as home:
            pin_theme_apps(home, btop=True)
            root = write_package(home, "probe", RestyledPackages.COLORS,
                                 apps=RestyledPackages.APPS)
            blueprint = helper.load_theme_package("probe")
            rendered = {name: body for name, body in helper.rendered_apps_for(blueprint, helper.bp_app_overrides(blueprint)).items()
                        if name.split(".")[0] == "btop"}
            helper.materialize_theme_package(blueprint, apps=rendered)
            survived = {path.name for path in (root / "apps").iterdir()}
        self.assertEqual(
            ("claude-dark.json" in blueprint["apps"], sorted(rendered),
             "claude-dark.json" in survived, "icons.theme" in survived),
            (True, ["btop.theme"], True, True))

    def test_a_curated_file_that_cannot_be_read_survives_the_save(self):
        """The save reads each declared curated file to copy it, and a read that
        fails once left the name out of the map it hands the writer. The prune
        then removed that file, because a short map is how a caller says it did
        not want one. The two are not the same: the prune's contract is what the
        caller withheld, not what it could not read. For a download or a
        user-created package the destination holds the only copy, so the failure
        deleted a user's only curated customisation with nothing said.
        """
        with temp_home() as home:
            root = write_package(home, "probe", RestyledPackages.COLORS,
                                 apps=RestyledPackages.APPS)
            blueprint = helper.load_theme_package("probe")
            unreadable = Path(blueprint["apps"]["claude-dark.json"])
            original = unreadable.read_text()
            unreadable.chmod(0o000)
            try:
                helper.save_theme_package(blueprint, name="probe")
            finally:
                # Tolerant, so a save that deleted the file reports through the
                # assertion below rather than as a traceback from the cleanup.
                if unreadable.is_file():
                    unreadable.chmod(0o644)
            survived = {path.name for path in (root / "apps").iterdir()}
            kept = unreadable.read_text() if unreadable.is_file() else None
            self.assertEqual(
                ("claude-dark.json" in survived, "icons.theme" in survived, kept),
                (True, True, original))

    def test_an_interrupted_save_publishes_no_digest_for_files_it_left(self):
        """theme.json carries the digest that certifies the package's contents, so
        it is written after the cleanup rather than before it. Written first, a
        save killed between the metadata and the prune left the stale merge-style
        file on disk already vouched for by the new palette, which is the state
        the digest exists to prevent. Written last, the interrupted package has
        no user theme.json at all, so the loader falls back to the built-in
        record and certifies nothing that this save did not finish.
        """
        with temp_home() as home:
            root = write_package(home, "probe", RestyledPackages.COLORS,
                                 apps=RestyledPackages.APPS)
            before = json.loads((root / "theme.json").read_text())["curatedPalette"]
            blueprint = helper.load_theme_package("probe")
            edited = dict(helper.parse_colors_toml_text(RestyledPackages.COLORS),
                          foreground="#101010")
            moved = dict(blueprint, palette=helper.palette_from_colors_map(
                edited, name="probe", wallpaper="")["palette"])
            with mock.patch.object(helper.Path, "unlink",
                                   side_effect=OSError("interrupted")):
                with self.assertRaises(OSError):
                    helper.save_theme_package(moved, name="probe")
            after = json.loads((root / "theme.json").read_text())["curatedPalette"]
        self.assertEqual(after, before)

    def test_a_package_recording_no_palette_drops_its_merge_style_file(self):
        """Nothing on disk says what a legacy package's curated values were picked
        against. The unreadable-diff-panel cost sits on keeping it and the plainer
        render on dropping it, so absence reads as a palette that does not match."""
        with installed_layout() as home:
            write_package(home, "legacy", RestyledPackages.COLORS,
                          apps=RestyledPackages.APPS, record_palette=False)
            self.assertEqual(sorted(helper.load_theme_package("legacy")["apps"]),
                             ["icons.theme"])


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
