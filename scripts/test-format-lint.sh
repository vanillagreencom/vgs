#!/usr/bin/env bash
# Control for scripts/check-format-lint.sh's no-shebang router arm (VGS-123).
#
# The arm used to fail only for `scripts/*.sh|*.py|*.js`, so a tracked
# EXECUTABLE under scripts/ with no extension and no shebang fell through
# unlinted. That file is not inert the way a data fixture is: bash's ENOEXEC
# fallback runs it, so it can be a working manifest command that satisfies
# check-validation-inventory.py's executable-bit requirement while no linter
# ever claims it — scripts/validate's own shape, one variation over.
#
# Driven from a THROWAWAY GIT REPO holding a copy of the check plus one probe
# file, because the check discovers work through `git ls-files`: a control that
# staged a probe in the real index would mutate the tree it is checking. The
# copy fails on this repo's other surfaces (no Go files, no packaging) and that
# is fine — every case asserts the presence or ABSENCE of one specific message,
# and the three fixtures differ only in the probe's name and mode.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

failures=0
case_failed=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
  case_failed=1
}
ok() {
  if [[ $case_failed -eq 0 ]]; then
    printf '  ok    %s\n' "$1"
  fi
  case_failed=0
}

EXEC_MSG="is executable with no shebang"
EXT_MSG="language extension but no shebang"

# probe_run <probe name> <mode: exec|noexec> — stage one probe in a fresh
# fixture repo and return everything the check printed.
probe_run() {
  local name="$1" mode="$2" fixture="$tmp/repo"
  rm -rf "$fixture"
  mkdir -p "$fixture/scripts"
  git -C "$fixture" init -q
  cp "$repo_root/scripts/check-format-lint.sh" "$fixture/scripts/"
  chmod +x "$fixture/scripts/check-format-lint.sh"
  printf 'echo probe\n' >"$fixture/scripts/$name"
  if [[ "$mode" == exec ]]; then chmod +x "$fixture/scripts/$name"; else chmod -x "$fixture/scripts/$name"; fi
  git -C "$fixture" add -A
  (cd "$fixture" && ./scripts/check-format-lint.sh) 2>&1 || true
}

# The fixture must reach the router at all. Without this, every assertion below
# could pass because the check died in its tool preamble, which is the shape
# where an absent message means "never looked" rather than "looked and found
# nothing".
out="$(probe_run probe-exec exec)"
if [[ "$out" != *"$EXEC_MSG"* && "$out" != *"$EXT_MSG"* && "$out" != *"no Go files matched"* ]]; then
  fail "fixture reaches the router" "the fixture check produced none of its own messages — it probably died in the tool preamble:
$out"
fi
ok "the fixture repo reaches the discovery loop"

# THE FAIL-OPEN: extensionless, executable, no shebang.
[[ "$out" == *"$EXEC_MSG"* ]] ||
  fail "executable no-shebang" "an extensionless executable with no shebang was not reported:
$out"
ok "an extensionless executable with no shebang fails closed"

# ...and the same content without the executable bit still falls through, which
# is what actually leaves data fixtures alone.
out="$(probe_run probe-data noexec)"
[[ "$out" != *"$EXEC_MSG"* ]] ||
  fail "non-executable fixture" "a non-executable extensionless fixture was reported as unlinted:
$out"
ok "a non-executable extensionless fixture still passes"

# The extension arm is unchanged: a .sh with no shebang is a lint gap whatever
# its mode, so the mode rule must not have replaced it.
out="$(probe_run probe-data.sh noexec)"
[[ "$out" == *"$EXT_MSG"* ]] ||
  fail "extension arm" "a non-executable .sh with no shebang was not reported:
$out"
ok "a non-executable .sh with no shebang still fails on the extension arm"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-format-lint: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-format-lint: all checks passed"
