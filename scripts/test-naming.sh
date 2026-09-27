#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

source scripts/check-naming.sh

fail() {
  printf 'test-naming: FAIL: %s\n' "$1" >&2
  exit 1
}

expect_failure() {
  local label="$1"
  local expected_status="$2"
  local expected_text="$3"
  shift 3
  local output status
  if output="$("$@" 2>&1)"; then
    fail "$label passed"
  else
    status=$?
  fi
  [[ "$status" == "$expected_status" ]] || fail "$label exited $status, expected $expected_status"
  [[ "$output" == *"$expected_text"* ]] || fail "$label did not report $expected_text"
}

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/compact/apps"
printf '%s\n' '{"name":"Aether","plugin":"aether.nvim"}' > "$fixture/compact/apps/vscode-theme.json"

compact="$(scan_curated_vscode_names "$fixture")" || fail "compact curated scan failed"
[[ "$compact" == *'vscode-theme.json:1:{"name":"Aether"'* ]] || fail "compact curated name was not scanned"
expect_failure "legacy curated name" 1 "Legacy upstream naming residue found" report_legacy_names "$compact"

printf '%s\n' '{"name":"VGS","plugin":"aether.nvim"}' > "$fixture/compact/apps/vscode-theme.json"
clean="$(scan_curated_vscode_names "$fixture")" || fail "clean curated scan failed"
[[ -z "$clean" ]] || fail "a third-party plugin reference was treated as a display name"
report_legacy_names "$clean" >/dev/null || fail "the clean inverse failed"

# shellcheck disable=SC2329  # main invokes this replacement indirectly
rg() {
  return 127
}
expect_failure "source scan error" 127 "source scan failed with exit 127" main

# shellcheck disable=SC2329  # main invokes this replacement indirectly
rg() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == '**/apps/vscode-theme.json' ]]; then
      return 2
    fi
  done
  command rg "$@"
}
expect_failure "curated scan error" 2 "curated VS Code name scan failed with exit 2" main
unset -f rg

main_output="$(scripts/check-naming.sh)" || fail "the repository naming scan failed"
[[ "$main_output" == *"No legacy upstream naming residue found."* ]] || fail "the clean repository verdict was missing"

printf 'test-naming: all checks passed\n'
