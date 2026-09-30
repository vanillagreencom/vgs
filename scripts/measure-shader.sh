#!/usr/bin/env bash
# Measure the passive VoiceOrb layer on a real GPU in the nested sandbox.
# Usage: scripts/measure-shader.sh [--calibrate FILE] [--keep]
# Default: check scripts/shader/ceilings.json and prove the 256-step control.
# Calibration derives each ceiling as twice the highest at scales 1 and 2.
# Each CPU, GPU, and presentation stream discards 120 warmup readings and
# keeps 600 samples. GPU timestamps keep compositor pacing out of GPU cost.
# Vulkan is required for device identity and timestamps. QSG_NO_VSYNC=1
# requests swap interval 0; Wayland can still pace frameSwapped callbacks.
# Exit 77: missing dependency, software device, or unavailable sandbox.
# Exit 1: missing samples, failed scene, ceiling exceeded, or accepted control.
# The result names the machine, UTC date, backend, GPU, and separate readings.
set -euo pipefail
self="$(readlink -f -- "${BASH_SOURCE[0]}")" || exit 1
repo="$(cd -- "$(dirname -- "$self")/.." && pwd -P)" || exit 1
choice=(--check "$repo/scripts/shader/ceilings.json")
keep=false
while (($#)); do
  case "$1" in
    --calibrate)
      [[ $# -ge 2 ]] || { echo 'shader-cost: refused argument=--calibrate'; exit 2; }
      choice=(--calibrate "$2"); shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$self"; exit 0 ;;
    *) printf 'shader-cost: refused argument=%s\n' "$1"; exit 2 ;;
  esac
done
source_repo="$repo"
export TMPDIR="$source_repo/tmp"
# The compiler owner has a hyphenated filename; import through its path.
qsb="$(python3 - "$repo/scripts/check-voiceorb-shader.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shader", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.qsb_tool() or "")
PY
)" || exit 1
[[ -n $qsb ]] || { echo 'shader-cost: status=not-measured missing=qsb'; exit 77; }
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
if ! env -i PATH=/usr/bin:/bin HOME="$home" LC_ALL=C "$qsb" --qt6 --qsbversion 64 -o "$repo/shell/costly.frag.qsb" "$sandbox/costly.frag"; then
  echo 'shader-cost: failed costly-shader=compile'; exit 1
fi
logs="$source_repo/tmp/shader-cost-$(date +%s)-$$"
mkdir -p -- "$logs"
printf 'shader-cost: logs=%s\n' "$logs"
output="$(first_name)" || exit 1
mode="$(unscaled_mode_of "$output")" || exit 1
double="$(hidpi_mode_of "$output")" || exit 1
for scale in 1 2; do
  target_mode="$mode"
  [[ $scale == 1 ]] || target_mode="$double"
  hold_mode "shader scale $scale" "$output" "$target_mode" "$scale"
  [[ ${#mode_hold[@]} -gt 0 ]] || { echo 'shader-cost: failed output=not-held'; exit 1; }
  for scene in off on costly; do
    stem="$logs/scale-$scale-$scene"
    spawn "$stem.launch.log" "${shell_env[@]}" VGS_SHADER_MODE="$scene" \
      QSG_RHI_BACKEND=vulkan QSG_RHI_PROFILE=1 QSG_NO_VSYNC=1 \
      QT_LOGGING_RULES='qt.scenegraph.time.renderloop.debug=true;qt.scenegraph.general=true;qt.rhi.general=true' \
      qs -p "$repo/shell/ShaderScene.qml"
    scene_pid="$spawn_pid"
    result=""
    done=false
    for ((poll=0; poll<timeout_s*5; poll++)); do
      kill -0 "$scene_pid" 2>/dev/null || break
      if result="$("${shell_env[@]}" qs ipc --pid "$scene_pid" call shader result 2>/dev/null)" \
        && [[ $result == *'"complete":true'* ]]; then done=true; break; fi
      sleep 0.2
    done
    # Read the flushed instance log by the scene's own pid, not its stdout.
    instance="$("${shell_env[@]}" qs list --all -j | python3 -c 'import json,sys; print(next(i["id"] for i in json.load(sys.stdin) if i["pid"] == int(sys.argv[1])))' "$scene_pid")" || {
      echo "shader-cost: failed scene=$scene scale=$scale instance=absent"; cat -- "$stem.launch.log"; exit 1;
    }
    cp -- "$rt_dir/quickshell/by-id/$instance/log.log" "$stem.log"
    printf '%s\n' "$result" >"$stem.json"
    kill -TERM "$scene_pid"
    scene_exit=0
    wait "$scene_pid" || scene_exit=$?
    # Reaping ends this process group's lease; teardown must not retain a
    # pid that the kernel can give to an unrelated process during later runs.
    remaining=()
    for group in "${pgids[@]}"; do
      [[ $group == "$scene_pid" ]] || remaining+=("$group")
    done
    pgids=("${remaining[@]}")
    [[ $scene_exit == 0 || $scene_exit == 143 ]] || {
      printf 'shader-cost: failed scene=%s scale=%s exit=%s\n' "$scene" "$scale" "$scene_exit"; exit 1;
    }
    [[ $done == true ]] || { echo "shader-cost: failed scene=$scene scale=$scale samples=incomplete"; exit 1; }
    [[ $(held_mode_state) == held ]] || { echo 'shader-cost: failed output=mode-reset'; exit 1; }
    printf 'shader-cost: scene=%s scale=%s samples=600 log=%s\n' "$scene" "$scale" "$stem.log"
  done
  release_mode "release shader scale $scale" "$output" "$mode" 1
  [[ $failures -eq 0 ]] || { echo 'shader-cost: failed output=release'; exit 1; }
done
python3 "$source_repo/scripts/shader/readings.py" "$logs" "${choice[@]}"
