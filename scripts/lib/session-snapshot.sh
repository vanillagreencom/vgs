#!/usr/bin/env bash
# Shared live-session snapshots for validation safety checks.
#
# Sourced by scripts/qml-smoke.sh and scripts/check-validation-safety.sh so both
# judge "did validation disturb the live session?" the same way.
#
# Each snapshot prints its data on stdout and reports how it went:
#   0  collected
#   1  collection failed (the caller must not read an empty result as "clean")
#   2  nothing to collect here (no compositor session)
#
# Requires: $repo_root

# Fail at source time with a named cause when the sourcing script forgot to set
# repo_root, instead of at first use with a bare command-not-found.
repo_root="${repo_root:?scripts/lib/session-snapshot.sh: sourcing script must set repo_root first}"

# One line per live VGS Quickshell instance: "<pid> <configPath>".
vgs_snapshot_instances() {
  local report rc=0
  # stderr is deliberately not suppressed: it is the only diagnostic behind an
  # "unverified session" verdict.
  report="$("$repo_root/bin/vshell" instances list --json)" || rc=$?
  # 2 == quickshell is not installed, so there is no registry here at all.
  [[ "$rc" == 2 ]] && return 2
  [[ "$rc" == 0 && -n "$report" ]] || return 1
  printf '%s' "$report" | python3 -c 'import json,sys
report = json.load(sys.stdin)
if not report.get("ok"):
    sys.exit(1)
for entry in sorted(report.get("instances", []), key=lambda item: item["pid"]):
    print(entry["pid"], entry["configPath"])'
}

# One line per live VGS layer surface: "<monitor>\t<namespace>". Repeats are
# meaningful — a duplicate shell shows up as a second surface with the same
# namespace on the same monitor.
#
# Hyprland only: Niri exposes no equivalent layer listing, so on Niri this half
# of the proof reports "nothing to collect" and the instance comparison carries
# the check on its own.
vgs_snapshot_layers() {
  local layers
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || return 2
  command -v hyprctl >/dev/null 2>&1 || return 2
  layers="$(hyprctl layers -j 2>/dev/null)" || return 1
  [[ -n "$layers" ]] || return 1
  printf '%s' "$layers" | python3 -c 'import json,sys
data = json.load(sys.stdin)
rows = []
for monitor, payload in data.items():
    for level in (payload.get("levels") or {}).values():
        for layer in level:
            namespace = layer.get("namespace") or ""
            if namespace.startswith("vshell:"):
                rows.append(f"{monitor}\t{namespace}")
print("\n".join(sorted(rows)))'
}

# Surfaces come and go while the live shell runs: a popout opening or closing
# mid-check is normal, and so is the shell raising its own fade-to-lock overlay
# when the seat goes idle. What must never happen is one shell's worth of
# surfaces becoming two — a duplicate shell, or overlays orphaned by one that
# died. So growth is judged against the number of live shells: N instances may
# legitimately own N surfaces of a namespace on a monitor, never more.
#
#   $1 before  $2 after  $3 live VGS instance count (defaults to 1)
vgs_layers_regressed() {
  local before="$1" after="$2" instances="${3:-1}"
  BEFORE="$before" AFTER="$after" INSTANCES="$instances" python3 -c '
import collections
import os
import sys

def counts(blob):
    return collections.Counter(line for line in blob.splitlines() if line.strip())

before = counts(os.environ["BEFORE"])
after = counts(os.environ["AFTER"])
allowed = max(1, int(os.environ.get("INSTANCES") or 1))
grown = [(key, before[key], after[key])
         for key in after
         if after[key] > before[key] and after[key] > allowed]
for key, was, now in sorted(grown):
    monitor, _, namespace = key.partition("\t")
    print(f"  {monitor} {namespace}: {was} -> {now} (only {allowed} live shell(s))",
          file=sys.stderr)
sys.exit(1 if grown else 0)
'
}

# Compares a before/after pair given their collection statuses. A snapshot that
# worked before validation and fails after it is itself a failure — that is the
# case where an empty result would otherwise read as "nothing changed".
#   $1 label  $2 before  $3 before_status  $4 after  $5 after_status
#   $6 comparator: "exact" or "growth"
#   ... $7 live VGS instance count, for the growth comparison
vgs_compare_snapshots() {
  local label="$1" before="$2" before_status="$3" after="$4" after_status="$5" mode="$6"
  local instances="${7:-1}"
  local prefix="${vgs_snapshot_prefix:-}"

  if [[ "$before_status" == 2 && "$after_status" == 2 ]]; then
    printf '%sno %s to compare (nothing of that kind exists on this system)\n' "$prefix" "$label"
    return 0
  fi
  # A snapshot that could not be read leaves the session unproven in both
  # directions. Skipping the baseline case would let a transient failure hide
  # damage that the "after" snapshot plainly shows.
  if [[ "$after_status" == 1 || "$before_status" == 1 ]]; then
    printf '%sFAIL: could not read %s (before=%s after=%s); the session is unverified\n' \
      "$prefix" "$label" "$before_status" "$after_status" >&2
    return 1
  fi
  if [[ "$before_status" != "$after_status" ]]; then
    printf '%sFAIL: %s became %s mid-run (before=%s after=%s); the session is unverified\n' \
      "$prefix" "$label" "un/available" "$before_status" "$after_status" >&2
    return 1
  fi

  if [[ "$mode" == growth ]]; then
    if ! vgs_layers_regressed "$before" "$after" "$instances"; then
      printf '%sFAIL: %s multiplied (duplicate shell or orphaned overlay)\n' "$prefix" "$label" >&2
      return 1
    fi
  elif [[ "$before" != "$after" ]]; then
    printf -- '--- %s before\n%s\n--- after\n%s\n' "$label" "$before" "$after" >&2
    printf '%sFAIL: %s changed\n' "$prefix" "$label" >&2
    return 1
  fi
  printf '%s%s unchanged by validation\n' "$prefix" "$label"
}
