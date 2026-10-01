#!/usr/bin/env bash
# Run the QML unit tests: every scripts/qml-tests/tst_*.qml under
# qmltestrunner on the offscreen platform, against the shipped qs.Ui and
# qs.Commons files. The tests need Qt and no Wayland session.
#
# Usage: scripts/qml-unit.sh [--ui DIR] [--commons DIR] [--core DIR] [--tests DIR] [TEST...]
#   --ui DIR       the qs.Ui module to test (default: shell/Ui); the control
#                  points it at a mutated copy
#   --commons DIR  the qs.Commons files (default: shell/Commons)
#   --core DIR     the qs.Core files (default: shell/Core)
#   --tests DIR    the test directory (default: scripts/qml-tests)
#   TEST           one or more test files to run instead of the directory
#
# The import root is built in a temporary directory: qs/Ui links to the
# module under test; qs/Commons holds the shipped Theme.qml, Tokens.js,
# ThemeLogic.js, Inset.js, SessionLockState.js and WatchedFile.qml, under a
# qmldir of their own, beside a stand-in ThemeSource that takes
# a document from the UnitTheme singleton of the qs.Unit module and calls the
# shipped accept; a stand-in Quickshell module supplies the Singleton and
# Scope types and a PopupWindow that positions nothing, and a stand-in
# Quickshell.Io a FileView the test finishes by hand, since the real
# modules' plugins do not load outside the shell. Nothing under the
# repository is written.
#
# A test file fails on any warning or error it logs, console.warn and
# console.error included, unless a declaration in that file expects it:
#   // expected-log: <message> -- <reason>
# in the comment block directly above `function <name>(`. It covers the
# lines qmltestrunner attributes to that function (`::<name>(`) whose
# message holds <message> as a literal substring: a log line holds
# absolute file:// paths and quotes, and a literal needs no escaping.
# Several may stack above one function. A declaration that matches no line
# of its function in the run fails the file as stale:
#   qml-unit: unexpected-log file=<name> line=<log line>
#   qml-unit: expected-log unmatched file=<name> line=<n> message=<message>
# A declaration with no reason, or with no function under its block, is
# refused (exit 2). A warning or error logged outside a test function, at
# load or at teardown, has no declaration and always fails. QtTest drops
# those from its log, so the run forces Qt's own handler to stderr and
# marks their level with QT_MESSAGE_PATTERN, which also adds `warning: ` or
# `critical: ` to the message of an attributed line. Debug and info lines
# are not judged, and no declaration excuses a script error.
#
# QML_UNIT_RUNNER names the qmltestrunner binary; unset, the one on PATH
# or under /usr/lib/qt6/bin is used. Exit 0 when every test passed, 1 when
# one failed, logged an unexpected line or could not load, 2 on a refusal,
# 77 when no runner was found:
#   qml-unit: status=not-measured missing=qmltestrunner
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
ui="$repo/shell/Ui"
commons="$repo/shell/Commons"
core="$repo/shell/Core"
tests="$repo/scripts/qml-tests"
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ui) ui="$(readlink -f -- "$2")"; shift 2 ;;
    --commons) commons="$(readlink -f -- "$2")"; shift 2 ;;
    --core) core="$(readlink -f -- "$2")"; shift 2 ;;
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
mkdir -p "$imports/qs/Commons" "$imports/qs/Core" "$imports/qs/Unit" "$imports/Quickshell/Io" "$imports/Qt/labs/folderlistmodel" "$root/home" "$root/runtime"
chmod 700 "$root/runtime"
ln -s -- "$ui" "$imports/qs/Ui"
# Theme.qml resolves the bundled font relative to its own directory.
ln -s -- "$repo/shell/assets" "$imports/qs/assets"
# The list is the part of qs.Commons these modules host: the module's own
# qmldir names Paths, Time and Workspaces too, whose Quickshell types do
# not load outside the shell, and a type a linked file names is resolved
# when that file compiles.
for file in Theme.qml Tokens.js ThemeLogic.js Inset.js SettingValues.js SessionLockState.js ClearingInset.qml WatchedFile.qml; do
  [[ -f $commons/$file ]] || { printf 'qml-unit: refused: missing=%s\n' "$commons/$file" >&2; exit 2; }
  ln -s -- "$commons/$file" "$imports/qs/Commons/$file"
