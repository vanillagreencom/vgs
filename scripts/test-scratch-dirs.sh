#!/usr/bin/env bash
# The scratch-directory guard at the top of the suites that remove their
# scratch directory on exit: scripts/vgsh-rows.sh (sourced by every
# scripts/test-vgsh*.sh) and the three suites below that use mktemp. A
# stub mktemp first on PATH answers each way a failed or wrong mktemp can,
# and each subject runs from a disposable caller directory inside this
# suite's scratch. Each case pins exit 1 and the first stderr line, and
# requires the caller directory, its sentinel and any file mktemp named to
# survive. The subjects are a fixed list: the other scratch-directory makers
# under scripts/ assign `mktemp -d` alone, and some of them start a sandbox,
# so they are not run here.
#
# The control at the end plants the old `cd "$(mktemp -d)"` shape in a copy
# of scripts/vgsh-rows.sh and requires the failing-mktemp case to go red,
# which it does by deleting the disposable caller directory.
#
# Exit 0 when every case and the control hold, 1 otherwise.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"

tmp="$repo/tmp/test-scratch-dirs-$$"
rm -rf -- "$tmp"
mkdir -p -- "$tmp" || { echo "test-scratch-dirs: scratch=mkdir-failed" >&2; exit 1; }
[[ -d $tmp && ! -L $tmp ]] || { echo "test-scratch-dirs: scratch=not-a-directory value=[$tmp]" >&2; exit 1; }
tmp="$(cd -- "$tmp" && pwd -P)"
trap 'rm -rf -- "${tmp:?}"' EXIT
failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# A regular file for the stub to name as the directory it made.
regular="$tmp/regular-file"
echo keep >"$regular"

# Stub answers: name | stub body | the refusal key the guard must print.
# `failed-dot` exits 1 but prints `.`, which the old shape resolved to the
# caller's directory on every bash version.
stubs=(
  "failed-dot|printf '.\\n'; exit 1|scratch=mktemp-failed"
  "failed-empty|exit 1|scratch=mktemp-failed"
  "empty|exit 0|scratch=not-a-directory"
  "regular-file|printf '%s\\n' '$regular'; exit 0|scratch=not-a-directory"
)
for entry in "${stubs[@]}"; do
  IFS='|' read -r name body _ <<<"$entry"
  mkdir -p "$tmp/stub-$name"
  printf '#!/bin/sh\n%s\n' "$body" >"$tmp/stub-$name/mktemp"
  chmod +x "$tmp/stub-$name/mktemp"
done

# Subjects: label | the script bash runs | its arguments. The library is
# sourced by a driver named test-scratch-driver, the name its refusals take.
subjects=(
  "vgsh-rows.sh|-c|source \"\$1\"|test-scratch-driver|$repo/scripts/vgsh-rows.sh"
  "test-launcher-file-search.sh|$repo/scripts/test-launcher-file-search.sh"
  "test-sandbox-shots.sh|$repo/scripts/test-sandbox-shots.sh"
  "test-smoke-verdict.sh|$repo/scripts/test-smoke-verdict.sh"
)

# run PREFIX STUB KEY BASH_ARGS...: run bash BASH_ARGS from a fresh caller
# directory with the stub first on PATH. Returns 0 when it exited 1 with
# `PREFIX: KEY` first on stderr and left the caller, its sentinel and the
# regular file in place; otherwise 1, with what broke in `problems`.
cases=0
problems=()
run() {
  local prefix="$1" stub="$2" key="$3" caller status=0 first
  shift 3
  cases=$((cases + 1))
  caller="$tmp/case-$cases/caller"
  mkdir -p "$caller"
  echo keep >"$caller/sentinel"
  (cd -- "$caller" && env -i PATH="$tmp/stub-$stub:$PATH" HOME="$tmp/home" TMPDIR="$tmp" \
    timeout 60 bash "$@" >"$tmp/out" 2>"$tmp/err") || status=$?
  problems=()
  if ! first="$(head -n 1 -- "$tmp/err")"; then
    problems+=("stderr=unreadable")
  fi
  [[ $status -eq 1 ]] || problems+=("exit=$status")
  [[ $first == "$prefix: $key"* ]] || problems+=("stderr=[$first]")
  [[ -f $caller/sentinel ]] || problems+=("caller=removed")
  [[ -f $regular ]] || { problems+=("regular-file=removed"); echo keep >"$regular"; }
  [[ ${#problems[@]} -eq 0 ]]
}

for subject in "${subjects[@]}"; do
  IFS='|' read -r -a args <<<"$subject"
  label="${args[0]}"
  args=("${args[@]:1}")
  if [[ $label == vgsh-rows.sh ]]; then prefix=test-scratch-driver; else prefix="${label%.sh}"; fi
  for entry in "${stubs[@]}"; do
    IFS='|' read -r name _ key <<<"$entry"
    if run "$prefix" "$name" "$key" "${args[@]}"; then
      ok "$label with mktemp $name refuses and keeps the caller"
    else
      fail "$label with mktemp $name: ${problems[*]}"
    fi
  done
done

# Control: the old shape in a copy of the library. The substitution must
# match exactly once and change the copy.
guard='tmp="$(mktemp -d)" || { echo "$(basename -- "$0" .sh): scratch=mktemp-failed" >&2; exit 1; }
[[ -d $tmp && ! -L $tmp ]] || { echo "$(basename -- "$0" .sh): scratch=not-a-directory value=[$tmp]" >&2; exit 1; }
tmp="$(cd -- "$tmp" && pwd -P)"'
old='tmp="$(cd -- "$(mktemp -d)" && pwd -P)"'
if ! text="$(cat -- "$repo/scripts/vgsh-rows.sh")"; then
  fail "control: scripts/vgsh-rows.sh is unreadable"
elif rest="${text#*"$guard"}"; [[ $rest == "$text" || $rest == *"$guard"* ]]; then
  fail "control: the guard block is not in scripts/vgsh-rows.sh exactly once"
else
  mkdir -p "$tmp/mutant/scripts"
  printf '%s\n' "${text/"$guard"/"$old"}" >"$tmp/mutant/scripts/vgsh-rows.sh"
  if run test-scratch-driver failed-dot scratch=mktemp-failed \
    -c 'source "$1"' test-scratch-driver "$tmp/mutant/scripts/vgsh-rows.sh"; then
    fail "control: the old shape in a copy of vgsh-rows.sh kept the caller"
  elif [[ " ${problems[*]} " != *" caller=removed "* ]]; then
    fail "control: the old shape went red without removing the caller: ${problems[*]}"
  else
    ok "control: the old shape in a copy of vgsh-rows.sh removes the caller"
  fi
fi

if [[ $failures -gt 0 ]]; then
  echo "test-scratch-dirs: failures=$failures"
  exit 1
fi
echo "test-scratch-dirs: ok"
