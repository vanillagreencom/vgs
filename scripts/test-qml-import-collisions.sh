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
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/check-qml-imports.py"
status=0

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; status=1; }

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

run_guard() {
  local name="$1"
  mkdir -p "$work/$name/scripts" "$work/$name/tools"
  cp "$guard" "$work/$name/scripts/check-qml-imports.py"
  [[ -f "$work/$name/tools/qml-import-collisions.tsv" ]] \
    || printf '# file\ttype\tmodule\n' > "$work/$name/tools/qml-import-collisions.tsv"
  ( cd "$work/$name" && python3 scripts/check-qml-imports.py 2>&1 )
}

# --- must fail: an ALIASED outside import does not excuse a bare name --------
# `import Quickshell.Wayland as QW` puts the module behind `QW.`, so a bare
# `IdleInhibitor {}` in that file is still unresolved and the declaration must
# not excuse it.
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
if run_guard collision_aliased >/dev/null; then
  fail "an aliased outside import does not excuse a bare name"
else
  ok "an aliased outside import does not excuse a bare name"
fi

# --- must pass: the declared collision ---------------------------------------
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
# The same three sources the checker itself consults, so this case cannot skip
# on a machine where the checker would in fact have resolved the module.
if [[ -d /usr/lib/qt6/qml || -d /usr/lib/qml \
      || -n "${QML2_IMPORT_PATH:-}" || -n "${QML_IMPORT_PATH:-}" ]] \
   || command -v qtpaths6 >/dev/null 2>&1; then
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

if [[ "$status" == 0 ]]; then
  printf 'test-qml-import-collisions: all checks passed\n'
else
  printf 'test-qml-import-collisions: failures above\n' >&2
fi
exit "$status"
