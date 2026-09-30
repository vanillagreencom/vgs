#!/usr/bin/env python3
"""Exercise the real log reader and ceiling judge with Qt-format records.

Log fields come from Qt 6.11.2 QSGRenderThread::syncAndRender and
QRhiVulkan::create. The costly shader is proved separately on the real GPU.
Controls remove each sample, percentile, pass and ceiling rule from a
disposable reader, without removing the matched error text. The runner's
held-scene loop and its argument refusals run with the sandbox stubbed,
and their controls plant one defect per rule in a copy.
"""
import importlib.util
import json
from pathlib import Path
import re
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


def stream_log(sync, render, gpu):
    """A log whose CPU and GPU records carry one value per frame."""
    return HEADER + "".join(
        CPU.replace("sync=1, render=1", f"sync={s}, render={r}") + GPU % g
        for s, r, g in zip(sync, render, gpu, strict=True))


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
            result = reader.calibrate([root])
            self.assertEqual(result["samples"], 600)
            self.assertEqual(result["warmup"], 120)
            self.assertEqual(result["readings"]["1"], {
                "cpu_sync_ms": 1, "cpu_render_ms": 1, "gpu_cost_ms": 0.1, "presentation_ms": 16})
            self.assertEqual(result["ceilings"], {
                "cpu_sync_ms": 2, "cpu_render_ms": 2, "gpu_cost_ms": 0.2, "presentation_ms": 32})
            self.assertEqual(set(result["readings"]), {"1", "2"})
            self.assertAlmostEqual(result["calibration_runs"][0]["costly_control"]["2"]["gpu_cost_ms"], 0.9)

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
            result = reader.calibrate([root])
            row = result["readings"]["1"]
            for name in reader.READINGS:
                with self.subTest(name=name):
                    self.assertEqual(reader.over_ceiling(dict(row, **{name: result["ceilings"][name] + 1}), result["ceilings"]), [name])
            self.assertEqual(reader.over_ceiling(result["ceilings"], result["ceilings"]), [])
            self.assertEqual(reader.over_ceiling(dict(row, cpu_sync_ms=1), dict(result["ceilings"], cpu_sync_ms=0)), ["cpu_sync_ms"])
            (root / "scale-2-costly.log").write_text(log(0.2))
            with self.assertRaisesRegex(ValueError, "costly-control=accepted scale=2"):
                reader.calibrate([root])

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
                        self.assertEqual(reader.check(root, baseline)["ceilings"], baseline["ceilings"])
                    else:
                        with self.assertRaisesRegex(ValueError, error):
                            reader.check(root, baseline)
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
                        reader.check(root, baseline)
                    path = root / "baseline.json"
                    path.write_text(json.dumps(baseline))
                    result = subprocess.run(
                        [sys.executable, str(READER), str(root), "--check", str(path)],
                        env={"PATH": "/usr/bin:/bin", "HOME": scratch, "LC_ALL": "C"},
                        text=True, capture_output=True, check=False)
                    self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
                    self.assertIn("shader-cost: status=not-measured calibration=identity-mismatch", result.stdout)

    def test_percentile_ignores_a_spike(self):
        # Nearest rank: the smallest sample with at least 90 percent of
        # the samples at or below it.
        self.assertEqual(reader.percentile(list(range(600, 0, -1))), 540)
        self.assertEqual(reader.percentile(list(range(1, 11))), 9)
        # Rows: the stream one kept sample spikes in, the spike, and the
        # reading without it. A stream read as its highest sample reads
        # the spike.
        rows = (
            ("cpu_sync_ms", 9, 1),
            ("cpu_render_ms", 9, 1),
            ("gpu_cost_ms", 5.0, 0.1),
            ("presentation_ms", 500, 16),
        )
        for name, spike, want in rows:
            with self.subTest(stream=name), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                fixture(root)
                streams = {"cpu_sync_ms": [1] * 720, "cpu_render_ms": [1] * 720,
                           "gpu_cost_ms": [0.2] * 720, "presentation_ms": [16] * 720}
                streams[name][reader.WARMUP + 300] = spike
                (root / "scale-1-on.log").write_text(stream_log(
                    streams["cpu_sync_ms"], streams["cpu_render_ms"], streams["gpu_cost_ms"]))
                (root / "scale-1-on.json").write_text(json.dumps(dict(STATE, presentation=streams["presentation_ms"])))
                self.assertAlmostEqual(reader.calibrate([root])["readings"]["1"][name], want)
                self.assertEqual(reader.check(root, BASELINE)["ceilings"], BASELINE["ceilings"])

    def test_gpu_cost_not_resolved(self):
        # Fewer than a tenth of the on scene's frames cost more than the
        # off scene's: the highest delta is positive, the 90th percentile
        # is zero.
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            fixture(root)
            gpu = [0.1] * 720
            for index in range(reader.WARMUP, reader.WARMUP + 50):
                gpu[index] = 0.5
            (root / "scale-1-on.log").write_text(stream_log([1] * 720, [1] * 720, gpu))
            with self.assertRaisesRegex(ValueError, "gpu-cost=not-resolved reading_ms=0"):
                reader.calibrate([root])

    def test_calibration_over_passes(self):
        with tempfile.TemporaryDirectory() as scratch:
            first, second, weak = (Path(scratch) / name for name in ("run-1", "run-2", "run-3"))
            for root in (first, second, weak):
                root.mkdir()
                fixture(root)
            (second / "scale-2-on.log").write_text(log(0.25))
            (weak / "scale-1-costly.log").write_text(log(0.35))
            result = reader.calibrate([first, second])
            self.assertAlmostEqual(result["ceilings"]["gpu_cost_ms"], 0.3)
            self.assertAlmostEqual(result["readings"]["2"]["gpu_cost_ms"], 0.15)
            self.assertAlmostEqual(result["readings"]["1"]["gpu_cost_ms"], 0.1)
            self.assertEqual([run["run"] for run in result["calibration_runs"]],
                             [f"{Path(scratch).name}/run-1", f"{Path(scratch).name}/run-2"])
            self.assertAlmostEqual(result["calibration_runs"][0]["readings"]["2"]["gpu_cost_ms"], 0.1)
            with self.assertRaisesRegex(ValueError, f"costly-control=accepted scale=1 .* run={Path(scratch).name}/run-3$"):
                reader.calibrate([first, second, weak])
            # A later pass is matched to the first pass's device.
            other = Path(scratch) / "run-4"
            other.mkdir()
            fixture(other)
            path = other / "scale-2-off.log"
            path.write_text(path.read_text().replace("'Test GPU'", "'Other GPU'"))
            with self.assertRaisesRegex(
                    reader.Unmeasured,
                    r"calibration=identity-mismatch scale=2 scene=off want=\[Vulkan:Test GPU\] got=\[Vulkan:Other GPU\]"):
                reader.calibrate([first, other])

    def test_check_takes_one_directory(self):
        with tempfile.TemporaryDirectory() as scratch:
            first, second = Path(scratch) / "a", Path(scratch) / "b"
            for root in (first, second):
                root.mkdir()
                fixture(root)
            path = Path(scratch) / "baseline.json"
            path.write_text(json.dumps(BASELINE))
            for roots, status in (([first], 0), ([first, second], 2)):
                with self.subTest(directories=len(roots)):
                    result = subprocess.run(
                        [sys.executable, str(READER), *map(str, roots), "--check", str(path)],
                        env={"PATH": "/usr/bin:/bin", "HOME": scratch, "LC_ALL": "C"},
                        text=True, capture_output=True, check=False)
                    self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                    if status:
                        self.assertEqual(result.stdout, "shader-cost: refused directories=2 check=1\n")

    def test_sample_and_ceiling_mutants_turn_tests_red(self):
        plants = (
            ("sample guard", "if len(values) < WARMUP + SAMPLES:", "if False and len(values) < WARMUP + SAMPLES:", "test_sample_and_attribution_rules"),
            ("ceiling guard", "if reading[name] > ceilings[name]", "if reading[name] > float('inf') + ceilings[name]", "test_costly_control_and_each_ceiling"),
            ("baseline rejection", 'raise ValueError(f"ceiling=exceeded scale={scale} readings={\',\'.join(broken)}")',
             'str(f"ceiling=exceeded scale={scale} readings={\',\'.join(broken)}")', "test_check_mode_report_and_cli"),
            ("calibration identity", "if identity is not None and (", "if identity is not None and False and (",
             "test_check_mode_calibration_identity"),
            ("percentile reading", "return ordered[rank - 1]", "return ordered[-1]", "test_percentile_ignores_a_spike"),
            ("CPU sync read as its highest", '"cpu_sync_ms": percentile(on["cpu_sync_ms"])',
             '"cpu_sync_ms": max(on["cpu_sync_ms"])', "test_percentile_ignores_a_spike cpu_sync_ms"),
            ("CPU render read as its highest", '"cpu_render_ms": percentile(on["cpu_render_ms"])',
             '"cpu_render_ms": max(on["cpu_render_ms"])', "test_percentile_ignores_a_spike cpu_render_ms"),
            ("GPU cost read as its highest", "cost = percentile(delta)", "cost = max(delta)",
             "test_percentile_ignores_a_spike gpu_cost_ms"),
            ("presentation read as its highest", '"presentation_ms": percentile(on["presentation_ms"])',
             '"presentation_ms": max(on["presentation_ms"])', "test_percentile_ignores_a_spike presentation_ms"),
            ("unresolved GPU cost accepted", "if cost <= 0:", "if cost < -1:", "test_gpu_cost_not_resolved"),
            ("passes not matched to the first", "measure(root, runs[0] if runs else None)", "measure(root, None)",
             "test_calibration_over_passes"),
            ("calibration over passes", "for root in roots:", "for root in roots[:1]:", "test_calibration_over_passes"),
            ("costly control of every pass", "    for run in runs:\n        prove_control(",
             "    for run in runs[:1]:\n        prove_control(", "test_calibration_over_passes"),
            ("check reads one directory", "if args.check and len(args.directory) != 1:",
             "if args.check and len(args.directory) != len(args.directory):", "test_check_takes_one_directory"),
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
                    test, _, stream = test.partition(" ")
                    # -B: same-length plants written in one second would
                    # otherwise load the previous plant's cached bytecode.
                    result = subprocess.run(
                        [sys.executable, "-B", str(copy), f"ShaderReadings.{test}"],
                        env={"PATH": "/usr/bin:/bin", "HOME": scratch, "LC_ALL": "C"},
                        text=True, capture_output=True, check=False)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("FAILED (", result.stderr)
                    if stream:
                        # A stream plant turns its own row red, no other.
                        failed = re.findall(r"^(?:FAIL|ERROR): .*\(stream='(\w+)'\)$", result.stderr, re.M)
                        self.assertEqual(failed, [stream], result.stderr)


SCENE = ROOT / "shader/measure-scene.sh"


class ShaderRunner(unittest.TestCase):
    def held_scene(self, text, states, restores="ok", prior_failures=0):
        """Drive measure_held_scene from TEXT with its sandbox stubbed:
        measure_scene counts each measurement, held_mode_state answers the
        next of STATES after each one and hold_restore answers RESTORES.
        Returns the run, how many times the scene was measured and the
        hold restored, and the scratch HOME the scene's log is under."""
        with tempfile.TemporaryDirectory() as scratch:
            subject = Path(scratch) / "measure-scene.sh"
            subject.write_text(text)
            script = """
set -euo pipefail
source "$1"
source "$2"
home="$HOME"; states="$3"; restores="$4"
failures="$5"; behaviour_failures="$5"; sandbox="$HOME"
mode_hold=(WAYLAND-1 "3510x1866 scale=2")
count() { local n=0; [[ -f $home/$1 ]] && n="$(<"$home/$1")"; echo $((n + 1)) >"$home/$1"; echo $((n + 1)); }
measure_scene() { count measured >/dev/null; scene_cpu_some_pct=1.5; }
held_mode_state() { local n; n="$(<"$home/measured")"; IFS=, read -r -a all <<<"$states"; echo "${all[n - 1]:-${all[-1]}}"; }
mode_scale_of() { echo "1755x933 scale=1.5"; }
hold_restore() { count restored >/dev/null; [[ $restores == ok ]] || { echo 'hold-restore: not-held output=WAYLAND-1'; return 1; }; }
measure_held_scene 2 on "$HOME/scale-2-on"
"""
            result = subprocess.run(
                ["bash", "-c", script, "_", str(ROOT / "smoke/verdict.sh"), str(subject), states, restores, str(prior_failures)],
                env={"PATH": "/usr/bin:/bin", "HOME": scratch, "LC_ALL": "C"},
                text=True, capture_output=True, check=False)
            counts = [int((Path(scratch) / name).read_text()) if (Path(scratch) / name).exists() else 0
                      for name in ("measured", "restored")]
            return result, counts, scratch

    RESET = "shader-cost: mode-reset scene=on scale=2 got=[1755x933 scale=1.5] attempt=%d"
    MEASURED = "shader-cost: scene=on scale=2 samples=600 cpu_some_pct=1.5 log=%s/scale-2-on.log"

    def held_cases(self):
        """Rows: states after each measurement, restore answer, earlier
        failures, exit status, measurements, restores, lines printed
        before the last and the last line."""
        return (
            ("held", "ok", 0, 0, 1, 0, [], self.MEASURED),
            ("reset,held", "ok", 0, 0, 2, 1, [self.RESET % 1], self.MEASURED),
            ("reset", "ok", 0, 77, 3, 2, [self.RESET % 1, self.RESET % 2, self.RESET % 3,
                                          "qml-smoke: status=not-measured nested-output=mode-reset failed=1"],
             "the nested output left a mode a row held: the host resized or refocused the nested window; "
             "leave the nested window alone during the run, then run the smoke again"),
            ("reset", "failed", 0, 1, 1, 1, [self.RESET % 1, "hold-restore: not-held output=WAYLAND-1"],
             "shader-cost: failed output=not-restored scene=on scale=2"),
            ("unreadable", "ok", 0, 1, 1, 0, [], "shader-cost: failed output=unreadable"),
            ("reset", "ok", 1, 1, 3, 2, [self.RESET % 1, self.RESET % 2, self.RESET % 3], "qml-smoke: failed=2"),
        )

    def assert_held_case(self, text, case):
        states, restores, prior, status, measured, restored, before, last = case
        result, counts, home = self.held_scene(text, states, restores, prior)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        self.assertEqual(counts, [measured, restored], result.stdout)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[:-1], before)
        self.assertEqual(lines[-1], last % home if last == self.MEASURED else last)

    def test_held_scene(self):
        text = SCENE.read_text()
        for case in self.held_cases():
            with self.subTest(states=case[0], restores=case[1], prior=case[2]):
                self.assert_held_case(text, case)

    def test_held_scene_mutants_turn_red(self):
        # Each plant keeps the matched text's place and removes one rule;
        # the case it names must fail.
        cases = self.held_cases()
        plants = (
            ("no measurement again", "scene_attempts=3", "scene_attempts=1", cases[1]),
            ("a reset is not counted", '"$((mode_resets + 1))"', '"$mode_resets"', cases[2]),
            ("a failed restore is ignored", "hold_restore || {", "hold_restore || true || {", cases[3]),
            ("an unreadable output passes", "      *) printf 'shader-cost: failed output=%s\\n' \"$state\"; exit 1 ;;",
             "      *) break ;;", cases[4]),
        )
        text = SCENE.read_text()
        for name, old, new, case in plants:
            with self.subTest(name=name):
                self.assertEqual(text.count(old), 1)
                changed = text.replace(old, new)
                self.assertNotEqual(changed, text)
                with self.assertRaises(AssertionError):
                    self.assert_held_case(changed, case)

    def runner_copy(self, root, harness, text, args=(), scene=None, readings=None):
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
        if scene is None:
            shutil.copyfile(SCENE, scripts / "shader/measure-scene.sh")
        else:
            (scripts / "shader/measure-scene.sh").write_text(scene)
        if readings is not None:
            (scripts / "shader/readings.py").write_text(readings)
        shutil.copyfile(ROOT.parent / "shell/Ui/feedback/shaders/voiceorb.frag", root / "shell/Ui/feedback/shaders/voiceorb.frag")
        (scripts / "smoke/harness.sh").write_text(harness)
        compiler = root / "qsb stand-in"
        compiler.write_text(f"""#!{sys.executable}
import json, os, pathlib, sys
pathlib.Path(os.environ["HOME"], "compiler-args.json").write_text(json.dumps(sys.argv[1:]))
""")
        compiler.chmod(0o755)
        return subprocess.run(
            ["bash", str(script), *args],
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

    def test_runs_needs_calibration(self):
        # Check mode judges one pass; the refusals come before the harness,
        # whose stand-in says so if it is reached.
        harness = "echo 'shader-test: harness-reached'; exit 0\n"
        cases = (
            (["--runs", "2"], "shader-cost: refused argument=--runs without=--calibrate"),
            (["--calibrate", "out.json", "--runs", "0"], "shader-cost: refused argument=--runs value=0"),
            (["--calibrate", "out.json", "--runs"], "shader-cost: refused argument=--runs value="),
        )
        text = RUNNER.read_text()
        old = "${choice[0]} != --calibrate"
        self.assertEqual(text.count(old), 1)
        changed = text.replace(old, "${choice[0]} == never")
        self.assertNotEqual(changed, text)
        with tempfile.TemporaryDirectory() as scratch:
            for index, (args, line) in enumerate(cases):
                with self.subTest(args=args):
                    result = self.runner_copy(Path(scratch) / str(index), harness, text, args)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, line + "\n")
            result = self.runner_copy(Path(scratch) / "mutant", harness, changed, cases[0][0])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("shader-test: harness-reached", result.stdout)

    def test_pass_loop(self):
        # The harness, the scene owner and the reader are stand-ins that
        # record what the runner hands them; the runner's own loop runs.
        harness = """
home="$HOME"; sandbox="$HOME/sandbox"
shell_env=(env -i PATH=/usr/bin:/bin HOME="$HOME")
mkdir -p -- "$sandbox"
failures=0; mode_hold=()
first_name() { echo WAYLAND-1; }
unscaled_mode_of() { echo 1755x933; }
hidpi_mode_of() { echo 3510x1866; }
hold_mode() { mode_hold=("$2" "$3 scale=$4"); }
release_mode() { mode_hold=(); }
"""
        scene = """
measure_held_scene() { printf 'held %s %s %s\\n' "$1" "$2" "${3#"$logs"/}" >>"$home/scenes"; }
measure_scene() { printf 'bare %s %s %s\\n' "$1" "$2" "${3#"$logs"/}" >>"$home/scenes"; }
"""
        readings = """import json, pathlib, sys
pathlib.Path(__file__).with_name("readings-args.json").write_text(json.dumps(sys.argv[1:]))
"""
        passes = 2
        want = [f"held {scale} {mode} run-{run}/scale-{scale}-{mode}"
                for run in range(1, passes + 1) for scale in (1, 2) for mode in ("off", "on", "costly")]
        text = RUNNER.read_text()
        plants = (
            ('measure_held_scene "$scale" "$scene"', 'measure_scene "$scale" "$scene"'),
            ("run <= runs;", "run <= 1;"),
            ('"${passes[@]}"', '"${passes[0]}"'),
        )
        sources = [text]
        for old, new in plants:
            self.assertEqual(text.count(old), 1, old)
            sources.append(text.replace(old, new))
            self.assertNotEqual(sources[-1], text)
        with tempfile.TemporaryDirectory() as scratch:
            for index, source in enumerate(sources):
                with self.subTest(mutant=index):
                    root = Path(scratch) / str(index)
                    result = self.runner_copy(root, harness, source, ["--calibrate", "out.json", "--runs", str(passes)],
                                              scene, readings)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    logs = [line.split("=", 1)[1] for line in result.stdout.splitlines()
                            if line.startswith("shader-cost: logs=")]
                    self.assertEqual(len(logs), 1, result.stdout)
                    scenes = (root / "home/scenes").read_text().splitlines()
                    args = json.loads((root / "scripts/shader/readings-args.json").read_text())
                    held = (scenes == want
                            and args == [f"{logs[0]}/run-{run}" for run in range(1, passes + 1)] + ["--calibrate", "out.json"])
                    self.assertEqual(held, index == 0, f"scenes={scenes} readings={args}")

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
