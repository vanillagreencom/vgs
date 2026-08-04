#!/usr/bin/env bash
# Drive ci.yml's review-gate step over its states, from the SHIPPED YAML.
#
# The step checks out the BASE revision on purpose — never PR-controlled
# predicate code under a token that can post the status which opens the gate.
# The consequence is that the PR adopting the engine has a base without it, and
# the first version of the step died sourcing a file that was not there
# (observed on PR #62). The same condition recurs permanently: a PR whose base
# predates the vendor commit, or a vendored tree that is deleted or renamed.
#
# A gate whose failure mode has never been exercised is the defect VGS-42
# exists to remove, so this pins the behavior:
#
#   engine ABSENT   -> post `pending` with the bootstrap reason, exit 0. Never
#                      `failure` (that means "changes requested", a false
#                      verdict) and never a crash (which posts nothing at all —
#                      the one outcome that neither blocks nor informs).
#   engine PRESENT  -> the predicate's real verdict is posted.
#   merge_group     -> the required context lands on the group sha even when
#                      the engine is absent, so a queue entry cannot block on a
#                      context nothing produces.
#
# The step's text is EXTRACTED from .github/workflows/ci.yml rather than copied
# here: a test against a copy proves nothing about what CI runs.
set -uo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/ci.yml"
rerun_workflow="$repo_root/.github/workflows/approval-rerun.yml"

failures=0
note() { printf 'test-review-gate-step: %s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }

scratch="$(mktemp -d -t vgs-gate-step.XXXXXX)"
trap 'rm -rf -- "$scratch"' EXIT

# --- extract the step body from the shipped workflow ------------------------

extractor="$scratch/extract-step.py"
cat >"$extractor" <<'PY'
import sys, pathlib
workflow, out, wanted = sys.argv[1], sys.argv[2], sys.argv[3]
lines = pathlib.Path(workflow).read_text().splitlines()
start = None
for index, line in enumerate(lines):
    if line.strip() == f"- name: {wanted}":
        start = index
        break
if start is None:
    sys.exit(f"could not find the {wanted!r} step in {workflow}")
run = None
for index in range(start, len(lines)):
    if lines[index].strip() == "run: |":
        run = index + 1
        break
if run is None:
    sys.exit(f"the {wanted!r} step has no 'run: |' block")
indent = len(lines[run]) - len(lines[run].lstrip())
body = []
for line in lines[run:]:
    if line.strip() and (len(line) - len(line.lstrip())) < indent:
        break
    body.append(line[indent:] if len(line) >= indent else line)
pathlib.Path(out).write_text("\n".join(body).rstrip() + "\n")
PY

step="$scratch/gate-step.sh"
python3 "$extractor" "$workflow" "$step" "Evaluate and post the review gate"
[[ -s "$step" ]] || { bad "extracted an empty step body"; exit 1; }
# `shell: bash -e {0}` is what Actions runs the block under; reproduce it, or a
# crash-on-missing-file would silently "pass" here while failing in CI.
bash -n "$step" || { bad "the extracted step is not valid bash"; exit 1; }

# --- a gh that records calls and answers from fixtures ----------------------

bindir="$scratch/bin"
mkdir -p "$bindir"
cat >"$bindir/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
# Status posts: record the state/context/description the step asked for.
if [ "${1:-}" = "api" ] && [ "${2:-}" = "-X" ] && [ "${3:-}" = "POST" ]; then
  target="$4"; shift 4
  state=""; context=""; description=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -f) case "$2" in
            state=*) state="${2#state=}" ;;
            context=*) context="${2#context=}" ;;
            description=*) description="${2#description=}" ;;
          esac
          shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\t%s\t%s\t%s\n' "${target##*/}" "$state" "$context" "$description" >>"$GH_POSTS"
  exit 0
