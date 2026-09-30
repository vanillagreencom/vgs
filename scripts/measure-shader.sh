#!/usr/bin/env bash
# Measure the passive VoiceOrb layer on a real GPU in the nested sandbox.
# Usage: scripts/measure-shader.sh [--calibrate FILE [--runs N]] [--keep]
# Default: check scripts/shader/ceilings.json and prove the 256-step control.
# Calibration measures N passes, 1 by default, in one sandbox and derives
# each ceiling as twice the highest reading over every pass and scale.
# Each CPU, GPU, and presentation stream discards 120 warmup readings and
# keeps 600 samples; a reading is their 90th percentile. GPU timestamps
# keep compositor pacing out of GPU cost.
# A scene the host's configure moved off the held mode runs again, a
# bounded number of times, and each scene line records the host's CPU
# pressure.
# Vulkan is required for device identity and timestamps. QSG_NO_VSYNC=1
# requests swap interval 0; Wayland can still pace frameSwapped callbacks.
# Exit 77: missing dependency, uncalibrated/software device, or sandbox fault.
# Exit 1: missing samples, failed scene, ceiling exceeded, or accepted control.
# The result names the machine, UTC date, backend, GPU, and separate readings.
set -euo pipefail
self="$(readlink -f -- "${BASH_SOURCE[0]}")" || exit 1
repo="$(cd -- "$(dirname -- "$self")/.." && pwd -P)" || exit 1
choice=(--check "$repo/scripts/shader/ceilings.json")
keep=false
runs=""
while (($#)); do
  case "$1" in
    --calibrate)
      [[ $# -ge 2 ]] || { echo 'shader-cost: refused argument=--calibrate'; exit 2; }
      choice=(--calibrate "$2"); shift 2 ;;
    --runs)
      [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { printf 'shader-cost: refused argument=--runs value=%s\n' "${2:-}"; exit 2; }
      runs="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$self"; exit 0 ;;
    *) printf 'shader-cost: refused argument=%s\n' "$1"; exit 2 ;;
  esac
done
# Check mode judges one pass against the committed record.
if [[ -n $runs && ${choice[0]} != --calibrate ]]; then
  echo 'shader-cost: refused argument=--runs without=--calibrate'; exit 2
fi
runs="${runs:-1}"
source_repo="$repo"
if ! mkdir -p -- "$source_repo/tmp"; then
  printf 'shader-cost: failed scratch=%s\n' "$source_repo/tmp"; exit 1
fi
export TMPDIR="$source_repo/tmp"
# The compiler owner has a hyphenated filename; import through its path.
compiler="$(python3 - "$repo/scripts/check-voiceorb-shader.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shader", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.qsb_tool() or "")
print(*module.OPTIONS, sep="\n")
PY
)" || exit 1
mapfile -t compiler_words <<<"$compiler"
[[ -n ${compiler_words[0]} ]] || { echo 'shader-cost: status=not-measured missing=qsb'; exit 77; }
timeout_s=90
plugin_set=smoke
harness_scene_only=true
source "$repo/scripts/smoke/harness.sh"
cp -- "$source_repo/scripts/shader/Scene.qml" "$repo/shell/ShaderScene.qml"
python3 - "$repo/shell/Ui/feedback/shaders/voiceorb.frag" "$sandbox/costly.frag" <<'PY'
from pathlib import Path
import sys
source, output = map(Path, sys.argv[1:])
text = source.read_text()
needle = "fragColor = ink * max(ring, arcs) * qt_Opacity;"
assert text.count(needle) == 1, "costly shader: output must match once"
changed = text.replace(needle, """
float cost = angle + phase;
for (int i = 0; i < 256; ++i)
    cost = sin(cost * 1.31 + float(i)) + cos(cost * 0.73 + radius) + atan(cost, 0.71);
fragColor = ink * max(ring, arcs) * qt_Opacity * (0.99 + 0.01 * sin(cost));
""")
assert changed != text
output.write_text(changed)
PY
if ! env -i PATH=/usr/bin:/bin HOME="$home" LC_ALL=C "${compiler_words[@]}" -o "$repo/shell/costly.frag.qsb" "$sandbox/costly.frag"; then
  echo 'shader-cost: failed costly-shader=compile'; exit 1
fi
logs="$source_repo/tmp/shader-cost-$(date +%s)-$$"
mkdir -p -- "$logs"
printf 'shader-cost: logs=%s\n' "$logs"
source "$source_repo/scripts/shader/measure-scene.sh"
output="$(first_name)" || exit 1
mode="$(unscaled_mode_of "$output")" || exit 1
double="$(hidpi_mode_of "$output")" || exit 1
passes=()
for ((run = 1; run <= runs; run++)); do
  pass="$logs/run-$run"
  mkdir -p -- "$pass"
  passes+=("$pass")
  for scale in 1 2; do
    target_mode="$mode"
    [[ $scale == 1 ]] || target_mode="$double"
    hold_mode "shader scale $scale" "$output" "$target_mode" "$scale"
    [[ ${#mode_hold[@]} -gt 0 ]] || { echo 'shader-cost: failed output=not-held'; exit 1; }
    for scene in off on costly; do
      measure_held_scene "$scale" "$scene" "$pass/scale-$scale-$scene"
    done
    release_mode "release shader scale $scale" "$output" "$mode" 1
    [[ $failures -eq 0 ]] || { echo 'shader-cost: failed output=release'; exit 1; }
  done
done
python3 "$source_repo/scripts/shader/readings.py" "${passes[@]}" "${choice[@]}"
