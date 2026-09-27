#!/usr/bin/env bash
# Controls for the SCAN in scripts/check-qml-imports.py: which QML forms it
# recognises as instantiating a type, and which it correctly leaves alone.
# Its sibling scripts/test-qml-import-collisions.sh covers the other half,
# the declared-collision list that excuses a name two modules both provide.
#
# A guard that only ever passes proves nothing, and this one is a text scan
# over a directory layout: it is exactly the kind of check that can be quietly
# narrowed into uselessness. So each case below builds a small QML tree, points
# the guard at it, and asserts on the verdict -- the must-fail cases first,
# because a scan that reports nothing would sail through the must-pass ones.
# Every refusal also names the type it could not reach: an empty tree and a
# crash both exit 1, so a status alone cannot say the scan found the defect.
#
# The first case IS the defect this guard was written for: WidgetsTab.qml used
# SettingsChoiceRow without importing qs.Modules.Settings.Widgets, the whole
# Bar -> Widgets page failed to build, and every gate stayed green.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/check-qml-imports.py"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

failures=0
case_failed=0
fail() {
  printf '  FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
  case_failed=1
}
ok() {
  if [[ $case_failed -eq 0 ]]; then
    printf '  ok    %s\n' "$1"
  fi
  case_failed=0
}

# Builds a tree under $work/<case> shaped like the repo: a quickshell/vshell
# root and a config/vshell/plugins root, which is what the guard scans.
seed() {
  local name="$1"
  rm -rf -- "${work:?}/$name"
  mkdir -p "$work/$name/quickshell/vshell/Widgets" \
           "$work/$name/quickshell/vshell/Modules/Settings/Widgets" \
           "$work/$name/config/vshell/plugins/demo"
  printf 'import QtQuick\nItem {}\n' \
    > "$work/$name/quickshell/vshell/Modules/Settings/Widgets/SettingsChoiceRow.qml"
  printf 'import QtQuick\nItem {}\n' \
    > "$work/$name/quickshell/vshell/Widgets/VgsButton.qml"
}

# Runs the guard against a seeded tree. The guard resolves its own repo root
# from its path, so it is copied in beside the tree it must scan, along with an
# empty collision list -- each case that needs a row writes its own.
run_guard() {
  local name="$1"
  mkdir -p "$work/$name/scripts" "$work/$name/tools"
  cp "$guard" "$work/$name/scripts/check-qml-imports.py"
  [[ -f "$work/$name/tools/qml-import-collisions.tsv" ]] \
    || printf '# file\ttype\tmodule\n' > "$work/$name/tools/qml-import-collisions.tsv"
  ( cd "$work/$name" && python3 scripts/check-qml-imports.py 2>&1 )
}

expect_reported() { # label; tree; the type the report must name
  local label="$1" tree="$2" type="$3" out
  if out="$(run_guard "$tree")"; then
    fail "$label: the guard passed a tree it must report"
  elif ! grep -q "$type" <<<"$out"; then
    fail "$label: the report does not name $type:
$out"
  fi
}

expect_clean() { # label; tree
  local label="$1" tree="$2" out
  if ! out="$(run_guard "$tree")"; then
    fail "$label: the guard reported a tree that is correct:
$out"
  fi
}

# --- must fail: the defect this guard exists for -----------------------------
case_missing_import() {
  seed missing_import
  cat > "$work/missing_import/quickshell/vshell/Modules/Settings/WidgetsTab.qml" <<'QML'
import QtQuick
import qs.Common

Item {
    SettingsChoiceRow {
        text: "Bar"
    }
}
QML
  expect_reported "missing import" missing_import SettingsChoiceRow
  ok "a type used without an import that reaches it is reported"
}

# --- must pass: the same file, with the import ------------------------------
case_with_import() {
  seed with_import
  cat > "$work/with_import/quickshell/vshell/Modules/Settings/WidgetsTab.qml" <<'QML'
import QtQuick
import qs.Common
import qs.Modules.Settings.Widgets

Item {
    SettingsChoiceRow {
        text: "Bar"
    }
}
QML
  expect_clean "with import" with_import
  ok "the import silences it"
}

