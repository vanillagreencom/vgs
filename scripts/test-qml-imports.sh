#!/usr/bin/env bash
# Controls for scripts/check-qml-imports.py.
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

# Writes a collision row for a case before it runs.
declare_collision() {
  local name="$1" file="$2" type="$3" module="$4"
  mkdir -p "$work/$name/tools"
  printf '# file\ttype\tmodule\n%s\t%s\t%s\n' "$file" "$type" "$module" \
    > "$work/$name/tools/qml-import-collisions.tsv"
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

# --- collisions: declared, undeclared, and mis-declared ---------------------
# Quickshell.Wayland ships an IdleInhibitor, and so does Modules/Bar/Widgets.
# Which one a file means is beyond a text scan, so it is declared -- this is
# the live case in BarWindow.qml, and getting it wrong fails correct code.
seed_collision() {
  local name="$1"
  seed "$name"
  mkdir -p "$work/$name/quickshell/vshell/Modules/Bar/Widgets"
  printf 'import QtQuick\nItem {}\n' \
    > "$work/$name/quickshell/vshell/Modules/Bar/Widgets/IdleInhibitor.qml"
  cat > "$work/$name/quickshell/vshell/Modules/Bar/BarWindow.qml" <<'QML'
import QtQuick
import Quickshell.Wayland

Item {
    IdleInhibitor {
        enabled: true
    }
}
QML
}

seed_collision collision_declared
declare_collision collision_declared \
  quickshell/vshell/Modules/Bar/BarWindow.qml IdleInhibitor Quickshell.Wayland
if run_guard collision_declared >/dev/null; then
  ok "a declared collision is honoured"
else
  fail "a declared collision is honoured"
fi

# Undeclared, the same tree is reported: the declaration is what excuses it,
# not the mere existence of an outside module.
seed_collision collision_undeclared
if run_guard collision_undeclared >/dev/null; then
  fail "an undeclared collision is still reported"
else
  ok "an undeclared collision is still reported"
fi

# A row naming a module that does not provide the type is a stale claim, and
# only fails where a module tree is installed to check it against.
if [[ -d /usr/lib/qt6/qml || -n "${QML2_IMPORT_PATH:-}" ]]; then
  seed_collision collision_stale
  declare_collision collision_stale \
    quickshell/vshell/Modules/Bar/BarWindow.qml IdleInhibitor QtQuick.Controls
  if out="$(run_guard collision_stale)"; then
    fail "a declaration naming the wrong module is reported"
  elif ! grep -q 'no longer provides' <<<"$out"; then
    fail "the stale-declaration report says what is wrong"
  else
    ok "a declaration naming the wrong module is reported"
  fi
else
  printf '  skip  stale-declaration case (no QML module tree to verify against)\n'
fi

# A row pointing at a file that does not exist would silently stop covering it.
seed_collision collision_ghost
declare_collision collision_ghost quickshell/vshell/Nope.qml IdleInhibitor Quickshell.Wayland
if run_guard collision_ghost >/dev/null; then
  fail "a row naming a file that does not exist is reported"
else
  ok "a row naming a file that does not exist is reported"
fi

# A malformed row is an error, not a skipped line.
seed_collision collision_malformed
mkdir -p "$work/collision_malformed/tools"
printf '# file\ttype\tmodule\nquickshell/vshell/Modules/Bar/BarWindow.qml IdleInhibitor\n' \
  > "$work/collision_malformed/tools/qml-import-collisions.tsv"
if run_guard collision_malformed >/dev/null; then
  fail "a malformed row is an error rather than a skipped line"
else
  ok "a malformed row is an error rather than a skipped line"
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
