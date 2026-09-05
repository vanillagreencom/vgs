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

# --- must fail: a type inside an object binding ------------------------------
# `delegate: Missing {` and `property Component page: Missing {` are ordinary
# QML and fail at runtime exactly like a bare one. Anchoring the scan to the
# start of a line missed both.
seed binding_forms
cat > "$work/binding_forms/quickshell/vshell/Widgets/Host.qml" <<'QML'
import QtQuick

Item {
    property Component page: SettingsChoiceRow {
        objectName: "nested"
    }
}
QML
if out="$(run_guard binding_forms)"; then
  fail "a type in a property binding is reported"
elif ! grep -q 'SettingsChoiceRow' <<<"$out"; then
  fail "the property-binding report names the type"
else
  ok "a type in a property binding is reported"
fi

seed delegate_form
cat > "$work/delegate_form/quickshell/vshell/Widgets/Host.qml" <<'QML'
import QtQuick

ListView {
    delegate: SettingsChoiceRow {
        objectName: "row"
    }
}
QML
if run_guard delegate_form >/dev/null; then
  fail "a type in a delegate binding is reported"
else
  ok "a type in a delegate binding is reported"
fi

# --- must fail: a type inside a list binding, written on one line ------------
# `children: [ A {}, B {} ]`. The first element of a multi-line list already
# starts its own line; an inline list gives the scan neither a line start nor
# a colon before the name, and both elements went unseen.
seed list_binding
cat > "$work/list_binding/quickshell/vshell/Widgets/ListHost.qml" <<'QML'
import QtQuick

Item {
    children: [ SettingsChoiceRow {}, SettingsChoiceRow {} ]
}
QML
if run_guard list_binding >/dev/null; then
  fail "a type in an inline list binding is reported"
else
  ok "a type in an inline list binding is reported"
fi

# --- must fail: a child object on the same line as its parent's brace --------
seed inline_child
cat > "$work/inline_child/quickshell/vshell/Widgets/Inline.qml" <<'QML'
import QtQuick

Item { SettingsChoiceRow {} }
QML
if run_guard inline_child >/dev/null; then
  fail "a child object after an opening brace is reported"
else
  ok "a child object after an opening brace is reported"
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

# --- must pass: the qualified form the alias does provide -------------------
seed aliased_qualified
cat > "$work/aliased_qualified/quickshell/vshell/Widgets/Aliased.qml" <<'QML'
import QtQuick
import qs.Modules.Settings.Widgets as W

Item {
    W.SettingsChoiceRow {
        objectName: "qualified"
    }
}
QML
if run_guard aliased_qualified >/dev/null; then
  ok "the qualified form an alias provides is not reported"
else
  fail "the qualified form an alias provides is not reported"
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