# --- must fail: each position a type can appear in ---------------------------
# One row per position, not one fixture holding all four: a single fixture
# passes as soon as the guard catches ANY of them, so a regression to a
# position-limited scanner could miss two and still look green.
#
# These were four separate misses while the scanner was a list of allowed
# positions. Each is ordinary QML that fails at runtime.
POSITIONS='binding;    property Component page: SettingsChoiceRow { objectName: "x" }
delegate;    ListView { delegate: SettingsChoiceRow { objectName: "x" } }
list;    children: [ SettingsChoiceRow {}, SettingsChoiceRow {} ]
child;    Item { SettingsChoiceRow { objectName: "x" } }'

case_positions() {
  local form body rows=0
  while IFS=';' read -r form body; do
    [[ -n "$form" ]] || continue
    rows=$((rows + 1))
    seed "position_$form"
    printf 'import QtQuick\n\nItem {\n%s\n}\n' "$body" \
      > "$work/position_$form/quickshell/vshell/Widgets/Host.qml"
    expect_reported "a type in a $form position" "position_$form" SettingsChoiceRow
  done <<<"$POSITIONS"
  [[ $rows -eq 4 ]] || fail "positions: expected 4 table rows, drove $rows"
  ok "a type is reported in a binding, a delegate, a list and a child position"
}

# --- must fail: an aliased import does not make a bare name visible ----------
# `import qs.X as W` puts the module behind `W.`, so a bare name in that file
# is still unresolved. Treating the alias as plain visibility would let a real
# error through.
case_aliased_import() {
  seed aliased_import
  cat > "$work/aliased_import/quickshell/vshell/Widgets/Aliased.qml" <<'QML'
import QtQuick
import qs.Modules.Settings.Widgets as W

Item {
    SettingsChoiceRow {
        objectName: "bare"
    }
}
QML
  expect_reported "aliased import" aliased_import SettingsChoiceRow
  ok "an aliased import does not make a bare name visible"
}

# --- must pass: type-looking text that is not code ---------------------------
# The scan reads text, so a name in a comment, a string or a template literal
# would otherwise fail a file whose code is correct.
case_noise() {
  seed noise
  cat > "$work/noise/quickshell/vshell/Widgets/Commented.qml" <<'QML'
import QtQuick

Item {
    // Example: SettingsChoiceRow { text: "x" }
    /* also SettingsChoiceRow { } in a block comment */
    property string hint: "write SettingsChoiceRow { } here"

    function describe(name) {
        return `or SettingsChoiceRow { text: ${name} }`;
    }
}
QML
  expect_clean noise noise
  ok "a type name in a comment, a string or a template literal is not code"
}

# --- must fail: real code below a comment naming the same type ---------------
# Blanking must not swallow what follows it, or the guard misses silently --
# the one failure it exists to prevent.
case_comment_then_code() {
  seed comment_then_code
  cat > "$work/comment_then_code/quickshell/vshell/Widgets/Both.qml" <<'QML'
import QtQuick

Item {
    // Example: SettingsChoiceRow { }
    SettingsChoiceRow { objectName: "real" }
}
QML
  expect_reported "comment then code" comment_then_code SettingsChoiceRow
  ok "real code below such a comment is still reported"
}

# --- must fail: a commented-out import does not grant visibility -------------
# Reading imports from the raw text was fail-open, and in the worst possible
# direction: commenting an import out is the single edit most likely to cause
# this error, and it was the edit that hid it.
case_commented_import() {
  seed commented_import
  cat > "$work/commented_import/quickshell/vshell/Modules/Settings/WidgetsTab.qml" <<'QML'
import QtQuick
// import qs.Modules.Settings.Widgets

Item {
    SettingsChoiceRow {
        text: "Bar"
    }
}
QML
  expect_reported "commented-out import" commented_import SettingsChoiceRow
  ok "a commented-out import does not grant visibility"
}

