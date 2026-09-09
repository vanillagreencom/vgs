#!/usr/bin/env python3
"""Controls for the settings type-role guard.

Every case here plants a defect the guard claims to catch and requires it to be
reported. A guard that cannot fail is a guard that proves nothing, and this one
reads QML by brace matching, which is exactly the kind of parsing that quietly
stops recognising its input.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
GUARD_PATH = REPO_ROOT / "scripts" / "check-settings-type.py"


def load_guard():
    loader = importlib.machinery.SourceFileLoader("settings_type_guard", str(GUARD_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


GUARD = load_guard()


def surface(body: str, marker: str = "    readonly property bool settingsSurface: true\n") -> str:
    return f"""import QtQuick
import qs.Common

Column {{
    id: root

{marker}
{body}
}}
"""


def check(body: str, **kwargs) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "Probe.qml"
        path.write_text(surface(body, **kwargs), encoding="utf-8")
        # The guard reports paths relative to the repo root; a temp file is not
        # under it, so point the root at the temp tree for the call.
        original = GUARD.REPO_ROOT
        GUARD.REPO_ROOT = Path(tmp)
        try:
            problems, _ = GUARD.check_file(path)
        finally:
            GUARD.REPO_ROOT = original
        return problems


TITLE = """    StyledText {
        text: "A page"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Theme.fontWeightSectionHeader
        color: Theme.surfaceText
    }"""

HEADER = """    StyledText {
        text: "A section"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Theme.fontWeightSectionHeader
        color: Theme.surfaceText
    }"""

SUB = """    StyledText {
        text: "An explanation"
        font.pixelSize: Theme.settingsFontSize
        color: Theme.surfaceVariantText
    }"""

BODY = """    StyledText {
        text: modelData.label
        font.pixelSize: Theme.settingsFontSize
        color: Theme.surfaceText
    }"""


class RolesAccepted(unittest.TestCase):
    def test_every_role_passes(self):
        self.assertEqual(check("\n\n".join([TITLE, HEADER, SUB, BODY])), [])

    def test_a_status_line_may_take_a_state_colour(self):
        status = BODY.replace("Theme.surfaceText",
                              "root.failed ? Theme.error : Theme.success")
        self.assertEqual(check(status), [])

    def test_a_list_row_may_dim_itself_with_a_ternary(self):
        row = BODY.replace("Theme.surfaceText",
                           "modelData.usable ? Theme.surfaceText : Theme.surfaceVariantText")
        self.assertEqual(check(row), [])


class RolesRefused(unittest.TestCase):
    def test_the_bar_size_is_refused(self):
        # The defect that started this: a section header at the bar's size renders
        # smaller than the controls it introduces.
        problems = check(HEADER.replace("Theme.fontSizeMedium", "Theme.fontSizeSmall"))
        self.assertEqual(len(problems), 1)
        self.assertIn("Theme.fontSizeSmall is the bar's size", problems[0])

    def test_a_literal_size_is_refused(self):
        problems = check(HEADER.replace("Theme.fontSizeMedium", "13"))
        self.assertEqual(len(problems), 1)
        self.assertIn("font.pixelSize is 13", problems[0])

    def test_a_title_spelling_its_weight_out_is_refused(self):
        problems = check(TITLE.replace("Theme.fontWeightSectionHeader", "Font.Bold"))
        self.assertEqual(len(problems), 1)
        self.assertIn("must take Theme.fontWeightSectionHeader", problems[0])

    def test_a_title_with_no_weight_is_refused(self):
        problems = check(TITLE.replace("        font.weight: Theme.fontWeightSectionHeader\n", ""))
        self.assertEqual(len(problems), 1)
        self.assertIn("the inherited weight", problems[0])

    def test_a_header_drifting_to_a_label_weight_is_refused(self):
        # The exact drift D012 exists to stop, and the case the first version of
        # this guard accepted: a heading reverted to Font.Medium became
        # indistinguishable from a control label and nothing reported it. The
        # guard can require the header weight because a settings page never
        # hand-writes a control label — VgsToggle and VgsDropdown render theirs.
        problems = check(HEADER.replace("Theme.fontWeightSectionHeader", "Font.Medium"))
        self.assertEqual(len(problems), 1)
        self.assertIn("must take Theme.fontWeightSectionHeader", problems[0])

    def test_a_header_with_no_weight_is_refused(self):
        problems = check(HEADER.replace("        font.weight: Theme.fontWeightSectionHeader\n", ""))
        self.assertEqual(len(problems), 1)
        self.assertIn("the inherited weight", problems[0])

    def test_a_near_miss_colour_in_the_small_tier_is_refused(self):
        # The live defect this found: cloudSync's rclone line on surfaceTextMedium,
        # which reads as sub text at a different alpha.
        problems = check(SUB.replace("Theme.surfaceVariantText", "Theme.surfaceTextMedium"))
        self.assertEqual(len(problems), 1)
        self.assertIn("Theme.surfaceTextMedium", problems[0])

    def test_a_stray_colour_inside_a_ternary_is_refused(self):
        row = BODY.replace("Theme.surfaceText",
                           "modelData.usable ? Theme.surfaceText : Theme.surfaceTextMedium")
        problems = check(row)
        self.assertEqual(len(problems), 1)
        self.assertIn("Theme.surfaceTextMedium", problems[0])

    def test_small_tier_text_with_no_colour_is_refused(self):
        problems = check(SUB.replace("        color: Theme.surfaceVariantText\n", ""))
        self.assertEqual(len(problems), 1)
        self.assertIn("states no colour", problems[0])


class MissingSizeRefused(unittest.TestCase):
    """A role the guard never sees is a role it never enforces."""

    def test_a_styled_text_with_no_size_is_refused(self):
        problems = check(SUB.replace("        font.pixelSize: Theme.settingsFontSize\n", ""))
        self.assertEqual(len(problems), 1)
        self.assertIn("states no font.pixelSize", problems[0])

    def test_a_sized_neighbour_does_not_cover_for_it(self):
        # The nastier shape: the file still declares roles, so a check that
        # read the surface rather than the block would find a size and pass.
        body = "\n\n".join([SUB, BODY.replace(
            "        font.pixelSize: Theme.settingsFontSize\n", "")])
        problems = check(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("states no font.pixelSize", problems[0])


class HeadingColourRefused(unittest.TestCase):
    """The role fixes a heading's colour as well as its weight."""

    def test_a_title_recoloured_is_refused(self):
        problems = check(TITLE.replace("Theme.surfaceText", "Theme.error"))
        self.assertEqual(len(problems), 1)
        self.assertIn("must take color Theme.surfaceText", problems[0])

    def test_a_header_recoloured_to_the_sub_text_colour_is_refused(self):
        # The nastiest of the three: it still reads as a heading, at the heading
        # weight, while having quietly left its role.
        problems = check(HEADER.replace("Theme.surfaceText", "Theme.surfaceVariantText"))
        self.assertEqual(len(problems), 1)
        self.assertIn("must take color Theme.surfaceText", problems[0])

    def test_a_heading_with_no_colour_is_refused(self):
        problems = check(HEADER.replace("        color: Theme.surfaceText\n", ""))
        self.assertEqual(len(problems), 1)
        self.assertIn("the inherited colour", problems[0])


