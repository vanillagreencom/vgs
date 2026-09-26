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
# Fixed identities and dates make every fixture's trunk the same commit, so
# one trunk id names the base of every row.
# Resolve node before replacing HOME: a version-manager shim may need the
# developer's configuration, which does not belong in the test environment.
node_bin="$(node -e 'process.stdout.write(process.execPath)')"
base_env=(env -i PATH="$(dirname -- "$node_bin"):$PATH" HOME="$tmp/home" LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z)

failures=0
test_args=()
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
  out="$(cd -- "$dir" && "${base_env[@]}" $extra bash scripts/validate "${test_area:-repo}" "${test_args[@]}" 2>&1)" || status=$?
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

# A committed defect: the feature branch holds its own commit, so HEAD is
# ahead of the merge base and only a diff from the merge base sees the line.
d="$tmp/committed"; fresh "$d"; printf 'feature \n' >"$d/feature.txt"
"${base_env[@]}" git -C "$d" add feature.txt
"${base_env[@]}" git -C "$d" commit -q -m feature
if [[ "$("${base_env[@]}" git -C "$d" rev-parse HEAD)" != "$trunk" ]]; then ok "the committed fixture's HEAD is ahead of trunk"; else fail "the committed fixture's HEAD is trunk"; fi
row "trailing whitespace in a committed change on the branch fails" "$d" 1 "" \
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

# A suite whose name is a proper prefix of a listed one: the fixture's
# validate lists scripts/test-validate.sh, and scripts/test-validate is
# covered by no row.
d="$tmp/prefix"; fresh "$d"; printf 'true\n' >"$d/scripts/test-validate"
row "a scripts/test-* file whose name prefixes a listed suite is refused" "$d" 1 "" \
  "validate: refused: test-without-row=scripts/test-validate"

# Exercise the real manifest rows, including the static smoke fixtures. The
# checker controls run unchanged; this control proves validate includes the
# fixture tree, so removing that row makes the planted defect pass wrongly.
d="$tmp/smoke-fixtures"; fresh "$d"
cp -R "$repo/scripts/." "$d/scripts/"
cp -R "$repo/shell" "$repo/bin" "$d/"
test_area=manifests
row "the smoke fixtures pass the offline manifest area" "$d" 0 "" "validate: ok"
python3 - "$d/scripts/smoke/fixtures/plugins/acme.tick/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as source:
    manifest = json.load(source)
manifest["schemaVersion"] = 0
with open(path, "w") as target:
    json.dump(manifest, target)
PY
row "a broken smoke fixture manifest fails the offline manifest area" "$d" 1 "" \
  "validate: failed=smoke fixture manifests (exit 1)"

# Selection is checked through the command the caller will run. Expected
# plans name consumers independently of the dependency table under test.
repo_plan=$'whitespace_check\nrows_cover_tests'
heap_plan=$'python3 scripts/test-attribute-heap-profile.py\n'"$repo_plan"
dispatch_plan=$'node scripts/test-dispatch.js\npython3 scripts/check-plugin-boundary.py\n'"$repo_plan"
fixture_plan=$'node scripts/check-manifests.js --base scripts/smoke/fixtures/plugins\npython3 scripts/check-plugin-boundary.py --shell scripts/smoke/fixtures\n'"$repo_plan"$'\nscripts/test-validate.sh\nscripts/qml-smoke.sh'
smoke_plan="$repo_plan"$'\nscripts/qml-smoke.sh'
cases=(
  "docs|docs/architecture/overview.md|offline|$repo_plan"
  "heap|scripts/attribute-heap-profile.py|offline|$heap_plan"
  "suite|scripts/test-attribute-heap-profile.py|offline|$heap_plan"
  "dispatch|shell/Core/Dispatch.js|offline|$dispatch_plan"
  "fixture|scripts/smoke/fixtures/plugins/acme.contention/Background.qml|all|$fixture_plan"
  "smoke-row|scripts/smoke/rows/example.sh|all|$smoke_plan"
)
for spec in "${cases[@]}"; do
  name="${spec%%|*}"; rest="${spec#*|}"
  file="${rest%%|*}"; rest="${rest#*|}"
  area="${rest%%|*}"; wanted="${rest#*|}"
  d="$tmp/plan-$name"; fresh "$d"
  mkdir -p -- "$d/$(dirname -- "$file")"
  printf 'changed\n' >"$d/$file"
  for state in untracked staged committed deleted; do
    case "$state" in
      staged) "${base_env[@]}" git -C "$d" add -- "$file" ;;
      committed) "${base_env[@]}" git -C "$d" commit -q -m change ;;
      deleted)
        # Compare the deletion against a base that actually contains it.
        "${base_env[@]}" git -C "$d" update-ref refs/remotes/origin/trunk HEAD
        rm -- "${d:?}/$file" ;;
    esac
    status=0
    out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate "$area" --changed refs/remotes/origin/trunk --list 2>"$tmp/plan.err")" || status=$?
    if [[ $status == 0 && $out == "$wanted" ]]; then ok "$name selects its consumers when $state"; else fail "$name $state plan: $out"; fi
  done