# --- must pass: a name a dot precedes is not an instantiation ----------------
# `font { }` is a grouped property, `Behavior on x { }` an on-binding, and
# `W.SettingsChoiceRow { }` the qualified form an aliased import provides.
# Reading any of them as a type would report a name for every styling block in
# the tree.
case_grouped_property() {
  seed grouped_property
  cat > "$work/grouped_property/quickshell/vshell/Widgets/Grouped.qml" <<'QML'
import QtQuick
import qs.Modules.Settings.Widgets as W

Text {
    font {
        pixelSize: 12
    }

    Behavior on opacity {
        NumberAnimation {}
    }

    W.SettingsChoiceRow {
        objectName: "qualified"
    }
}
QML
  expect_clean "grouped property" grouped_property
  ok "a dot before a name keeps it from being read as a type"
}

# --- must pass: a sibling in the same directory needs no import -------------
case_same_directory() {
  seed same_directory
  cat > "$work/same_directory/quickshell/vshell/Widgets/VgsPanel.qml" <<'QML'
import QtQuick

Item {
    VgsButton {
        text: "Save"
    }
}
QML
  expect_clean "same directory" same_directory
  ok "a sibling in the same directory needs no import"
}

# --- must pass: a plugin reaching a public module it imports ----------------
case_plugin_ok() {
  seed plugin_ok
  cat > "$work/plugin_ok/config/vshell/plugins/demo/DemoWidget.qml" <<'QML'
import QtQuick
import qs.Widgets

Item {
    VgsButton {
        text: "Go"
    }
}
QML
  expect_clean "plugin with the import" plugin_ok
  ok "a plugin reaching a public module it imports passes"
}

# --- must fail: the same plugin without that import -------------------------
case_plugin_missing() {
  seed plugin_missing
  cat > "$work/plugin_missing/config/vshell/plugins/demo/DemoWidget.qml" <<'QML'
import QtQuick

Item {
    VgsButton {
        text: "Go"
    }
}
QML
  expect_reported "plugin without the import" plugin_missing VgsButton
  ok "a plugin missing that import is reported"
}

# --- must pass: an inline component is defined by the file that uses it -----
case_inline_component() {
  seed inline_component
  cat > "$work/inline_component/quickshell/vshell/Modules/Settings/InlineHost.qml" <<'QML'
import QtQuick

Item {
    component SettingsChoiceRow: Item {}

    SettingsChoiceRow {
        objectName: "inline"
    }
}
QML
  expect_clean "inline component" inline_component
  ok "an inline component is not reported against the file declaring it"
}

# --- must pass: a Qt type this tree does not define is none of its business --
case_foreign_type() {
  seed foreign_type
  cat > "$work/foreign_type/quickshell/vshell/Widgets/Plain.qml" <<'QML'
import QtQuick

Item {
    Rectangle {
        color: "red"
    }
}
QML
  expect_clean "foreign type" foreign_type
  ok "a type this tree does not define is left alone"
}

# --- must fail: an empty tree is a broken scan, not a clean one -------------
case_empty_tree() {
  local out
  rm -rf -- "${work:?}/empty"
  mkdir -p "$work/empty/quickshell/vshell" "$work/empty/config/vshell/plugins"
  if out="$(run_guard empty)"; then
    fail "empty tree: the guard passed a tree it scanned nothing in"
  elif ! grep -q 'no QML files found' <<<"$out"; then
    fail "empty tree: the guard failed for another reason:
$out"
  fi
  ok "a tree with no QML files fails rather than reporting success"
}

CASES=(
  case_missing_import
  case_with_import
  case_positions
  case_aliased_import
  case_noise
  case_comment_then_code
  case_commented_import
  case_grouped_property
  case_same_directory
  case_plugin_ok
  case_plugin_missing
  case_inline_component
  case_foreign_type
  case_empty_tree
)
for imports_case in "${CASES[@]}"; do
  "$imports_case"
done

if [[ $failures -ne 0 ]]; then
  printf 'test-qml-imports: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'test-qml-imports: all checks passed\n'