done
cp -- "$tests/stand-ins/ThemeSource.qml" "$imports/qs/Commons/ThemeSource.qml"
printf 'module qs.Commons\nsingleton Theme 1.0 Theme.qml\ninternal ThemeSource ThemeSource.qml\nInset 1.0 Inset.js\nSettingValues 1.0 SettingValues.js\nSessionLockState 1.0 SessionLockState.js\nClearingInset 1.0 ClearingInset.qml\nWatchedFile 1.0 WatchedFile.qml\n' >"$imports/qs/Commons/qmldir"
for file in TuiRecords.qml SessionLock.qml ShortcutRegistry.qml PluginLogic.js PackageManagers.js HyprlandLayer.js; do
  [[ -f $core/$file ]] || { printf 'qml-unit: refused: missing=%s\n' "$core/$file" >&2; exit 2; }
  ln -s -- "$core/$file" "$imports/qs/Core/$file"
done
cp -- "$tests/stand-ins/ShortcutRegistryInputs.qml" "$imports/qs/Core/Registry.qml"
cp -- "$tests/stand-ins/ShortcutCapabilities.qml" "$imports/qs/Core/Capabilities.qml"
printf 'module qs.Core\nTuiRecords 1.0 TuiRecords.qml\nSessionLock 1.0 SessionLock.qml\nShortcutRegistry 1.0 ShortcutRegistry.qml\nsingleton Registry 1.0 Registry.qml\nsingleton Capabilities 1.0 Capabilities.qml\nPluginLogic 1.0 PluginLogic.js\nPackageManagers 1.0 PackageManagers.js\nHyprlandLayer 1.0 HyprlandLayer.js\n' >"$imports/qs/Core/qmldir"
cp -- "$tests/stand-ins/UnitTheme.qml" "$imports/qs/Unit/UnitTheme.qml"
# Where the module under test is, for the test that reads its qmldir.
printf '.pragma library\nvar UI_DIR = %s;\n' "$(python3 -c 'import json, sys; print(json.dumps("file://" + sys.argv[1]))' "$ui")" >"$imports/qs/Unit/UnitPaths.js"
printf 'module qs.Unit\nsingleton UnitTheme 1.0 UnitTheme.qml\nUnitPaths 1.0 UnitPaths.js\n' >"$imports/qs/Unit/qmldir"
for file in Singleton.qml Scope.qml PopupWindow.qml Edges.qml PopupAdjustment.qml; do
  cp -- "$tests/stand-ins/$file" "$imports/Quickshell/$file"
done
printf 'module Quickshell\nSingleton 1.0 Singleton.qml\nScope 1.0 Scope.qml\nPopupWindow 1.0 PopupWindow.qml\nEdges 1.0 Edges.qml\nPopupAdjustment 1.0 PopupAdjustment.qml\n' >"$imports/Quickshell/qmldir"
mkdir -p -- "$imports/Quickshell/Hyprland"
cp -- "$tests/stand-ins/GlobalShortcut.qml" "$imports/Quickshell/Hyprland/GlobalShortcut.qml"
printf 'module Quickshell.Hyprland\nGlobalShortcut 1.0 GlobalShortcut.qml\n' >"$imports/Quickshell/Hyprland/qmldir"
for file in FileView.qml Process.qml StdioCollector.qml ProcessRegistry.qml FileViewError.qml; do
  cp -- "$tests/stand-ins/$file" "$imports/Quickshell/Io/$file"
done
cp -- "$tests/stand-ins/FolderListModel.qml" "$tests/stand-ins/FolderListRegistry.qml" "$imports/Qt/labs/folderlistmodel/"
printf 'module Quickshell.Io\nFileView 1.0 FileView.qml\nProcess 1.0 Process.qml\nStdioCollector 1.0 StdioCollector.qml\nsingleton ProcessRegistry 1.0 ProcessRegistry.qml\nsingleton FileViewError 1.0 FileViewError.qml\n' >"$imports/Quickshell/Io/qmldir"
printf 'module Qt.labs.folderlistmodel\nFolderListModel 1.0 FolderListModel.qml\nsingleton FolderListRegistry 1.0 FolderListRegistry.qml\n' >"$imports/Qt/labs/folderlistmodel/qmldir"

