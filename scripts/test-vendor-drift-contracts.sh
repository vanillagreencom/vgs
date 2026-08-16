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

# EVERY STRING THE OPERATOR READS LIVES IN THE REPORT HALF: vendor_drift_main
# returns status and emits nothing itself. Enforced against the emitters rather
# than against one spelling of them — an earlier version anchored `printf` to
# the start of a line, which a plain `echo`, and a `printf` after `if true; then`
# on the same line, both walked straight past. Comments are stripped first, the
# way the locale pin below does, so a mention is not a violation.
#
# Scoped to this ONE function on purpose: the other decision-half functions
# printf their RETURN VALUES, so a blanket ban would flag those.
main_body="$(sed -n '/^vendor_drift_main() {/,$p' "$repo_root/scripts/lib/vendor-drift.sh" |
  grep -vE '^[[:space:]]*#')"
[[ -n "$main_body" ]] || fail "no strings in the decision half" "vendor_drift_main was not found"
emitted="$(printf '%s\n' "$main_body" |
  grep -nE '(^|[^[:alnum:]_])(printf|echo)([^[:alnum:]_]|$)|<<-?['\''\"]?[A-Za-z_]' || true)"
[[ -z "$emitted" ]] ||
  fail "no strings in the decision half" "vendor_drift_main emits directly instead of calling an emitter: $emitted"
ok "vendor_drift_main returns status and prints nothing itself"

# Sourced files inherit the caller's options, so each states them: these
# functions read command output into variables and branch on it, and an unset
# variable or swallowed non-zero must abort rather than be classified.
for lib in vendor-drift.sh vendor-drift-report.sh vendor-drift-test.sh; do
  grep -qx 'set -euo pipefail' "$repo_root/scripts/lib/$lib" ||
    fail "strict mode" "scripts/lib/$lib does not set -euo pipefail"
done
ok "all three libraries declare strict mode rather than inheriting it by luck"

# ── every pointer from a library header resolves, and resolves HERE ───────
# The library headers stopped describing their rules and started pointing at the
# suites that execute them, which trades one kind of rot for another: a pointer
# is a claim too. One was wrong within minutes of being written — it named the
# evidence suite for controls that live in this file — and a reader who follows
# a bad pointer finds neither the description nor the control, concludes the
# rule is unenforced, and restates it as prose. That is the round undone.
SUITES=(test-vendor-drift.sh test-vendor-drift-evidence.sh test-vendor-drift-contracts.sh)

# Every suite a library header names must exist.
named="$(grep -ohE 'scripts/test-vendor-drift[a-z-]*\.sh' "$repo_root"/scripts/lib/vendor-drift*.sh | sort -u)"
[[ -n "$named" ]] || fail "header pointers" "no library header names a suite at all"
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  [[ -f "$repo_root/$ref" ]] || fail "header pointers" "a library header names $ref, which does not exist"
done <<<"$named"

# And the guard each pointer describes must be in the suite it names — not in a
# sibling, which is the exact shape of the bug this replaces.
while IFS='|' read -r library suite marker; do
  [[ -n "$library" ]] || continue
  grep -qF -- "scripts/$suite" "$repo_root/scripts/lib/$library" ||
    fail "header pointers" "$library does not name scripts/$suite, where its guard lives"
  grep -qF -- "$marker" "$repo_root/scripts/$suite" ||
    fail "header pointers" "scripts/$suite does not hold the guard $library points at: $marker"
  for other in "${SUITES[@]}"; do
    [[ "$other" == "$suite" ]] && continue
    # The table below names every marker, so its own rows are excluded by their
    # shape — otherwise this file reports itself as a duplicate holder.
    grep -F -- "$marker" "$repo_root/scripts/$other" | grep -qvE '^[a-z-]+\.sh\|' &&
      fail "header pointers" "the guard $marker is in scripts/$other too, so the pointer is ambiguous"
  done
