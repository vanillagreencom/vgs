#!/usr/bin/env bash
# Formatter/lint floor for first-party code (VGS-110). One deterministic tool
# per surface, no style rewrites:
#
#   Go      gofmt -l     backend/ minus vendor/ — any listed file is a failure
#   Shell   shellcheck   scripts/*.sh, scripts/lib/*.sh, install.sh,
#                        uninstall.sh, packaging/*.sh, the packaging hooks
#                        (*.postinst has a shebang; the sourced *.install
#                        scriptlets carry an in-file shell= directive) and
#                        bash-shebang bin/ files. The lib files are covered
#                        because their
#                        pathspec lists them explicitly — that is what to
#                        preserve when editing; being inputs also lets the
#                        tool resolve `source` directives pointing at them.
#                        (A comment line must never START with the word
#                        "shellcheck": that shape is a directive and a
#                        malformed one is an SC1072 parse error.)
#   Python  ruff check   scripts/, scripts/lib/ and the bin/ Python
#                        entrypoints and modules (extensionless files are
#                        reached by shebang detection and passed explicitly);
#                        rule floor lives in ruff.toml (F + E9)
#   JS      node --check per file — a syntax floor, dependency-free on purpose
#
# REQUIRE SEMANTICS THROUGHOUT (the qml-smoke.sh --require precedent): a
# missing tool, a wrong tool version, a failed `git ls-files`, or an empty
# file set FAILS this check instead of skipping the surface, because a silent
# skip is indistinguishable from a pass. Findings are fixed at the source or
# carry a per-line disable with a reason; there is no baseline file and no
# severity downgrade here.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# Single source of truth for the version-sensitive tool pins: ci.yml extracts
# these exact assignments (sed on this file), so bumping a pin is a one-line
# edit here and CI follows. The local run REQUIRES exactly these versions:
# both tools add and retune checks across releases, and an unpinned local
# tool would let the local verdict drift from CI's.
# Deliberately unpinned: gofmt (ships with the Go toolchain, which go.mod and
# ci.yml's setup-go already pin) and node (its --check is a bare syntax floor,
# not a findings engine, so version drift cannot move the verdict).
SHELLCHECK_VERSION=0.11.0
RUFF_VERSION=0.16.2

status=0
fail() { printf 'check-format-lint: FAIL: %s\n' "$*" >&2; status=1; }

missing=0
for tool in git gofmt shellcheck ruff node; do
  command -v "$tool" >/dev/null 2>&1 && continue
  printf 'check-format-lint: FAIL: required tool %s is not installed — install it, do not skip (gofmt ships with go; ruff: uv tool install ruff)\n' "$tool" >&2
  missing=1
done
[[ "$missing" == 0 ]] || exit 1

shellcheck_actual="$(shellcheck --version | awk '/^version:/ {print $2}')"
if [[ "$shellcheck_actual" != "$SHELLCHECK_VERSION" ]]; then
  fail "shellcheck is $shellcheck_actual but the pin is $SHELLCHECK_VERSION — install the pinned version (release binary: github.com/koalaman/shellcheck) or bump SHELLCHECK_VERSION here"
fi
ruff_actual="$(ruff --version | awk '{print $2}')"
if [[ "$ruff_actual" != "$RUFF_VERSION" ]]; then
  fail "ruff is $ruff_actual but the pin is $RUFF_VERSION — install the pinned version (uv tool install ruff==$RUFF_VERSION) or bump RUFF_VERSION here"
fi
[[ "$status" == 0 ]] || exit 1

# Tracked files only: git pathspecs are the discovery mechanism, so a new file
# is covered the moment it is added and scratch clutter never fails the check.
# Collection goes through a temp file rather than process substitution so
# git's OWN exit status is checked: mapfile reports only its own status, and a
# git that emitted part of the listing and then died would otherwise pass a
# surface on a partial set.
list_tmp="$(mktemp)"
trap 'rm -f -- "$list_tmp"' EXIT

# Writes the NUL-delimited listing for the given pathspecs to $list_tmp.
# On git failure: FAIL, truncate the listing so no surface can consume a
# partial set, and return nonzero so the caller's mapfile is skipped.
list_files() {
  if ! git ls-files -z -- "$@" >"$list_tmp"; then
    : >"$list_tmp"
    fail "git ls-files failed for pathspecs: $* (its stderr is above; not running this surface on a partial listing)"
    return 1
  fi
}

# --- Go: gofmt over the non-vendored backend ---------------------------------
go_files=()
list_files 'backend/*.go' ':!backend/vendor' && mapfile -d '' -t go_files <"$list_tmp"
if [[ ${#go_files[@]} -eq 0 ]]; then
  fail "no Go files matched backend/*.go — stale pathspec or the git failure above, not a clean tree"
else
  unformatted="$(gofmt -l "${go_files[@]}")"
  [[ -z "$unformatted" ]] || fail "gofmt -l wants to reformat (run gofmt -w on):
$unformatted"
fi

# --- Shell and Python discovery under bin/ (shebang-routed) ------------------
bin_files=()
list_files 'bin/*' && mapfile -d '' -t bin_files <"$list_tmp"
if [[ ${#bin_files[@]} -eq 0 ]]; then
  fail "no files matched bin/* — stale pathspec or the git failure above; bin/ has dropped out of the shell and python surfaces"
fi

# --- Shell: shellcheck -------------------------------------------------------
shell_files=()
list_files 'scripts/*.sh' 'scripts/lib/*.sh' 'install.sh' 'uninstall.sh' 'packaging/*.sh' \
  'packaging/*.install' 'packaging/*.postinst' \
  && mapfile -d '' -t shell_files <"$list_tmp"
for file in "${bin_files[@]}"; do
  IFS= read -r shebang <"$file" || continue
  [[ "$shebang" == '#!'*bash* ]] && shell_files+=("$file")
done
if [[ ${#shell_files[@]} -eq 0 ]]; then
  fail "no shell files found — stale pathspecs or the git failure above"
else
  shellcheck "${shell_files[@]}" || fail "shellcheck findings above: fix them, or add a per-line disable with a reason"
fi

# --- Python: ruff (rule floor in ruff.toml) ----------------------------------
py_files=()
list_files 'scripts/*.py' 'scripts/lib/*.py' 'bin/*.py' && mapfile -d '' -t py_files <"$list_tmp"
for file in "${bin_files[@]}"; do
  IFS= read -r shebang <"$file" || continue
  [[ "$shebang" == '#!'*python* ]] && py_files+=("$file")
done
if [[ ${#py_files[@]} -eq 0 ]]; then
  fail "no Python files found — stale pathspecs or the git failure above"
else
  ruff check --no-cache "${py_files[@]}" || fail "ruff findings above: fix them, or add a targeted noqa with a reason"
fi

# --- JS: node --check, the syntax floor --------------------------------------
js_files=()
list_files 'scripts/*.js' 'scripts/lib/*.js' && mapfile -d '' -t js_files <"$list_tmp"
if [[ ${#js_files[@]} -eq 0 ]]; then
  fail "no JS files matched scripts/*.js — stale pathspec or the git failure above"
else
  for file in "${js_files[@]}"; do
    node --check "$file" || fail "JS syntax error in $file"
  done
fi

[[ "$status" == 0 ]] || exit "$status"
printf 'check-format-lint: ok (%d go, %d shell, %d python, %d js files)\n' \
  "${#go_files[@]}" "${#shell_files[@]}" "${#py_files[@]}" "${#js_files[@]}"
