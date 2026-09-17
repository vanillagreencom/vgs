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
#   - that report is advisory, so a helper that fails still leaves the unit
#     enabled and started, and the failure is named;
#   - a systemd that accepts the unit gets enable then start, as two calls;
#   - a systemd that refuses either one points at systemctl's own message, and
#     at status and the journal for a refused start, never at the compositor
#     route, which only a missing systemctl earns;
#   - an argument after the verb is refused with a usage line, before anything
#     runs.
#
# Negative rows use lacks rather than grep -v, which answers a different
# question: -v selects the lines that do not match, so it succeeds whenever the
# file holds any other line, and four rows here passed unconditionally on it.
#
# The message half is derived from the tree rather than from a list here:
#   - no file under packaging/ and no line of README.md repeats the raw enable
#     command; bin/vshell is its single owner, and install.sh performs the
#     enable rather than printing it, so both are outside the scanned set;
#   - every channel directory under packaging/ carries an install message that
#     names the first-start step its own channel can run, each channel keyed to
#     both the file and the step, so neither a build recipe can answer for the
#     message nor a systemd instruction pass on Void.
#
# Two recipe rows guard what no message names. Each anchor holds its line
# together with the structure that makes it work, because both regressions keep
# the text: an enable moved out of install.sh's start branch still reads as an
# enable, and a commented-out override still leaves --no-enable in the file
# while dh goes back to enabling VGS for every account on the machine.
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

# The PATH every case uses unless it is testing what happens without systemd.
stub_path="$stubs:/usr/bin:/bin"

# Run $2's setup verb in case directory $1 with the stub systemctl exiting $3
# for enable and $4 for start and the stub helper exiting $5, under PATH $6.
# Remaining arguments follow the verb. Sets setup_rc, call_log and err_out.
run_setup() {
  local dir="$tmp/$1" src="$2" enable_rc="$3" start_rc="$4" helper_rc="$5" path="$6"
  shift 6
  mkdir -p "$dir/bin"
  cp "$src" "$dir/bin/vshell"
  cat >"$dir/bin/vshell-helper" <<'EOF'
#!/usr/bin/env bash
printf 'helper %s\n' "$*" >>"$CALL_LOG"
exit "$HELPER_RC"
EOF
  chmod +x "$dir/bin/vshell" "$dir/bin/vshell-helper"
  call_log="$dir/calls.log"
  err_out="$dir/err"
  : >"$call_log"
  setup_rc=0
  env -i HOME="$dir" PATH="$path" CALL_LOG="$call_log" HELPER_RC="$helper_rc" \
    SYSTEMCTL_ENABLE_RC="$enable_rc" SYSTEMCTL_START_RC="$start_rc" \
    "$dir/bin/vshell" setup "$@" >"$dir/out" 2>"$err_out" || setup_rc=$?
}

first_call() { head -n 1 "$call_log"; }

# True when no line of file $2 holds the literal $1. grep -v cannot say this:
# it selects the lines that do not match, so it succeeds whenever the file has
# any other line at all, which every file these rows read always does.
lacks() { ! grep -qF -- "$1" "$2"; }

# True when file $1 holds the literal $2, which may span lines. Reading the
# whole file rather than grepping lets an anchor pin a line together with the
# structure that guards it; an unreadable file fails the caller's test.
file_holds() {
  local text
  text="$(<"$1")" || return 2
  [[ $text == *"$2"* ]]
}

# True when file $1 does not hold the literal $2. expect runs its command as
# argv, where a leading ! would be a command name rather than a negation.
file_lacks() { ! file_holds "$1" "$2"; }

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

# The file, or files, in a channel directory that carry its install message,
# relative to that directory. Naming them is what keeps a build recipe from
# answering for the message: packaging/debian/rules names vshell setup in a
# comment, and a scan of the whole directory passed on that comment while the
# postinst said nothing.
channel_messages() {
  case "$1" in
    arch) printf '%s\n' 'vgs-shell.install' 'vgs-shell-git/vgs-shell-git.install' ;;
    debian) printf '%s\n' 'vgs-shell.postinst' ;;
    fedora) printf '%s\n' 'vgs-shell.spec' ;;
    gentoo) printf '%s\n' 'vgs-shell-*.ebuild' ;;
    ubuntu) printf '%s\n' 'README.md' ;;
    void) printf '%s\n' 'INSTALL.msg' ;;
    *) return 1 ;;
  esac
}

