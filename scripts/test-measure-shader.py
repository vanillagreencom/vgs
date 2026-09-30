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
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
READER = ROOT / "shader/readings.py"
RUNNER = ROOT / "measure-shader.sh"
spec = importlib.util.spec_from_file_location("readings", READER)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)

DEVICE = "Physical device 0: 'Test GPU' 1.2.3 (api 1.3.0 vendor 0x1 device 0x2 type 2)\nDEBUG qt.rhi.general:     using this physical device"
HEADER = DEVICE + "\nCreating QRhi with backend Vulkan for window 0x1234 (wflags 0x1)\nSwap interval is 0, attempting to disable vsync when presenting.\n"
CPU = "DEBUG qt.scenegraph.time.renderloop: [window 0x1234][render thread 0xabcd] syncAndRender: frame rendered in 2ms, sync=1, render=1, swap=0\n"
GPU = "DEBUG qt.scenegraph.time.renderloop: [window 0x1234][render thread 0xabcd] syncAndRender: last retrieved GPU frame time was %.4f ms\n"
STATE = {"complete": True, "window": "ProxiedWindow(0x1234)", "scale": 1, "presentation": [16] * 720}
BASELINE = {"backend": "Vulkan", "device": "Test GPU", "ceilings": {
    "cpu_sync_ms": 2, "cpu_render_ms": 2, "gpu_cost_ms": 0.2, "presentation_ms": 32}}


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

    def test_check_mode_report_and_cli(self):
        cases = (
            ("within ceiling", 0.2, None),
            ("normal GPU regression", 0.05, "ceiling=exceeded scale=1 readings=gpu_cost_ms"),
            ("accepted costly shader", 1.0, "costly-control=accepted scale=1"),
        )
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            fixture(root)
            for name, ceiling, error in cases:
                with self.subTest(name=name):
                    baseline = dict(BASELINE, ceilings=dict(BASELINE["ceilings"], gpu_cost_ms=ceiling))
                    if error is None:
                        self.assertEqual(reader.report(root, baseline)["ceilings"], baseline["ceilings"])
                    else:
                        with self.assertRaisesRegex(ValueError, error):
                            reader.report(root, baseline)
                    path = root / "baseline.json"
                    path.write_text(json.dumps(baseline))
                    result = subprocess.run(
                        [sys.executable, str(READER), str(root), "--check", str(path)],
                        env={"PATH": "/usr/bin:/bin", "HOME": scratch, "LC_ALL": "C"},
                        text=True, capture_output=True, check=False)
                    self.assertEqual(result.returncode, 1 if error else 0, result.stdout + result.stderr)
                    if error:
                        self.assertIn("shader-cost: failed " + error, result.stdout)
                    else:
                        self.assertEqual(json.loads(result.stdout)["ceilings"], baseline["ceilings"])

    def test_check_mode_calibration_identity(self):
        # Every scene is a real producer of device identity, including the
        # off and costly scenes. A mismatched baseline backend also skips.
        cases = [(scale, mode, BASELINE) for scale in (1, 2) for mode in ("off", "on", "costly")]
        cases.append((None, None, dict(BASELINE, backend="OpenGL")))
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            for scale, mode, baseline in cases:
                with self.subTest(scale=scale, mode=mode, backend=baseline["backend"]):
                    fixture(root)
                    if scale is not None:
                        path = root / f"scale-{scale}-{mode}.log"
                        path.write_text(path.read_text().replace("'Test GPU'", "'Other GPU'"))
                    with self.assertRaisesRegex(reader.Unmeasured, "calibration=identity-mismatch"):
                        reader.report(root, baseline)
                    path = root / "baseline.json"
                    path.write_text(json.dumps(baseline))
                    result = subprocess.run(
                        [sys.executable, str(READER), str(root), "--check", str(path)],
                        env={"PATH": "/usr/bin:/bin", "HOME": scratch, "LC_ALL": "C"},
                        text=True, capture_output=True, check=False)
                    self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
                    self.assertIn("shader-cost: status=not-measured calibration=identity-mismatch", result.stdout)

    def test_sample_and_ceiling_mutants_turn_tests_red(self):
        plants = (
            ("sample guard", "if len(values) < WARMUP + SAMPLES:", "if False and len(values) < WARMUP + SAMPLES:", "test_sample_and_attribution_rules"),
            ("ceiling guard", "if reading[name] > ceilings[name]", "if reading[name] > float('inf') + ceilings[name]", "test_costly_control_and_each_ceiling"),
            ("baseline rejection", 'raise ValueError(f"ceiling=exceeded scale={scale} readings={\',\'.join(broken)}")',
             'str(f"ceiling=exceeded scale={scale} readings={\',\'.join(broken)}")', "test_check_mode_report_and_cli"),
            ("calibration identity", "if baseline is not None and (", "if baseline is not None and False and (",
             "test_check_mode_calibration_identity"),
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


class ShaderRunner(unittest.TestCase):
    def mode_result(self, text, state, prior_failures=0):
        start = '    mode_state="$(held_mode_state)"'
        end = "    printf 'shader-cost: scene="
        self.assertEqual(text.count(start), 1)
        self.assertEqual(text.count(end), 1)
        guard = text[text.index(start):text.index(end)]
        with tempfile.TemporaryDirectory() as scratch:
            script = """
set -euo pipefail
source "$1"
state="$2"
held_mode_state() { printf '%s\\n' "$state"; }
failures="$3"; behaviour_failures="$3"; sandbox="$HOME"
""" + guard + "\necho 'shader-test: held'\n"
            return subprocess.run(
                ["bash", "-c", script, "_", str(ROOT / "smoke/verdict.sh"), state, str(prior_failures)],
                env={"PATH": "/usr/bin:/bin", "HOME": scratch, "LC_ALL": "C"},
                text=True, capture_output=True, check=False)

    def test_held_mode_verdict(self):
        cases = (
            ("held", 0, 0, "shader-test: held"),
            ("reset", 0, 77, "qml-smoke: status=not-measured nested-output=mode-reset failed=1"),
            ("unreadable", 0, 1, "shader-cost: failed output=unreadable"),
            ("reset", 1, 1, "qml-smoke: failed=2"),
        )
        for state, prior, status, first_line in cases:
            with self.subTest(state=state, prior=prior):
                result = self.mode_result(RUNNER.read_text(), state, prior)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertEqual(result.stdout.splitlines()[0], first_line)
        old = '"$((mode_resets + 1))"'
        text = RUNNER.read_text()
        self.assertEqual(text.count(old), 1)
        changed = text.replace(old, '"$mode_resets"')
        self.assertNotEqual(text, changed)
        result = self.mode_result(changed, "reset")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("status=not-measured", result.stdout)

    def runner_copy(self, root, harness, text):
        scripts = root / "scripts"
        (scripts / "smoke").mkdir(parents=True)
        (scripts / "shader").mkdir()
        (root / "home").mkdir()
        (root / "shell/Ui/feedback/shaders").mkdir(parents=True)
        script = scripts / "measure-shader.sh"
        script.write_text(text)
        owner = (ROOT / "check-voiceorb-shader.py").read_text()
        declarations = [line for line in owner.splitlines() if line.startswith("OPTIONS = ")]
        self.assertEqual(len(declarations), 1)
        changed = owner.replace(declarations[0], 'OPTIONS = ("--test-owner-option", "--test option with spaces")')
        self.assertNotEqual(changed, owner)
        (scripts / "check-voiceorb-shader.py").write_text(changed)
        shutil.copyfile(ROOT / "shader/Scene.qml", scripts / "shader/Scene.qml")
        shutil.copyfile(ROOT.parent / "shell/Ui/feedback/shaders/voiceorb.frag", root / "shell/Ui/feedback/shaders/voiceorb.frag")
        (scripts / "smoke/harness.sh").write_text(harness)
        compiler = root / "qsb stand-in"
        compiler.write_text(f"""#!{sys.executable}
import json, os, pathlib, sys
pathlib.Path(os.environ["HOME"], "compiler-args.json").write_text(json.dumps(sys.argv[1:]))
""")
        compiler.chmod(0o755)
        return subprocess.run(
            ["bash", str(script)],
            env={"PATH": "/usr/bin:/bin", "HOME": str(root / "home"), "LC_ALL": "C", "QSB": str(compiler)},
            text=True, capture_output=True, check=False)

    def test_fresh_checkout_scratch_creation(self):
        harness = """
scratch="$(mktemp -d "$TMPDIR/vgsh-smoke.XXXXXX")"
printf 'shader-test: scratch=%s\\n' "$scratch"
exit 0
"""
        text = RUNNER.read_text()
        old = 'mkdir -p -- "$source_repo/tmp"'
        self.assertEqual(text.count(old), 1)
        plants = ((text, 0), (text.replace(old, ': "$source_repo/tmp"'), 1))
        with tempfile.TemporaryDirectory() as scratch:
            for index, (source, status) in enumerate(plants):
                with self.subTest(mutant=index):
                    root = Path(scratch) / str(index)
                    result = self.runner_copy(root, harness, source)
                    self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                    self.assertEqual((root / "tmp").is_dir(), status == 0)

    def test_compiler_consumes_owner_options(self):
        # Stop before any compositor or QML process. The compiler only
        # records argv; the script still builds its real disposable source.
        harness = """
home="$HOME"; sandbox="$HOME/sandbox"
shell_env=(env -i PATH=/usr/bin:/bin HOME="$HOME")
mkdir -p -- "$sandbox"
first_name() { echo 'shader-test: stop-after-compile' >&2; return 1; }
"""
        text = RUNNER.read_text()
        old = '"${compiler_words[@]}"'
        self.assertEqual(text.count(old), 1)
        plants = ((text, True), (text.replace(old, '"${compiler_words[0]}"'), False))
        with tempfile.TemporaryDirectory() as scratch:
            for index, (source, includes_options) in enumerate(plants):
                with self.subTest(mutant=index):
                    root = Path(scratch) / str(index)
                    result = self.runner_copy(root, harness, source)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("shader-test: stop-after-compile", result.stderr)
                    args = json.loads((root / "home/compiler-args.json").read_text())
                    self.assertEqual("--test-owner-option" in args, includes_options)
                    if includes_options:
                        self.assertEqual(args[:2], ["--test-owner-option", "--test option with spaces"])


if __name__ == "__main__":
    unittest.main()
