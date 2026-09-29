#!/usr/bin/env bash
# The Slack token probe of vgs.notifications,
# shell/plugins/vgs.notifications/token-status.sh, against a stub
# secret-tool first on PATH. The stub answers `secret-tool search` as
# libsecret's tool does (tool/secret-tool.c, on_retrieve_secret, 0.20.4 to
# 0.21.8), one answer per account: an item on stdout, an unlocked item's
# secret included, and its attributes and any error on stderr; for a locked
# item, the error gnome-keyring returns, `Cannot get secret of a locked
# object`. Each case pins the probe's stdout lines, one per account, and its
# exit status, that the stub ran `search service vgs-notifications account
# <account>` for each workspace's account in order and then for `slack`,
# and nothing else, that its stdout pointed at /dev/null, and that the
# stub's secret appears in nothing the probe printed. A search that
# outlasts the probe's ten seconds is not exercised: only a bus that never
# answers reaches it, so `reason=timeout` is unexercised.
#
# The controls at the end edit a copy of the probe, one rule at a time, and
# require the suite to fail on each copy: among them a copy that reads the
# search's stdout, and one that prints the secret.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
probe="$repo/shell/plugins/vgs.notifications/token-status.sh"
# The EXIT trap is armed only on the directory mktemp made: an empty or
# non-directory answer never reaches rm -rf.
TMP_ROOT="$(mktemp -d)" || { echo "test-notifications-token-status: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-notifications-token-status: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "test-notifications-token-status: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
for tool in timeout readlink python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'test-notifications-token-status: status=not-measured missing=%s\n' "$tool"
    exit 77
  fi
done

secret="xoxp-test-token-4f2a"
stub="$TMP_ROOT/stub"
mkdir -p "$stub"
# The stub reads each account's answer from $stub/states, lines of
# `<account> <mode>`, an account it lists nowhere answering `absent`, and
# logs its argument list and the target of its stdout to $stub/calls, one
# call per line.
cat >"$stub/secret-tool" <<SH
#!/usr/bin/env bash
printf '%s|%s\n' "\$*" "\$(readlink /proc/\$\$/fd/1)" >>"$stub/calls"
account="" prev=""
for arg in "\$@"; do [[ \$prev == account ]] && account="\$arg"; prev="\$arg"; done
mode=absent
while read -r name answer; do [[ \$name == "\$account" ]] && mode="\$answer"; done <"$stub/states"
item() { printf '[/1]\nlabel = VGS notifications Slack token\n'; }
attributes() { printf 'attribute.service = vgs-notifications\nattribute.account = %s\n' "\$account" >&2; }
case "\$mode" in
  present) item; printf 'secret = %s\n' '$secret'; attributes ;;
  absent) ;;
  locked) item; printf 'secret-tool: Cannot get secret of a locked object\n' >&2; attributes ;;
  failed) printf 'secret-tool: The name org.freedesktop.secrets was not provided by any .service files\n' >&2; exit 1 ;;
  unrecognised) item; printf 'secret-tool: Received invalid secret from the secret storage\n' >&2; attributes ;;
  *) printf 'stub: mode unreadable\n' >&2; exit 99 ;;
esac
if [[ \${1:-} == lookup && \$mode == present ]]; then printf '%s\n' '$secret'; fi
SH
chmod 755 "$stub/secret-tool"
# A directory that is not the stub's, for the test-stub guard.
other="$TMP_ROOT/other"
mkdir -p "$other"
# A PATH with no secret-tool: the tools the probe needs, linked alone.
bare="$TMP_ROOT/bare"
mkdir -p "$bare"
for tool in bash timeout readlink cat; do ln -s -- "$(command -v "$tool")" "$bare/$tool"; done

# run SCRIPT STATES PATH TEST_DIR [TEAM_ID...]: the probe under a clean
# environment with the stub answering STATES, `;`-separated `<account>
# <mode>` pairs; prints its stdout, then `stderr=<first line>`,
# `exit=<status>` and `calls=<the stub's log, ; separated>`.
run() {
  local script="$1" states="$2" path="$3" test_dir="$4" out status=0
  shift 4
  local env_args=(env -i PATH="$path")
  tr ';' '\n' <<<"$states" >"$stub/states"
  : >"$stub/calls"
  [[ -z $test_dir ]] || env_args+=(VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR="$test_dir")
  out="$("${env_args[@]}" bash "$script" "$@" 2>"$TMP_ROOT/err")" || status=$?
  printf '%s\nstderr=%s\nexit=%s\ncalls=%s\n' "$out" "$(head -n 1 "$TMP_ROOT/err")" "$status" "$(paste -sd ';' "$stub/calls")"
  if grep -q -F -- "$secret" "$TMP_ROOT/err"; then echo "leak=stderr"; fi
}

failures=0
check() { # LABEL WANT GOT
  if [[ $2 == "$3" ]]; then return 0; fi
  failures=$((failures + 1))
  printf '  FAIL  %s\n        want %q\n        got  %q\n' "$1" "$2" "$3"
}

