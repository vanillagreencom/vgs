#!/usr/bin/env bash
# The vgs.agent-warden floating TUIs, shell/plugins/vgs.agent-warden/tui/
# setup.sh and vsys.sh, against a stand-in vsys that logs its argv and ends
# with the code a file names. It proves setup runs `vsys warden install`
# once and ends with vsys's code, and vsys.sh runs vsys with no argument
# and keeps its code. Each run has no controlling terminal and a PATH of
# the stand-in, a stand-in gum and bash alone, so no run reaches the host's
# vsys or systemd.
#
# The controls at the end edit a copy of a script, one rule at a time, and
# require a case to fail on each copy.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
tui="$repo/shell/plugins/vgs.agent-warden/tui"
TMP_ROOT="$(mktemp -d)" || { echo "test-agent-warden-tui: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-agent-warden-tui: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "test-agent-warden-tui: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
for tool in setsid python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'test-agent-warden-tui: status=not-measured missing=%s\n' "$tool"
    exit 77
  fi
done

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

tools="$TMP_ROOT/tools"
mkdir -p "$tools"
ln -s -- "$(command -v bash)" "$tools/bash"
# The library draws its header with gum; the stand-in prints its words.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' >"$tools/gum"
# vsys logs its argv as one line, `[]` for none, and ends with the code in
# $TMP_ROOT/code.
cat >"$tools/vsys" <<SH
#!/usr/bin/env bash
printf '[%s]\n' "\$*" >>"$TMP_ROOT/calls"
exit "\$(<"$TMP_ROOT/code")"
SH
chmod 755 "$tools/gum" "$tools/vsys"

# tui SCRIPT CODE: runs SCRIPT with vsys ending CODE; the exit status in
# $status, the stand-in's calls in $calls.
tui() {
  printf '%s\n' "$2" >"$TMP_ROOT/code"
  : >"$TMP_ROOT/calls"
  status=0
  setsid -w env -i PATH="$tools" HOME="$TMP_ROOT" VGS_TUI_LIB="$repo/bin/lib/tui.sh" bash "$1" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" </dev/null || status=$?
  calls="$(cat "$TMP_ROOT/calls")"
}

# The cases, each a check on one run: they return 1 on a miss.
case_setup_installs_once() {
  tui "$1" 0
  [[ $status == 0 && $calls == "[warden install]" ]]
}
case_setup_keeps_the_failure() {
  tui "$1" 3
  [[ $status == 3 && $calls == "[warden install]" ]]
}
case_vsys_runs_bare() {
  tui "$1" 0
  [[ $status == 0 && $calls == "[]" ]]
}
case_vsys_keeps_its_code() {
  tui "$1" 3
  [[ $status == 3 && $calls == "[]" ]]
}
CASES=(case_setup_installs_once case_setup_keeps_the_failure case_vsys_runs_bare case_vsys_keeps_its_code)
SCRIPTS=(setup.sh setup.sh vsys.sh vsys.sh)
for i in "${!CASES[@]}"; do
  case="${CASES[i]}"
  if "$case" "$tui/${SCRIPTS[i]}"; then ok "${case#case_}"; else fail "${case#case_}: status=$status calls=[${calls//$'\n'/;}] err=[$(head -n 1 "$TMP_ROOT/err")]"; fi
done

# Controls: a case, the script, the line it needs and a replacement
# without the rule.
CONTROL_CASES=(case_setup_installs_once case_setup_keeps_the_failure case_vsys_runs_bare case_vsys_keeps_its_code)
CONTROL_SCRIPTS=(setup.sh setup.sh vsys.sh vsys.sh)
CONTROL_LINES=('vsys warden install' 'vsys warden install' 'exec vsys' 'exec vsys')
CONTROL_REPLACEMENTS=('vsys warden install; vsys warden install' 'vsys warden install || true' 'exec vsys --once' 'vsys || true')
for i in "${!CONTROL_CASES[@]}"; do
  case="${CONTROL_CASES[i]}"
  copy="$TMP_ROOT/copy.sh"
  if ! python3 - "$tui/${CONTROL_SCRIPTS[i]}" "$copy" "${CONTROL_LINES[i]}" "${CONTROL_REPLACEMENTS[i]}" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
hits = [i for i, line in enumerate(lines) if line == sys.argv[3]]
if len(hits) != 1:
    sys.exit("control line occurs %d times: %s" % (len(hits), sys.argv[3]))
lines[hits[0]] = sys.argv[4]
open(sys.argv[2], "w").write("\n".join(lines))
PY
  then
    fail "control $case: its line must occur once"
  elif "$case" "$copy"; then
    fail "control $case: passed on a copy without the rule"
  else
    ok "control $case"
  fi
done

if [[ $failures -gt 0 ]]; then
  printf 'test-agent-warden-tui: failures=%d\n' "$failures"
  exit 1
fi
printf 'test-agent-warden-tui: ok cases=%d controls=%d\n' "${#CASES[@]}" "${#CONTROL_CASES[@]}"
