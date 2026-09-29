#!/usr/bin/env bash
# The Slack token probe of vgs.notifications,
# shell/plugins/vgs.notifications/token-status.sh, against a stub
# secret-tool first on PATH. The stub answers `secret-tool search` as
# libsecret's tool does (tool/secret-tool.c, on_retrieve_secret, 0.20.4 to
# 0.21.8): an item on stdout, an unlocked item's secret included, and its
# attributes and any error on stderr; for a locked item, the error
# gnome-keyring returns, `Cannot get secret of a locked object`. Each case
# pins the probe's one stdout line and exit status, that the stub ran
# `search service vgs-notifications account slack` and nothing else, that
# its stdout pointed at /dev/null, and that the stub's secret appears in
# nothing the probe printed. A search that outlasts the probe's ten seconds
# is not exercised: only a bus that never answers reaches it, so
# `reason=timeout` is unexercised.
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
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
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
# The stub reads its answer from $stub/mode and logs its argument list and
# the target of its stdout to $stub/calls, one call per line.
cat >"$stub/secret-tool" <<SH
#!/usr/bin/env bash
printf '%s|%s\n' "\$*" "\$(readlink /proc/\$\$/fd/1)" >>"$stub/calls"
item() { printf '[/1]\nlabel = VGS notifications Slack token\n'; }
attributes() { printf 'attribute.service = vgs-notifications\nattribute.account = slack\n' >&2; }
case "\$(cat "$stub/mode")" in
  present) item; printf 'secret = %s\n' '$secret'; attributes ;;
  absent) ;;
  locked) item; printf 'secret-tool: Cannot get secret of a locked object\n' >&2; attributes ;;
  failed) printf 'secret-tool: The name org.freedesktop.secrets was not provided by any .service files\n' >&2; exit 1 ;;
  unrecognised) item; printf 'secret-tool: Received invalid secret from the secret storage\n' >&2; attributes ;;
  *) printf 'stub: mode unreadable\n' >&2; exit 99 ;;
esac
if [[ \${1:-} == lookup ]]; then printf '%s\n' '$secret'; fi
SH
chmod 755 "$stub/secret-tool"
# A directory that is not the stub's, for the test-stub guard.
other="$TMP_ROOT/other"
mkdir -p "$other"
# A PATH with no secret-tool: the tools the probe needs, linked alone.
bare="$TMP_ROOT/bare"
mkdir -p "$bare"
for tool in bash timeout readlink cat; do ln -s -- "$(command -v "$tool")" "$bare/$tool"; done

# run SCRIPT MODE PATH [TEST_DIR]: the probe under a clean environment with
# the stub answering MODE; prints its stdout, then `stderr=<first line>`,
# `exit=<status>` and `calls=<the stub's log, ; separated>`.
run() {
  local script="$1" mode="$2" path="$3" test_dir="${4:-}" out status=0
  local env_args=(env -i PATH="$path")
  printf '%s\n' "$mode" >"$stub/mode"
  : >"$stub/calls"
  [[ -z $test_dir ]] || env_args+=(VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR="$test_dir")
  out="$("${env_args[@]}" bash "$script" 2>"$TMP_ROOT/err")" || status=$?
  printf '%s\nstderr=%s\nexit=%s\ncalls=%s\n' "$out" "$(head -n 1 "$TMP_ROOT/err")" "$status" "$(paste -sd ';' "$stub/calls")"
  if grep -q -F -- "$secret" "$TMP_ROOT/err"; then echo "leak=stderr"; fi
}

failures=0
check() { # LABEL WANT GOT
  if [[ $2 == "$3" ]]; then return 0; fi
  failures=$((failures + 1))
  printf '  FAIL  %s\n        want %q\n        got  %q\n' "$1" "$2" "$3"
}

search="search service vgs-notifications account slack|/dev/null"
suite() {
  local script="$1" before=$failures path="$stub:$bare"
  # Cases: label | mode | the stdout line.
  local cases=(
    "a stored token in an unlocked collection is present|present|slack-token: present"
    "no stored token is absent|absent|slack-token: absent"
    "a stored token in a locked collection is locked|locked|slack-token: locked"
    "a search the store refuses leaves the token unavailable|failed|slack-token: unavailable reason=search-failed status=1"
    "an item whose secret fails otherwise is unavailable|unrecognised|slack-token: unavailable reason=unrecognised"
  )
  local row label mode line
  for row in "${cases[@]}"; do
    IFS='|' read -r label mode line <<<"$row"
    check "$label" "$line"$'\nstderr=\nexit=0\ncalls='"$search" "$(run "$script" "$mode" "$path")"
  done
  check "no secret-tool on PATH leaves the token unavailable" $'slack-token: unavailable reason=secret-tool-missing\nstderr=\nexit=0\ncalls=' "$(run "$script" present "$bare")"
  check "under a test directory the stub inside it answers" $'slack-token: present\nstderr=\nexit=0\ncalls='"$search" "$(run "$script" present "$path" "$stub")"
  check "under a test directory a secret-tool outside it is refused before it runs" $'\nstderr=notifications-token-status: secret-tool=test-stub-required\nexit=5\ncalls=' "$(run "$script" present "$path" "$other")"
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
    ("a copy that prints the secret value", 'echo "slack-token: present"', 'echo "slack-token: present"; secret-tool lookup "${attrs[@]}"'),
    ("a copy that asks the store to unlock", 'secret-tool search "${attrs[@]}"', 'secret-tool search --unlock "${attrs[@]}"'),
    ("a copy that reads a locked item as present", 'elif [[ $found == true && -z $failure ]]; then', 'elif [[ $found == true ]]; then'),
    ("a copy that reads any failure as locked", '${failure,,} == *locked*', '-n $failure'),
    ("a copy that reads a failed search as absent", 'if [[ $status -ne 0 ]]; then', 'if false; then'),
    ("a copy without the test-stub guard", 'if [[ -n ${VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR:-} ]]; then', 'if false; then'),
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
if [[ $passed -ne 7 ]]; then
  echo "test-notifications-token-status: controls=$passed want 7; the control table is broken"
  failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then echo "test-notifications-token-status: $failures failing"; exit 1; fi
echo "test-notifications-token-status: ok"
