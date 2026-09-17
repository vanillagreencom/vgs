#!/usr/bin/env bash
# Drive the first-start route: the `vshell setup` verb and the packaging
# messages that name it. A package cannot enable a systemd user unit for the
# user, so this one verb is what every install message points at, and the two
# halves only stay true together.
#
# The verb runs against a stub systemctl and a stub vshell-helper staged beside
# a copy of the CLI, so no real unit and no real user manager is touched:
#   - a user manager that accepts the unit gets --user enable --now, and the
#     run then reports through deps status;
#   - a user manager that refuses fails the verb, names the compositor route,
#     and reports nothing as if it had run;
#   - an argument after the verb is refused.
#
# The packaging half is derived from the tree rather than from a list here:
#   - no file under packaging/, and not install.sh, repeats the raw enable
#     command; bin/vshell is its single owner and is outside the scanned set;
#   - every channel directory under packaging/ names a first-start step.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script_under_test="$repo_root/bin/vshell"

tmp="$(mktemp -d)" || {
  printf 'test-vshell-setup: could not create a temporary directory\n' >&2
  exit 1
}
trap 'rm -rf "${tmp:?}"' EXIT

failures=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}
ok() { printf '  ok    %s\n' "$1"; }
# $1 case key, $2 description, $3 detail on failure, then the test command.
expect() {
  local key="$1" what="$2" detail="$3"
  shift 3
  if "$@"; then
    ok "$what"
  else
    fail "$key" "$detail"
  fi
}

stubs="$tmp/stubs"
mkdir -p "$stubs"
cat >"$stubs/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
exit "$SYSTEMCTL_RC"
EOF
chmod +x "$stubs/systemctl"

# Run $2's setup verb in case directory $1 against a systemctl that exits $3.
# Remaining arguments follow the verb. Sets setup_rc and the three log paths.
run_setup() {
  local dir="$tmp/$1" src="$2" rc="$3"
  shift 3
  mkdir -p "$dir/bin"
  cp "$src" "$dir/bin/vshell"
  cat >"$dir/bin/vshell-helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HELPER_LOG"
EOF
  chmod +x "$dir/bin/vshell" "$dir/bin/vshell-helper"
  systemctl_log="$dir/systemctl.log"
  helper_log="$dir/helper.log"
  err_out="$dir/err"
  : >"$systemctl_log"
  : >"$helper_log"
  setup_rc=0
  env -i HOME="$dir" PATH="$stubs:/usr/bin:/bin" \
    SYSTEMCTL_LOG="$systemctl_log" SYSTEMCTL_RC="$rc" HELPER_LOG="$helper_log" \
    "$dir/bin/vshell" setup "$@" >"$dir/out" 2>"$err_out" || setup_rc=$?
}

# The install messages and installers that tell a user how VGS first starts.
# bin/vshell holds the raw enable command and is deliberately outside this set,
# as is this script, which names the command in $raw_enable.
first_start_paths=(packaging install.sh README.md)

# Every scanned file under $1 that repeats the raw enable command. A path that
# does not resolve is reported rather than skipped: a silent grep over a
# misspelled path would pass the rule while reading nothing.
raw_enable='systemctl --user enable'
packaging_owners() {
  local path scanned=() found
  for path in "${first_start_paths[@]}"; do
    if [[ -e "$1/$path" ]]; then
      scanned+=("$1/$path")
    else
      printf 'unresolved-scan-path %s\n' "$1/$path"
    fi
  done
  ((${#scanned[@]} > 0)) || return 0
  local status=0
  found="$(grep -rlF -- "$raw_enable" "${scanned[@]}")" || status=$?
  case "$status" in
    0) printf '%s\n' "$found" | LC_ALL=C sort ;;
    1) : ;; # grep found nothing, which is the state the rule wants
    *) printf 'scan-failed status=%s\n' "$status" ;;
  esac
  return 0
}

