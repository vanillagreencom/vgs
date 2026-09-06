#!/usr/bin/env bash
# Test routing in an isolated Git repository, because discovery reads tracked files.
# Executable text without a shebang can still run through the Bash ENOEXEC fallback.
# The fixture repository has no Go, Python or JS surfaces and fails the tool preamble for
# that unrelated reason, so probe_check swallows the status and the router's own diagnostic
# is the only channel a row can read. Every row therefore pins a message, and every row
# first requires evidence that the run reached the discovery loop: absence of a diagnostic
# in a run that died early proves nothing.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

failures=0
case_failed=0
out=""
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

# Each router verdict as its own format string; %s is the reported path. The binary
# classification failure names the path mid-sentence, so it carries no placeholder:
# classification failure suppresses the executable-bit message, and its absence alone
# cannot prove an exemption.
declare -A MESSAGES=(
  [exec]='%s is executable with no shebang'
  [ext]='%s has a language extension but no shebang'
  [unrouted]='%s has an unrouted shebang'
  [depth]='%s lives under a scripts/ subdirectory this check does not collect'
  [lib-depth]='%s lives under a scripts/lib/ subdirectory this check does not route'
  [undetermined]='could not be determined'
)
ROUTER_RAN="no Go files matched backend/*.go"

# Plant tracked probes by path, mode, and first line. Binary probes contain NUL bytes and are
# executable so they exercise content classification rather than the non-executable exemption.
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
# Run the check as it stands. A case whose index must disagree with the worktree calls this
# directly: staging again would erase the divergence it exists to exercise.
probe_execute() {
  out="$( (cd "$fixture" && ./scripts/check-format-lint.sh) 2>&1 || true)"
}
probe_check() {
  git -C "$fixture" add -A
  probe_execute
}
probe_run() {
  probe_init
  probe_add "$@"
  probe_check
}

# Require evidence that the run reached the collection loop the router sits in.
assert_router_ran() {
  [[ "$out" == *"$ROUTER_RAN"* ]] ||
    fail "$1" "the fixture check produced none of its own messages — it died in the tool preamble:
$out"
}

expect_message() { # reported path, message key, present|absent
  local rel="$1" key="$2" want="$3" text
  if [[ -z "${MESSAGES[$key]+set}" ]]; then
    fail "$rel" "no router message named $key"
    return
  fi
  # shellcheck disable=SC2059  # the message table holds the format string; %s is the path
  text="$(printf "${MESSAGES[$key]}" "$rel")"
  if [[ "$want" == present ]]; then
    [[ "$out" == *"$text"* ]] || fail "$rel" "the router did not report: $text
$out"
  else
    [[ "$out" != *"$text"* ]] || fail "$rel" "the router reported what it must not: $text
$out"
  fi
}

expect_messages() { # reported path, comma-separated keys or -, present|absent
  local rel="$1" keys="$2" want="$3" key
  local -a list
  [[ "$keys" != - ]] || return 0
  IFS=',' read -r -a list <<<"$keys"
  for key in "${list[@]}"; do
    expect_message "$rel" "$key" "$want"
  done
}

# path; mode; first line or - for the default; messages required; messages forbidden.
# Deeper paths matter because Bash case wildcards cross directory separators: a later switch
# to pathname matching must not silently narrow coverage.
PROBES='scripts/probe-exec;exec;-;exec;-
scripts/probe-data;noexec;-;-;exec
scripts/probe-data.sh;noexec;-;ext;-
bin/probe-data.sh;noexec;-;ext;-
bin/probe-data.js;noexec;-;ext;-
bin/probe_module.py;noexec;import sys;-;ext,unrouted,exec
scripts/probe-sh;exec;#!/bin/sh;unrouted;-
scripts/probe-zsh;exec;#!/usr/bin/env zsh;unrouted;-
bin/probe-sh;exec;#!/bin/sh;unrouted;-
bin/probe-zsh;exec;#!/usr/bin/env zsh;unrouted;-
bin/probe-exec;exec;-;exec;-
bin/probe-binary;binary;-;-;exec,undetermined
bin/probe[1];exec;-;exec;-
scripts/sub/probe;noexec;-;depth;-
scripts/a/b/probe;noexec;-;depth;-
scripts/lib/probe.py;noexec;import sys;-;depth,lib-depth
scripts/lib/sub/probe;noexec;-;lib-depth;-'

case_probes() {
  local rel mode first present absent rows=0
  while IFS=';' read -r rel mode first present absent; do
    [[ -n "$rel" ]] || continue
    rows=$((rows + 1))
    [[ "$first" != - ]] || first='echo probe'
    probe_run "$rel" "$mode" "$first"
    assert_router_ran "$rel"
    expect_messages "$rel" "$present" present
    expect_messages "$rel" "$absent" absent
  done <<<"$PROBES"
  [[ $rows -eq 17 ]] || fail "probes" "expected 17 table rows, drove $rows"
  ok "each tracked path is routed, exempted or reported as unlinted"
}

case_pathspec_magic() {
  # A bracketed filename must not inherit binary classification from another path matched as
  # a pattern. Both files must exist in the same fixture to exercise that interaction.
  probe_init
  probe_add 'bin/probe1' binary
  probe_add 'bin/probe[1]' exec
  probe_check
  assert_router_ran 'bin/probe[1]'
  expect_message 'bin/probe[1]' exec present
  expect_message 'bin/probe1' exec absent
  expect_message 'bin/probe1' undetermined absent
  ok "a glob-shaped filename cannot borrow a neighbouring binary's exemption"
}

case_worktree_column() {
  # Stage binary content, then replace only the worktree content. The exemption must follow
  # what runs, not what the index holds.
  probe_init
  probe_add bin/swap binary
  git -C "$fixture" add -A
  printf 'echo hi\n' >"$fixture/bin/swap"
  chmod +x "$fixture/bin/swap"
  probe_execute
  assert_router_ran bin/swap
  expect_message bin/swap exec present
  ok "the binary exemption reads the worktree, not the index"
}

case_text_attribute_on_text() {
  # The w/ column reports content independently of the attr/ text policy.
  probe_init
  probe_add bin/attributed exec
  printf 'bin/** -text\n' >"$fixture/.gitattributes"
  probe_check
  assert_router_ran bin/attributed
  expect_message bin/attributed exec present
  ok "a -text attribute cannot buy a text file the binary exemption"
}

case_text_attribute_on_binary() {
  probe_init
  probe_add bin/probe-binary binary
  printf 'bin/** -text\n' >"$fixture/.gitattributes"
  probe_check
  assert_router_ran bin/probe-binary
  expect_message bin/probe-binary exec absent
  expect_message bin/probe-binary undetermined absent
  ok "a real binary stays exempt whatever .gitattributes says"
}

# These fixtures inject no git failure and no ambiguous --eol result, so those refusal paths
# remain uncovered.
CASES=(
  case_probes
  case_pathspec_magic
  case_worktree_column
  case_text_attribute_on_text
  case_text_attribute_on_binary
)
for lint_case in "${CASES[@]}"; do
  "$lint_case"
done

if [[ $failures -ne 0 ]]; then
  printf '\ntest-format-lint: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-format-lint: all checks passed"
