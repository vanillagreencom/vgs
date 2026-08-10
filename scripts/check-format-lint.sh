#!/usr/bin/env bash
# Formatter/lint floor for first-party code (VGS-110). One deterministic tool
# per surface, no style rewrites:
#
#   Go      gofmt -l     backend/ minus vendor/ — any listed file is a failure
#   Shell   shellcheck   scripts/*.sh, scripts/lib/*.sh, bash-shebang bin/ files,
#                        in ONE invocation so `source`d libraries are followed
#   Python  ruff check   scripts/, scripts/lib/ and the bin/ Python entrypoints
#                        and modules; rule floor lives in ruff.toml (F + E9)
#   JS      node --check per file — a syntax floor, dependency-free on purpose
#
# REQUIRE SEMANTICS THROUGHOUT (the qml-smoke.sh --require precedent): a
# missing tool FAILS this check instead of skipping it, because a silent skip
# is indistinguishable from a pass. An empty file set fails the same way — a
# pathspec that stops matching would otherwise switch a surface off silently.
# Findings are fixed at the source or carry a per-line disable with a reason;
# there is no baseline file and no severity downgrade here.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

status=0
fail() { printf 'check-format-lint: FAIL: %s\n' "$*" >&2; status=1; }

missing=0
for tool in git gofmt shellcheck ruff node; do
  command -v "$tool" >/dev/null 2>&1 && continue
  printf 'check-format-lint: FAIL: required tool `%s` is not installed — install it, do not skip (gofmt ships with go; ruff: uv tool install ruff)\n' "$tool" >&2
  missing=1
done
[[ "$missing" == 0 ]] || exit 1

# Tracked files only: git pathspecs are the discovery mechanism, so a new file
# is covered the moment it is added and scratch clutter never fails the check.
collect() {
  local -n into="$1"
  shift
  into=()
  local file
  while IFS= read -r -d '' file; do
    into+=("$file")
  done < <(git ls-files -z -- "$@")
}

# --- Go: gofmt over the non-vendored backend ---------------------------------
collect go_files 'backend/*.go' ':!backend/vendor'
if [[ ${#go_files[@]} -eq 0 ]]; then
  fail "no Go files matched backend/*.go — the pathspec is stale, not the tree clean"
else
  unformatted="$(gofmt -l "${go_files[@]}")"
  [[ -z "$unformatted" ]] || fail "gofmt -l wants to reformat (run gofmt -w on):
$unformatted"
fi

# --- Shell: shellcheck, shebang-detected under bin/ --------------------------
collect shell_files 'scripts/*.sh' 'scripts/lib/*.sh'
collect bin_files 'bin/*'
for file in "${bin_files[@]}"; do
  IFS= read -r shebang <"$file" || continue
  [[ "$shebang" == '#!'*bash* ]] && shell_files+=("$file")
done
if [[ ${#shell_files[@]} -eq 0 ]]; then
  fail "no shell files found — the scripts/*.sh pathspec is stale"
else
  shellcheck "${shell_files[@]}" || fail "shellcheck findings above: fix them, or add a per-line disable with a reason"
fi

# --- Python: ruff (rule floor in ruff.toml), shebang-detected under bin/ -----
collect py_files 'scripts/*.py' 'scripts/lib/*.py' 'bin/*.py'
for file in "${bin_files[@]}"; do
  IFS= read -r shebang <"$file" || continue
  [[ "$shebang" == '#!'*python* ]] && py_files+=("$file")
done
if [[ ${#py_files[@]} -eq 0 ]]; then
  fail "no Python files found — the scripts/*.py pathspec is stale"
else
  ruff check --no-cache "${py_files[@]}" || fail "ruff findings above: fix them, or add a targeted \`# noqa: <rule>\` with a reason"
fi

# --- JS: node --check, the syntax floor --------------------------------------
collect js_files 'scripts/*.js' 'scripts/lib/*.js'
if [[ ${#js_files[@]} -eq 0 ]]; then
  fail "no JS files found — the scripts/*.js pathspec is stale"
else
  for file in "${js_files[@]}"; do
    node --check "$file" || fail "JS syntax error in $file"
  done
fi

[[ "$status" == 0 ]] || exit "$status"
printf 'check-format-lint: ok (%d go, %d shell, %d python, %d js files)\n' \
  "${#go_files[@]}" "${#shell_files[@]}" "${#py_files[@]}" "${#js_files[@]}"