done

d="$tmp/plan-rename"; fresh "$d"
mkdir -p "$d/shell/Core"
printf 'source\n' >"$d/shell/Core/Dispatch.js"
"${base_env[@]}" git -C "$d" add shell/Core/Dispatch.js
"${base_env[@]}" git -C "$d" commit -q -m source
"${base_env[@]}" git -C "$d" mv shell/Core/Dispatch.js README.md
if out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --changed HEAD --list 2>"$tmp/plan.err")" && [[ $out == "$dispatch_plan" ]]; then ok "a rename selects consumers of the removed source path"; else fail "rename omitted the old path's consumers: $out"; fi

d="$tmp/plan-shared"; fresh "$d"
printf 'changed\n' >"$d/scripts/qml-library.js"
out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --changed HEAD --list 2>"$tmp/plan.err")"
for consumer in 'node scripts/test-plugin-logic.js' 'node scripts/test-dispatch.js' 'node scripts/test-lifetime.js' 'node scripts/test-qml-library.js' 'node scripts/check-manifests.js' 'node scripts/test-check-manifests.js' 'scripts/test-vgsh.sh' 'python3 scripts/test-vgs-plugin.py' 'scripts/test-validate.sh'; do
  if grep -qxF "$consumer" <<<"$out"; then ok "shared loader selects $consumer"; else fail "shared loader omitted $consumer"; fi
done
if grep -qF 'heap-profile' <<<"$out"; then fail "shared loader selected unrelated heap tests"; else ok "shared loader omits unrelated heap tests"; fi

d="$tmp/plan-full"; fresh "$d"
full_plan="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --list 2>"$tmp/plan.err")"
for reason in unknown unreadable policy; do
  base=HEAD
  case "$reason" in
    unknown) printf 'new\n' >"$d/new-source.rs" ;;
    unreadable) rm -- "${d:?}/new-source.rs"; base=missing-ref ;;
    policy) printf '\n' >>"$d/scripts/validate" ;;
  esac
  if out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --changed "$base" --list 2>"$tmp/plan.err")" && [[ $out == "$full_plan" ]]; then ok "$reason input selects the full area"; else fail "$reason input omitted a suite: $out"; fi
done

# Exercise the real selected guard, then remove only its dependency edge.
# The policy mutation is committed into the fixture's base, so selection
# still judges the same changed source rather than its own policy edit.
d="$tmp/selected-guard"; fresh "$d"
cp -R "$repo/scripts/." "$d/scripts/"
cp -R "$repo/shell" "$repo/bin" "$d/"
"${base_env[@]}" git -C "$d" add -A
"${base_env[@]}" git -C "$d" commit -q -m fixture
printf 'import "../plugins/vgs.bar"\nQtObject {}\n' >"$d/shell/Core/Bad.qml"
test_area=offline
test_args=(--changed HEAD)
row "a changed core import runs and fails its boundary check" "$d" 1 "" \
  "validate: failed=plugin boundary (exit 1)"
python3 - "$d/scripts/validate" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
edge = 'plugin boundary|python3 scripts/check-plugin-boundary.py|shell/* bin/vgsh-scan'
assert source.count(edge) == 1
path.write_text(source.replace(edge, edge.replace('shell/* ', '')))
PY
"${base_env[@]}" git -C "$d" add scripts/validate
"${base_env[@]}" git -C "$d" commit -q -m control
row "removing the source dependency makes the planted defect escape" "$d" 0 "" "validate: ok"

d="$tmp/arguments"; fresh "$d"
argument_cases=(
  'missing|--changed|changed-base=missing-or-repeated'
  'empty|--changed|changed-base=missing-or-repeated'
  'dash-prefixed|--changed --list|changed-base=missing-or-repeated'
  'repeated|--changed HEAD --changed HEAD|changed-base=missing-or-repeated'
  'second-area|logic|extra-argument=logic'
)
for spec in "${argument_cases[@]}"; do
  IFS='|' read -r name arguments refusal <<<"$spec"
  read -r -a test_args <<<"$arguments"
  [[ $name == empty ]] && test_args+=("")
  row "invalid $name argument is refused" "$d" 2 "" "validate: refused: $refusal"
done

if [[ $failures -gt 0 ]]; then
  echo "test-validate: failed=$failures"
  exit 1
fi
echo "test-validate: ok"