# Every channel directory under $1 that names no first-start step.
packaging_gaps() {
  local dir
  for dir in "$1"/packaging/*/; do
    [[ -d $dir ]] || continue
    grep -rqF -e 'vshell setup' -e 'exec-once = vshell run' -- "$dir" ||
      printf '%s\n' "${dir%/}"
  done
}

echo "=== vshell setup ==="

run_setup accepted "$script_under_test" 0
expect enable-unit "setup enables and starts vshell.service" \
  "systemctl argv: $(cat "$systemctl_log")" \
  grep -qxF -- '--user enable --now vshell.service' "$systemctl_log"
expect enable-status "setup succeeds when the unit enables" \
  "rc=$setup_rc" test "$setup_rc" -eq 0
expect enable-report "setup reports features and notification ownership" \
  "helper argv: $(cat "$helper_log")" \
  grep -qxF -- 'deps status' "$helper_log"

run_setup refused "$script_under_test" 1
expect refuse-status "a user manager that refuses the unit fails setup" \
  "rc=$setup_rc" test "$setup_rc" -eq 1
expect refuse-route "the refusal names the compositor route" \
  "stderr: $(cat "$err_out")" \
  grep -qF -- 'exec-once = vshell run' "$err_out"
expect refuse-silent "a refused setup reports nothing as if it had run" \
  "helper argv: $(cat "$helper_log")" test ! -s "$helper_log"

run_setup extra-argument "$script_under_test" 0 status
expect reject-argument "setup takes no argument" \
  "rc=$setup_rc stderr: $(cat "$err_out")" test "$setup_rc" -eq 2

echo "=== packaging messages ==="

expect single-owner "no packaging message and no installer repeats the raw enable command" \
  "also named in: $(packaging_owners "$repo_root" | tr '\n' ' ')" \
  test -z "$(packaging_owners "$repo_root")"
expect every-channel "every packaging channel names a first-start step" \
  "no step in: $(packaging_gaps "$repo_root" | tr '\n' ' ')" \
  test -z "$(packaging_gaps "$repo_root")"

echo "=== must-fail controls ==="

# Copy the CLI to $1 with each following ANCHOR REPLACEMENT pair applied. Each
# anchor must occur exactly once, so a control whose anchor drifted reports
# itself as broken rather than passing on a text it no longer matches.
mutants="$tmp/mutants"
mkdir -p "$mutants"
# Occurrences of needle $2 in haystack $1. grep counts matching lines, which a
# multi-line anchor turns into an alternation over its lines.
count_substring() {
  local rest="$1" n=0
  while [[ $rest == *"$2"* ]]; do
    rest="${rest#*"$2"}"
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

build_mutant() {
  local mutant="$1" text count
  shift
  text="$(<"$script_under_test")"
  while (($# >= 2)); do
    if ! count="$(count_substring "$text" "$1")"; then
      fail control-anchor "the anchor counter failed on: $1"
      return 1
    fi
    if [[ $count -ne 1 ]]; then
      fail control-anchor "anchor occurs $count time(s), want 1: $1"
      return 1
    fi
    text="${text/"$1"/"$2"}"
    shift 2
  done
  printf '%s\n' "$text" >"$mutant"
  chmod +x "$mutant"
}

enable_call='systemctl --user enable --now vshell.service'
# shellcheck disable=SC2016  # bash source of the script under test, quoted verbatim as its anchor
refusal_status='  Niri      spawn-at-startup "vshell" "run"
EOF
    return 1'
# shellcheck disable=SC2016  # bash source substituted into the mutant, quoted verbatim
refusal_success='  Niri      spawn-at-startup "vshell" "run"
EOF
    return 0'

if build_mutant "$mutants/no-enable" "$enable_call" 'true'; then
  run_setup control-no-enable "$mutants/no-enable" 0
  expect control-no-enable "dropping the enable call reddens the accepted case" \
    "systemctl argv: $(cat "$systemctl_log")" \
    test ! -s "$systemctl_log"
fi

if build_mutant "$mutants/refuse-passes" "$refusal_status" "$refusal_success"; then
  run_setup control-refuse-passes "$mutants/refuse-passes" 1
  expect control-refuse-passes "a refusal that returns success reddens the refused case" \
    "rc=$setup_rc" test "$setup_rc" -eq 0
fi

mutant_tree="$tmp/tree"
mkdir -p "$mutant_tree"
for path in "${first_start_paths[@]}"; do
  cp -r "$repo_root/$path" "$mutant_tree/$path"
done

printf '  %s --now vshell.service\n' "$raw_enable" >>"$mutant_tree/README.md"
expect control-single-owner "an install instruction that repeats the raw enable command reddens the owner rule" \
  "owners: $(packaging_owners "$mutant_tree" | tr '\n' ' ')" \
  test -n "$(packaging_owners "$mutant_tree")"

: >"$mutant_tree/packaging/void/INSTALL.msg"
expect control-every-channel "a channel that loses its first-start step reddens the channel rule" \
  "gaps: $(packaging_gaps "$mutant_tree" | tr '\n' ' ')" \
  test -n "$(packaging_gaps "$mutant_tree")"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-vshell-setup: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'test-vshell-setup: all checks passed\n'
