#!/usr/bin/env bash
# Drives .github/scripts/classify-harness-only.sh over real git history.
#
# This predicate decides whether the lanes that produce required evidence run,
# so its verdict is proven by EXECUTION rather than by reading the script: the
# rename case below was wrong once, silently, and no amount of looking at the
# `case` arms would have shown it — `git diff --name-only` reports only the
# POST-image path for a detected rename, so a product file moved into the
# render read as harness-only over a commit that deleted product code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFY="$ROOT/.github/scripts/classify-harness-only.sh"
[ -x "$CLASSIFY" ] || { echo "FAIL: $CLASSIFY is missing or not executable" >&2; exit 1; }

work="$(mktemp -d)"
export RUNNER_TEMP="$work/runner"
mkdir -p "$RUNNER_TEMP"
trap 'rm -rf "$work"' EXIT

cases=0
run_case() { # LABEL EVENT BASE HEAD EXPECT
  # HEAD is unused: this classifier diffs `<base>...HEAD` in the checkout it
  # runs in, so the case moves the work tree rather than passing a head sha.
  local label=$1 event=$2 base=$3 _head=$4 expect=$5 got
  export GITHUB_OUTPUT="$RUNNER_TEMP/out"
  : >"$GITHUB_OUTPUT"
  EVENT_NAME="$event" PR_BASE_SHA="$base" PUSH_BEFORE="$base" \
    "$CLASSIFY" >/dev/null 2>&1
  got="$(sed -n 's/^harness_only=//p' "$GITHUB_OUTPUT" | tail -1)"
  cases=$((cases + 1))
  if [ "$got" = "$expect" ]; then
    printf 'ok    %s -> %s\n' "$label" "$got"
  else
    printf 'FAIL  %s -> %s (want %s)\n' "$label" "${got:-<none>}" "$expect" >&2
    exit 1
  fi
}

repo="$work/repo"
mkdir -p "$repo"
cd "$repo"
git init -q .
git config user.email t@e.invalid
git config user.name t
mkdir -p src .agents/skills/x .claude/skills .codex .opencode/instructions .cursor/rules .pi/kendex
printf 'export const a = 1\n%s\n' "$(seq 1 40)" >src/app.ts
echo base >.agents/skills/x/SKILL.md
git add -A
git commit -qm base
BASE="$(git rev-parse HEAD)"

# Every render surface at once, one extension each: the pre-2026-08-26 shape
# let render markdown through while a hook shell or a JSON forced every lane.
echo render >.agents/skills/x/SKILL.md
printf 'exit 0\n' >.claude/skills/hook.sh
echo '{}' >.codex/hooks.json
echo note >.opencode/instructions/kendex.md
echo rule >.cursor/rules/rust.mdc
printf 'exit 0\n' >.pi/kendex/hook.sh
echo '{}' >opencode.json
git add -A
git commit -qm "render-only refresh"
RENDER="$(git rev-parse HEAD)"
run_case "render-only (pull_request)" pull_request "$BASE" "$RENDER" true
run_case "render-only (push)" push "$BASE" "$RENDER" true
run_case "render-only (merge_group)" merge_group HEAD^1 "$RENDER" true

echo more >>src/app.ts
echo more >>.agents/skills/x/SKILL.md
git add -A
git commit -qm mixed
MIXED="$(git rev-parse HEAD)"
run_case "mixed render + product" pull_request "$RENDER" "$MIXED" false

echo yet >>src/app.ts
git add -A
git commit -qm product
PRODUCT="$(git rev-parse HEAD)"
run_case "product-only" pull_request "$MIXED" "$PRODUCT" false

# THE RENAME CASES. Rename detection reports one path; both sides must count.
git mv src/app.ts .agents/skills/x/app.ts
git commit -qm "move a product file into the render"
INTO="$(git rev-parse HEAD)"
run_case "rename product -> render (pull_request)" pull_request "$PRODUCT" "$INTO" false
run_case "rename product -> render (merge_group)" merge_group HEAD^1 "$INTO" false

git mv .agents/skills/x/SKILL.md "src/moved-out.md"
git commit -qm "move a render file into product"
OUT="$(git rev-parse HEAD)"
run_case "rename render -> product" pull_request "$INTO" "$OUT" false

git mv .agents/skills/x/app.ts .agents/skills/x/app2.ts
git commit -qm "move inside the render"
INSIDE="$(git rev-parse HEAD)"
run_case "rename inside the render" pull_request "$OUT" "$INSIDE" true

# A path that only STARTS like a render root is ordinary product code.
echo x >.agentsfoo.ts
echo y >opencode.json.bak
git add -A
git commit -qm near-miss
NEAR="$(git rev-parse HEAD)"
run_case "near-miss paths (.agentsfoo.ts, opencode.json.bak)" pull_request "$INSIDE" "$NEAR" false

# Fail-closed: nothing unreadable, empty or unknown may answer true.
run_case "empty diff" pull_request "$NEAR" "$NEAR" false
run_case "unreadable base" pull_request 0000000000000000000000000000000000000000 "$NEAR" false
run_case "missing endpoints" pull_request "" "" false
run_case "unclassified event" schedule "$BASE" "$NEAR" false

printf 'classify-harness-only: %d case(s), all pass\n' "$cases"