fi
# Reads the predicate makes, answered from the fixture directory.
case "$*" in
  *"/reviews"*)   cat "$FIXTURES/reviews.json" ;;
  *"/pulls/"*)    cat "$FIXTURES/pull.json" ;;
  *"/status"*)    cat "$FIXTURES/status.json" ;;
  *"check-runs"*) cat "$FIXTURES/checkruns.json" ;;
  *"/comments"*)  cat "$FIXTURES/comments.json" ;;
  *graphql*)      cat "$FIXTURES/threads.txt" ;;
  *) printf '{}\n' ;;
esac
SHIM
chmod +x "$bindir/gh"

fixtures="$scratch/fixtures"
mkdir -p "$fixtures"
write_fixtures() {
  printf '%s\n' "$1" >"$fixtures/reviews.json"
  printf '{"user":{"login":"author"},"head":{"sha":"deadbeefcafe"}}\n' >"$fixtures/pull.json"
  printf '{"statuses":[]}\n' >"$fixtures/status.json"
  printf '{"check_runs":[]}\n' >"$fixtures/checkruns.json"
  printf '[]\n' >"$fixtures/comments.json"
  printf '0\n' >"$fixtures/threads.txt"
}

run_step() {
  local workdir="$1" event="$2"
  : >"$scratch/posts"
  : >"$scratch/calls"
  (
    cd "$workdir" || exit 1
    PATH="$bindir:$PATH" \
    GH_CALLS="$scratch/calls" GH_POSTS="$scratch/posts" FIXTURES="$fixtures" \
    GH_TOKEN=fake GH_REPO=vanillagreencom/vgs PR_NUMBER=62 \
    HEAD_SHA=deadbeefcafe PR_AUTHOR=author EVENT_NAME="$event" \
    GITHUB_SHA=groupsha1234 RUN_URL=https://example.invalid/run \
    bash -e "$step"
  ) >"$scratch/out" 2>&1
}

posted() { cut -f2 <"$scratch/posts" | tr '\n' ',' ; }
posted_target() { cut -f1 <"$scratch/posts" | head -1; }
posted_desc() { cut -f4 <"$scratch/posts" | head -1; }
post_count() { grep -c . <"$scratch/posts" || true; }

# --- state 1: the engine is ABSENT from the checked-out (base) revision -----

absent="$scratch/base-without-engine"
mkdir -p "$absent"
run_step "$absent" pull_request
rc=$?
[[ "$rc" -eq 0 ]] && ok "engine absent: step exits 0" || bad "engine absent: exit $rc, wanted 0 (a crash posts nothing at all)"
[[ "$(post_count)" -eq 1 ]] && ok "engine absent: posts exactly one status" || bad "engine absent: posted $(post_count) status(es), wanted 1"
[[ "$(posted)" == "pending," ]] && ok "engine absent: state is pending" || bad "engine absent: posted '$(posted)', wanted pending"
[[ "$(posted_target)" == "deadbeefcafe" ]] && ok "engine absent: posts on the PR head" || bad "engine absent: posted on '$(posted_target)'"
if [[ -n "$(posted_desc)" ]]; then
  ok "engine absent: the status carries a reason (\"$(posted_desc)\")"
else
  bad "engine absent: posted an empty description, so the pending state explains nothing"
fi

# --- state 2: merge_group with the engine absent ----------------------------
# A queue entry must still get the required context, or it blocks forever on a
# context nothing produces.

run_step "$absent" merge_group
rc=$?
[[ "$rc" -eq 0 ]] && ok "merge_group, engine absent: step exits 0" || bad "merge_group, engine absent: exit $rc"
[[ "$(posted)" == "success," ]] && ok "merge_group, engine absent: posts success" || bad "merge_group, engine absent: posted '$(posted)', wanted success"
[[ "$(posted_target)" == "groupsha1234" ]] && ok "merge_group: posts on the group sha" || bad "merge_group: posted on '$(posted_target)', wanted the group sha"

# --- state 3: the engine is PRESENT, no review evidence ---------------------

