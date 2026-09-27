#!/usr/bin/env bash
# Run the QML unit tests: every scripts/qml-tests/tst_*.qml under
# qmltestrunner on the offscreen platform, against the shipped qs.Ui and
# qs.Commons files. The tests need Qt and no Wayland session.
#
# Usage: scripts/qml-unit.sh [--ui DIR] [--commons DIR] [--tests DIR] [TEST...]
#   --ui DIR       the qs.Ui module to test (default: shell/Ui); the control
#                  points it at a mutated copy
#   --commons DIR  the qs.Commons files (default: shell/Commons)
#   --tests DIR    the test directory (default: scripts/qml-tests)
#   TEST           one or more test files to run instead of the directory
#
# The import root is built in a temporary directory: qs/Ui links to the
# module under test; qs/Commons holds the shipped Theme.qml, Tokens.js and
# ThemeLogic.js beside a stand-in ThemeSource that takes a document from the
# UnitTheme singleton of the qs.Unit module and calls the shipped accept; a
# stand-in Quickshell module supplies the Singleton type and a PopupWindow
# that positions nothing, since the real module's plugin does not load
# outside the shell. Nothing under the repository is written.
#
# QML_UNIT_RUNNER names the qmltestrunner binary; unset, the one on PATH
# or under /usr/lib/qt6/bin is used. Exit 0 when every test passed, 1 when
# one failed or a test file could not load, 77 when no runner was found:
#   qml-unit: status=not-measured missing=qmltestrunner
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
ui="$repo/shell/Ui"
commons="$repo/shell/Commons"
tests="$repo/scripts/qml-tests"
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ui) ui="$(readlink -f -- "$2")"; shift 2 ;;
    --commons) commons="$(readlink -f -- "$2")"; shift 2 ;;
    --tests) tests="$(readlink -f -- "$2")"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    -*) printf 'qml-unit: refused: argument=%s\n' "$1" >&2; exit 2 ;;
    *) files+=("$(readlink -f -- "$1")"); shift ;;
  esac
done

runner="${QML_UNIT_RUNNER:-}"
if [[ -z $runner ]]; then
  if ! runner="$(command -v qmltestrunner)"; then
    runner=/usr/lib/qt6/bin/qmltestrunner
  fi
fi
if [[ -z $runner || ! -x $runner ]]; then
  echo "qml-unit: status=not-measured missing=qmltestrunner"
  exit 77
fi

root="$(mktemp -d)"
trap 'rm -rf -- "${root:?}"' EXIT
imports="$root/imports"
mkdir -p "$imports/qs/Commons" "$imports/qs/Unit" "$imports/Quickshell" "$root/home" "$root/runtime"
chmod 700 "$root/runtime"
ln -s -- "$ui" "$imports/qs/Ui"
# Theme.qml resolves the bundled font relative to its own directory.
ln -s -- "$repo/shell/assets" "$imports/qs/assets"
for file in Theme.qml Tokens.js ThemeLogic.js; do
  [[ -f $commons/$file ]] || { printf 'qml-unit: refused: missing=%s\n' "$commons/$file" >&2; exit 2; }
  ln -s -- "$commons/$file" "$imports/qs/Commons/$file"
done
cp -- "$tests/stand-ins/ThemeSource.qml" "$imports/qs/Commons/ThemeSource.qml"
printf 'module qs.Commons\nsingleton Theme 1.0 Theme.qml\ninternal ThemeSource ThemeSource.qml\n' >"$imports/qs/Commons/qmldir"
cp -- "$tests/stand-ins/UnitTheme.qml" "$imports/qs/Unit/UnitTheme.qml"
# Where the module under test is, for the test that reads its qmldir.
printf '.pragma library\nvar UI_DIR = %s;\n' "$(python3 -c 'import json, sys; print(json.dumps("file://" + sys.argv[1]))' "$ui")" >"$imports/qs/Unit/UnitPaths.js"
printf 'module qs.Unit\nsingleton UnitTheme 1.0 UnitTheme.qml\nUnitPaths 1.0 UnitPaths.js\n' >"$imports/qs/Unit/qmldir"
for file in Singleton.qml PopupWindow.qml Edges.qml PopupAdjustment.qml; do
  cp -- "$tests/stand-ins/$file" "$imports/Quickshell/$file"
done
printf 'module Quickshell\nSingleton 1.0 Singleton.qml\nPopupWindow 1.0 PopupWindow.qml\nEdges 1.0 Edges.qml\nPopupAdjustment 1.0 PopupAdjustment.qml\n' >"$imports/Quickshell/qmldir"

if [[ ${#files[@]} -eq 0 ]]; then
  mapfile -t files < <(find "$tests" -maxdepth 1 -name 'tst_*.qml' | sort)
fi
if [[ ${#files[@]} -eq 0 ]]; then
  printf 'qml-unit: refused: tests=none dir=%s\n' "$tests" >&2
  exit 2
fi

# Every test file runs in its own process, so a file that fails to load
# names itself, and one file's singleton state never reaches another.
status=0
for file in "${files[@]}"; do
  echo "== $(basename -- "$file")"
  file_status=0
  out="$(env -i HOME="$root/home" PATH="/usr/bin:/usr/lib/qt6/bin" LC_ALL=C.UTF-8 \
    QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR="$root/runtime" QML_XHR_ALLOW_FILE_READ=1 \
    "$runner" -import "$imports" -input "$file" 2>&1)" || file_status=$?
  # grep exits 1 when every line was filtered, which is the quiet pass.
  filtered=0
  grep -vE '^Totals: [0-9]+ passed, 0 failed|^\*{9} (Start|Finished) testing|^Config: Using QtTest|^PASS   :' <<<"$out" || filtered=$?
  if [[ $filtered -gt 1 ]]; then
    echo "qml-unit: refused: output-filter=$filtered file=$(basename -- "$file")"
    exit 2
  fi
  # A binding that assigned nothing or a script that threw is a defect the
  # assertions may not reach.
  if grep -qE 'Unable to assign|TypeError|ReferenceError|is not a function|Cannot read property' <<<"$out"; then
    echo "qml-unit: warnings file=$(basename -- "$file")"
    file_status=1
  fi
  if [[ $file_status -ne 0 ]]; then
    status=1
    echo "qml-unit: failed file=$(basename -- "$file") status=$file_status"
  fi
done
[[ $status -eq 0 ]] && echo "qml-unit: ok files=${#files[@]}"
exit "$status"
