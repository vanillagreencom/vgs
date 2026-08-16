#!/usr/bin/env bash
# Assert the tracked review-gate engine matches the vstack-managed copy.
#
# Why two copies exist, why the printed repair depends on which side is newer,
# and what each verdict means: scripts/lib/vendor-drift.sh, which holds the
# whole check. This file only names the engine.
#
#   scripts/check-review-gate-vendor.sh
#   scripts/check-review-gate-vendor.sh --allow-missing-source
#   scripts/check-review-gate-vendor.sh --confirm-mirror-is-newer
#   scripts/check-review-gate-vendor.sh --help
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/vendor-drift.sh
source "$repo_root/scripts/lib/vendor-drift.sh"

vendor_drift_main check-review-gate-vendor review-gate "$repo_root" "$@"
