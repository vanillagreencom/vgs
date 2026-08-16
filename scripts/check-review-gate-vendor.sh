#!/usr/bin/env bash
# Assert the tracked review-gate engine matches the vstack-managed copy.
#
# This file only names the engine. The check is split across two libraries:
# scripts/lib/vendor-drift.sh holds the evidence, the decision, and why there
# are two copies at all; scripts/lib/vendor-drift-report.sh holds what the
# check may print and the rule governing the destructive repair. Run this
# script with --help for the options.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/vendor-drift.sh
source "$repo_root/scripts/lib/vendor-drift.sh"

vendor_drift_main check-review-gate-vendor review-gate "$repo_root" "$@"
