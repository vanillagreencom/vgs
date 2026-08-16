#!/usr/bin/env bash
# Assert the tracked review-gate engine matches the vstack-managed copy.
#
# WHY THERE ARE TWO COPIES. The engine has to be IN the repository: CI runs the
# predicate and the selftest from a plain checkout, which has no vstack and no
# shared skills mirror. The sibling repos track it at `.agents/skills/`, but VGS
# symlinks `.agents` wholesale into every worktree (project-skills/README.md),
# so a file tracked under that path reports as deleted in every worktree — git
# cannot stat through the symlinked directory. Tracking it there would leave a
# permanently dirty tree.
#
# So the tracked, CI-facing copy lives at third_party/review-gate/, and
# `vstack refresh` keeps maintaining .agents/skills/review-gate for agent
# discovery. This check is what stops the two from drifting: `vstack refresh`
# updates the mirror, and the next local validation run fails until the update
# is copied across and committed.
#
#   scripts/check-review-gate-vendor.sh
#   scripts/check-review-gate-vendor.sh --allow-missing-source
#       accept that the vstack copy is absent and the comparison did not happen
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
vendored="$repo_root/third_party/review-gate"
managed="$repo_root/.agents/skills/review-gate"

allow_missing=false
for arg in "$@"; do
  case "$arg" in
    --allow-missing-source) allow_missing=true ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-review-gate-vendor: unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$vendored" ]]; then
  echo "check-review-gate-vendor: FAIL: $vendored is missing; CI has nothing to run" >&2
  exit 1
fi

if [[ ! -d "$managed" ]]; then
  if [[ "$allow_missing" == true ]]; then
    echo "check-review-gate-vendor: skipped: no vstack copy at .agents/skills/review-gate, so drift was NOT checked"
    exit 0
  fi
  echo "check-review-gate-vendor: FAIL: no vstack copy at .agents/skills/review-gate" >&2
  echo "check-review-gate-vendor: run 'vstack add --skill review-gate', or pass" >&2
  echo "check-review-gate-vendor: --allow-missing-source to accept an unchecked vendor copy." >&2
  exit 1
fi

# .vstack-refreshed is vstack's own bookkeeping, not engine content.
if diff -r --exclude=.vstack-refreshed -- "$managed" "$vendored" >/dev/null 2>&1; then
  echo "check-review-gate-vendor: ok (third_party/review-gate matches the vstack copy)"
  exit 0
fi

echo "check-review-gate-vendor: FAIL: third_party/review-gate has drifted from the vstack copy" >&2
diff -r --exclude=.vstack-refreshed -- "$managed" "$vendored" >&2 || true
cat >&2 <<'EOF'
check-review-gate-vendor: after a `vstack refresh` that updates the engine, copy
check-review-gate-vendor: it across and commit the result:
check-review-gate-vendor:   rsync -a --delete --exclude=.vstack-refreshed \
check-review-gate-vendor:     .agents/skills/review-gate/ third_party/review-gate/
EOF
exit 1