if [[ ${#files[@]} -eq 0 ]]; then
  mapfile -t files < <(find "$tests" -maxdepth 1 -name 'tst_*.qml' | sort)
fi
if [[ ${#files[@]} -eq 0 ]]; then
  printf 'qml-unit: refused: tests=none dir=%s\n' "$tests" >&2
  exit 2
fi

# Judge one file's logged lines against its declarations, as the header
# states. Exit 0 when every line is expected and every declaration matched,
# 1 on a finding, 2 on a refused declaration.
judge_log() { # TEST_FILE OUTPUT_FILE
  python3 - "$1" "$2" <<'PY'
import os, re, sys

test_path, out_path = sys.argv[1], sys.argv[2]
name = os.path.basename(test_path)
DECLARATION = re.compile(r"^\s*//\s*expected-log:(.*)$")
FUNCTION = re.compile(r"^\s*function\s+(\w+)\s*\(")
ATTRIBUTED = re.compile(r"^(?:QWARN  |QCRITICAL): [^( ]*::(\w+)\([^)]*\) (.*)$")
LOGGED = re.compile(r"^(?:QWARN  |QCRITICAL): ")
OUTSIDE = re.compile(r"^(?:warning|critical): ")

lines = open(test_path, encoding="utf-8").read().splitlines()
declarations = []
for index, text in enumerate(lines):
    found = DECLARATION.match(text)
    if not found:
        continue
    message, separator, reason = found.group(1).rpartition(" -- ")
    message, reason = message.strip(), reason.strip()
    if not separator or not message or not reason:
        print(f"qml-unit: refused: expected-log=no-reason file={name} line={index + 1}")
        print("  the declaration reads `// expected-log: <message> -- <reason>`")
        sys.exit(2)
    below = index + 1
    while below < len(lines) and lines[below].lstrip().startswith("//"):
        below += 1
    function = FUNCTION.match(lines[below]) if below < len(lines) else None
    if not function:
        print(f"qml-unit: refused: expected-log=no-function file={name} line={index + 1}")
        print("  the comment block holding the declaration sits directly above a function")
        sys.exit(2)
    declarations.append({"line": index + 1, "message": message, "function": function.group(1), "hits": 0})

status = 0
for line in open(out_path, encoding="utf-8", errors="replace").read().splitlines():
    if not (LOGGED.match(line) or OUTSIDE.match(line)):
        continue
    attributed = ATTRIBUTED.match(line)
    covering = [d for d in declarations if attributed and d["function"] == attributed.group(1) and d["message"] in attributed.group(2)]
    for declaration in covering:
        declaration["hits"] += 1
    if not covering:
        print(f"qml-unit: unexpected-log file={name} line={line}")
        status = 1
for declaration in declarations:
    if declaration["hits"] == 0:
        print(f"qml-unit: expected-log unmatched file={name} line={declaration['line']} message={declaration['message']}")
        status = 1
sys.exit(status)
PY
}

# Every test file runs in its own process, so a file that fails to load
# names itself, and one file's singleton state never reaches another.
status=0
for file in "${files[@]}"; do
  echo "== $(basename -- "$file")"
  file_status=0
  out="$(env -i HOME="$root/home" PATH="/usr/bin:/usr/lib/qt6/bin" LC_ALL=C.UTF-8 \
    QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR="$root/runtime" QML_XHR_ALLOW_FILE_READ=1 \
    QT_FORCE_STDERR_LOGGING=1 QT_MESSAGE_PATTERN='%{if-warning}warning: %{endif}%{if-critical}critical: %{endif}%{if-category}%{category}: %{endif}%{message}' \
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
  printf '%s\n' "$out" >"$root/out"
  judged=0
  judge_log "$file" "$root/out" || judged=$?
  case $judged in
    0) ;;
    1) file_status=1 ;;
    *) exit 2 ;;
  esac
  if [[ $file_status -ne 0 ]]; then
    status=1
    echo "qml-unit: failed file=$(basename -- "$file") status=$file_status"
  fi
done
[[ $status -eq 0 ]] && echo "qml-unit: ok files=${#files[@]}"
exit "$status"
