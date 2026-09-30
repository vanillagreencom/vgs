#!/usr/bin/env python3
"""Read Qt 6.11 threaded-render-loop logs from one standalone layer.

Qt's window-addressed sync/render log is CPU submission, in integer ms.
QSG_RHI_PROFILE supplies GPU timestamp frame durations, independent of
Wayland frame callback pacing. Presentation is the layer's frameSwapped
interval in the GUI thread, in ms, not time spent executing on the GPU.
Each stream discards 120 warmup readings and retains 600 samples, and
its reading is their nearest-rank 90th percentile, so a few frames a
busy host delays do not set it. The report's GPU cost is paired
on-minus-off GPU frame time, not CPU time or presentation interval.
Calibration reads one directory per pass and derives each ceiling from
the highest reading over every pass; check mode judges one directory.
Software devices exit 77; absent samples fail.
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
# The reading of a stream is its nearest-rank percentile.
PERCENTILE = 90
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


def percentile(values):
    """The nearest-rank PERCENTILE of values: the smallest sample with at
    least PERCENTILE percent of the samples at or below it."""
    ordered = sorted(values)
    rank = -(-len(ordered) * PERCENTILE // 100)
    return ordered[rank - 1]


def reading(on, off):
    """Keep submission, GPU delta, and presentation readings separate."""
    if on["device"] != off["device"] or on["backend"] != off["backend"]:
        raise ValueError("baseline=device-mismatch")
    delta = [a - b for a, b in zip(on["gpu_frame_ms"], off["gpu_frame_ms"], strict=True)]
    cost = percentile(delta)
    if cost <= 0:
        raise ValueError(f"gpu-cost=not-resolved reading_ms={cost}")
    return {
        "cpu_sync_ms": percentile(on["cpu_sync_ms"]),
        "cpu_render_ms": percentile(on["cpu_render_ms"]),
        "gpu_cost_ms": cost,
        "presentation_ms": percentile(on["presentation_ms"]),
    }


def over_ceiling(reading, ceilings):
    """Return every exceeded reading, including a zero CPU ceiling."""
    return [name for name in READINGS if reading[name] > ceilings[name]]


def measure(root, identity=None):
    """Read one pass's scenes at both scales, each scene's backend and
    device matched to identity when one is given."""
    scenes = {}
    for scale in (1, 2):
        scenes[scale] = {}
        for mode in ("off", "on", "costly"):
            stem = root / f"scale-{scale}-{mode}"
            scenes[scale][mode] = scene(
                stem.with_suffix(".log").read_text(),
                json.loads(stem.with_suffix(".json").read_text()), scale)
            measured = scenes[scale][mode]
            if identity is not None and (
                measured["device"] != identity["device"] or measured["backend"] != identity["backend"]
            ):
                raise Unmeasured(
                    f"calibration=identity-mismatch scale={scale} scene={mode} "
                    f"want=[{identity['backend']}:{identity['device']}] "
                    f"got=[{measured['backend']}:{measured['device']}]")
    return {
        "backend": scenes[1]["on"]["backend"], "device": scenes[1]["on"]["device"],
        "readings": {str(scale): reading(rows["on"], rows["off"]) for scale, rows in scenes.items()},
        "costly_control": {str(scale): reading(rows["costly"], rows["off"]) for scale, rows in scenes.items()},
    }


def prove_control(run, ceilings, suffix=""):
    """The costly shader must exceed the GPU ceiling at every scale."""
    for scale, control in run["costly_control"].items():
        # The control proves GPU cost, not a scheduling hiccup on the CPU.
        if "gpu_cost_ms" not in over_ceiling(control, ceilings):
            raise ValueError(
                f"costly-control=accepted scale={scale} gpu_cost_ms={control['gpu_cost_ms']} "
                f"ceiling={ceilings['gpu_cost_ms']}{suffix}")


def record(run, ceilings):
    """The fields every result carries, calibration or check."""
    return {
        "machine": socket.gethostname(), "date": datetime.now(timezone.utc).isoformat(),
        "backend": run["backend"], "device": run["device"],
        "warmup": WARMUP, "samples": SAMPLES, "percentile": PERCENTILE,
        "method": f"nearest-rank p{PERCENTILE} of each stream; GPU timestamp frame time on minus off, "
                  "paired by sample; QSG_NO_VSYNC=1",
        "ceilings": ceilings,
    }


def check(root, baseline):
    """Judge one pass at both scales, and its costly shader, against the
    committed ceilings."""
    run = measure(root, baseline)
    ceilings = baseline["ceilings"]
    for scale, row in run["readings"].items():
        broken = over_ceiling(row, ceilings)
        if broken:
            raise ValueError(f"ceiling=exceeded scale={scale} readings={','.join(broken)}")
    prove_control(run, ceilings)
    return dict(record(run, ceilings), readings=run["readings"], costly_control=run["costly_control"])


def calibrate(roots):
    """Derive each ceiling as twice the highest reading over every pass and
    scale; the costly shader of every pass must exceed the GPU ceiling."""
    runs = []
    for root in roots:
        run = measure(root, runs[0] if runs else None)
        run["run"] = f"{root.parent.name}/{root.name}"
        runs.append(run)
    readings = {scale: {name: max(run["readings"][scale][name] for run in runs) for name in READINGS}
                for scale in ("1", "2")}
    ceilings = {name: 2 * max(row[name] for row in readings.values()) for name in READINGS}
    for run in runs:
        prove_control(run, ceilings, f" run={run['run']}")
    return dict(record(runs[0], ceilings), readings=readings, calibration_runs=[
        {"run": run["run"], "readings": run["readings"], "costly_control": run["costly_control"]}
        for run in runs])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="+")
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument("--calibrate", type=Path)
    choice.add_argument("--check", type=Path)
    args = parser.parse_args()
    if args.check and len(args.directory) != 1:
        print(f"shader-cost: refused directories={len(args.directory)} check=1")
        return 2
    try:
        if args.check:
            result = check(args.directory[0], json.loads(args.check.read_text()))
        else:
            result = calibrate(args.directory)
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
