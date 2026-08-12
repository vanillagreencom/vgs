#!/usr/bin/env bash
# Assert the tracked size-ratchet engine matches the vstack-managed copy.
#
# Same two-copy situation as scripts/check-review-gate-vendor.sh, and for the
# same reason: CI runs the gate from a plain checkout, which has no vstack and
# no shared skills mirror, and a file tracked under the symlinked `.agents/`
# would report as deleted in every worktree. So the tracked, CI-facing copy
# lives at third_party/size-ratchet/, `vstack refresh` keeps maintaining
# .agents/skills/size-ratchet for agent discovery, and this check stops the
# two from drifting.
#
#   scripts/check-size-ratchet-vendor.sh
#   scripts/check-size-ratchet-vendor.sh --allow-missing-source
#       accept that the vstack copy is absent and the comparison did not happen
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
vendored="$repo_root/third_party/size-ratchet"
managed="$repo_root/.agents/skills/size-ratchet"

allow_missing=false
for arg in "$@"; do
  case "$arg" in
    --allow-missing-source) allow_missing=true ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-size-ratchet-vendor: unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$vendored" ]]; then
  echo "check-size-ratchet-vendor: FAIL: $vendored is missing; CI has nothing to run" >&2
  exit 1
fi

if [[ ! -d "$managed" ]]; then
  if [[ "$allow_missing" == true ]]; then
    echo "check-size-ratchet-vendor: skipped: no vstack copy at .agents/skills/size-ratchet, so drift was NOT checked"
    exit 0
  fi
  echo "check-size-ratchet-vendor: FAIL: no vstack copy at .agents/skills/size-ratchet" >&2
  echo "check-size-ratchet-vendor: run 'vstack add --skill size-ratchet', or pass" >&2
  echo "check-size-ratchet-vendor: --allow-missing-source to accept an unchecked vendor copy." >&2
  exit 1
fi

# .vstack-refreshed is vstack's own bookkeeping, not engine content.
if diff -r --exclude=.vstack-refreshed -- "$managed" "$vendored" >/dev/null 2>&1; then
  echo "check-size-ratchet-vendor: ok (third_party/size-ratchet matches the vstack copy)"
  exit 0
fi

echo "check-size-ratchet-vendor: FAIL: third_party/size-ratchet has drifted from the vstack copy" >&2
diff -r --exclude=.vstack-refreshed -- "$managed" "$vendored" >&2 || true
cat >&2 <<'EOF'
check-size-ratchet-vendor: after a `vstack refresh` that updates the engine, copy
check-size-ratchet-vendor: it across and commit the result:
check-size-ratchet-vendor:   rsync -a --delete --exclude=.vstack-refreshed \
check-size-ratchet-vendor:     .agents/skills/size-ratchet/ third_party/size-ratchet/
EOF
exit 1
