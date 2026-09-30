#!/usr/bin/env python3
"""Read Qt 6.11 threaded-render-loop logs from one standalone layer.

Qt's window-addressed sync/render log is CPU submission, in integer ms.
QSG_RHI_PROFILE supplies GPU timestamp frame durations, independent of
Wayland frame callback pacing. Presentation is the layer's frameSwapped
interval in the GUI thread, in ms, not time spent executing on the GPU.
Each stream discards 120 warmup readings and retains 600 samples.
The report's GPU cost is paired on-minus-off GPU frame time, not CPU time
or presentation interval. Software devices exit 77; absent samples fail.
"""
import argparse
import json
import math
from pathlib import Path
import re
import socket
from datetime import datetime, timezone
import sys

WARMUP = 120
SAMPLES = 600
READINGS = ("cpu_sync_ms", "cpu_render_ms", "gpu_cost_ms", "presentation_ms")


class Unmeasured(Exception):
    """The backend cannot provide real-GPU evidence."""


def samples(values, name):
    """Refuse an empty or incomplete stream before taking its sample window."""
    if len(values) < WARMUP + SAMPLES:
        raise ValueError(f"samples={name} count={len(values)} need={WARMUP + SAMPLES}")
    result = values[WARMUP:WARMUP + SAMPLES]
    if any(not math.isfinite(v) or v < 0 for v in result):
        raise ValueError(f"samples={name} invalid-value")
    return result


def scene(log, state, scale):
    """Attribute each stream to the layer's actual QQuickWindow."""
    if re.search(r"software (?:adaptation|backend)|backend Software", log, re.I):
        raise Unmeasured("backend=software")
    # Qt's QRhi Vulkan selection log names each enumerated device followed
    # by 'using this physical device' only for the one it selects.
    device = re.search(r"Physical device \d+: '([^']+)'.* type (\d+)\)\n[^\n]*using this physical device", log)
    if device is None:
        raise ValueError("backend=device-unreadable")
    if int(device[2]) == 4:
        raise Unmeasured(f"backend=software device={device[1]}")
    if int(device[2]) not in (1, 2):
        raise Unmeasured(f"backend=non-gpu device={device[1]} type={device[2]}")
    window = re.fullmatch(r"ProxiedWindow\((0x[0-9a-f]+)\)", state["window"])
    if window is None:
        raise ValueError("window=unreadable")
    address = window[1]
    if state["scale"] != scale:
        raise ValueError(f"scale={state['scale']} want={scale}")
    if state["complete"] is not True:
        raise ValueError("scene=incomplete")
    if not re.search(rf"Creating QRhi with backend Vulkan for window {address}\b", log):
        raise ValueError("backend=not-vulkan-for-layer")
    if "Swap interval is 0, attempting to disable vsync when presenting." not in log:
        raise ValueError("swap-interval=unverified")
    lines = [line for line in log.splitlines()
             if "qt.scenegraph.time.renderloop:" in line and f"[window {address}]" in line]
    cpu = [tuple(map(float, match.groups())) for line in lines
           if (match := re.search(r"frame rendered in \d+ms, sync=(\d+), render=(\d+), swap=\d+", line))]
    gpu = [float(match[1]) for line in lines
           if (match := re.search(r"last retrieved GPU frame time was ([0-9.]+) ms", line))]
    return {
        "backend": "Vulkan", "device": device[1], "window": address, "scale": scale,
        "cpu_sync_ms": samples([p[0] for p in cpu], "cpu-sync"),
        "cpu_render_ms": samples([p[1] for p in cpu], "cpu-render"),
        "gpu_frame_ms": samples(gpu, "gpu"),
        "presentation_ms": samples(state["presentation"], "presentation"),
    }


def highest(on, off):
    """Keep submission, GPU delta, and presentation readings separate."""
    if on["device"] != off["device"] or on["backend"] != off["backend"]:
        raise ValueError("baseline=device-mismatch")
    delta = [a - b for a, b in zip(on["gpu_frame_ms"], off["gpu_frame_ms"], strict=True)]
    peak = max(delta)
    if peak <= 0:
        raise ValueError(f"gpu-cost=not-resolved highest_ms={peak}")
    return {
        "cpu_sync_ms": max(on["cpu_sync_ms"]),
        "cpu_render_ms": max(on["cpu_render_ms"]),
        "gpu_cost_ms": peak,
        "presentation_ms": max(on["presentation_ms"]),
    }


def over_ceiling(reading, ceilings):
    """Return every exceeded reading, including a zero CPU ceiling."""
    return [name for name in READINGS if reading[name] > ceilings[name]]


def report(root, baseline=None):
    """Judge both scales and the costly shader against one measured ceiling."""
    scenes = {}
    for scale in (1, 2):
        scenes[scale] = {}
        for mode in ("off", "on", "costly"):
            stem = root / f"scale-{scale}-{mode}"
            scenes[scale][mode] = scene(
                stem.with_suffix(".log").read_text(),
                json.loads(stem.with_suffix(".json").read_text()), scale)
    readings = {str(scale): highest(rows["on"], rows["off"]) for scale, rows in scenes.items()}
    if baseline is None:
        ceilings = {name: 2 * max(row[name] for row in readings.values()) for name in READINGS}
    else:
        ceilings = baseline["ceilings"]
        for scale, row in readings.items():
            broken = over_ceiling(row, ceilings)
            if broken:
                raise ValueError(f"ceiling=exceeded scale={scale} readings={','.join(broken)}")
    controls = {}
    for scale, rows in scenes.items():
        reading = highest(rows["costly"], rows["off"])
        broken = over_ceiling(reading, ceilings)
        # The control proves GPU cost, not a scheduling hiccup on the CPU.
        if "gpu_cost_ms" not in broken:
            raise ValueError(f"costly-control=accepted scale={scale} gpu_cost_ms={reading['gpu_cost_ms']} ceiling={ceilings['gpu_cost_ms']}")
        controls[str(scale)] = reading
    return {
        "machine": socket.gethostname(), "date": datetime.now(timezone.utc).isoformat(),
        "backend": scenes[1]["on"]["backend"], "device": scenes[1]["on"]["device"],
        "warmup": WARMUP, "samples": SAMPLES,
        "method": "GPU timestamp frame time on minus off; QSG_NO_VSYNC=1",
        "readings": readings, "ceilings": ceilings, "costly_control": controls,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument("--calibrate", type=Path)
    choice.add_argument("--check", type=Path)
    args = parser.parse_args()
    try:
        baseline = json.loads(args.check.read_text()) if args.check else None
        result = report(args.directory, baseline)
        if args.calibrate:
            args.calibrate.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    except Unmeasured as error:
        print(f"shader-cost: status=not-measured {error}")
        return 77
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"shader-cost: failed {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
