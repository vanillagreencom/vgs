#!/usr/bin/env bash
# Formatter/lint floor for first-party code (VGS-110). One deterministic tool
# per surface, no style rewrites:
#
#   Go      gofmt -l     backend/ minus vendor/ — any listed file is a failure
#   Shell   shellcheck   bash-shebang files under scripts/ and bin/ (routed by
#                        shebang, so an extensionless entry point like
#                        scripts/validate is covered without being named),
#                        scripts/lib/*.sh, install.sh,
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
#   Python  ruff check   python-shebang files under scripts/ and bin/, plus
#                        scripts/lib/*.py and bin/*.py (the importable modules
#                        that carry no shebang by design);
#                        rule floor lives in ruff.toml (F + E9)
#   JS      node --check node-shebang files under scripts/, plus
#                        scripts/lib/*.js — a syntax floor, dependency-free
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

# --- Shell, Python and JS discovery by SHEBANG (bin/ and scripts/) -----------
# Extension globs cannot see an extensionless entry point, and naming each one
# by hand is coverage that lasts until the next one is added and forgotten —
# `scripts/validate` was added that way and would have been the only such file
# anyone remembered. bin/ was already discovered by shebang; scripts/ now is
# too, and a file there whose extension claims a language but whose shebang
# does not route it FAILS rather than dropping out silently.
#
# `:(glob)` is load-bearing: a plain `scripts/*` pathspec matches across `/`,
# swallowing scripts/lib/, which is listed separately below because those are
# libraries (sourced or imported, some without a shebang at all).
bin_files=()
list_files 'bin/*' && mapfile -d '' -t bin_files <"$list_tmp"
if [[ ${#bin_files[@]} -eq 0 ]]; then
  fail "no files matched bin/* — stale pathspec or the git failure above; bin/ has dropped out of the shell and python surfaces"
fi

script_files=()
list_files ':(glob)scripts/*' && mapfile -d '' -t script_files <"$list_tmp"
if [[ ${#script_files[@]} -eq 0 ]]; then
  fail "no files matched scripts/* — stale pathspec or the git failure above; scripts/ has dropped out of every lint surface"
fi

# `:(glob)scripts/*` stops at the top level and scripts/lib/ is listed by hand
# below, so a NEW subdirectory would never be collected, never enter the router,
# and therefore never trip the unrouted arm either — a quiet coverage drop
# instead of a decision. Naming the known depth here makes adding one a
# conscious edit.
scripts_all=()
list_files 'scripts/' && mapfile -d '' -t scripts_all <"$list_tmp"
for file in "${scripts_all[@]}"; do
  case "$file" in
    scripts/lib/*) continue ;;
    scripts/*/*)
      fail "$file lives under a scripts/ subdirectory this check does not collect (only scripts/* and scripts/lib/* are). Add its directory to the pathspecs here in the same PR, or it is silently unlinted"
      ;;
  esac
done

shebang_shell=()
shebang_python=()
shebang_js=()
for file in "${bin_files[@]}" "${script_files[@]}"; do
  shebang=""
  IFS= read -r shebang <"$file" || true
  case "$shebang" in
    '#!'*bash*) shebang_shell+=("$file") ;;
    '#!'*python*) shebang_python+=("$file") ;;
    '#!'*node*) shebang_js+=("$file") ;;
    '#!'*)
      # A SHEBANG THE CASES ABOVE DID NOT ROUTE — `#!/bin/sh`, `#!/usr/bin/env
      # zsh`, perl, ruby. Asserting on the shebang rather than on the extension
      # is the point. scripts/validate (`#!/usr/bin/env bash`) went unlinted
      # because it carries no EXTENSION, which shebang routing now covers; an
      # extension test is blind to the same file arriving with `#!/bin/sh`, so
      # this arm names it instead of dropping it. A file with NO shebang keeps
      # falling through, which is what leaves data fixtures alone.
      case "$file" in
        scripts/*)
          fail "$file has an unrouted shebang ($shebang) — no linter claims it. Route it in this case statement, rewrite the shebang to one that is routed, or it is silently unlinted"
          ;;
      esac
      ;;
    *)
      # No shebang at all. Only scripts/ is asserted here: bin/ deliberately
      # holds importable Python modules with no shebang (bin/vshell_niri.py and
      # friends), which is documented in AGENTS.md and is not a lint gap.
      case "$file" in
        scripts/*.sh | scripts/*.py | scripts/*.js)
          fail "$file has a language extension but no shebang routing it to a linter — give it one, or this file is silently unlinted"
          ;;
      esac
      ;;
  esac
done

# --- Shell: shellcheck -------------------------------------------------------
shell_files=()
list_files 'scripts/lib/*.sh' 'install.sh' 'uninstall.sh' \
  'packaging/*.sh' 'packaging/*.install' 'packaging/*.postinst' \
  && mapfile -d '' -t shell_files <"$list_tmp"
shell_files+=("${shebang_shell[@]}")
if [[ ${#shell_files[@]} -eq 0 ]]; then
  fail "no shell files found — stale pathspecs or the git failure above"
else
  shellcheck "${shell_files[@]}" || fail "shellcheck findings above: fix them, or add a per-line disable with a reason"
fi

# --- Python: ruff (rule floor in ruff.toml) ----------------------------------
py_files=()
list_files 'scripts/lib/*.py' 'bin/*.py' && mapfile -d '' -t py_files <"$list_tmp"
py_files+=("${shebang_python[@]}")
if [[ ${#py_files[@]} -eq 0 ]]; then
  fail "no Python files found — stale pathspecs or the git failure above"
else
  ruff check --no-cache "${py_files[@]}" || fail "ruff findings above: fix them, or add a targeted noqa with a reason"
fi

# --- JS: node --check, the syntax floor --------------------------------------
js_files=()
list_files 'scripts/lib/*.js' && mapfile -d '' -t js_files <"$list_tmp"
js_files+=("${shebang_js[@]}")
if [[ ${#js_files[@]} -eq 0 ]]; then
  fail "no JS files found — stale pathspecs or the git failure above"
else
  for file in "${js_files[@]}"; do
    node --check "$file" || fail "JS syntax error in $file"
  done
fi

[[ "$status" == 0 ]] || exit "$status"
printf 'check-format-lint: ok (%d go, %d shell, %d python, %d js files)\n' \
  "${#go_files[@]}" "${#shell_files[@]}" "${#py_files[@]}" "${#js_files[@]}"
