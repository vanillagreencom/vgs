#!/usr/bin/env bash
# Lint GitHub workflows and the shell code in their run blocks.
#
# Usage: scripts/check-workflows.sh [--allow-missing-tools]
#
# --allow-missing-tools: report a skip when required tools are absent.
# -h, --help: print this help.
#
# Requires actionlint and shellcheck on PATH.
# actionlint checks workflow syntax and job references.
# Embedded shell code is checked by shellcheck.
# Missing tools fail by default.
# Use default mode for CI and required validation.
# Workflow files belong in .github/workflows.
# Both .yml and .yaml files are checked.
# An empty workflow directory fails.
# Tool findings cause a nonzero exit.
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
# actionlint invokes shellcheck by name, so it must be available on PATH.
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
