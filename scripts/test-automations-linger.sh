#!/usr/bin/env bash
# The vgs.automations `linger` floating TUI,
# shell/plugins/vgs.automations/tui/linger.sh, against a stand-in loginctl
# that logs its argv and answers `show-user` from a file. It proves the
# script turns lingering on only after the question is answered yes, asks
# nothing and changes nothing when lingering is already on, keeps it off
# when the question cannot be asked, and refuses by key without the
# presenter, with an argument, without loginctl and when loginctl cannot
# read the state. Each run has no controlling terminal and a PATH of the
# stand-in, a stand-in gum and a few host tools, so no run reaches the
# host's logind.
#
# The controls at the end edit a copy of the script, one rule at a time, and
# require the suite to fail on each copy.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
script="$repo/shell/plugins/vgs.automations/tui/linger.sh"
TMP_ROOT="$(mktemp -d)" || { echo "test-automations-linger: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-automations-linger: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "test-automations-linger: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
for tool in setsid id python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'test-automations-linger: status=not-measured missing=%s\n' "$tool"
    exit 77
  fi
done

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

user="$(id -un)"
tools="$TMP_ROOT/tools"
stub="$TMP_ROOT/stub"
mkdir -p "$tools" "$stub"
for tool in bash id cat mkdir; do ln -s -- "$(command -v "$tool")" "$tools/$tool"; done
# The library draws its header with gum; the stand-in prints its words.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' >"$tools/gum"
chmod 755 "$tools/gum"
# answers: `yes`, `no`, or `fail` for a show-user that exits 1.
cat >"$stub/loginctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP_ROOT/calls"
if [[ \$1 == show-user ]]; then
  state="\$(<"$TMP_ROOT/state")"
  [[ \$state == fail ]] && exit 1
  printf '%s\n' "\$state"
fi
exit 0
SH
chmod 755 "$stub/loginctl"

# linger SCRIPT STATE [PATH_HEAD] [ENV...] -- ARGS...: runs SCRIPT with the
# stand-in's STATE; the exit status in $status, stderr's first line in
# $first, the stand-in's calls in $calls.
linger() {
  local file="$1" state="$2" head="$3"
  shift 3
  local env=()
  while [[ $1 != -- ]]; do env+=("$1"); shift; done
  shift
  printf '%s\n' "$state" >"$TMP_ROOT/state"
  : >"$TMP_ROOT/calls"
  status=0
  setsid -w env -i PATH="$head:$tools" HOME="$TMP_ROOT" VGS_TUI_LIB="$repo/bin/lib/tui.sh" "${env[@]}" bash "$file" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" </dev/null || status=$?
  first="$(head -n 1 "$TMP_ROOT/err" 2>/dev/null || true)"
  calls="$(cat "$TMP_ROOT/calls")"
}

# The cases, each a check on one run: they return 1 on a miss.
case_asks_before_enabling() {
  linger "$1" no "$stub" VGS_TUI_UNATTENDED=1 --
  [[ $status == 0 && $calls == "show-user $user --property=Linger --value"$'\n'"enable-linger $user" ]]
}
case_keeps_off_without_an_answer() {
  linger "$1" no "$stub" --
  [[ $status == 0 && $calls == "show-user $user --property=Linger --value" ]]
}
case_leaves_it_on() {
  linger "$1" yes "$stub" VGS_TUI_UNATTENDED=1 --
  [[ $status == 0 && $calls == "show-user $user --property=Linger --value" ]]
}
case_refuses_unreadable() {
  linger "$1" fail "$stub" VGS_TUI_UNATTENDED=1 --
  [[ $status == 1 && $first == "Could not check whether automations can run while you are logged out. Try again." && $calls == "show-user $user --property=Linger --value" ]]
}
case_refuses_without_loginctl() {
  linger "$1" no "$TMP_ROOT/empty" VGS_TUI_UNATTENDED=1 --
  [[ $status == 1 && $first == "Automations cannot run while you are logged out on this system." ]]
}
case_refuses_an_argument() {
  linger "$1" no "$stub" --
  linger "$1" no "$stub" -- extra
  [[ $status == 2 && $first == "This setup request is invalid. Open Automations and try again." && -z $calls ]]
}
case_refuses_outside_the_presenter() {
  printf 'no\n' >"$TMP_ROOT/state"
  status=0
  setsid -w env -i PATH="$stub:$tools" bash "$1" >/dev/null 2>"$TMP_ROOT/err" </dev/null || status=$?
  [[ $status == 2 && $(head -n 1 "$TMP_ROOT/err") == "automations: refused: tui=missing" ]]
}
CASES=(case_asks_before_enabling case_keeps_off_without_an_answer case_leaves_it_on case_refuses_unreadable case_refuses_without_loginctl case_refuses_an_argument case_refuses_outside_the_presenter)
mkdir -p "$TMP_ROOT/empty"
for case in "${CASES[@]}"; do
  if "$case" "$script"; then ok "${case#case_}"; else fail "${case#case_}: status=$status first=[$first] calls=[${calls//$'\n'/;}]"; fi
done

# Controls: a case, the text in the script it needs, and a replacement
# without the rule.
CONTROL_CASES=(case_asks_before_enabling case_keeps_off_without_an_answer case_leaves_it_on case_refuses_unreadable case_refuses_without_loginctl)
CONTROL_NEEDLES=('loginctl enable-linger "$user"' 'if ! vgs_tui_confirm "Allow automations to run while $user is logged out?"; then' 'if [[ $state == yes ]]; then' '[[ $status == 0 ]] || refuse 1' 'command -v loginctl >/dev/null || refuse')
CONTROL_REPLACEMENTS=('true' 'if false; then' 'if false; then' 'false && refuse 1' 'true || refuse')
for i in "${!CONTROL_CASES[@]}"; do
  case="${CONTROL_CASES[i]}"
  copy="$TMP_ROOT/copy.sh"
  if ! python3 - "$script" "$copy" "${CONTROL_NEEDLES[i]}" "${CONTROL_REPLACEMENTS[i]}" <<'PY2'
import sys
source = open(sys.argv[1]).read()
if source.count(sys.argv[3]) != 1:
    sys.exit("control text occurs %d times: %s" % (source.count(sys.argv[3]), sys.argv[3]))
open(sys.argv[2], "w").write(source.replace(sys.argv[3], sys.argv[4]))
PY2
  then
    fail "control $case: its text must occur once"
  elif "$case" "$copy"; then
    fail "control $case: passed on a copy without the rule"
  else
    ok "control $case"
  fi
done

if [[ $failures -gt 0 ]]; then
  printf 'test-automations-linger: failures=%d\n' "$failures"
  exit 1
fi
printf 'test-automations-linger: ok cases=%d controls=%d\n' "${#CASES[@]}" "${#CONTROL_CASES[@]}"
