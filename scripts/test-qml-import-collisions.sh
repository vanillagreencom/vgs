#!/usr/bin/env bash
# Controls for the DECLARED COLLISION LIST that scripts/check-qml-imports.py
# reads: tools/qml-import-collisions.tsv.
#
# A collision is a type name this tree defines as a file that an installed Qt
# or Quickshell module also provides -- BarWindow.qml's IdleInhibitor against
# Quickshell.Wayland is the live one. Which of the two a file means is beyond a
# text scan, so it is declared.
#
# That list is the guard's one escape hatch, which is exactly why it needs its
# own controls: a row must excuse only the single file and type it names, must
# be an error rather than a silent skip when it is malformed or points at
# nothing, and must fail where the module it claims can be read and does not
# provide that type. Its sibling scripts/test-qml-imports.sh covers the scan.
#
# Every refusal names its own diagnostic, so a case cannot pass on a guard that
# refused for an unrelated reason.
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

# A tree shaped like the repo, carrying the live collision: this tree's own
# IdleInhibitor bar pill, and a BarWindow that means Quickshell.Wayland's.
seed_collision() {
  local name="$1"
  rm -rf -- "${work:?}/$name"
  mkdir -p "$work/$name/quickshell/vshell/Modules/Bar/Widgets" \
           "$work/$name/config/vshell/plugins"
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

declare_collision() {
  local name="$1" file="$2" type="$3" module="$4"
  mkdir -p "$work/$name/tools"
  printf '# file\ttype\tmodule\n%s\t%s\t%s\n' "$file" "$type" "$module" \
    > "$work/$name/tools/qml-import-collisions.tsv"
}

# Runs the guard in a seeded tree, with any environment assignments the case needs.
run_guard() {
  local name="$1"
  shift
  mkdir -p "$work/$name/scripts" "$work/$name/tools"
  cp "$guard" "$work/$name/scripts/check-qml-imports.py"
  [[ -f "$work/$name/tools/qml-import-collisions.tsv" ]] \
    || printf '# file\ttype\tmodule\n' > "$work/$name/tools/qml-import-collisions.tsv"
  ( cd "$work/$name" && env "$@" python3 scripts/check-qml-imports.py 2>&1 )
}

expect_reported() { # label; tree; the fragment the report must carry
  local label="$1" tree="$2" fragment="$3" out
  if out="$(run_guard "$tree")"; then
    fail "$label: the guard passed a tree it must report"
  elif ! grep -q "$fragment" <<<"$out"; then
    fail "$label: the report does not say '$fragment':
$out"
  fi
}

# --- must fail: an ALIASED outside import does not excuse a bare name --------
# `import Quickshell.Wayland as QW` puts the module behind `QW.`, so a bare
# `IdleInhibitor {}` in that file is still unresolved and the declaration must
# not excuse it.
case_aliased_outside_import() {
  seed_collision collision_aliased
  declare_collision collision_aliased \
    quickshell/vshell/Modules/Bar/BarWindow.qml IdleInhibitor Quickshell.Wayland
  cat > "$work/collision_aliased/quickshell/vshell/Modules/Bar/BarWindow.qml" <<'QML'
import QtQuick
import Quickshell.Wayland as QW

Item {
    IdleInhibitor {
        enabled: true
    }
}
QML
  expect_reported "aliased outside import" collision_aliased IdleInhibitor
  ok "an aliased outside import does not excuse a bare name"
}

# --- must pass: the declared collision ---------------------------------------
case_declared_collision() {
  local out
  seed_collision collision_declared
  declare_collision collision_declared \
    quickshell/vshell/Modules/Bar/BarWindow.qml IdleInhibitor Quickshell.Wayland
  if ! out="$(run_guard collision_declared)"; then
    fail "declared collision: the guard reported a declared row:
$out"
  fi
  ok "a declared collision is honoured"
}

# Undeclared, the same tree is reported: the declaration is what excuses it,
# not the mere existence of an outside module.
case_undeclared_collision() {
  seed_collision collision_undeclared
  expect_reported "undeclared collision" collision_undeclared IdleInhibitor
  ok "an undeclared collision is still reported"
}

# --- must fail: a row naming a module that does not provide the type ---------
# The claim is checked against a fixture module tree this case installs, so the
# verdict does not depend on what the machine happens to have: the guard reads
# QML_IMPORT_PATH first, and takes the .qml stems a pure-QML module ships as the
# types it provides. QtQuick.Controls here provides Button and nothing else.
case_stale_declaration() {
  local qml_root="$work/collision_stale/qml"
  seed_collision collision_stale
  declare_collision collision_stale \
    quickshell/vshell/Modules/Bar/BarWindow.qml IdleInhibitor QtQuick.Controls
  mkdir -p "$qml_root/QtQuick/Controls"
  printf 'import QtQuick\nItem {}\n' > "$qml_root/QtQuick/Controls/Button.qml"
  local out
  if out="$(run_guard collision_stale \
    QML_IMPORT_PATH="$qml_root" QML2_IMPORT_PATH="$qml_root")"; then
    fail "stale declaration: the guard passed a row naming the wrong module"
  elif ! grep -q 'no longer provides' <<<"$out"; then
    fail "stale declaration: the report does not say the module no longer provides it:
$out"
  fi
  ok "a declaration naming the wrong module is reported"
}

# A row pointing at a file that does not exist would silently stop covering it.
case_ghost_row() {
  seed_collision collision_ghost
  declare_collision collision_ghost quickshell/vshell/Nope.qml IdleInhibitor Quickshell.Wayland
  expect_reported "ghost row" collision_ghost 'Nope.qml does not exist'
  ok "a row naming a file that does not exist is reported"
}

# A malformed row is an error, not a skipped line.
case_malformed_row() {
  seed_collision collision_malformed
  mkdir -p "$work/collision_malformed/tools"
  printf '# file\ttype\tmodule\nquickshell/vshell/Modules/Bar/BarWindow.qml IdleInhibitor\n' \
    > "$work/collision_malformed/tools/qml-import-collisions.tsv"
  expect_reported "malformed row" collision_malformed 'expected file<TAB>type<TAB>module'
  ok "a malformed row is an error rather than a skipped line"
}

CASES=(
  case_aliased_outside_import
  case_declared_collision
  case_undeclared_collision
  case_stale_declaration
  case_ghost_row
  case_malformed_row
)
for collisions_case in "${CASES[@]}"; do
  "$collisions_case"
done

if [[ $failures -ne 0 ]]; then
  printf 'test-qml-import-collisions: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'test-qml-import-collisions: all checks passed\n'
