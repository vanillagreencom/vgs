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

SUITES=(test-vendor-drift.sh test-vendor-drift-evidence.sh test-vendor-drift-contracts.sh)

# ── every library pointer resolves, and every one of them is covered ──────
# The library headers stopped describing their rules and started pointing at the
# suites that execute them, which trades one kind of rot for another: a pointer
# is a claim too, and one was wrong within minutes of being written.
#
# WHY THE ROWS ARE ENUMERATED AND NOT LISTED. The first version of this control
# was a hand-maintained table, and it did not cover every pointer — because in
# the SAME commit that added it I added a fourth pointer and never wrote its
# row, while believing the class was closed. A reviewer found it by mutation,
# not by reading. A table you must remember to extend is the prose problem
# wearing a test's clothes, so the pointers are enumerated from source and a
# pointer without a row FAILS here. Do not "simplify" this back into a list.
POINTER_ANCHORS="the contract controls in|one fixture per ignore arm"
POINTER_ANCHORS="$POINTER_ANCHORS|decision-table rows of|driven by stubs in"

# Rows are `anchor|suite|marker`, and are excluded from every grep below by that
# shape — the marker names itself here, so a file holding the table would
# otherwise always match its own row. That self-match made one row inert once.
ROW_SHAPE='\|test-vendor-drift[a-z-]*\.sh\|'

pointer_lines="$(grep -hE 'scripts/test-vendor-drift[a-z-]*\.sh' \
  "$repo_root/scripts/lib/vendor-drift.sh" "$repo_root/scripts/lib/vendor-drift-report.sh" || true)"
[[ -n "$pointer_lines" ]] || fail "header pointers" "no library header names a suite at all"

# Every suite a pointer names must exist.
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  [[ -f "$repo_root/$ref" ]] || fail "header pointers" "a library header names $ref, which does not exist"
done < <(printf '%s\n' "$pointer_lines" | grep -ohE 'scripts/test-vendor-drift[a-z-]*\.sh' | sort -u)

# Every pointer must be covered by a row. This is the half that stops the next
# pointer arriving uncovered.
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  printf '%s' "$line" | grep -qE "$POINTER_ANCHORS" ||
    fail "header pointers" "this library pointer has no row here, so nothing checks it: $line"
done <<<"$pointer_lines"

# And every row must describe a pointer that exists, name the suite that pointer
# names, and that suite must hold the guard — and hold it alone.
while IFS='|' read -r anchor suite marker; do
  [[ -n "$anchor" ]] || continue
  matched="$(printf '%s\n' "$pointer_lines" | grep -F -- "$anchor" || true)"
  [[ -n "$matched" ]] || fail "header pointers" "no library pointer matches the row anchored at: $anchor"
  printf '%s' "$matched" | grep -qF -- "scripts/$suite" ||
    fail "header pointers" "the pointer anchored at '$anchor' does not name scripts/$suite, where its guard lives"
  grep -F -- "$marker" "$repo_root/scripts/$suite" | grep -qvE "$ROW_SHAPE" ||
    fail "header pointers" "scripts/$suite does not hold the guard that pointer describes: $marker"
  for other in "${SUITES[@]}"; do
    [[ "$other" == "$suite" ]] && continue
    grep -F -- "$marker" "$repo_root/scripts/$other" | grep -qvE "$ROW_SHAPE" &&
      fail "header pointers" "the guard $marker is in scripts/$other too, so the pointer is ambiguous"
  done
done <<TABLE
the contract controls in|test-vendor-drift-contracts.sh|the report half calls nothing the decision half defines
one fixture per ignore arm|test-vendor-drift-evidence.sh|every ignore arm attributes its line
decision-table rows of|test-vendor-drift-evidence.sh|a decided reading implies its own strict ordering
driven by stubs in|test-vendor-drift-evidence.sh|a probe answering anything but false is read as shallow
TABLE
ok "every library pointer is covered by a row, names the suite holding its guard, and that suite holds it alone"

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
