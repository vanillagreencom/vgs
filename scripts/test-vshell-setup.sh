#!/usr/bin/env bash
# Drive the first-start route: the `vshell setup` verb, the install messages
# that name it, and the two package recipes that must not enable the unit
# themselves. No VGS package enables vshell.service, so this one verb is what
# every install message points at, and the parts only stay true together.
#
# The verb runs against a stub systemctl and a stub vshell-helper staged beside
# a copy of the CLI, so no real unit and no real user manager is touched. Both
# stubs append to one log, so the order of the calls is a fact the rows can pin:
#   - deps status runs before the start, because the unit is Type=simple and a
#     report taken after it would name the owner the shell is replacing;
#   - a systemd that accepts the unit gets enable then start, as two calls;
#   - a systemd that refuses either one points at systemctl's own message, and
#     at status and the journal for a refused start, never at the compositor
#     route, which only a missing systemctl earns;
#   - an argument after the verb is refused with a usage line, before anything
#     runs.
#
# The message half is derived from the tree rather than from a list here:
#   - no file under packaging/ and no line of README.md repeats the raw enable
#     command; bin/vshell is its single owner, and install.sh performs the
#     enable rather than printing it, so both are outside the scanned set;
#   - every channel directory under packaging/ names the first-start step its
#     own channel can run, keyed per channel so Void cannot pass on a systemd
#     instruction it has no systemd to execute.
#
# Two recipe rows guard what the scan cannot see, each pinned because a silent
# deletion leaves no other trace: install.sh's own enable call, and the Debian
# rules override that keeps dh_installsystemduser from enabling VGS for every
# account on the machine.
#
# The openSUSE channel is outside every rule here: its spec lives in the OBS
# project, not in this repository, so nothing in this tree can reach it.
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

# A PATH that genuinely has no systemctl, standing in for a system without
# systemd. It cannot simply drop the system directories: the CLI needs a shell
# and a few coreutils to reach the branch at all, so they are linked in by name
# and systemctl is the one thing left out.
nosystemd="$tmp/nosystemd"
mkdir -p "$nosystemd"
for tool in bash env readlink dirname cat basename; do
  tool_path="$(command -v "$tool")" || {
    printf 'test-vshell-setup: %s is not on PATH\n' "$tool" >&2
    exit 1
  }
  ln -s -- "$tool_path" "$nosystemd/$tool"
done
if PATH="$nosystemd" command -v systemctl >/dev/null 2>&1; then
  printf 'test-vshell-setup: the systemd-free PATH still resolves systemctl\n' >&2
  exit 1
fi
cat >"$stubs/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$CALL_LOG"
case " $* " in
  *" enable "*) exit "$SYSTEMCTL_ENABLE_RC" ;;
  *" start "*) exit "$SYSTEMCTL_START_RC" ;;
esac
exit 0
EOF
chmod +x "$stubs/systemctl"

# Run $2's setup verb in case directory $1 with the stub systemctl exiting $3
# for enable and $4 for start, resolved through the directory $5. The stub
# directory is put ahead of the system ones; $nosystemd replaces them, because
# it is the case where no systemctl may be reachable at all. Remaining arguments
# follow the verb. Sets setup_rc, call_log and err_out.
run_setup() {
  local dir="$tmp/$1" src="$2" enable_rc="$3" start_rc="$4" stub_dir="$5"
  shift 5
  mkdir -p "$dir/bin"
  cp "$src" "$dir/bin/vshell"
  cat >"$dir/bin/vshell-helper" <<'EOF'
#!/usr/bin/env bash
printf 'helper %s\n' "$*" >>"$CALL_LOG"
EOF
  chmod +x "$dir/bin/vshell" "$dir/bin/vshell-helper"
  call_log="$dir/calls.log"
  err_out="$dir/err"
  : >"$call_log"
  setup_rc=0
  local path="$stub_dir"
  [[ $stub_dir == "$nosystemd" ]] || path="$stub_dir:/usr/bin:/bin"
  env -i HOME="$dir" PATH="$path" CALL_LOG="$call_log" \
    SYSTEMCTL_ENABLE_RC="$enable_rc" SYSTEMCTL_START_RC="$start_rc" \
    "$dir/bin/vshell" setup "$@" >"$dir/out" 2>"$err_out" || setup_rc=$?
}

first_call() { head -n 1 "$call_log"; }

# The install messages and READMEs that tell a user how VGS first starts.
# bin/vshell holds the raw enable command and is deliberately outside this set,
# as is install.sh, which runs the enable rather than printing it, and this
# script, which names the command in $raw_enable.
first_start_paths=(packaging README.md)

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