class SmallTierClosure(unittest.TestCase):
    """A set that only rejects wrong tokens is not closed."""

    def test_a_hex_literal_is_refused(self):
        problems = check(SUB.replace("Theme.surfaceVariantText", '"#ff0000"'))
        self.assertEqual(len(problems), 1)
        self.assertIn("does not resolve to theme tokens", problems[0])

    def test_a_named_colour_literal_is_refused(self):
        problems = check(SUB.replace("Theme.surfaceVariantText", '"red"'))
        self.assertEqual(len(problems), 1)
        self.assertIn("does not resolve to theme tokens", problems[0])

    def test_a_literal_hidden_in_a_ternary_is_refused(self):
        row = BODY.replace("Theme.surfaceText",
                           'modelData.usable ? Theme.surfaceText : "#888888"')
        problems = check(row)
        self.assertEqual(len(problems), 1)
        self.assertIn("does not resolve to theme tokens", problems[0])

    def test_a_property_branch_is_refused(self):
        # The branch beside an allowed token carries whatever the property was
        # assigned, and a check that only read the tokens present passed it.
        row = BODY.replace("Theme.surfaceText",
                           "root.failed ? Theme.error : root.customColor")
        problems = check(row)
        self.assertEqual(len(problems), 1)
        self.assertIn("root.customColor", problems[0])

    def test_a_property_branch_in_a_nested_ternary_is_refused(self):
        row = BODY.replace(
            "Theme.surfaceText",
            "a ? Theme.error : b ? Theme.surfaceText : root.customColor")
        problems = check(row)
        self.assertEqual(len(problems), 1)
        self.assertIn("root.customColor", problems[0])

    def test_a_nested_ternary_of_allowed_tokens_passes(self):
        # Both conditions name properties. Refusing them would refuse the shape
        # a real status line is written in.
        row = BODY.replace(
            "Theme.surfaceText",
            "a ? Theme.error : b ? Theme.surfaceText : Theme.surfaceVariantText")
        self.assertEqual(check(row), [])