# Every channel directory under $1 whose install message is missing or names no
# first-start step, or the wrong one for its channel, or that this suite has no
# expectation for.
packaging_gaps() {
  local dir name step message path seen=0 matched
  for dir in "$1"/packaging/*/; do
    [[ -d $dir ]] || continue
    seen=$((seen + 1))
    name="$(basename -- "${dir%/}")"
    if ! step="$(channel_step "$name")"; then
      printf 'unknown-channel %s\n' "${dir%/}"
      continue
    fi
    while IFS= read -r message; do
      matched=0
      # Unquoted so a channel may name its message by glob, as Gentoo does: its
      # ebuild carries the version in its filename.
      # shellcheck disable=SC2231  # deliberate glob over the channel's message names
      for path in "${dir%/}"/$message; do
        [[ -f $path ]] || continue
        matched=1
        file_holds "$path" "$step" || printf 'no-step %s\n' "$path"
      done
      ((matched)) || printf 'no-message %s\n' "${dir%/}/$message"
    done < <(channel_messages "$name")
  done
  # An empty glob would otherwise leave the rule passing on nothing at all.
  ((seen > 0)) || printf 'no-channel-directories %s\n' "$1/packaging"
}

# install.sh enables the unit itself rather than calling the bundle's setup
# verb, because --version installs an older bundle whose CLI need not carry it.
# The anchor holds the enable together with the branch that decides it runs, so
# a --no-start install that quietly starts the shell anyway reddens the row as
# surely as a deleted line does.
# shellcheck disable=SC2016  # bash source of install.sh, quoted verbatim as its anchor
installer_anchor='if [[ "$start" == true ]]; then
  systemctl --user enable --now vshell.service'

# dh_installsystemduser rides the default dh sequence from compat 12 and enables
# the unit for every account on the machine unless this override is present. The
# anchor holds the make target with it: commenting the target out leaves the
# flag in the file while dh goes back to running the default.
debian_anchor='override_dh_installsystemduser:
	dh_installsystemduser --no-enable'

echo "=== vshell setup ==="

run_setup accepted "$script_under_test" 0 0 0 "$stub_path"
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

run_setup report-failed "$script_under_test" 0 0 1 "$stub_path"
expect report-failed-status "a failing report does not fail setup" \
  "rc=$setup_rc stderr: $(cat "$err_out")" test "$setup_rc" -eq 0
expect report-failed-still-starts "a failing report does not keep the unit from starting" \
  "calls: $(tr '\n' '|' <"$call_log")" \
  grep -qxF -- 'systemctl --user start vshell.service' "$call_log"
expect report-failed-said-so "a failing report is named rather than passed over" \
  "stderr: $(cat "$err_out")" \
  grep -qF -- 'could not read the dependency report' "$err_out"

run_setup enable-refused "$script_under_test" 1 0 0 "$stub_path"
expect enable-refused-status "a refused enable fails setup" \
  "rc=$setup_rc" test "$setup_rc" -eq 1
expect enable-refused-cause "a refused enable points at systemctl's own message" \
  "stderr: $(cat "$err_out")" \
  grep -qF -- 'could not enable vshell.service' "$err_out"
expect enable-refused-no-route "a refused enable does not offer the compositor route" \
  "stderr: $(cat "$err_out")" \
  lacks 'exec-once = vshell run' "$err_out"
expect enable-refused-no-start "a refused enable does not go on to start the unit" \
  "calls: $(tr '\n' '|' <"$call_log")" \
  lacks 'systemctl --user start' "$call_log"

run_setup start-refused "$script_under_test" 0 1 0 "$stub_path"
expect start-refused-status "a refused start fails setup" \
  "rc=$setup_rc" test "$setup_rc" -eq 1
expect start-refused-cause "a refused start points at status and the journal" \
  "stderr: $(cat "$err_out")" \
  grep -qF -- 'journalctl --user -u vshell.service' "$err_out"
expect start-refused-no-route "a refused start does not offer the compositor route" \
  "stderr: $(cat "$err_out")" \
  lacks 'exec-once = vshell run' "$err_out"

run_setup no-systemctl "$script_under_test" 0 0 0 "$nosystemd"
expect no-systemctl-status "a system with no systemctl fails setup" \
  "rc=$setup_rc" test "$setup_rc" -eq 1
expect no-systemctl-route "a missing systemctl is the case that earns the compositor route" \
  "stderr: $(cat "$err_out")" \
  grep -qF -- 'exec-once = vshell run' "$err_out"

run_setup extra-argument "$script_under_test" 0 0 0 "$stub_path" status
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

expect installer-enables "install.sh enables the unit itself, under the start branch" \
  "install.sh does not hold the anchor" \
  file_holds "$repo_root/install.sh" "$installer_anchor"
expect debian-no-enable "the Debian rules target keeps dh_installsystemduser from enabling the unit" \
  "packaging/debian/rules does not hold the anchor" \
  file_holds "$repo_root/packaging/debian/rules" "$debian_anchor"

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

enable_call='  if ! systemctl --user enable vshell.service; then'
# shellcheck disable=SC2016  # bash source of the script under test, quoted verbatim as its anchor
report_first='  "$helper" deps status ||
    echo "vshell setup: could not read the dependency report; enabling the unit anyway." >&2'
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

if build_mutant "$mutants/no-enable" "$enable_call" '  if false; then'; then
  run_setup control-no-enable "$mutants/no-enable" 0 0 0 "$stub_path"
  expect control-no-enable "dropping the enable call reddens the accepted case" \
    "calls: $(tr '\n' '|' <"$call_log")" \
    lacks 'systemctl --user enable' "$call_log"
fi

if build_mutant "$mutants/report-last" "$report_first" '  :' \
  "$tail_line" "$tail_reports"; then
  run_setup control-report-last "$mutants/report-last" 0 0 0 "$stub_path"
  expect control-report-last "reporting after the start reddens the ordering case" \
    "first call: $(first_call)" \
    test "$(first_call)" != 'helper deps status'
fi

if build_mutant "$mutants/start-passes" "$start_refusal" "$start_refusal_passes"; then
  run_setup control-start-passes "$mutants/start-passes" 0 1 0 "$stub_path"
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
  test "$(packaging_gaps "$mutant_tree")" = "no-step $mutant_tree/packaging/void/INSTALL.msg"

# The step named in a build recipe rather than the install message. Scanning the
# whole channel directory passed on exactly this.
printf 'Start it with vshell setup\n' >"$mutant_tree/packaging/debian/rules"
: >"$mutant_tree/packaging/debian/vgs-shell.postinst"
expect control-recipe-not-message "a step named only in a build recipe reddens the channel rule" \
  "gaps: $(packaging_gaps "$mutant_tree" | tr '\n' ' ')" \
  file_holds <(packaging_gaps "$mutant_tree") "no-step $mutant_tree/packaging/debian/vgs-shell.postinst"

mkdir -p "$mutant_tree/packaging/madeup"
printf 'vshell setup\n' >"$mutant_tree/packaging/madeup/INSTALL.msg"
expect control-unknown-channel "a channel this suite has no expectation for reddens the channel rule" \
  "gaps: $(packaging_gaps "$mutant_tree" | tr '\n' ' ')" \
  file_holds <(packaging_gaps "$mutant_tree") "unknown-channel $mutant_tree/packaging/madeup"

empty_tree="$tmp/empty-tree"
mkdir -p "$empty_tree/packaging"
expect control-no-channels "a packaging tree with no channel directory reddens the channel rule" \
  "gaps: $(packaging_gaps "$empty_tree" | tr '\n' ' ')" \
  test "$(packaging_gaps "$empty_tree")" = "no-channel-directories $empty_tree/packaging"

# The enable moved out of the start branch: the command is still in the file, so
# a rule that only counted the text would stay green while --no-start started
# the shell anyway.
python3 - "$mutant_tree/install.sh" "$installer_anchor" <<'PY'
import sys
from pathlib import Path
path, anchor = Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
assert text.count(anchor) == 1, text.count(anchor)
path.write_text(text.replace(anchor, 'systemctl --user enable --now vshell.service\nif [[ "$start" == true ]]; then\n  :'))
PY
expect control-installer-enables "an enable outside the start branch reddens the installer row" \
  "install.sh still holds the anchor" \
  file_lacks "$mutant_tree/install.sh" "$installer_anchor"
expect control-installer-text-kept "that control keeps the enable command in the file" \
  "the enable command is gone, so the control proves nothing" \
  grep -qF -- "$raw_enable --now vshell.service" "$mutant_tree/install.sh"

# The override target commented out: dh goes back to the default sequence and
# enables the unit, while the --no-enable flag still sits in the file.
printf '# override_dh_installsystemduser:\n#\tdh_installsystemduser --no-enable\n' \
  >"$mutant_tree/packaging/debian/rules"
expect control-debian-no-enable "a commented-out override reddens the Debian row" \
  "packaging/debian/rules still holds the anchor" \
  file_lacks "$mutant_tree/packaging/debian/rules" "$debian_anchor"
expect control-debian-text-kept "that control keeps the no-enable flag in the file" \
  "the flag is gone, so the control proves nothing" \
  grep -qF -- 'dh_installsystemduser --no-enable' "$mutant_tree/packaging/debian/rules"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-vshell-setup: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'test-vshell-setup: all checks passed\n'
