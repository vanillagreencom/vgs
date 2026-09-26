#!/usr/bin/env bash
# Lint tracked first-party source. Missing tools, unsupported versions, and empty file sets fail.
# Sourced libraries need explicit pathspecs because they can lack shebangs.
# A comment beginning with shellcheck is a directive, even when intended as prose.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# CI reads these version assignments. Local runs require the same versions.
# gofmt follows the Go toolchain; node provides syntax checks.
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

# Capture git output in a file so a partial listing cannot hide a failed git command.
# Process substitution does not expose the producer status to mapfile.
list_tmp="$(mktemp)"
trap 'rm -f -- "$list_tmp"' EXIT

# Write a NUL-delimited tracked-file listing. On failure, discard partial output and return nonzero.
list_files() {
  if ! git ls-files -z -- "$@" >"$list_tmp"; then
    : >"$list_tmp"
    fail "git ls-files failed for pathspecs: $* (its stderr is above; not running this surface on a partial listing)"
    return 1
  fi
}

# Classify worktree content because the executable check and linters read the worktree.
# The attr/ column declares policy; w/ reports detected content.
# Literal pathspecs prevent a filename with brackets from matching another file.
# An ambiguous or failed classification fails the check before the caller can exempt the file.
is_binary() {
  local eol worktree_eol
  if ! eol="$(git ls-files --eol -- ":(literal)$1")"; then
    fail "git ls-files --eol failed for $1, so whether it is a binary could not be determined"
    return 0
  fi
  if [[ -z "$eol" || "$eol" == *$'\n'* ]]; then
    fail "git ls-files --eol did not return exactly one entry for $1, so whether it is a binary could not be determined"
    return 0
  fi
  read -r _ worktree_eol _ <<<"$eol"
  [[ "$worktree_eol" == "w/-text" ]]
}


go_files=()
list_files 'backend/*.go' ':!backend/vendor' && mapfile -d '' -t go_files <"$list_tmp"
if [[ ${#go_files[@]} -eq 0 ]]; then
  fail "no Go files matched backend/*.go — stale pathspec or the git failure above, not a clean tree"
else
  unformatted="$(gofmt -l "${go_files[@]}")"
  [[ -z "$unformatted" ]] || fail "gofmt -l wants to reformat (run gofmt -w on):
$unformatted"
fi

# Shebang routing includes extensionless scripts.
# The glob pathspec stops at scripts/, leaving sourced libraries to their explicit pathspecs.
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

# New script directories need explicit routing. Bash case wildcards cross directory separators.
# Nested extensionless libraries need routing even though extension pathspecs can reach nested files.
scripts_all=()
list_files 'scripts/' && mapfile -d '' -t scripts_all <"$list_tmp"
for file in "${scripts_all[@]}"; do
  case "${file#scripts/}" in
    lib/*/*)
      fail "$file lives under a scripts/lib/ subdirectory this check does not route: the lib pathspecs below DO collect a nested file carrying a .sh/.py/.js extension (a git pathspec's * crosses /), but a nested extensionless file is in neither the pathspecs nor the shebang router. Add its directory to the pathspecs here in the same PR"
      ;;
    lib/*) continue ;;
    */*)
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
      # Any shebang not handled above has no assigned linter.
      fail "$file has an unrouted shebang ($shebang) — no linter claims it. Route it in this case statement, rewrite the shebang to one that is routed, or it is silently unlinted"
      ;;
    *)
      # Bash can execute text without a shebang through its ENOEXEC fallback.
      # The executable bit therefore requires lint coverage unless the file is binary.
      if [[ -x "$file" ]] && ! is_binary "$file"; then
        fail "$file is executable with no shebang — something runs it (bash falls back to ENOEXEC), so something must lint it. Give it a shebang this case statement routes, or drop the executable bit if nothing is meant to run it"
      fi
      # bin/*.py has an explicit importable-module pathspec. Shell and JS files need shebang routing.
      case "$file" in
        scripts/*.sh | scripts/*.py | scripts/*.js | bin/*.sh | bin/*.js)
          fail "$file has a language extension but no shebang routing it to a linter — give it one, or this file is silently unlinted"
          ;;
      esac
      ;;
  esac
done


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


py_files=()
list_files 'scripts/lib/*.py' 'bin/*.py' && mapfile -d '' -t py_files <"$list_tmp"
py_files+=("${shebang_python[@]}")
if [[ ${#py_files[@]} -eq 0 ]]; then
  fail "no Python files found — stale pathspecs or the git failure above"
else
  ruff check --no-cache "${py_files[@]}" || fail "ruff findings above: fix them, or add a targeted noqa with a reason"
fi


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