done <<TABLE
vendor-drift.sh|test-vendor-drift-contracts.sh|the report half calls nothing the decision half defines
vendor-drift.sh|test-vendor-drift-evidence.sh|every ignore arm attributes its line
vendor-drift.sh|test-vendor-drift-evidence.sh|a decided reading implies its own strict ordering
TABLE
ok "every suite a library header names exists and holds the guard described, not a sibling"

# ── the locale fix itself ─────────────────────────────────────────────────
# Asserted on the source, not behaviourally: no translated locale is guaranteed
# installed anywhere this suite runs, so a behavioural test would silently pass
# on a C-only machine. What the classifier's default arm guarantees — pinned in
# scripts/test-vendor-drift-evidence.sh, not above — is that a translated marker
# is SAFE; this pins that it is also CORRECT.
# Comments stripped before matching, exactly as flag_carriers does and for the
# same reason: with the whole file matched, the inverse control PASSED — leave a
# comment naming `LC_ALL=C diff -r -u`, change the real call, and this stayed
# green with the drift diff running under the ambient locale.
diff_invocation="$(grep -n 'diff -r -u' "$repo_root/scripts/lib/vendor-drift.sh" |
  grep -vE '^[0-9]+:[[:space:]]*#' || true)"
expect_contains "$diff_invocation" "LC_ALL=C diff -r -u" "locale pin"
ok "the drift diff runs under LC_ALL=C, so the markers stay in the parsed language"

# ── no automated caller may assert the direction ──────────────────────────
# --confirm-mirror-is-newer is an operator assertion: a manifest row or CI step
# carrying it would make the destructive command unconditional again.
callers=()
while IFS= read -r caller; do callers+=("$caller"); done < <(vendor_drift_caller_surfaces)
# A discovery that finds nothing must fail: a renamed directory would otherwise
# leave a carrier outside the swept set with this green.
((${#callers[@]} > 0)) || fail "no automated caller" "the caller enumeration found no surfaces at all"
for known in scripts/validate scripts/check-review-gate-vendor.sh .github/workflows/ci.yml; do
  printf '%s\n' "${callers[@]}" | grep -qxF "$repo_root/$known" ||
    fail "no automated caller" "the enumeration missed a known caller surface: $known"
done
carriers="$(flag_carriers "${callers[@]}")"
[[ -z "$carriers" ]] ||
  fail "no automated caller" "these tracked callers pass $CONFIRM_FLAG: $carriers"
# A carrier is planted in each surface class in turn and swept by the REAL
# enumeration, proving the sweep reaches that class rather than that grep
# matches a string. Planting happens in a THROWAWAY repository: the live one is
# read and never written, so concurrent runs cannot collide and no failure can
# leave the destructive flag at a tracked-looking path.
planted_root="$(new_caller_fixture caller-surfaces)"
for surface in scripts/planted-caller.sh .github/workflows/planted.yml .github/workflows/planted.yaml; do
  printf '#!/usr/bin/env bash\nscripts/check-review-gate-vendor.sh %s\n' "$CONFIRM_FLAG" \
    >"$planted_root/$surface"
  # Guarded: a broken index must report, not abort the suite mid-run.
  git -C "$planted_root" add -N -- "$surface" >/dev/null 2>&1 ||
    fail "no automated caller" "could not stage a planted carrier at $surface"
  planted_surfaces=()
  while IFS= read -r one; do planted_surfaces+=("$one"); done \
    < <(vendor_drift_caller_surfaces "$planted_root")
  planted="$(flag_carriers "${planted_surfaces[@]}")"
  git -C "$planted_root" rm -q --cached -- "$surface" >/dev/null 2>&1 || true
  rm -f "$planted_root/$surface"
  [[ "$planted" == *"$surface"* ]] ||
    fail "no automated caller" "the sweep did not reach a planted carrier at $surface"
done
ok "no tracked caller asserts the direction, and the search that says so can fail"

if ((failures > 0)); then
  printf 'test-vendor-drift-contracts: FAIL (%d)\n' "$failures" >&2
  exit 1
fi
printf 'test-vendor-drift-contracts: ok\n'
