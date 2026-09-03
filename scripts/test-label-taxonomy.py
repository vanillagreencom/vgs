#!/usr/bin/env python3
"""Controls for the label-taxonomy parser.

The parser is the allow-list the project-management preflight consults before
every issue create or label update, and the preflight STOPS on a label it
cannot find. A label the parser cannot see is therefore indistinguishable from
one nobody documented: the sweep reports it missing however carefully it was
written down. `1.0`, kendex's release set, was exactly that for as long as the
pattern demanded a leading letter.

The guard has no inline self-test, so its controls live here.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import sys
import tempfile
from pathlib import Path


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


def load_guard():
    loader = importlib.machinery.SourceFileLoader("label_taxonomy_guard", str(GUARD_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


guard = load_guard()


def assert_equal(actual, expected, message):
    if actual != expected:
        raise AssertionError(f"{message}: expected {expected!r}, got {actual!r}")


def sections_for(text):
    """Run the real parser over a manifest holding `text`."""
    with tempfile.TemporaryDirectory() as tmp:
        manifest = Path(tmp) / "kendex.toml"
        manifest.write_text(text, encoding="utf-8")
        original = guard.MANIFEST
        guard.MANIFEST = manifest
        try:
            return guard.taxonomy_sections()
        finally:
            guard.MANIFEST = original


def test_a_label_name_may_begin_with_a_digit():
    usable, never = sections_for(TAXONOMY)
    assert_equal("1.0" in usable, True, "a leading-digit label is read from a usable table")
    assert_equal("2.0" in never, True, "and from the never-use table")
    assert_equal("releases" in usable, True, "an ordinary name still parses")
    assert_equal("agent:generalist" in usable, True, "a colon in the name still parses")
    assert_equal("1.0" in never, False, "the two tables stay separate")


def test_the_leading_letter_pattern_is_what_hid_it():
    """The must-fail control. Restoring the old letter-only pattern has to put
    the numeric labels back out of reach, or the case above proves nothing
    about the fix it exists for."""
    import re

    original = guard.LABEL_SPAN
    guard.LABEL_SPAN = re.compile(r"`([A-Za-z][A-Za-z0-9:._-]*)`")
    try:
        usable, never = sections_for(TAXONOMY)
    finally:
        guard.LABEL_SPAN = original
    assert_equal("1.0" in usable, False, "the old pattern could not see a numeric label")
    assert_equal("2.0" in never, False, "in either table")
    assert_equal("releases" in usable, True, "while still reading the rest, which is why it hid")


def test_prose_backticks_are_not_labels():
    """Both sets, because this fixture appends past the never-use heading and
    so lands there: checking only the usable set would let the filter be
    removed with the control still green."""
    usable, never = sections_for(TAXONOMY + """
Prose naming `kendex` and `docs/architecture/` must not become labels.

| Label | Use when |
|-------|----------|
| `linear` | Filtered as prose, not a label. |
""")
    for name in ("kendex", "docs/architecture/", "linear"):
        assert_equal(name in usable, False, f"{name!r} is prose, not a usable label")
        assert_equal(name in never, False, f"{name!r} is prose, not a never-use label")


def main() -> int:
    test_a_label_name_may_begin_with_a_digit()
    test_the_leading_letter_pattern_is_what_hid_it()
    test_prose_backticks_are_not_labels()
    print("label taxonomy parser controls passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
