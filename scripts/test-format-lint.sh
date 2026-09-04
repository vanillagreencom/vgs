#!/usr/bin/env bash
# Test routing in an isolated Git repository because discovery uses tracked files.
# The fixture lacks unrelated source areas and can fail for those; assert the specific routing diagnostic.
# Executable text without a shebang can still run through Bash ENOEXEC fallback.
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
# Binary exemptions must exclude both executable-text and unable-to-classify diagnostics.
# Classification failure suppresses the first message, so its absence alone cannot prove exemption.
UNDETERMINED_MSG="could not be determined"

# Plant tracked probes by path, mode, and first line. Binary probes contain NUL bytes and are executable
# so they exercise content classification rather than the non-executable exemption.
# Separate setup and execution permit filenames that interact in one fixture.
fixture="$tmp/repo"
probe_init() {
  rm -rf "$fixture"
  mkdir -p "$fixture/scripts" "$fixture/bin"
  git -C "$fixture" init -q
  cp "$repo_root/scripts/check-format-lint.sh" "$fixture/scripts/"
  chmod +x "$fixture/scripts/check-format-lint.sh"
}
probe_add() {
  local rel="$1" mode="$2" first="${3:-echo probe}"
  mkdir -p "$(dirname -- "$fixture/$rel")"
  if [[ "$mode" == binary ]]; then
    printf '\177ELF\000\000\000\000probe\n' >"$fixture/$rel"
    chmod +x "$fixture/$rel"
  else
    printf '%s\n' "$first" >"$fixture/$rel"
    if [[ "$mode" == exec ]]; then chmod +x "$fixture/$rel"; else chmod -x "$fixture/$rel"; fi
  fi
}
probe_check() {
  git -C "$fixture" add -A
  (cd "$fixture" && ./scripts/check-format-lint.sh) 2>&1 || true
}
probe_run() {
  probe_init
  probe_add "$@"
  probe_check
}

# Require evidence that the router ran; a missing diagnostic after preamble failure proves nothing.
out="$(probe_run scripts/probe-exec exec)"
if [[ "$out" != *"$EXEC_MSG"* && "$out" != *"$EXT_MSG"* && "$out" != *"no Go files matched"* ]]; then
  fail "fixture reaches the router" "the fixture check produced none of its own messages — it probably died in the tool preamble:
$out"
fi
ok "the fixture repo reaches the discovery loop"


[[ "$out" == *"$EXEC_MSG"* ]] ||
  fail "executable no-shebang" "an extensionless executable with no shebang was not reported:
$out"
ok "an extensionless executable with no shebang fails closed"


out="$(probe_run scripts/probe-data noexec)"
[[ "$out" != *"$EXEC_MSG"* ]] ||
  fail "non-executable fixture" "a non-executable extensionless fixture was reported as unlinted:
$out"
ok "a non-executable extensionless fixture still passes"

# The extension rule must still catch non-executable shell scripts without shebang routing.
out="$(probe_run scripts/probe-data.sh noexec)"
[[ "$out" == *"$EXT_MSG"* ]] ||
  fail "extension arm" "a non-executable .sh with no shebang was not reported:
$out"
ok "a non-executable .sh with no shebang still fails on the extension arm"

# bin shell and JS files lack importable-module pathspecs, so their language extensions require routing.
for probe in bin/probe-data.sh bin/probe-data.js; do
  out="$(probe_run "$probe" noexec)"
  [[ "$out" == *"$EXT_MSG"* ]] ||
    fail "extension arm under bin" "a non-executable shebang-less $probe was not reported:
$out"
done
ok "a non-executable shebang-less bin/*.sh or bin/*.js is reported"

# bin Python modules have an explicit ruff pathspec and must not be reported as unclaimed.
out="$(probe_run bin/probe_module.py noexec 'import sys')"
[[ "$out" != *"$EXT_MSG"* ]] ||
  fail "bin python extension" "a shebang-less bin/*.py module was reported by the extension arm:
$out"
ok "a shebang-less bin/*.py module is still exempt: the ruff pathspec lints it"

UNROUTED_MSG="has an unrouted shebang"

# Unrouted shebangs must fail under both bin and scripts.
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

# Non-executable importable modules can legitimately lack a shebang.
out="$(probe_run bin/vshell_module.py noexec 'import sys')"
[[ "$out" != *"$UNROUTED_MSG"* && "$out" != *"$EXEC_MSG"* ]] ||
  fail "bin module" "a shebang-less bin/ Python module was reported:
$out"
ok "a shebang-less bin/ Python module still passes"