present="$scratch/base-with-engine"
mkdir -p "$present"
cp -r "$repo_root/third_party" "$present/third_party"
cp "$repo_root/vstack.settings.toml" "$present/vstack.settings.toml"

write_fixtures '[]'
run_step "$present" pull_request
rc=$?
[[ "$rc" -eq 0 ]] && ok "engine present, no evidence: step exits 0" || bad "engine present, no evidence: exit $rc"
[[ "$(posted)" == "pending," ]] && ok "engine present, no evidence: real verdict is pending" || bad "engine present, no evidence: posted '$(posted)', wanted pending"
if grep -q "bootstrap\|base revision has no gate engine" <<<"$(posted_desc)"; then
  bad "engine present: still reported the bootstrap reason, so the predicate did not run"
else
  ok "engine present: the description comes from the predicate, not the bootstrap branch"
fi

# --- state 4: the engine is PRESENT, an approving review at the head --------

write_fixtures '[{"state":"APPROVED","commit_id":"deadbeefcafe","user":{"login":"a-reviewer"},"submitted_at":"2026-08-04T00:00:00Z"}]'
run_step "$present" pull_request
rc=$?
[[ "$rc" -eq 0 ]] && ok "engine present, approved at head: step exits 0" || bad "engine present, approved at head: exit $rc"
if [[ "$(posted)" == "success," ]]; then
  ok "engine present, approved at head: posts success"
else
  bad "engine present, approved at head: posted '$(posted)', wanted success"
  sed -n '1,20p' "$scratch/out" >&2
fi

# --- state 5: changes requested is the ONLY red path ------------------------

write_fixtures '[{"state":"CHANGES_REQUESTED","commit_id":"deadbeefcafe","user":{"login":"a-reviewer"},"submitted_at":"2026-08-04T00:00:00Z"}]'
run_step "$present" pull_request
[[ "$(posted)" == "failure," ]] && ok "engine present, changes requested: posts failure" || bad "engine present, changes requested: posted '$(posted)', wanted failure"

# --- state 6: approval-rerun.yml's bootstrap branch -------------------------
# The same default-branch condition, in the workflow that surfaces as a CHECK
# ON THE PR. A red check there says the PR is broken when the only fact is that
# the gate cannot be converged yet. Observed live on PR #62.

rerun_step="$scratch/rerun-step.sh"
python3 "$extractor" "$rerun_workflow" "$rerun_step" "Converge the review gate for the PR head"
if [[ -s "$rerun_step" ]] && bash -n "$rerun_step"; then
  : >"$scratch/posts"
  : >"$scratch/calls"
  (
    cd "$absent" || exit 1
    PATH="$bindir:$PATH" \
    GH_CALLS="$scratch/calls" GH_POSTS="$scratch/posts" FIXTURES="$fixtures" \
    GH_TOKEN=fake GH_REPO=vanillagreencom/vgs PR_NUMBER=62 \
    HEAD_SHA=deadbeefcafe PR_AUTHOR=author \
    bash -e "$rerun_step"
  ) >"$scratch/out" 2>&1
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "rerun, engine absent: exits 0 (no false red check on the PR)"
  else
    bad "rerun, engine absent: exit $rc — a red check claims the PR is broken when only the gate is unconvergeable"
  fi
  [[ "$(posted)" == "pending," ]] && ok "rerun, engine absent: posts pending" || bad "rerun, engine absent: posted '$(posted)', wanted pending"
  if grep -q '::notice::' "$scratch/out"; then
    ok "rerun, engine absent: says so in the log rather than passing silently"
  else
    bad "rerun, engine absent: exited 0 with no notice, which is a silent skip"
  fi
else
  bad "could not extract approval-rerun.yml's converge step"
fi

if [[ "$failures" -eq 0 ]]; then
  note "review-gate step: all states behave as specified"
  exit 0
fi
note "FAIL: $failures assertion(s) failed"
exit 1
