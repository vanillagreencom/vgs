#!/usr/bin/env bash
# Controls for the checks scripts/validate makes itself, run as
# `scripts/validate repo` in a scratch repository: a copy of the script and
# the kendex settings loader, a base branch `trunk` with its remote-tracking
# ref, and a feature branch on top. Each row plants one defect in a fresh
# copy and asserts the exit status and the keyed lines the script's header
# promises; one row plants nothing and passes.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
# One row removes a file's permission bits, which bind only a non-root uid;
# a run that could not measure it is not a pass.
if [[ $(id -u) == 0 ]]; then
  echo "test-validate: status=not-measured reason=euid-0"
  exit 77
fi
tmp="$(mktemp -d)"
trap 'chmod -R u+rwx -- "${tmp:?}" 2>/dev/null; rm -rf -- "${tmp:?}"' EXIT

# Every git and validate call runs with this environment and nothing else.
base_env=(env -i PATH="$PATH" HOME="$tmp/home" LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid)

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# A fresh scratch repository at $1: trunk holds the script, the loader, a
# settings file naming trunk as the base branch and one clean file;
# refs/remotes/origin/trunk points at it; HEAD is a feature branch on top.
fresh() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/.agents/skills/orch/scripts/lib"
  cp -- "$repo/scripts/validate" "$dir/scripts/validate"
  cp -- "$repo/.agents/skills/orch/scripts/lib/kendex-env.sh" "$dir/.agents/skills/orch/scripts/lib/kendex-env.sh"
  printf '[env]\nWORKTREE_DEFAULT_BRANCH = "trunk"\n' >"$dir/kendex.settings.toml"
  printf 'clean\n' >"$dir/clean.txt"
  "${base_env[@]}" git -C "$dir" init -q -b trunk
  "${base_env[@]}" git -C "$dir" add -A
  "${base_env[@]}" git -C "$dir" commit -q -m base
  "${base_env[@]}" git -C "$dir" update-ref refs/remotes/origin/trunk HEAD
  "${base_env[@]}" git -C "$dir" checkout -q -b feature
}

# row NAME DIR WANT_EXIT EXTRA_ENV LINE...: run `scripts/validate repo` in
# DIR under EXTRA_ENV (words of NAME=VALUE, or "") and assert its exit
# status and that each LINE is a whole line of its output.
row() {
  local name="$1" dir="$2" want_exit="$3" extra="$4" out status=0 line missing=""
  shift 4
  # shellcheck disable=SC2086
  out="$(cd -- "$dir" && "${base_env[@]}" $extra bash scripts/validate repo 2>&1)" || status=$?
  for line in "$@"; do
    grep -qxF -e "$line" <<<"$out" || missing+="[$line]"
  done
  if [[ $status == "$want_exit" && -z $missing ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit missing=$missing"; printf '%s\n' "$out" | sed 's/^/        /'; fi
}

d="$tmp/clean"; fresh "$d"
trunk="$("${base_env[@]}" git -C "$d" rev-parse refs/remotes/origin/trunk)"
row "a clean tree passes against the base the settings file names" "$d" 0 "" \
  "whitespace: base=$trunk" "validate: ok"

d="$tmp/tracked"; fresh "$d"; printf 'clean \n' >"$d/clean.txt"
row "trailing whitespace in a tracked change fails" "$d" 1 "" \
  "whitespace: findings scope=tracked" "whitespace: failed base=$trunk"

d="$tmp/quoted"; fresh "$d"; mkdir -p "$d/dé"; printf 'x \n' >"$d/dé/f.txt"
row "trailing whitespace in an untracked file whose name git quotes fails" "$d" 1 "" \
  "whitespace: findings scope=untracked path=dé/f.txt" "whitespace: failed base=$trunk"

d="$tmp/unreadable"; fresh "$d"; printf 'x\n' >"$d/locked.txt"; chmod 000 "$d/locked.txt"
row "an unreadable untracked file is an error, not a pass" "$d" 1 "" \
  "whitespace: unreadable scope=untracked path=locked.txt status=128" "whitespace: failed base=$trunk"

d="$tmp/no-base"; fresh "$d"
row "no resolvable base exits 77" "$d" 77 "WORKTREE_DEFAULT_BRANCH=absent" \
  "whitespace: status=not-measured reason=no-base missing=base-ref branch=absent remote-refs=0"

d="$tmp/orphan"; fresh "$d"; printf 'true\n' >"$d/scripts/test-orphan.sh"
row "a scripts/test-* file named by no row is refused" "$d" 1 "" \
  "validate: refused: test-without-row=scripts/test-orphan.sh"

if [[ $failures -gt 0 ]]; then
  echo "test-validate: failed=$failures"
  exit 1
fi
echo "test-validate: ok"