# Use an extensionless executable so the extension arm cannot satisfy the no-shebang control.
out="$(probe_run bin/probe-exec exec)"
[[ "$out" == *"$EXEC_MSG"* ]] ||
  fail "executable no-shebang under bin" "an executable shebang-less bin/ file was not reported:
$out"
ok "an executable shebang-less bin/ file fails closed"

# Executable binaries need an exemption because source linters cannot parse them.
out="$(probe_run bin/probe-binary binary)"
[[ "$out" != *"$EXEC_MSG"* ]] ||
  fail "binary exemption" "a tracked binary under bin/ was reported as unlinted:
$out"
[[ "$out" != *"$UNDETERMINED_MSG"* ]] ||
  fail "binary exemption" "the binary was not classified at all, so its silence is not an exemption:
$out"
ok "a tracked binary under bin/ is exempt from the executable-bit rule"

# A bracketed filename must not inherit binary classification from another path matched as a pattern.
# Both files must exist in the same fixture to exercise that interaction.
probe_init
probe_add 'bin/probe1' binary
probe_add 'bin/probe[1]' exec
out="$(probe_check)"
[[ "$out" == *"bin/probe[1] $EXEC_MSG"* ]] ||
  fail "pathspec magic" "an executable shebang-less bin/probe[1] was exempted by a neighbouring binary:
$out"
[[ "$out" != *"bin/probe1 $EXEC_MSG"* ]] ||
  fail "pathspec magic" "the binary bin/probe1 was reported:
$out"
[[ "$out" != *"$UNDETERMINED_MSG"* ]] ||
  fail "pathspec magic" "a probe was not classified at all, so the exemption is not what was observed:
$out"
ok "a glob-shaped filename cannot borrow a neighbouring binary's exemption"

# Check the same text file alone to distinguish filename interaction from ordinary classification.
out="$(probe_run 'bin/probe[1]' exec)"
[[ "$out" == *"bin/probe[1] $EXEC_MSG"* ]] ||
  fail "pathspec magic control" "the same file alone was not reported:
$out"
ok "a glob-shaped filename is reported on its own"

# Stage binary content, then replace only the worktree content. Exemption must follow what runs.
probe_init
probe_add bin/swap binary
git -C "$fixture" add -A
printf 'echo hi\n' >"$fixture/bin/swap"
chmod +x "$fixture/bin/swap"
out="$( (cd "$fixture" && ./scripts/check-format-lint.sh) 2>&1 || true)"
[[ "$out" == *"bin/swap $EXEC_MSG"* ]] ||
  fail "worktree column" "a text script staged as a binary was exempted on its index blob:
$out"
ok "the binary exemption reads the worktree, not the index"

# The w/ column reports content independently of the attr/ text policy.
# Test both text refusal and binary exemption under the same attribute.
probe_init
probe_add bin/attributed exec
printf 'bin/** -text\n' >"$fixture/.gitattributes"
out="$(probe_check)"
[[ "$out" == *"bin/attributed $EXEC_MSG"* ]] ||
  fail "gitattributes -text" "an executable shebang-less text file under a -text attribute was exempted:
$out"
ok "a -text attribute cannot buy a text file the binary exemption"


probe_init
probe_add bin/probe-binary binary
printf 'bin/** -text\n' >"$fixture/.gitattributes"
out="$(probe_check)"
[[ "$out" != *"bin/probe-binary $EXEC_MSG"* ]] ||
  fail "gitattributes -text" "a real binary under a -text attribute was reported as unlinted:
$out"
[[ "$out" != *"$UNDETERMINED_MSG"* ]] ||
  fail "gitattributes -text" "the binary was not classified at all, so this proves nothing about the attribute:
$out"
ok "a real binary stays exempt whatever .gitattributes says"

# These fixtures do not inject git failures or ambiguous --eol results, so those refusal paths remain uncovered.

DEPTH_MSG="lives under a scripts/ subdirectory this check does not collect"
LIB_DEPTH_MSG="lives under a scripts/lib/ subdirectory this check does not route"

# Test deeper paths because Bash case wildcards cross directory separators.
# A later switch to pathname matching must not silently narrow coverage.
for probe in scripts/sub/probe scripts/a/b/probe; do
  out="$(probe_run "$probe" noexec)"
  [[ "$out" == *"$DEPTH_MSG"* ]] ||
    fail "scripts depth guard" "$probe was not reported as uncollected:
$out"
done
ok "a file under a scripts/ subdirectory is reported at any depth"

# Nested extensionless libraries are outside extension pathspecs and need explicit routing.
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
