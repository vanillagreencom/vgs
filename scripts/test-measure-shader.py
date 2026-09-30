#!/usr/bin/env python3
"""Exercise the real log reader and ceiling judge with Qt-format records.

Log fields come from Qt 6.11.2 QSGRenderThread::syncAndRender and
QRhiVulkan::create. The costly shader is proved separately on the real GPU.
Controls remove each sample/ceiling rule from a disposable reader, without
removing the matched error text.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
READER = ROOT / "shader/readings.py"
spec = importlib.util.spec_from_file_location("readings", READER)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)

DEVICE = "Physical device 0: 'Test GPU' 1.2.3 (api 1.3.0 vendor 0x1 device 0x2 type 2)\nDEBUG qt.rhi.general:     using this physical device"
HEADER = DEVICE + "\nCreating QRhi with backend Vulkan for window 0x1234 (wflags 0x1)\nSwap interval is 0, attempting to disable vsync when presenting.\n"
CPU = "DEBUG qt.scenegraph.time.renderloop: [window 0x1234][render thread 0xabcd] syncAndRender: frame rendered in 2ms, sync=1, render=1, swap=0\n"
GPU = "DEBUG qt.scenegraph.time.renderloop: [window 0x1234][render thread 0xabcd] syncAndRender: last retrieved GPU frame time was %.4f ms\n"
STATE = {"complete": True, "window": "ProxiedWindow(0x1234)", "scale": 1, "presentation": [16] * 720}


def log(gpu=0.2):
    return HEADER + (CPU + GPU % gpu) * 720


def fixture(root):
    for scale in (1, 2):
        for mode, gpu in (("off", 0.1), ("on", 0.2), ("costly", 1.0)):
            stem = root / f"scale-{scale}-{mode}"
            stem.with_suffix(".log").write_text(log(gpu))
            stem.with_suffix(".json").write_text(json.dumps(dict(STATE, scale=scale)))


class ShaderReadings(unittest.TestCase):
    def test_distinct_readings_and_calibration(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            fixture(root)
            result = reader.report(root)
            self.assertEqual(result["samples"], 600)
            self.assertEqual(result["warmup"], 120)
            self.assertEqual(result["readings"]["1"], {
                "cpu_sync_ms": 1, "cpu_render_ms": 1, "gpu_cost_ms": 0.1, "presentation_ms": 16})
            self.assertEqual(result["ceilings"], {
                "cpu_sync_ms": 2, "cpu_render_ms": 2, "gpu_cost_ms": 0.2, "presentation_ms": 32})
            self.assertEqual(set(result["readings"]), {"1", "2"})
            self.assertAlmostEqual(result["costly_control"]["2"]["gpu_cost_ms"], 0.9)

    def test_sample_and_attribution_rules(self):
        cases = (
            ("zero CPU", HEADER + GPU % 0.2, STATE, "samples=cpu-sync"),
            ("zero GPU", HEADER + CPU * 720, STATE, "samples=gpu"),
            ("zero presentation", log(), dict(STATE, presentation=[]), "samples=presentation"),
            ("incomplete GPU", HEADER + (CPU + GPU % 0.2) * 719, STATE, "samples=cpu-sync"),
            ("other window", log().replace("[window 0x1234]", "[window 0x5678]"), STATE, "samples=cpu-sync"),
            ("wrong scale", log(), dict(STATE, scale=2), "scale=2"),
            ("no vsync proof", log().replace("Swap interval is 0", "Swap interval is 1"), STATE, "swap-interval=unverified"),
            ("incomplete scene", log(), dict(STATE, complete=False), "scene=incomplete"),
            ("no device", log().replace("using this physical device", "not selected"), STATE, "backend=device-unreadable"),
        )
        for name, text, state, error in cases:
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, error):
                reader.scene(text, state, 1)

    def test_software_is_77(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            fixture(root)
            (root / "scale-1-off.log").write_text(log().replace("type 2)", "type 4)"))
            result = subprocess.run(
                [sys.executable, str(READER), str(root), "--calibrate", str(root / "baseline.json")],
                env={"PATH": "/usr/bin:/bin", "HOME": scratch, "LC_ALL": "C"},
                text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
            self.assertIn("shader-cost: status=not-measured backend=software", result.stdout)
            self.assertFalse((root / "baseline.json").exists())

    def test_costly_control_and_each_ceiling(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            fixture(root)
            result = reader.report(root)
            row = result["readings"]["1"]
            for name in reader.READINGS:
                with self.subTest(name=name):
                    self.assertEqual(reader.over_ceiling(dict(row, **{name: result["ceilings"][name] + 1}), result["ceilings"]), [name])
            self.assertEqual(reader.over_ceiling(result["ceilings"], result["ceilings"]), [])
            self.assertEqual(reader.over_ceiling(dict(row, cpu_sync_ms=1), dict(result["ceilings"], cpu_sync_ms=0)), ["cpu_sync_ms"])
            (root / "scale-2-costly.log").write_text(log(0.2))
            with self.assertRaisesRegex(ValueError, "costly-control=accepted scale=2"):
                reader.report(root)

    def test_sample_and_ceiling_mutants_turn_tests_red(self):
        plants = (
            ("sample guard", "if len(values) < WARMUP + SAMPLES:", "if False and len(values) < WARMUP + SAMPLES:", "test_sample_and_attribution_rules"),
            ("ceiling guard", "if reading[name] > ceilings[name]", "if reading[name] > float('inf') + ceilings[name]", "test_costly_control_and_each_ceiling"),
        )
        source = READER.read_text()
        suite = Path(__file__).read_text()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / "shader").mkdir()
            for name, old, new, test in plants:
                with self.subTest(name=name):
                    self.assertEqual(source.count(old), 1)
                    changed = source.replace(old, new)
                    self.assertNotEqual(changed, source)
                    (root / "shader/readings.py").write_text(changed)
                    copy = root / "test-measure-shader.py"
                    copy.write_text(suite)
                    result = subprocess.run(
                        [sys.executable, str(copy), f"ShaderReadings.{test}"],
                        env={"PATH": "/usr/bin:/bin", "HOME": scratch, "LC_ALL": "C"},
                        text=True, capture_output=True, check=False)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("FAILED (", result.stderr)


if __name__ == "__main__":
    unittest.main()
