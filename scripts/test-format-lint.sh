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

# probe_run <path under the fixture> <mode: exec|noexec|binary> [first line] —
# stage one probe in a fresh fixture repo and return everything the check
# printed. The path carries its tree, so the same case can be run under scripts/
# and bin/, and at any depth.
#
# `binary` writes NUL bytes and takes the executable bit: that is what git's
# `--eol` calls `i/-text`, and it is the shape of the tracked ELF that actually
# lives in bin/. It is deliberately EXECUTABLE, since a binary that is not would
# pass the mode rule for the wrong reason.
probe_run() {
  local rel="$1" mode="$2" first="${3:-echo probe}" fixture="$tmp/repo"
  rm -rf "$fixture"
  mkdir -p "$fixture/scripts" "$fixture/bin" "$(dirname -- "$fixture/$rel")"
  git -C "$fixture" init -q
  cp "$repo_root/scripts/check-format-lint.sh" "$fixture/scripts/"
  chmod +x "$fixture/scripts/check-format-lint.sh"
  if [[ "$mode" == binary ]]; then
    printf '\177ELF\000\000\000\000probe\n' >"$fixture/$rel"
    chmod +x "$fixture/$rel"
  else
    printf '%s\n' "$first" >"$fixture/$rel"
    if [[ "$mode" == exec ]]; then chmod +x "$fixture/$rel"; else chmod -x "$fixture/$rel"; fi
  fi
  git -C "$fixture" add -A
  (cd "$fixture" && ./scripts/check-format-lint.sh) 2>&1 || true
}

# The fixture must reach the router at all. Without this, every assertion below
# could pass because the check died in its tool preamble, which is the shape
# where an absent message means "never looked" rather than "looked and found
# nothing".
out="$(probe_run scripts/probe-exec exec)"
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
out="$(probe_run scripts/probe-data noexec)"
[[ "$out" != *"$EXEC_MSG"* ]] ||
  fail "non-executable fixture" "a non-executable extensionless fixture was reported as unlinted:
$out"
ok "a non-executable extensionless fixture still passes"

# The extension arm is unchanged: a .sh with no shebang is a lint gap whatever
# its mode, so the mode rule must not have replaced it.
out="$(probe_run scripts/probe-data.sh noexec)"
[[ "$out" == *"$EXT_MSG"* ]] ||
  fail "extension arm" "a non-executable .sh with no shebang was not reported:
$out"
ok "a non-executable .sh with no shebang still fails on the extension arm"

UNROUTED_MSG="has an unrouted shebang"

# AN UNROUTED SHEBANG IS A FAILURE IN BOTH TREES. bin/ goes through the same
# discovery loop, so excluding it here left the fail-closed guarantee covering
# half the surface: the identical file was a named failure under scripts/ and
# silently unlinted under bin/.
for tree in scripts bin; do
  out="$(probe_run "$tree/probe-sh" exec '#!/bin/sh')"
  [[ "$out" == *"$UNROUTED_MSG"* ]] ||
    fail "unrouted shebang in $tree" "an unrouted #!/bin/sh under $tree/ was not reported:
$out"
  out="$(probe_run "$tree/probe-zsh" exec '#!/usr/bin/env zsh')"
  [[ "$out" == *"$UNROUTED_MSG"* ]] ||
    fail "unrouted shebang in $tree" "an unrouted zsh shebang under $tree/ was not reported:
$out"
done
ok "an unrouted shebang is reported under scripts/ AND under bin/"

# ...while an ABSENT shebang under bin/ still passes for a NON-EXECUTABLE file.
# That exclusion is deliberate and documented — bin/ holds importable Python
# modules with no shebang — and it is the MODE that grants it, not the tree.
out="$(probe_run bin/vshell_module.py noexec 'import sys')"
[[ "$out" != *"$UNROUTED_MSG"* && "$out" != *"$EXEC_MSG"* ]] ||
  fail "bin module" "a shebang-less bin/ Python module was reported:
$out"
ok "a shebang-less bin/ Python module still passes"

# THE SAME FILE WITH THE EXECUTABLE BIT IS A FAILURE, and this is the arm that
# used to check scripts/ only. bash's ENOEXEC fallback runs such a file, so an
# executable shebang-less bin/ entry point works while no linter here claims it
# — the identical hole the scripts/ side already refuses. The probe is
# extensionless on purpose: a .py would also trip the extension arm, and a case
# that two arms can satisfy proves neither.
out="$(probe_run bin/probe-exec exec)"
[[ "$out" == *"$EXEC_MSG"* ]] ||
  fail "executable no-shebang under bin" "an executable shebang-less bin/ file was not reported:
$out"
ok "an executable shebang-less bin/ file fails closed"

# ...and a tracked BINARY is exempt, which is what keeps that arm from reporting
# bin/vshell-asdcontrol — a compiled ELF no linter here could ever claim. Without
# this case the arm above would pass just as well with the exemption deleted and
# the real tree failing.
out="$(probe_run bin/probe-binary binary)"
[[ "$out" != *"$EXEC_MSG"* ]] ||
  fail "binary exemption" "a tracked binary under bin/ was reported as unlinted:
$out"
ok "a tracked binary under bin/ is exempt from the executable-bit rule"

DEPTH_MSG="lives under a scripts/ subdirectory this check does not collect"
LIB_DEPTH_MSG="lives under a scripts/lib/ subdirectory this check does not collect"

# THE DEPTH GUARD, at more than one level. A review reading `scripts/*/*` as a
# pathname pattern concluded that scripts/a/b/c escapes it; `*` in a case pattern
# matches `/`, so it does not. Pinned here rather than argued: if the guard is
# ever rewritten into a form where `*` stops at `/`, this case fails instead of
# the coverage quietly narrowing.
for probe in scripts/sub/probe scripts/a/b/probe; do
  out="$(probe_run "$probe" noexec)"
  [[ "$out" == *"$DEPTH_MSG"* ]] ||
    fail "scripts depth guard" "$probe was not reported as uncollected:
$out"
done
ok "a file under a scripts/ subdirectory is reported at any depth"

# scripts/lib/ is exempt at its OWN level only: a nested extensionless file
# there is in neither the lib pathspecs nor the router, which is the same quiet
# drop one directory over.
out="$(probe_run scripts/lib/probe.py noexec 'import sys')"
[[ "$out" != *"$DEPTH_MSG"* && "$out" != *"$LIB_DEPTH_MSG"* ]] ||
  fail "lib exemption" "a file directly under scripts/lib/ was reported as uncollected:
$out"
ok "a file directly under scripts/lib/ stays exempt"

out="$(probe_run scripts/lib/sub/probe noexec)"
[[ "$out" == *"$LIB_DEPTH_MSG"* ]] ||
  fail "lib depth guard" "a nested file under scripts/lib/ was not reported:
$out"
ok "a nested directory under scripts/lib/ is reported"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-format-lint: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-format-lint: all checks passed"
