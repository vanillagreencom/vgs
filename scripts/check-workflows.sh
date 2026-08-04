#!/usr/bin/env bash
# Lint .github/workflows, INCLUDING the shell inside every `run:` block.
#
# actionlint lints `run:` blocks by shelling out to shellcheck. With shellcheck
# absent it skips every shell block, reports nothing about the omission, and
# exits 0 — so "actionlint clean" on a workflow full of inline bash can mean
# only "the YAML parsed". That false green was produced by the very tool used to
# validate the workflow whose purpose is to stop checks passing without checking
# (VGS-38).
#
# So this wrapper applies the house rule from qml-smoke.sh's --require-static: a
# check that cannot run must FAIL, not skip. Missing tooling is an error here,
# never a quiet degradation.
#
#   scripts/check-workflows.sh          fail if actionlint or shellcheck is absent
#   scripts/check-workflows.sh --allow-missing-tools
#                                       report the absence and skip; for a
#                                       developer machine that has neither, never
#                                       for CI or an automated run
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_dir="$repo_root/.github/workflows"

allow_missing=false
for arg in "$@"; do
  case "$arg" in
    --allow-missing-tools) allow_missing=true ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-workflows: unknown option: $arg" >&2; exit 2 ;;
  esac
done

note() { printf 'check-workflows: %s\n' "$*"; }
fail() { printf 'check-workflows: FAIL: %s\n' "$*" >&2; }

missing=()
command -v actionlint >/dev/null 2>&1 || missing+=("actionlint")
# actionlint invokes shellcheck by name; a shellcheck on PATH is the only thing
# that makes its `run:` linting real.
command -v shellcheck >/dev/null 2>&1 || missing+=("shellcheck")

if [[ ${#missing[@]} -gt 0 ]]; then
  if [[ "$allow_missing" == true ]]; then
    note "skipped: ${missing[*]} not installed, so run: blocks were NOT linted"
    exit 0
  fi
  fail "${missing[*]} not installed"
  cat >&2 <<'EOF'
check-workflows: both are required. actionlint alone silently skips every `run:`
check-workflows: block when shellcheck is absent and still exits 0, so a pass
check-workflows: would prove only that the YAML parsed.
check-workflows:   Arch:   pacman -S actionlint shellcheck
check-workflows:   Ubuntu: apt-get install shellcheck  (actionlint: go install
check-workflows:           github.com/rhysd/actionlint/cmd/actionlint@latest)
check-workflows: Pass --allow-missing-tools only on a machine where you accept
check-workflows: that the workflows went unchecked.
EOF
  exit 1
fi

mapfile -t workflows < <(find "$workflow_dir" -maxdepth 1 -name '*.yml' -o -maxdepth 1 -name '*.yaml' | sort)
if [[ ${#workflows[@]} -eq 0 ]]; then
  fail "no workflows found under $workflow_dir"
  exit 1
fi

actionlint "${workflows[@]}"
note "ok (${#workflows[@]} workflows, run: blocks linted by shellcheck $(shellcheck --version | awk '/^version:/ {print $2}'))"
