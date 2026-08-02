#!/usr/bin/env bash
# Shared live-session snapshots for validation safety checks.
#
# Sourced by scripts/qml-smoke.sh and scripts/check-validation-safety.sh so both
# judge "did validation disturb the live session?" the same way.
#
# Requires: $repo_root

# One line per live VGS Quickshell instance: "<pid> <configPath>".
vgs_snapshot_instances() {
  "$repo_root/bin/vshell" instances list --json 2>/dev/null | python3 -c 'import json,sys
try:
    report = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for entry in sorted(report.get("instances", []), key=lambda item: item["pid"]):
    print(entry["pid"], entry["configPath"])' 2>/dev/null || true
}

# One line per live VGS layer surface: "<monitor>\t<namespace>". Repeats are
# meaningful — a duplicate shell shows up as a second surface with the same
# namespace on the same monitor.
vgs_snapshot_layers() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || return 0
  command -v hyprctl >/dev/null 2>&1 || return 0
  hyprctl layers -j 2>/dev/null | python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = []
for monitor, payload in data.items():
    for level in (payload.get("levels") or {}).values():
        for layer in level:
            namespace = layer.get("namespace") or ""
            if namespace.startswith("vshell:"):
                rows.append(f"{monitor}\t{namespace}")
print("\n".join(sorted(rows)))' 2>/dev/null || true
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
