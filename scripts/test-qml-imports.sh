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
# from its path, so it is copied in beside the tree it must scan.
run_guard() {
  local name="$1"
  mkdir -p "$work/$name/scripts"
  cp "$guard" "$work/$name/scripts/check-qml-imports.py"
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

# --- must pass: a name an imported installed module also provides -----------
# Quickshell.Wayland ships an IdleInhibitor, and so does Modules/Bar/Widgets.
# Which one a file means is beyond a text scan, so an imported outside module
# that provides the name has to end the question -- this is the live case in
# BarWindow.qml, and getting it wrong would fail the build on correct code.
seed outside_module
mkdir -p "$work/outside_module/quickshell/vshell/Modules/Bar/Widgets"
printf 'import QtQuick\nItem {}\n' \
  > "$work/outside_module/quickshell/vshell/Modules/Bar/Widgets/IdleInhibitor.qml"
cat > "$work/outside_module/quickshell/vshell/Modules/Bar/BarWindow.qml" <<'QML'
import QtQuick
import Quickshell.Wayland

Item {
    IdleInhibitor {
        enabled: true
    }
}
QML
if run_guard outside_module >/dev/null; then
  ok "a name an imported installed module also provides is not reported"
else
  fail "a name an imported installed module also provides is not reported"
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
