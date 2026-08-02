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

# One line per live VGS Quickshell instance: "<pid> <configPath>".
vgs_snapshot_instances() {
  local report
  report="$("$repo_root/bin/vshell" instances list --json 2>/dev/null)" || return 1
  [[ -n "$report" ]] || return 1
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

# Surfaces come and go while the live shell runs — a popout opening mid-check is
# normal and must not read as damage. What must never happen is a surface count
# *growing*: that is a duplicate shell or an orphaned overlay. Prints the
# offending namespaces and returns non-zero when any count increased.
vgs_layers_regressed() {
  local before="$1" after="$2"
  BEFORE="$before" AFTER="$after" python3 -c '
import collections
import os
import sys

def counts(blob):
    return collections.Counter(line for line in blob.splitlines() if line.strip())

before = counts(os.environ["BEFORE"])
after = counts(os.environ["AFTER"])
grown = [(key, before[key], after[key]) for key in after if after[key] > before[key]]
for key, was, now in sorted(grown):
    monitor, _, namespace = key.partition("\t")
    print(f"  {monitor} {namespace}: {was} -> {now}", file=sys.stderr)
sys.exit(1 if grown else 0)
'
}

# Compares a before/after pair given their collection statuses. A snapshot that
# worked before validation and fails after it is itself a failure — that is the
# case where an empty result would otherwise read as "nothing changed".
#   $1 label  $2 before  $3 before_status  $4 after  $5 after_status
#   $6 comparator: "exact" or "growth"
vgs_compare_snapshots() {
  local label="$1" before="$2" before_status="$3" after="$4" after_status="$5" mode="$6"
  local prefix="${vgs_snapshot_prefix:-}"

  if [[ "$before_status" == 2 && "$after_status" == 2 ]]; then
    printf '%sno %s to compare (no compositor session)\n' "$prefix" "$label"
    return 0
  fi
  if [[ "$after_status" == 1 ]]; then
    printf '%sFAIL: could not read %s after validation; the session is unverified\n' \
      "$prefix" "$label" >&2
    return 1
  fi
  if [[ "$before_status" != 0 ]]; then
    printf '%sno %s baseline; comparison skipped\n' "$prefix" "$label" >&2
    return 0
  fi

  if [[ "$mode" == growth ]]; then
    if ! vgs_layers_regressed "$before" "$after"; then
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
