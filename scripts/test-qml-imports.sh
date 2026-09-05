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
#
# The first case IS the defect this guard was written for: WidgetsTab.qml used
# SettingsChoiceRow without importing qs.Modules.Settings.Widgets, the whole
# Bar -> Widgets page failed to build, and every gate stayed green.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/check-qml-imports.py"
status=0

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; status=1; }

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

# --- must fail: the defect this guard exists for -----------------------------
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
if out="$(run_guard missing_import)"; then
  fail "a type used without an import that reaches it is reported"
elif ! grep -q 'SettingsChoiceRow' <<<"$out"; then
  fail "the report names the type that could not be reached"
else
  ok "a type used without an import that reaches it is reported"
fi

# --- must pass: the same file, with the import ------------------------------
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
if run_guard with_import >/dev/null; then
  ok "the import silences it"
else
  fail "the import silences it"
fi

# --- must fail: every position a type can appear in --------------------------
# One control, because the scan is now one rule: an uppercase name before `{`
# unless a `.` or a word character precedes it. These four forms were four
# separate misses while it was a list of allowed positions -- a property
# binding, a delegate binding, an inline list, and a child sharing its
# parent's line -- and each is ordinary QML that fails at runtime.
seed positions
cat > "$work/positions/quickshell/vshell/Widgets/Host.qml" <<'QML'
import QtQuick

Item {
    property Component page: SettingsChoiceRow { objectName: "binding" }

    ListView { delegate: SettingsChoiceRow { objectName: "delegate" } }

    children: [ SettingsChoiceRow {}, SettingsChoiceRow {} ]

    Item { SettingsChoiceRow { objectName: "inline child" } }
}
QML
if out="$(run_guard positions)"; then
  fail "a type is reported wherever it appears"
elif ! grep -q 'SettingsChoiceRow' <<<"$out"; then
  fail "the report names the type it could not reach"
else
  ok "a type is reported wherever it appears"
fi

# --- must fail: an aliased import does not make a bare name visible ----------
# `import qs.X as W` puts the module behind `W.`, so a bare name in that file
# is still unresolved. Treating the alias as plain visibility would let a real
# error through.
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
if run_guard aliased_import >/dev/null; then
  fail "an aliased import does not make a bare name visible"
else
  ok "an aliased import does not make a bare name visible"
fi

# --- must pass: type-looking text that is not code ---------------------------
# The scan reads text, so a name in a comment, a string or a template literal
# would otherwise fail a file whose code is correct.
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
if run_guard noise >/dev/null; then
  ok "a type name in a comment, a string or a template literal is not code"
else
  fail "a type name in a comment, a string or a template literal is not code"
fi

# --- must fail: real code below a comment naming the same type ---------------
# Blanking must not swallow what follows it, or the guard misses silently --
# the one failure it exists to prevent.
seed comment_then_code
cat > "$work/comment_then_code/quickshell/vshell/Widgets/Both.qml" <<'QML'
import QtQuick

Item {
    // Example: SettingsChoiceRow { }
    SettingsChoiceRow { objectName: "real" }
}
QML
if run_guard comment_then_code >/dev/null; then
  fail "real code below such a comment is still reported"
else
  ok "real code below such a comment is still reported"
fi

# --- must fail: a commented-out import does not grant visibility -------------
# Reading imports from the raw text was fail-open, and in the worst possible
# direction: commenting an import out is the single edit most likely to cause
# this error, and it was the edit that hid it.
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
if run_guard commented_import >/dev/null; then
  fail "a commented-out import does not grant visibility"
else
  ok "a commented-out import does not grant visibility"
fi

# --- must pass: a grouped property is not an instantiation -------------------
# `anchors.fill:` and `font { ... }` must not be read as types, or the scan
# would report a name for every styling block in the tree.
seed grouped_property
cat > "$work/grouped_property/quickshell/vshell/Widgets/Grouped.qml" <<'QML'
import QtQuick

Text {
    font {
        pixelSize: 12
    }

    Behavior on opacity {
        NumberAnimation {}
    }
}
QML
if run_guard grouped_property >/dev/null; then
  ok "a grouped property and an on-binding are not read as types"
else
  fail "a grouped property and an on-binding are not read as types"
fi

# --- must pass: a sibling in the same directory needs no import -------------
seed same_directory
cat > "$work/same_directory/quickshell/vshell/Widgets/VgsPanel.qml" <<'QML'
import QtQuick

Item {
    VgsButton {
        text: "Save"
    }
}
QML
if run_guard same_directory >/dev/null; then
  ok "a sibling in the same directory needs no import"
else
  fail "a sibling in the same directory needs no import"
fi

# --- must pass: a plugin reaching a public module it imports ----------------
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
if run_guard plugin_ok >/dev/null; then
  ok "a plugin reaching a public module it imports passes"
else
  fail "a plugin reaching a public module it imports passes"
fi

# --- must fail: the same plugin without that import -------------------------
seed plugin_missing
cat > "$work/plugin_missing/config/vshell/plugins/demo/DemoWidget.qml" <<'QML'
import QtQuick

Item {
    VgsButton {
        text: "Go"
    }
}
QML
if run_guard plugin_missing >/dev/null; then
  fail "a plugin missing that import is reported"
else
  ok "a plugin missing that import is reported"
fi

# --- must pass: an inline component is defined by the file that uses it -----
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
if run_guard inline_component >/dev/null; then
  ok "an inline component is not reported against the file declaring it"
else
  fail "an inline component is not reported against the file declaring it"
fi

# --- must pass: a Qt type this tree does not define is none of its business --
seed foreign_type
cat > "$work/foreign_type/quickshell/vshell/Widgets/Plain.qml" <<'QML'
import QtQuick

Item {
    Rectangle {
        color: "red"
    }
}
QML
if run_guard foreign_type >/dev/null; then
  ok "a type this tree does not define is left alone"
else
  fail "a type this tree does not define is left alone"
fi

# --- must fail: an empty tree is a broken scan, not a clean one -------------
rm -rf -- "${work:?}/empty"
mkdir -p "$work/empty/quickshell/vshell" "$work/empty/config/vshell/plugins"
if run_guard empty >/dev/null; then
  fail "a tree with no QML files fails rather than reporting success"
else
  ok "a tree with no QML files fails rather than reporting success"
fi

if [[ "$status" == 0 ]]; then
  printf 'test-qml-imports: all checks passed\n'
else
  printf 'test-qml-imports: failures above\n' >&2
fi
exit "$status"