# The first-start step each channel directory must name. Void runs runit, so a
# systemd instruction there would be one its users cannot execute; keying the
# token per channel is what stops the two being interchangeable. A directory
# absent from this table is reported rather than skipped, so a channel added
# without a decision about its first start reddens instead of passing.
channel_step() {
  case "$1" in
    arch | debian | fedora | gentoo | ubuntu) printf 'vshell setup\n' ;;
    void) printf 'exec-once = vshell run\n' ;;
    *) return 1 ;;
  esac
}

# Every channel directory under $1 that names no first-start step, the wrong one
# for its channel, or that this suite has no expectation for.
packaging_gaps() {
  local dir name step seen=0
  for dir in "$1"/packaging/*/; do
    [[ -d $dir ]] || continue
    seen=$((seen + 1))
    name="$(basename -- "${dir%/}")"
    if ! step="$(channel_step "$name")"; then
      printf 'unknown-channel %s\n' "${dir%/}"
      continue
    fi
    grep -rqF -e "$step" -- "$dir" || printf 'no-step %s\n' "${dir%/}"
  done
  # An empty glob would otherwise leave the rule passing on nothing at all.
  ((seen > 0)) || printf 'no-channel-directories %s\n' "$1/packaging"
}

# Lines of file $1 holding the literal $2. grep exits 1 on no match, which is a
# real count of zero, and above 1 on an unreadable file or a broken invocation.
# That last case prints -1, a count no row expects, so the row reddens instead
# of reading an instrument failure as a clean subject.
count_matches() {
  local count status=0
  count="$(grep -cF -- "$2" "$1")" || status=$?
  if ((status > 1)); then
    printf 'test-vshell-setup: could not read %s (grep status %s)\n' "$1" "$status" >&2
    printf '%s\n' -1
    return 0
  fi
  printf '%s\n' "$count"
}

# install.sh enables the unit itself rather than calling the bundle's setup
# verb, because --version installs an older bundle whose CLI need not carry it.
installer_enables() {
  count_matches "$1/install.sh" "$raw_enable --now vshell.service"
}

# dh_installsystemduser rides the default dh sequence from compat 12 and enables
# the unit for every account on the machine unless this override is present.
debian_no_enable() {
  count_matches "$1/packaging/debian/rules" 'dh_installsystemduser --no-enable'
}

echo "=== vshell setup ==="

run_setup accepted "$script_under_test" 0 0 "$stubs"
expect accept-status "setup succeeds when the unit enables and starts" \
  "rc=$setup_rc calls: $(tr '\n' '|' <"$call_log")" test "$setup_rc" -eq 0
expect accept-report-first "the report runs before the start, not inside it" \
  "first call: $(first_call)" \
  test "$(first_call)" = 'helper deps status'
expect accept-enable "setup enables vshell.service" \
  "calls: $(tr '\n' '|' <"$call_log")" \
  grep -qxF -- 'systemctl --user enable vshell.service' "$call_log"
expect accept-start "setup starts vshell.service as its own call" \
  "calls: $(tr '\n' '|' <"$call_log")" \
  grep -qxF -- 'systemctl --user start vshell.service' "$call_log"

run_setup enable-refused "$script_under_test" 1 0 "$stubs"
expect enable-refused-status "a refused enable fails setup" \
  "rc=$setup_rc" test "$setup_rc" -eq 1
expect enable-refused-cause "a refused enable points at systemctl's own message" \
  "stderr: $(cat "$err_out")" \
  grep -qF -- 'could not enable vshell.service' "$err_out"
expect enable-refused-no-route "a refused enable does not offer the compositor route" \
  "stderr: $(cat "$err_out")" \
  grep -qvF -- 'exec-once = vshell run' "$err_out"
expect enable-refused-no-start "a refused enable does not go on to start the unit" \
  "calls: $(tr '\n' '|' <"$call_log")" \
  grep -qvF -- 'systemctl --user start' "$call_log"

run_setup start-refused "$script_under_test" 0 1 "$stubs"
expect start-refused-status "a refused start fails setup" \
  "rc=$setup_rc" test "$setup_rc" -eq 1
expect start-refused-cause "a refused start points at status and the journal" \
  "stderr: $(cat "$err_out")" \
  grep -qF -- 'journalctl --user -u vshell.service' "$err_out"
expect start-refused-no-route "a refused start does not offer the compositor route" \
  "stderr: $(cat "$err_out")" \
  grep -qvF -- 'exec-once = vshell run' "$err_out"

run_setup no-systemctl "$script_under_test" 0 0 "$nosystemd"
expect no-systemctl-status "a system with no systemctl fails setup" \
  "rc=$setup_rc" test "$setup_rc" -eq 1
expect no-systemctl-route "a missing systemctl is the case that earns the compositor route" \
  "stderr: $(cat "$err_out")" \
  grep -qF -- 'exec-once = vshell run' "$err_out"

run_setup extra-argument "$script_under_test" 0 0 "$stubs" status
expect reject-argument-status "setup takes no argument" \
  "rc=$setup_rc" test "$setup_rc" -eq 2
expect reject-argument-usage "a refused argument prints the usage line" \
  "stderr: $(cat "$err_out")" \
  grep -qF -- 'Usage: vshell setup' "$err_out"
expect reject-argument-inert "a refused argument touches neither systemd nor the helper" \
  "calls: $(tr '\n' '|' <"$call_log")" test ! -s "$call_log"

echo "=== install messages ==="

expect single-owner "no packaging message and no README line repeats the raw enable command" \
  "also named in: $(packaging_owners "$repo_root" | tr '\n' ' ')" \
  test -z "$(packaging_owners "$repo_root")"
expect every-channel "every packaging channel names the first-start step it can run" \
  "gaps: $(packaging_gaps "$repo_root" | tr '\n' ' ')" \
  test -z "$(packaging_gaps "$repo_root")"

echo "=== package recipes ==="

expect installer-enables "install.sh enables the unit itself" \
  "occurrences: $(installer_enables "$repo_root")" \
  test "$(installer_enables "$repo_root")" -eq 1
expect debian-no-enable "the Debian rules keep dh_installsystemduser from enabling the unit" \
  "occurrences: $(debian_no_enable "$repo_root")" \
  test "$(debian_no_enable "$repo_root")" -eq 1

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

enable_call='systemctl --user enable vshell.service || status=$?'
# shellcheck disable=SC2016  # bash source of the script under test, quoted verbatim as its anchor
report_first='  "$helper" deps status
  local status=0'
# shellcheck disable=SC2016  # bash source of the script under test, quoted verbatim as its anchor
start_refusal='  journalctl --user -u vshell.service
EOF
    return 1'
# shellcheck disable=SC2016  # bash source substituted into the mutant, quoted verbatim
start_refusal_passes='  journalctl --user -u vshell.service
EOF
    return 0'
tail_line='  echo "Re-run vshell deps status once the shell is up to see the settled state."'
# shellcheck disable=SC2016  # bash source substituted into the mutant, quoted verbatim
tail_reports='  "$helper" deps status'

if build_mutant "$mutants/no-enable" "$enable_call" 'status=0'; then
  run_setup control-no-enable "$mutants/no-enable" 0 0 "$stubs"
  expect control-no-enable "dropping the enable call reddens the accepted case" \
    "calls: $(tr '\n' '|' <"$call_log")" \
    grep -qvF -- 'systemctl --user enable' "$call_log"
fi

if build_mutant "$mutants/report-last" "$report_first" '  local status=0' \
  "$tail_line" "$tail_reports"; then
  run_setup control-report-last "$mutants/report-last" 0 0 "$stubs"
  expect control-report-last "reporting after the start reddens the ordering case" \
    "first call: $(first_call)" \
    test "$(first_call)" != 'helper deps status'
fi

if build_mutant "$mutants/start-passes" "$start_refusal" "$start_refusal_passes"; then
  run_setup control-start-passes "$mutants/start-passes" 0 1 "$stubs"
  expect control-start-passes "a refused start that returns success reddens its case" \
    "rc=$setup_rc" test "$setup_rc" -eq 0
fi

mutant_tree="$tmp/tree"
mkdir -p "$mutant_tree"
for path in "${first_start_paths[@]}" install.sh; do
  cp -r "$repo_root/$path" "$mutant_tree/$path"
done

printf '  %s --now vshell.service\n' "$raw_enable" >>"$mutant_tree/README.md"
expect control-single-owner "an install instruction that repeats the raw enable command reddens the owner rule" \
  "owners: $(packaging_owners "$mutant_tree" | tr '\n' ' ')" \
  test "$(packaging_owners "$mutant_tree")" = "$mutant_tree/README.md"

# Void's message rewritten to the systemd step it has no systemd to run. The
# old rule accepted either token anywhere and stayed green on exactly this.
printf 'Start it with vshell setup\n' >"$mutant_tree/packaging/void/INSTALL.msg"
expect control-wrong-channel-step "the systemd step in Void's message reddens the channel rule" \
  "gaps: $(packaging_gaps "$mutant_tree" | tr '\n' ' ')" \
  test "$(packaging_gaps "$mutant_tree")" = "no-step $mutant_tree/packaging/void"

: >"$mutant_tree/install.sh"
expect control-installer-enables "an install.sh that stops enabling the unit reddens its row" \
  "occurrences: $(installer_enables "$mutant_tree")" \
  test "$(installer_enables "$mutant_tree")" -eq 0

: >"$mutant_tree/packaging/debian/rules"
expect control-debian-no-enable "Debian rules without the override redden their row" \
  "occurrences: $(debian_no_enable "$mutant_tree")" \
  test "$(debian_no_enable "$mutant_tree")" -eq 0

if [[ $failures -ne 0 ]]; then
  printf '\ntest-vshell-setup: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'test-vshell-setup: all checks passed\n'
