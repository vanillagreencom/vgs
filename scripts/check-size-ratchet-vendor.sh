#!/usr/bin/env bash
# Assert the tracked size-ratchet engine matches the vstack-managed copy.
#
# Same two-copy situation, same direction hazard, and the same implementation as
# scripts/check-review-gate-vendor.sh: both are one call into
# scripts/lib/vendor-drift.sh, which holds the reasoning and the check.
#
#   scripts/check-size-ratchet-vendor.sh
#   scripts/check-size-ratchet-vendor.sh --allow-missing-source
#   scripts/check-size-ratchet-vendor.sh --confirm-mirror-is-newer
#   scripts/check-size-ratchet-vendor.sh --help
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/vendor-drift.sh
source "$repo_root/scripts/lib/vendor-drift.sh"

vendor_drift_main check-size-ratchet-vendor size-ratchet "$repo_root" "$@"
