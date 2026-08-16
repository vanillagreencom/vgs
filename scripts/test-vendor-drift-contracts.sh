#!/usr/bin/env bash
# Structural contracts the vendor drift libraries state about themselves
# (VGS-155). Every guard here READS the source; none drives the check — which is
# what separates this file from scripts/test-vendor-drift.sh (whole runs) and
# scripts/test-vendor-drift-evidence.sh (the parser and the reading).
#
# WHY THIS FILE EXISTS. Each of these replaced a paragraph that asserted the
# same rule in prose. Prose is believed; a guard bites. This change is its own
# argument: four guards across two review cycles turned out to be vacuous, and
# every time the failure was a stated rule taken on trust. So the rules about
# file shape — which half holds what, which way the dependency runs, that each
# library arms its own strict mode, that the parsed diff is pinned to one
# language — execute here, and the headers they came from now carry only what
# cannot be executed: why a decision was taken, and what it costs.
#
# Each was proven to fail with its behaviour removed before the paragraph it
# replaced was deleted.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

PROG=check-demo-vendor
ENGINE=demo-engine

# shellcheck source=scripts/lib/vendor-drift-test.sh
source "$repo_root/scripts/lib/vendor-drift-test.sh"

# ── contracts the libraries state about themselves ────────────────────────
# Everything below replaces a paragraph that used to ASSERT one of these in
# prose. A stated rule is believed; an executed one bites. Each was proven to
# fail with the behaviour removed before the paragraph was deleted.

# The two halves are a one-way dependency: the decision half sources the report
# half, and the report half calls nothing back, so there is no cycle to resolve
# at call time.
decision_fns="$(grep -oE '^vendor_drift_[a-z_]+\(\)' "$repo_root/scripts/lib/vendor-drift.sh" | tr -d '()')"
[[ -n "$decision_fns" ]] || fail "one-way dependency" "found no functions in the decision half to check"
back_calls=""
while IFS= read -r fn; do
  [[ -n "$fn" ]] || continue
  grep -nE "(^|[^_[:alnum:]])$fn([^_[:alnum:]]|$)" "$repo_root/scripts/lib/vendor-drift-report.sh" |
    grep -vE '^[0-9]+:[[:space:]]*#' | grep -q . && back_calls+="$fn "
done <<<"$decision_fns"
[[ -z "$back_calls" ]] ||
  fail "one-way dependency" "the report half reaches back into the decision half: $back_calls"
ok "the report half calls nothing the decision half defines"

# Every string the operator reads lives in the report half, so a reader looking
# for what is printed has one place to look.
main_body="$(sed -n '/^vendor_drift_main() {/,$p' "$repo_root/scripts/lib/vendor-drift.sh")"
[[ -n "$main_body" ]] || fail "no strings in the decision half" "vendor_drift_main was not found"
printf '%s' "$main_body" | grep -nE '^[[:space:]]*printf' |
  grep -q . && fail "no strings in the decision half" "vendor_drift_main prints directly instead of calling an emitter"
ok "vendor_drift_main returns status and prints nothing itself"

# Sourced files inherit the caller's options, so each states them: these
# functions read command output into variables and branch on it, and an unset
# variable or swallowed non-zero must abort rather than be classified.
for lib in vendor-drift.sh vendor-drift-report.sh vendor-drift-test.sh; do
  grep -qx 'set -euo pipefail' "$repo_root/scripts/lib/$lib" ||
    fail "strict mode" "scripts/lib/$lib does not set -euo pipefail"
done
ok "all three libraries declare strict mode rather than inheriting it by luck"

# ── the locale fix itself ─────────────────────────────────────────────────
# Asserted on the source, not behaviourally: no translated locale is guaranteed
# installed anywhere this suite runs, so a behavioural test would silently pass
# on a C-only machine. What the default arm above already guarantees is that a
# translated marker is SAFE; this pins that it is also CORRECT.
# Comments stripped before matching, exactly as flag_carriers does and for the
# same reason: with the whole file matched, the inverse control PASSED — leave a
# comment naming `LC_ALL=C diff -r -u`, change the real call, and this stayed
# green with the drift diff running under the ambient locale.
diff_invocation="$(grep -n 'diff -r -u' "$repo_root/scripts/lib/vendor-drift.sh" |
  grep -vE '^[0-9]+:[[:space:]]*#' || true)"
expect_contains "$diff_invocation" "LC_ALL=C diff -r -u" "locale pin"
ok "the drift diff runs under LC_ALL=C, so the markers stay in the parsed language"

if ((failures > 0)); then
  printf 'test-vendor-drift-contracts: FAIL (%d)\n' "$failures" >&2
  exit 1
fi
printf 'test-vendor-drift-contracts: ok\n'
