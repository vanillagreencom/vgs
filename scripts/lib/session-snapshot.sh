#!/usr/bin/env bash
# Collect live-session resources for validation safety checks. Requires repo_root.
# Status 0 means collected, 1 means failed, and 2 means no applicable session resource.

# Fail while sourcing so missing repo_root names its cause before the first snapshot call.
repo_root="${repo_root:?scripts/lib/session-snapshot.sh: sourcing script must set repo_root first}"

# One line per live VGS Quickshell instance: "<pid> <configPath>".
vgs_snapshot_instances() {
  local report rc=0
  # Keep stderr because it explains why session safety could not be verified.
  report="$("$repo_root/bin/vshell" instances list --json)" || rc=$?

  [[ "$rc" == 2 ]] && return 2 # quickshell is not installed, so there is no registry here at all
  [[ "$rc" == 0 && -n "$report" ]] || return 1
  printf '%s' "$report" | python3 -c 'import json,sys
report = json.load(sys.stdin)
if not report.get("ok"):
    sys.exit(1)
for entry in sorted(report.get("instances", []), key=lambda item: item["pid"]):
    print(entry["pid"], entry["configPath"])'
}

# Print monitor and namespace per Hyprland layer surface, retaining duplicates.
# Niri has no equivalent layer listing; its safety check uses process instances only.
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

# Popup and idle-lock changes are normal during a snapshot. Compare surface growth
# with the live instance count so duplicate or orphaned surfaces can still fail.
# $1 before, $2 after, $3 live VGS instance count (default 1).
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

# Compare snapshots and their collection statuses. Read failure cannot count as unchanged.
# $1 label, $2 before, $3 before_status, $4 after, $5 after_status,
# $6 exact or growth comparator, $7 live instance count for growth.
vgs_compare_snapshots() {
  local label="$1" before="$2" before_status="$3" after="$4" after_status="$5" mode="$6"
  local instances="${7:-1}"
  local prefix="${vgs_snapshot_prefix:-}"

  if [[ "$before_status" == 2 && "$after_status" == 2 ]]; then
    printf '%sno %s to compare (nothing of that kind exists on this system)\n' "$prefix" "$label"
    return 0
  fi
  # An unreadable baseline also leaves the comparison unverified.
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