class SurfaceRecognition(unittest.TestCase):
    def test_a_file_without_the_marker_is_not_a_surface(self):
        self.assertEqual(check(HEADER.replace("Theme.fontSizeMedium", "Theme.fontSizeSmall"),
                               marker=""), [])

    def test_a_pluginsettings_root_is_a_surface_without_the_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Probe.qml"
            path.write_text(
                "import QtQuick\n\n// A comment before the root.\nPluginSettings {\n    id: root\n"
                '    StyledText {\n        font.pixelSize: Theme.fontSizeSmall\n'
                "        color: Theme.surfaceText\n    }\n}\n", encoding="utf-8")
            original = GUARD.REPO_ROOT
            GUARD.REPO_ROOT = Path(tmp)
            try:
                problems, _ = GUARD.check_file(path)
            finally:
                GUARD.REPO_ROOT = original
        self.assertEqual(len(problems), 1)


class RootDetection(unittest.TestCase):
    def test_a_block_comment_before_the_root_does_not_hide_it(self):
        text = ("import QtQuick\n\n/* A licence header,\n   several lines of it. */\n"
                "PluginSettings {\n    id: root\n}\n")
        self.assertTrue(GUARD.is_surface(text))

    def test_a_non_settings_root_is_not_a_surface(self):
        self.assertFalse(GUARD.is_surface("import QtQuick\n\nColumn {\n    id: root\n}\n"))

    def test_a_run_of_blank_lines_does_not_hang(self):
        # The first version matched the whole preamble in one pattern and
        # alternated a whitespace run inside a repetition. That backtracks
        # exponentially, and it was not theoretical: 40 blank lines above a root
        # that does not match ran for minutes before it was killed. CodeQL
        # flagged it py/redos. Any settings file with a long enough gap above
        # its root would have hung the check in CI.
        text = "import QtQuick\n" + "\n" * 400 + "notATypeName\n"
        started = time.monotonic()
        self.assertFalse(GUARD.is_surface(text))
        self.assertLess(time.monotonic() - started, 2.0,
                        "root detection is superlinear in the blank lines above the root")


class BraceWalking(unittest.TestCase):
    """The guard reads blocks by matching braces, so prose is the hazard."""

    def test_a_brace_inside_a_string_does_not_close_the_block(self):
        # Without blanking, the "{" in this label would close the StyledText
        # block early and the weight below it would go unseen — the check would
        # pass a title that spells its weight out.
        body = """    StyledText {
        text: "Use {braces} in prose"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }"""
        problems = check(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("must take Theme.fontWeightSectionHeader", problems[0])

    def test_a_brace_inside_a_comment_does_not_close_the_block(self):
        body = """    StyledText {
        // A closing } written in prose above the size.
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }"""
        problems = check(body)
        self.assertEqual(len(problems), 1)

    def test_a_commented_out_size_is_not_a_role(self):
        body = """    StyledText {
        // font.pixelSize: Theme.fontSizeSmall
        font.pixelSize: Theme.settingsFontSize
        color: Theme.surfaceVariantText
    }"""
        self.assertEqual(check(body), [])

    def test_a_neighbour_block_does_not_supply_the_weight(self):
        # Two sibling blocks: the second has no weight of its own and must not
        # borrow the first's.
        body = TITLE + "\n\n" + """    StyledText {
        text: "Another"
        font.pixelSize: Theme.fontSizeLarge
        color: Theme.surfaceText
    }"""
        problems = check(body)
        self.assertEqual(len(problems), 1)
        self.assertIn("the inherited weight", problems[0])


class RepositoryState(unittest.TestCase):
    def test_the_shipped_surfaces_pass_and_are_actually_found(self):
        self.assertEqual(GUARD.main(), 0)
        found = [p for p in sorted(GUARD.PLUGIN_ROOT.rglob("*.qml"))
                 if GUARD.is_surface(p.read_text(encoding="utf-8"))]
        # A guard that recognises nothing reports success. Name the floor so
        # that failure reads as the recogniser breaking, not the tree emptying.
        self.assertGreaterEqual(len(found), 7, f"only {len(found)} settings surface(s) recognised")


if __name__ == "__main__":
    unittest.main()