search() { printf 'search service vgs-notifications account %s|/dev/null' "$1"; }
legacy="$(search slack)"
suite() {
  local script="$1" before=$failures path="$stub:$bare"
  # The single-workspace account alone: label | mode | its line.
  local cases=(
    "a stored token in an unlocked collection is present|present|slack-token: account=slack present"
    "no stored token is absent|absent|slack-token: account=slack absent"
    "a stored token in a locked collection is locked|locked|slack-token: account=slack locked"
    "a search the store refuses leaves the token unavailable|failed|slack-token: account=slack unavailable reason=search-failed status=1"
    "an item whose secret fails otherwise is unavailable|unrecognised|slack-token: account=slack unavailable reason=unrecognised"
  )
  local row label mode line
  for row in "${cases[@]}"; do
    IFS='|' read -r label mode line <<<"$row"
    check "$label" "$line"$'\nstderr=\nexit=0\ncalls='"$legacy" "$(run "$script" "slack $mode" "$path" "")"
  done
  check "each workspace's account is asked in order, then the single-workspace one" \
    $'slack-token: account=slack:T1 present\nslack-token: account=slack:T2 locked\nslack-token: account=slack absent\nstderr=\nexit=0\ncalls='"$(search slack:T1);$(search slack:T2);$legacy" \
    "$(run "$script" "slack:T1 present;slack:T2 locked;slack absent" "$path" "" T1 T2)"
  check "a token stored for one account is not another's" \
    $'slack-token: account=slack:T1 absent\nslack-token: account=slack present\nstderr=\nexit=0\ncalls='"$(search slack:T1);$legacy" \
    "$(run "$script" "slack present" "$path" "" T1)"
  check "a failed search leaves only its own account unavailable" \
    $'slack-token: account=slack:T1 unavailable reason=search-failed status=1\nslack-token: account=slack present\nstderr=\nexit=0\ncalls='"$(search slack:T1);$legacy" \
    "$(run "$script" "slack:T1 failed;slack present" "$path" "" T1)"
  check "no secret-tool on PATH leaves every account unavailable" \
    $'slack-token: account=slack:T1 unavailable reason=secret-tool-missing\nslack-token: account=slack unavailable reason=secret-tool-missing\nstderr=\nexit=0\ncalls=' \
    "$(run "$script" "slack present" "$bare" "" T1)"
  check "a team id that is not letters and digits is refused before any search" \
    $'\nstderr=notifications-token-status: refused: team-id want=[A-Za-z0-9]{1,32}\nexit=2\ncalls=' \
    "$(run "$script" "slack present" "$path" "" T1 'T2;x')"
  check "a team id of 33 characters is refused" \
    $'\nstderr=notifications-token-status: refused: team-id want=[A-Za-z0-9]{1,32}\nexit=2\ncalls=' \
    "$(run "$script" "slack present" "$path" "" "$(printf 'T%.0s' {1..33})")"
  check "more than 16 team ids are refused before any search" \
    $'\nstderr=notifications-token-status: refused: teams count=17 want<=16\nexit=2\ncalls=' \
    "$(run "$script" "slack present" "$path" "" T{1..17})"
  check "16 team ids are asked" 17 "$(run "$script" "slack present" "$path" "" T{1..16} | grep -c '^slack-token: ')"
  check "under a test directory the stub inside it answers" $'slack-token: account=slack present\nstderr=\nexit=0\ncalls='"$legacy" "$(run "$script" "slack present" "$path" "$stub")"
  check "under a test directory a secret-tool outside it is refused before it runs" $'\nstderr=notifications-token-status: secret-tool=test-stub-required\nexit=5\ncalls=' "$(run "$script" "slack present" "$path" "$other")"
  [[ $failures -eq $before ]]
}

if suite "$probe"; then echo "  ok    the probe answers every case without reading or printing the token"; fi

# One control per rule: a copy with that rule removed and the text around it
# kept; the suite must fail on every copy.
mkdir -p "$TMP_ROOT/controls"
python3 - "$probe" "$TMP_ROOT/controls" <<'CONTROLS'
import pathlib, sys
source, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = source.read_text()
controls = [
    ("a copy that reads the search's stdout", '2>&1 >/dev/null)"', '2>&1)"'),
    ("a copy that prints the secret value", 'echo "present"', 'echo "present"; secret-tool lookup service vgs-notifications account "$1"'),
    ("a copy that asks the store to unlock", 'secret-tool search service vgs-notifications account "$1"', 'secret-tool search --unlock service vgs-notifications account "$1"'),
    ("a copy that reads a locked item as present", 'elif [[ $found == true && -z $failure ]]; then', 'elif [[ $found == true ]]; then'),
    ("a copy that reads any failure as locked", '${failure,,} == *locked*', '-n $failure'),
    ("a copy that reads a failed search as absent", 'if [[ $status -ne 0 ]]; then', 'if false; then'),
    ("a copy without the test-stub guard", 'if [[ -n ${VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR:-} ]]; then', 'if false; then'),
    ("a copy that takes any team id", 'if [[ ! $team =~ ^[A-Za-z0-9]{1,32}$ ]]; then', 'if false; then'),
    ("a copy that takes any number of team ids", 'if [[ $# -gt $teams_max ]]; then', 'if false; then'),
    ("a copy that asks no workspace's account", 'accounts+=("slack:$team")', ':'),
    ("a copy that asks no single-workspace account", 'accounts+=(slack)\n', '\n'),
]
for n, (label, needle, replacement) in enumerate(controls):
    assert text.count(needle) == 1, "control needle must occur once: " + label
    (out / ("%02d.sh" % n)).write_text("# " + label + "\n" + text.replace(needle, replacement))
CONTROLS
passed=0
for copy in "$TMP_ROOT"/controls/*.sh; do
  label="$(head -n 1 "$copy" | cut -c3-)"
  saved=$failures
  if suite "$copy" >/dev/null; then
    echo "  FAIL  control \"$label\": the suite passed on a probe without that rule"
    failures=$((saved + 1))
  else
    failures=$saved
    passed=$((passed + 1))
    echo "  ok    control: $label"
  fi
done
if [[ $passed -ne 11 ]]; then
  echo "test-notifications-token-status: controls=$passed want 11; the control table is broken"
  failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then echo "test-notifications-token-status: $failures failing"; exit 1; fi
echo "test-notifications-token-status: ok"
