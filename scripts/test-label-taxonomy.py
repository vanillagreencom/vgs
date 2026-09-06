#!/usr/bin/env python3
"""Controls for label extraction from the taxonomy tables."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GUARD_PATH = REPO_ROOT / "scripts" / "check-label-taxonomy.py"

TAXONOMY = """
## Project issue label taxonomy

### Domain labels

| Label | Use when |
|-------|----------|
| `releases` | Cutting a release. |
| `1.0` | A leading digit is a real label name. |
| `agent:generalist` | A colon is too. |

### Never-use labels

| Label | Why never |
|-------|-----------|
| `ios` | Wrong platform. |
| `2.0` | Numeric here as well. |
"""
USABLE = {"releases", "1.0", "agent:generalist"}
NEVER = {"ios", "2.0"}


def load_guard():
    loader = importlib.machinery.SourceFileLoader("label_taxonomy_guard", str(GUARD_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


guard = load_guard()


def sections_for(text):
    """Run the real parser over a manifest holding `text`."""
    with tempfile.TemporaryDirectory() as tmp:
        manifest = Path(tmp) / "kendex.toml"
        manifest.write_text(text, encoding="utf-8")
        with mock.patch.object(guard, "MANIFEST", manifest):
            return guard.taxonomy_sections()


class LabelTaxonomyParser(unittest.TestCase):
    def test_each_table_yields_its_own_labels_digit_led_and_colon_names_included(self):
        self.assertEqual(sections_for(TAXONOMY), (USABLE, NEVER))

    def test_control_the_letter_only_pattern_loses_the_numeric_labels(self):
        """The mutant that hid the bug: a leading-letter pattern still reads the rest."""
        letter_led = re.compile(r"`([A-Za-z][A-Za-z0-9:._-]*)`")
        with mock.patch.object(guard, "LABEL_SPAN", letter_led):
            self.assertEqual(sections_for(TAXONOMY), (USABLE - {"1.0"}, NEVER - {"2.0"}))

    def test_prose_backticks_are_not_labels(self):
        """Both sets: the appended text lands after the never-use heading, so an
        assertion on the usable set alone would let the filter go with the control green."""
        prose = TAXONOMY + """
Prose naming `kendex` and `docs/architecture/` must not become labels.

| Label | Use when |
|-------|----------|
| `linear` | Filtered as prose, not a label. |
"""
        self.assertEqual(sections_for(prose), (USABLE, NEVER))


if __name__ == "__main__":
    unittest.main()
