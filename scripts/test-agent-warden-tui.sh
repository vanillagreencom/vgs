#!/usr/bin/env bash
# The vgs.agent-warden floating TUIs, shell/plugins/vgs.agent-warden/tui/,
# against a stand-in vsys that logs its argv and exits with the code in a
# file. It proves `setup` runs `vsys warden install` once and ends with its
# code, and `vsys` runs vsys with no arguments and ends with its code. The
# smoke's stand-in terminal runs no bundled plugin script, so this is the
# only run of them. Each run has no controlling terminal and a PATH of the
# stand-in, a stand-in gum and a few host tools, so no run reaches the host's
# vsys or systemd.
#
# The controls at the end edit a copy of a script, one rule at a time, and
# require the suite to fail on each copy.
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
stub="$TMP_ROOT/stub"
mkdir -p "$tools" "$stub"
for tool in bash cat; do ln -s -- "$(command -v "$tool")" "$tools/$tool"; done
# The library draws its header with gum; the stand-in prints its words.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' >"$tools/gum"
chmod 755 "$tools/gum"
cat >"$stub/vsys" <<SH
#!/usr/bin/env bash
printf '[%s]\n' "\$*" >>"$TMP_ROOT/calls"
exit "\$(<"$TMP_ROOT/code")"
SH
chmod 755 "$stub/vsys"

# run_tui SCRIPT CODE: runs SCRIPT with the stand-in exiting CODE; the exit
# status in $status, the stand-in's calls in $calls.
run_tui() {
  printf '%s\n' "$2" >"$TMP_ROOT/code"
  : >"$TMP_ROOT/calls"
  status=0
  setsid -w env -i PATH="$stub:$tools" HOME="$TMP_ROOT" VGS_TUI_LIB="$repo/bin/lib/tui.sh" bash "$1" >/dev/null 2>&1 </dev/null || status=$?
  calls="$(cat "$TMP_ROOT/calls")"
}

# The cases, each a check on one script: they return 1 on a miss.
case_setup_installs_the_warden() { run_tui "$1" 0; [[ $status == 0 && $calls == "[warden install]" ]]; }
case_setup_ends_with_its_code() { run_tui "$1" 3; [[ $status == 3 && $calls == "[warden install]" ]]; }
case_vsys_runs_bare() { run_tui "$1" 0; [[ $status == 0 && $calls == "[]" ]]; }
case_vsys_ends_with_its_code() { run_tui "$1" 4; [[ $status == 4 && $calls == "[]" ]]; }
CASES=(case_setup_installs_the_warden case_setup_ends_with_its_code case_vsys_runs_bare case_vsys_ends_with_its_code)
SCRIPTS=(setup.sh setup.sh vsys.sh vsys.sh)
for i in "${!CASES[@]}"; do
  case="${CASES[i]}"
  if "$case" "$tui/${SCRIPTS[i]}"; then ok "${case#case_}"; else fail "${case#case_}: status=$status calls=[${calls//$'\n'/;}]"; fi
done

# Controls: a case, the script, the text in it the case needs, and a
# replacement without the rule.
CONTROL_CASES=(case_setup_installs_the_warden case_setup_ends_with_its_code case_vsys_runs_bare case_vsys_ends_with_its_code)
CONTROL_SCRIPTS=(setup.sh setup.sh vsys.sh vsys.sh)
CONTROL_NEEDLES=($'\nvsys warden install\n' $'\nvsys warden install\n' $'\nexec vsys\n' $'\nexec vsys\n')
CONTROL_REPLACEMENTS=($'\nvsys warden status\n' $'\nvsys warden install || true\n' $'\nexec vsys warden\n' $'\nvsys || true\n')
for i in "${!CONTROL_CASES[@]}"; do
  case="${CONTROL_CASES[i]}"
  copy="$TMP_ROOT/copy.sh"
  if ! python3 - "$tui/${CONTROL_SCRIPTS[i]}" "$copy" "${CONTROL_NEEDLES[i]}" "${CONTROL_REPLACEMENTS[i]}" <<'PY'
import sys
source = open(sys.argv[1]).read()
if source.count(sys.argv[3]) != 1:
    sys.exit("control text occurs %d times: %r" % (source.count(sys.argv[3]), sys.argv[3]))
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
  printf 'test-agent-warden-tui: failures=%d\n' "$failures"
  exit 1
fi
printf 'test-agent-warden-tui: ok cases=%d controls=%d\n' "${#CASES[@]}" "${#CONTROL_CASES[@]}"
