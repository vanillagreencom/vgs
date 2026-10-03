#!/usr/bin/env bash
# The vgs.notifications `open` floating TUI,
# shell/plugins/vgs.notifications/tui/open.sh, which a click on a card with
# `x-vgs-click: open` runs on the card's x-vgs-open file. A stand-in editor
# and a stand-in xdg-open log their argv. It proves the script runs $EDITOR
# split on white space with the file last, falls back to xdg-open with
# EDITOR unset, hands on the editor's failure, and refuses by key a
# relative path, a file it cannot read, a missing opener, a wrong argument
# count and a run outside the presenter. Presented refusal keys stay in
# the diagnostic log. Child stdout and stderr remain unchanged. Each run has no controlling
# terminal and a PATH of the stand-ins and a few host tools.
#
# The controls at the end edit a copy of the script, one rule at a time, and
# require the suite to fail on each copy.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
script="$repo/shell/plugins/vgs.notifications/tui/open.sh"
TMP_ROOT="$(mktemp -d)" || { echo "test-notifications-open: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-notifications-open: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "test-notifications-open: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
for tool in setsid python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'test-notifications-open: status=not-measured missing=%s\n' "$tool"
    exit 77
  fi
done

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

tools="$TMP_ROOT/tools"
opener="$TMP_ROOT/opener"
mkdir -p "$tools" "$opener"
for tool in bash cat mkdir; do ln -s -- "$(command -v "$tool")" "$tools/$tool"; done
# The stand-ins log `<name> <argv>` and exit with $TMP_ROOT/exit's code.
for name in editor xdg-open; do
  cat >"$opener/$name" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >>"$TMP_ROOT/calls"
printf 'child: key=value\n'
printf 'child error: reason=fixture\n' >&2
exit "\$(<"$TMP_ROOT/exit")"
SH
  chmod 755 "$opener/$name"
done
file="$TMP_ROOT/runs/job@1767225600000-1.log"
mkdir -p "$(dirname -- "$file")"
printf 'transcript\n' >"$file"

# open SCRIPT PATH_HEAD EXIT [NAME=VALUE...] -- ARGS...: the status in
# $status, visible streams in $visible/$output, the logged key in $diagnostic,
# and the stand-ins' calls in $calls.
open_file() {
  local copy="$1" head="$2" code="$3"
  shift 3
  local env=()
  while [[ $1 != -- ]]; do env+=("$1"); shift; done
  shift
  printf '%s\n' "$code" >"$TMP_ROOT/exit"
  : >"$TMP_ROOT/calls"
  mkdir -p "$TMP_ROOT/state/vgs/notifications"
  : >"$TMP_ROOT/state/vgs/notifications/diagnostics.log"
  status=0
  setsid -w env -i PATH="$head:$tools" HOME="$TMP_ROOT" XDG_STATE_HOME="$TMP_ROOT/state" VGS_TUI_LIB="$repo/bin/lib/tui.sh" "${env[@]}" bash "$copy" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" </dev/null || status=$?
  visible="$(cat "$TMP_ROOT/err")"
  output="$(cat "$TMP_ROOT/out")"
  diagnostic="$(cat "$TMP_ROOT/state/vgs/notifications/diagnostics.log")"
  first="$(head -n 1 "$TMP_ROOT/err" 2>/dev/null || true)"
  calls="$(cat "$TMP_ROOT/calls")"
}

case_editor_with_its_words() {
  open_file "$1" "$opener" 0 "EDITOR=$opener/editor --wait" -- "$file"
  [[ $status == 0 && $calls == "editor --wait $file" ]]
}
case_xdg_open_without_an_editor() {
  open_file "$1" "$opener" 0 -- "$file"
  [[ $status == 0 && $calls == "xdg-open $file" && $output == "child: key=value" && $visible == "child error: reason=fixture" ]]
}
case_the_editor_failure() {
  open_file "$1" "$opener" 4 "EDITOR=$opener/editor" -- "$file"
  [[ $status == 4 && $calls == "editor $file" && $output == "child: key=value" && $visible == "child error: reason=fixture" ]]
}
case_refuses_a_relative_path() {
  open_file "$1" "$opener" 0 "EDITOR=$opener/editor" -- "-R"
  [[ $status == 2 && $diagnostic == "notifications: refused: path=-R reason=relative" && -n $visible && $visible != *"notifications: refused:"* && -z $calls ]]
}
case_refuses_a_missing_file() {
  open_file "$1" "$opener" 0 "EDITOR=$opener/editor" -- "$TMP_ROOT/gone.log"
  [[ $status == 1 && $diagnostic == "notifications: refused: file=unreadable path=$TMP_ROOT/gone.log" && -n $visible && $visible != *"notifications: refused:"* && $visible == *"missing"* && $visible != *"opened"* && -z $calls ]]
}
case_refuses_without_an_opener() {
  open_file "$1" "$TMP_ROOT/empty" 0 -- "$file"
  [[ $status == 1 && $diagnostic == "notifications: refused: opener=missing" && -n $visible && $visible != *"notifications: refused:"* ]]
}
case_refuses_two_arguments() {
  open_file "$1" "$opener" 0 "EDITOR=$opener/editor" -- "$file" "$file"
  [[ $status == 2 && $diagnostic == "notifications: refused: argument=2" && -n $visible && $visible != *"notifications: refused:"* && -z $calls ]]
}
case_refuses_outside_the_presenter() {
  status=0
  setsid -w env -i PATH="$opener:$tools" bash "$1" "$file" >/dev/null 2>"$TMP_ROOT/err" </dev/null || status=$?
  [[ $status == 2 && $(head -n 1 "$TMP_ROOT/err") == "notifications: refused: tui=missing" ]]
}
CASES=(case_editor_with_its_words case_xdg_open_without_an_editor case_the_editor_failure case_refuses_a_relative_path case_refuses_a_missing_file case_refuses_without_an_opener case_refuses_two_arguments case_refuses_outside_the_presenter)
mkdir -p "$TMP_ROOT/empty"
for case in "${CASES[@]}"; do
  if "$case" "$script"; then ok "${case#case_}"; else fail "${case#case_}: status=$status first=[$first] calls=[${calls//$'\n'/;}]"; fi
done

# Controls: a case, the text in the script it needs, and a replacement
# without the rule.
CONTROL_CASES=(case_editor_with_its_words case_xdg_open_without_an_editor case_refuses_a_relative_path case_refuses_a_missing_file case_the_editor_failure)
CONTROL_NEEDLES=('"${editor[@]}" "$file"' 'xdg-open "$file"' '[[ $file == /* ]] || refuse 2' '[[ -f $file && -r $file ]] || refuse 1' '  "${editor[@]}" "$file"
  exit')
CONTROL_REPLACEMENTS=('"$EDITOR" "$file"' 'true' 'true || refuse 2' 'true || refuse 1' '  "${editor[@]}" "$file" || true
  exit')
CONTROL_CASES+=(case_refuses_a_missing_file case_refuses_a_missing_file case_refuses_a_missing_file case_the_editor_failure)
CONTROL_NEEDLES+=('>>"$dir/diagnostics.log"' "printf 'notifications: refused: %s\n' \"\$2\" >>\"\$dir/diagnostics.log\"" "printf '%s\n' \"\$@\" >&2 ;;" '  "${editor[@]}" "$file"')
CONTROL_REPLACEMENTS+=('>&2' ':' "printf 'The file opened.\n' >&2 ;;" '  "${editor[@]}" "$file" >/dev/null 2>/dev/null')
for i in "${!CONTROL_CASES[@]}"; do
  case="${CONTROL_CASES[i]}"
  copy="$TMP_ROOT/copy.sh"
  if ! python3 - "$script" "$copy" "${CONTROL_NEEDLES[i]}" "${CONTROL_REPLACEMENTS[i]}" <<'PY'
import sys
source = open(sys.argv[1]).read()
if source.count(sys.argv[3]) != 1:
    sys.exit("control text occurs %d times: %s" % (source.count(sys.argv[3]), sys.argv[3]))
open(sys.argv[2], "w").write(source.replace(sys.argv[3], sys.argv[4]))
PY
  then
    fail "control $case: its text must occur once"
  elif "$case" "$copy"; then
    fail "control $case: passed on a copy without the rule"
  else
    ok "control $case"
  fi
done

if [[ $failures -gt 0 ]]; then
  printf 'test-notifications-open: failures=%d\n' "$failures"
  exit 1
fi
printf 'test-notifications-open: ok cases=%d controls=%d\n' "${#CASES[@]}" "${#CONTROL_CASES[@]}"
