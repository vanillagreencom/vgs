#!/usr/bin/env bash
# Is this diff nothing but kendex render output?
#
# ONE reader of the changed-file set, answering the one question ci.yml asks:
# may the expensive tail of `ci-ok` stand down? A diff whose every path is
# `kendex refresh` output (.agents, .claude, .codex, .opencode, .cursor, .pi,
# opencode.json) skips the Go toolchain, the Go build/vet/race block, the
# pinned actionlint/shellcheck/ruff download, the workflow lint, the format and
# lint floor, the Qt install and the QML static smoke. Those trees are
# upstream's, tested in vanillagreencom/kendex. The cheap text checks still run
# over the whole tree, so the render keeps its integrity coverage.
#
# A SCRIPT, not inline workflow shell, because this decides whether required
# evidence is produced: scripts/test-classify-harness-only.sh drives it over
# real git history, the rename case included.
#
# Env (supplied by ci.yml's `ci-ok` job):
#   EVENT_NAME   github.event_name
#   PR_BASE_SHA  pull_request
#   PUSH_BEFORE  push
#   GITHUB_OUTPUT / RUNNER_TEMP
#
# Writes `harness_only=true|false`. Fail-closed everywhere: an unresolvable
# base, an empty diff and an unknown event all answer false, which runs
# everything.

set -euo pipefail
case "$EVENT_NAME" in
  pull_request) base="$PR_BASE_SHA" ;;
  merge_group) base="HEAD^1" ;;
  push) base="$PUSH_BEFORE" ;;
  *)
    echo "::warning::no diff base defined for event $EVENT_NAME; running every check"
    echo "harness_only=false" >>"$GITHUB_OUTPUT"
    exit 0
    ;;
esac

if [ -z "$base" ] || ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  echo "::warning::cannot resolve '$base' for event $EVENT_NAME; running every check"
  echo "harness_only=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

git diff --name-only --no-renames "$base...HEAD" >"$RUNNER_TEMP/changed.txt"
if [ ! -s "$RUNNER_TEMP/changed.txt" ]; then
  echo "::warning::empty diff against '$base'; running every check"
  echo "harness_only=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

harness_only=true
while IFS= read -r path; do
  case "$path" in
    .agents/* | .claude/* | .codex/* | .opencode/* | .cursor/* | .pi/* | opencode.json) continue ;;
  esac
  harness_only=false
  break
done <"$RUNNER_TEMP/changed.txt"

sed 's/^/changed: /' "$RUNNER_TEMP/changed.txt"
echo "harness_only=$harness_only"
echo "harness_only=$harness_only" >>"$GITHUB_OUTPUT"
