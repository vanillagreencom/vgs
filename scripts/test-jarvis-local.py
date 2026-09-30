#!/usr/bin/env python3
"""Consumer contract controls, not model feasibility or speech quality.

All child processes run in the shared Jarvis world. Neutral local bytes test
the verifier, never inference. The external recognizer double checks the
consumer's decode call, not a replacement speech algorithm.
"""
import copy
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile
import io
import contextlib
import wave
import unittest

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "shell/plugins/vgs.jarvis/measure-local"


def namespace_entry():
    """Enter the existing environment owner rather than duplicate its rules."""
    if os.environ.get("JARVIS_TEST_ROOT"):
        return
    with tempfile.TemporaryDirectory(prefix="jarvis-local-standins-") as name:
        result = subprocess.run(
            [str(REPO / "scripts/lib/jarvis-env.sh"), str(Path(name).resolve()), "--",
             sys.executable, str(Path(__file__).resolve())],
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}, check=False)
    raise SystemExit(result.returncode)


class LocalContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.program = self.root / "measure-local"
        self.program.write_text(SOURCE.read_text())
        (self.root / "fixtures").mkdir()
        for name in ("probe.txt", "probe.wav"):
            (self.root / "fixtures" / name).write_bytes((SOURCE.parent / "fixtures" / name).read_bytes())
        self.spec = json.loads((SOURCE.parent / "artifacts.json").read_text())
        # An inert verifier fixture. No fake model ever enters a speech runtime.
        data = b"local verifier fixture"
        digest = hashlib.sha256(data).hexdigest()
        self.models = self.root / "models"
        (self.models / "export").mkdir(parents=True)
        (self.models / "model").write_bytes(data)
        (self.models / "export/model").write_bytes(data)
        a = self.spec["artifacts"][0]
        a.update(directory="export", url="https://fixture.invalid/model", sha256=digest,
                 files={"model": digest})
        self.spec["artifacts"] = [a]
        self.spec["tiers"] = {"probe": {"provider": "cpu", "artifacts": ["parakeet"]}}

    def command(self, spec=None, mode="--check"):
        path = self.root / "artifacts.json"
        path.write_text(json.dumps(self.spec if spec is None else spec))
        result = subprocess.run(
            [sys.executable, str(self.program), "--manifest", str(path),
             "--models", str(self.models), mode],
            env={"PATH": os.environ["PATH"], "LC_ALL": "C", "HOME": str(self.root),
                 "TMPDIR": str(self.root), "VGS_TEST_RUN": "1"},
            capture_output=True, text=True, check=False)
        return result

    def mutant(self, needle):
        text = SOURCE.read_text()
        self.assertEqual(text.count(needle), 1, needle)
        changed = text.replace(needle, "if False:")
        self.assertNotEqual(changed, text)
        self.program.write_text(changed)

    def test_metadata_rules_and_controls(self):
        # Each row plants only its named defect, then disables only the
        # enforcing condition on a disposable program copy.
        cases = [
            ("schema", lambda s: s.update(schemaVersion=2),
             'if value["schemaVersion"] != 1:', "schemaVersion=unsupported"),
            ("empty", lambda s: (s.update(artifacts=[]), s.update(tiers={})),
             "if not ids or len(ids) != len(set(ids)):", "artifacts=empty-or-duplicate"),
            ("duplicate", lambda s: s["artifacts"].append(copy.deepcopy(s["artifacts"][0])),
             "if not ids or len(ids) != len(set(ids)):", "artifacts=empty-or-duplicate"),
            ("path", lambda s: s["artifacts"][0].update(directory="../elsewhere"),
             'if path.is_absolute() or ".." in path.parts:', "path=outside-root"),
            ("url", lambda s: s["artifacts"][0].update(url="http://fixture.invalid/model"),
             'if urlparse(artifact["url"]).scheme != "https":', "url=not-https"),
            ("revision", lambda s: s["artifacts"][0].update(revision=""),
             'if not artifact["revision"] or not artifact["languages"] or not artifact["modelLicense"]:', "metadata=missing"),
            ("languages", lambda s: s["artifacts"][0].update(languages=[]),
             'if not artifact["revision"] or not artifact["languages"] or not artifact["modelLicense"]:', "metadata=missing"),
            ("licence", lambda s: s["artifacts"][0].update(modelLicense=""),
             'if not artifact["revision"] or not artifact["languages"] or not artifact["modelLicense"]:', "metadata=missing"),
            ("runtime", lambda s: s["artifacts"][0].update(runtime="missing"),
             'if artifact["runtime"] not in value["runtimes"] or not artifact["files"]:', "runtime-or-files=missing"),
            ("files", lambda s: s["artifacts"][0].update(files={}),
             'if artifact["runtime"] not in value["runtimes"] or not artifact["files"]:', "runtime-or-files=missing"),
            ("file digest", lambda s: s["artifacts"][0].update(files={"model": "not-a-digest"}),
             'if not re.fullmatch(r"[0-9a-f]{64}", digest):', "sha256=invalid"),
            ("archive digest", lambda s: s["artifacts"][0].update(sha256="not-a-digest"),
             'if not re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]):', "archive-sha256=invalid"),
            ("tier", lambda s: s["tiers"]["probe"].update(artifacts=["unknown"]),
             'if not tier["artifacts"] or any(a not in ids for a in tier["artifacts"]):', "tier=unknown-or-empty"),
            ("bound", lambda s: s["artifacts"][0].update(maxInputSamples=0),
             'if "maxInputSamples" in artifact and (type(artifact["maxInputSamples"]) is not int or artifact["maxInputSamples"] <= 0):', "input-bound=invalid"),
        ]
        for name, plant, needle, diagnostic in cases:
            with self.subTest(name=name):
                self.program.write_text(SOURCE.read_text())
                bad = copy.deepcopy(self.spec)
                plant(bad)
                result = self.command(bad)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("measure-local: failed=" + diagnostic, result.stderr)
                self.mutant(needle)
                result = self.command(bad)
                self.assertEqual(result.returncode, 0, "must-fail control did not redden: " + result.stderr)
        self.program.write_text(SOURCE.read_text())
        self.assertEqual(self.command().stdout.strip(), "measure-local: manifest=ok")

    def test_local_input_verification(self):
        self.assertEqual(self.command(mode="--verify").stdout.strip(), "measure-local: inputs=ok")
        (self.models / "export/model").write_bytes(b"corrupt local bytes")
        result = self.command(mode="--verify")
        self.assertEqual(result.returncode, 1)
        self.assertIn("input=hash-mismatch", result.stderr)
        self.mutant("if sha256(path) != digest:")
        self.assertEqual(self.command(mode="--verify").returncode, 0)
        self.program.write_text(SOURCE.read_text())
        (self.models / "export/model").unlink()
        result = self.command(mode="--verify")
        self.assertEqual(result.returncode, 77)
        self.assertIn("status=not-measured input=missing", result.stderr)

    def test_fixture_integrity_control(self):
        (self.root / "fixtures/probe.txt").write_text("altered transcript")
        result = self.command()
        self.assertEqual(result.returncode, 1)
        self.assertIn("fixture=hash-mismatch", result.stderr)
        self.mutant('if sha256(path) != fixture["audioSha256"] or sha256(text_path) != fixture["transcriptSha256"]:')
        self.assertEqual(self.command().returncode, 0)

    def test_fixture_format_controls(self):
        cases = [
            (2, 2, 16000, b"\0" * 8, "fixture=format-invalid",
             "if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):"),
            (1, 1, 16000, b"\0" * 8, "fixture=format-invalid",
             "if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):"),
            (1, 2, 8000, b"\0" * 8, "fixture=format-invalid",
             "if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):"),
            (1, 2, 16000, b"", "fixture=empty", "if not data:"),
        ]
        for channels, width, rate, data, diagnostic, needle in cases:
            with self.subTest(diagnostic=diagnostic, rate=rate, width=width, channels=channels):
                self.program.write_text(SOURCE.read_text())
                path = self.root / "fixtures/probe.wav"
                with wave.open(str(path), "wb") as out:
                    out.setnchannels(channels)
                    out.setsampwidth(width)
                    out.setframerate(rate)
                    out.writeframes(data)
                self.spec["fixture"]["audioSha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                result = self.command()
                self.assertEqual(result.returncode, 1)
                self.assertIn(diagnostic, result.stderr)
                self.mutant(needle)
                self.assertEqual(self.command().returncode, 0)
        self.program.write_text(SOURCE.read_text())
        path.write_bytes((SOURCE.parent / "fixtures/probe.wav").read_bytes())
        self.spec["fixture"]["audioSha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        text = self.root / "fixtures/probe.txt"
        text.write_text("")
        self.spec["fixture"]["transcriptSha256"] = hashlib.sha256(text.read_bytes()).hexdigest()
        self.assertEqual(self.command().returncode, 1)
        self.mutant("if not text:")
        self.assertEqual(self.command().returncode, 0)

    def test_consumer_decode_control(self):
        class Recognizer:
            def create_stream(self):
                class Stream:
                    def accept_waveform(self, rate, samples):
                        self.result = type("Result", (), {"text": ""})()
                return Stream()

            def decode_stream(self, stream):
                stream.result.text = "external recognizer result"

        artifact = {"engine": "parakeet", "id": "parakeet"}
        self.assertEqual(self.load_module().infer(artifact, Recognizer(), [0.1], "", self.spec, None),
                         {"text": "external recognizer result", "chunk_samples": [1], "input_samples": 1})
        text = SOURCE.read_text()
        needle = "            model.decode_stream(stream)\n            if not stream.result.text.strip():"
        self.assertEqual(text.count(needle), 1)
        changed = text.replace(needle, "            pass  # decode call removed by control\n            if not stream.result.text.strip():")
        self.assertNotEqual(text, changed)
        self.program.write_text(changed)
        with self.assertRaisesRegex(ValueError, "inference=empty-transcript"):
            self.load_module().infer(artifact, Recognizer(), [0.1], "", self.spec, None)

    def load_module(self, builtins_override=None):
        loader = importlib.machinery.SourceFileLoader("local_contract", str(self.program))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        if builtins_override is not None:
            module.__dict__["__builtins__"] = builtins_override
        loader.exec_module(module)
        return module

    def test_fixture_outcomes_and_controls(self):
        cases = [
            ("parakeet", {"text": "unrelated nonempty text"},
             'if not all(word in words for word in fixture["transcriptWords"]):', "transcript-mismatch"),
            ("piper", {"sample_rate": 16000, "audio_seconds": 2},
             'if result["sample_rate"] != artifact["outputSampleRate"] or result["audio_seconds"] < 1:', "audio-mismatch"),
            ("piper", {"sample_rate": 22050, "audio_seconds": 0.01},
             'if result["sample_rate"] != artifact["outputSampleRate"] or result["audio_seconds"] < 1:', "audio-mismatch"),
            ("silero", {"segments": [{"samples": 1}]},
             'if sum(segment["samples"] for segment in result["segments"]) < fixture["minimumSpeechSamples"]:', "speech-mismatch"),
            ("smart-turn", {"probability": 0.1},
             'if result["probability"] <= fixture["minimumTurnProbability"]:', "turn-mismatch"),
            ("wake", {"decode_calls": 0},
             'if result["decode_calls"] <= 0:', "wake-not-decoded"),
        ]
        for engine, result, needle, diagnostic in cases:
            with self.subTest(engine=engine, diagnostic=diagnostic):
                self.program.write_text(SOURCE.read_text())
                artifact = {"engine": engine, "id": engine, "outputSampleRate": 22050}
                with self.assertRaisesRegex(ValueError, "fixture=" + diagnostic):
                    self.load_module().outcome(artifact, result, self.spec)
                self.mutant(needle)
                self.load_module().outcome(artifact, result, self.spec)

    def test_bounded_chunks_preserve_input(self):
        class Recognizer:
            def __init__(self):
                self.inputs = []

            def create_stream(self):
                owner = self
                class Stream:
                    def accept_waveform(self, rate, samples):
                        owner.inputs.append((rate, samples))
                        self.result = type("Result", (), {"text": "read this local test"})()
                return Stream()

            def decode_stream(self, stream):
                pass

        artifact = {"engine": "moonshine", "id": "moonshine", "maxInputSamples": 3}
        model = Recognizer()
        result = self.load_module().infer(artifact, model, [1, 2, 3, 4, 5, 6, 7], "", self.spec, None)
        self.assertEqual(model.inputs, [(16000, [1, 2, 3]), (16000, [4, 5, 6]), (16000, [7])])
        self.assertEqual(result["chunk_samples"], [3, 3, 1])
        # Disabling the bound must turn the same independent assertion red.
        text = SOURCE.read_text()
        needle = 'bound = artifact.get("maxInputSamples", len(samples))'
        self.assertEqual(text.count(needle), 1)
        self.program.write_text(text.replace(needle, "bound = len(samples)"))
        model = Recognizer()
        self.load_module().infer(artifact, model, [1, 2, 3, 4, 5, 6, 7], "", self.spec, None)
        self.assertNotEqual(model.inputs, [(16000, [1, 2, 3]), (16000, [4, 5, 6]), (16000, [7])])

    def test_whisper_later_segment_executes(self):
        # The double emits a later marker only after decode_stream consumes
        # that segment. Submission counts alone cannot satisfy this assertion.
        class Recognizer:
            def create_stream(self):
                class Stream:
                    def accept_waveform(self, rate, samples):
                        self.samples = samples
                        self.result = type("Result", (), {"text": ""})()
                return Stream()

            def decode_stream(self, stream):
                visible = stream.samples[:464000]
                stream.result.text = "later-segment" if 2 in visible else "first-segment"

        spec = json.loads((SOURCE.parent / "artifacts.json").read_text())
        artifact = next(a for a in spec["artifacts"] if a["id"] == "whisper")
        self.assertEqual(artifact["maxInputSamples"], 464000)
        samples = [1] * 464000 + [2] * 32000
        result = self.load_module().infer(artifact, Recognizer(), samples, "", self.spec, None)
        self.assertEqual(result["text"], "first-segment later-segment")
        text = SOURCE.read_text()
        needle = "for offset in range(0, len(samples), bound):"
        self.assertEqual(text.count(needle), 1)
        self.program.write_text(text.replace(needle, "for offset in range(0, min(len(samples), bound), bound):"))
        result = self.load_module().infer(artifact, Recognizer(), samples, "", self.spec, None)
        self.assertNotEqual(result["text"], "first-segment later-segment")
        # A single oversized call also loses the marker in the bounded SDK.
        needle = 'bound = artifact.get("maxInputSamples", len(samples))'
        self.assertEqual(text.count(needle), 1)
        self.program.write_text(text.replace(needle, "bound = len(samples)"))
        result = self.load_module().infer(artifact, Recognizer(), samples, "", self.spec, None)
        self.assertNotEqual(result["text"], "first-segment later-segment")

    def test_provider_vocabulary_controls(self):
        for provider in ("gpu", None, 1, [], {}, True):
            with self.subTest(provider=provider):
                self.program.write_text(SOURCE.read_text())
                bad = copy.deepcopy(self.spec)
                bad["tiers"]["probe"]["provider"] = provider
                result = self.command(bad)
                self.assertEqual(result.returncode, 1)
                self.assertIn("tier-provider=invalid", result.stderr)
                self.mutant('if type(tier["provider"]) is not str or tier["provider"] not in PROVIDERS:')
                self.assertEqual(self.command(bad).returncode, 0)
        self.program.write_text(SOURCE.read_text())
        bad = copy.deepcopy(self.spec)
        bad["artifacts"][0]["providers"] = ["gpu"]
        self.assertEqual(self.command(bad).returncode, 1)
        self.mutant('if not isinstance(artifact["providers"], list) or not artifact["providers"] or any(type(p) is not str or p not in PROVIDERS for p in artifact["providers"]):')
        self.assertEqual(self.command(bad).returncode, 0)
        self.program.write_text(SOURCE.read_text())
        from types import SimpleNamespace
        sdk = SimpleNamespace(OfflineRecognizer=SimpleNamespace(from_moonshine_v2=lambda **kwargs: kwargs))
        artifact = {"id": "moonshine", "engine": "moonshine", "directory": ".", "providers": ["cpu"]}
        self.assertEqual(self.load_module().load(artifact, self.root, "cuda", None, sdk)["provider"], "cpu")

    def test_sampler_primary_and_secondary_controls(self):
        text = SOURCE.read_text()
        call = "\n        main()\n"
        self.assertEqual(text.count(call), 1)
        for primary in ('RuntimeError("fixture-native-failure")', 'ValueError("fixture-output-failure")'):
            body = '\n        with GpuSamples(False) as gpu:\n            gpu.error = TimeoutError("fixture-sampler-timeout")\n            raise ' + primary + '\n'
            self.program.write_text(text.replace(call, body))
            result = self.command()
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("measure-local: failed=fixture-", result.stderr)
            self.assertIn("secondary-error=gpu-sampler cause=fixture-sampler-timeout", result.stderr)
            needle = "if primary is not None:"
            self.assertEqual(text.count(needle), 1)
            self.program.write_text(text.replace(call, body).replace(needle, "if False:"))
            result = self.command()
            self.assertEqual(result.returncode, 77)
        body = '\n        with GpuSamples(False) as gpu:\n            gpu.error = TimeoutError("fixture-sampler-timeout")\n'
        self.program.write_text(text.replace(call, body))
        result = self.command()
        self.assertEqual(result.returncode, 77)
        self.assertIn("status=not-measured gpu-sampler=failed", result.stderr)
        needle = "if self.error:"
        self.assertEqual(text.count(needle), 1)
        self.program.write_text(text.replace(call, body).replace(needle, "if False:"))
        self.assertEqual(self.command().returncode, 0)
        self.program.write_text(text)
        module = self.load_module()
        gpu = module.GpuSamples(False)
        class Thread:
            def join(self):
                self.joined = True
                gpu.error = TimeoutError("during-cleanup")
        worker = Thread()
        gpu.thread = worker
        diagnostics = io.StringIO()
        with contextlib.redirect_stderr(diagnostics):
            with self.assertRaisesRegex(RuntimeError, "primary"):
                with gpu:
                    raise RuntimeError("primary")
        self.assertTrue(worker.joined)
        self.assertTrue(gpu.stop.is_set())
        self.assertIn("during-cleanup", diagnostics.getvalue())

    def test_synthesis_speed_control(self):
        module = self.load_module()
        artifact = {"engine": "piper"}
        self.assertEqual(module.speed([artifact], [{"audio_seconds": 10}], 2, 0.5), (0.05, "generated-audio"))
        self.assertEqual(module.speed([artifact, {"engine": "moonshine"}], [], 2, 0.5), (0.25, "tier-input-audio"))
        text = SOURCE.read_text()
        needle = 'elapsed / warm[0]["audio_seconds"]'
        self.assertEqual(text.count(needle), 1)
        self.program.write_text(text.replace(needle, "elapsed / input_seconds"))
        self.assertNotEqual(self.load_module().speed([artifact], [{"audio_seconds": 10}], 2, 0.5), (0.05, "generated-audio"))

    def test_auxiliary_archive_controls(self):
        self.spec["artifacts"][0].update(
            url="https://fixture.invalid/export.tar.bz2", auxiliaryDirectories=["data"])
        data = b"pinned phonemizer data"
        (self.models / "export/data").mkdir()
        (self.models / "export/data/table").write_bytes(data)
        archive = self.models / "export.tar.bz2"
        with tarfile.open(archive, "w:bz2") as out:
            item = tarfile.TarInfo("export/data/table")
            item.size = len(data)
            out.addfile(item, io.BytesIO(data))
        self.spec["artifacts"][0]["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.assertEqual(self.command(mode="--verify").returncode, 0)

        (self.models / "export/data/table").write_bytes(b"changed")
        result = self.command(mode="--verify")
        self.assertEqual(result.returncode, 1)
        self.assertIn("auxiliary=hash-mismatch", result.stderr)
        self.mutant("if sha256(path) != expected:")
        self.assertEqual(self.command(mode="--verify").returncode, 0)
        # A directory name in the manifest must actually occur in the archive.
        self.program.write_text(SOURCE.read_text())
        self.spec["artifacts"][0]["auxiliaryDirectories"] = ["empty"]
        (self.models / "export/empty").mkdir()
        result = self.command(mode="--verify")
        self.assertEqual(result.returncode, 1)
        self.assertIn("auxiliary=archive-empty", result.stderr)
        self.mutant("if not count:")
        self.assertEqual(self.command(mode="--verify").returncode, 0)

    def test_gpu_process_filter_control(self):
        from types import SimpleNamespace
        pid = os.getpid()
        def read(module):
            module.subprocess = SimpleNamespace(run=lambda *args, **kwargs:
                SimpleNamespace(stdout=f"{pid}, 32\n{pid + 1}, 99\n"))
            return module.GpuSamples(True).read()
        self.assertEqual(read(self.load_module()), 32 * 1024 * 1024)
        text = SOURCE.read_text()
        needle = "if int(pid) == os.getpid():"
        self.assertEqual(text.count(needle), 1)
        self.program.write_text(text.replace(needle, "if True:"))
        self.assertNotEqual(read(self.load_module()), 32 * 1024 * 1024)

    def test_namespace_guard_control(self):
        from types import SimpleNamespace
        def instrument():
            module = self.load_module()
            missing = module.importlib.metadata.PackageNotFoundError
            module.socket = SimpleNamespace(if_nameindex=lambda: [(1, "lo"), (2, "fixture-interface")])
            module.importlib = SimpleNamespace(metadata=SimpleNamespace(
                version=lambda name: "fixture-unavailable-version", PackageNotFoundError=missing))
            return module
        module = instrument()
        with self.assertRaisesRegex(ValueError, "isolation=network-namespace-required"):
            module.run(self.spec, [], self.models, "cpu", None, "probe")
        self.mutant('if {name for _, name in socket.if_nameindex()} - {"lo"}:')
        module = instrument()
        with self.assertRaisesRegex(module.Unavailable, "runtime=version-mismatch"):
            module.run(self.spec, [], self.models, "cpu", None, "probe")

    def test_runtime_version_guard_control(self):
        import builtins
        from types import SimpleNamespace
        def instrument():
            original = builtins.__import__
            def import_dependency(name, *args, **kwargs):
                if name == "numpy":
                    raise ImportError("control-reached-runtime-import")
                return original(name, *args, **kwargs)
            module = self.load_module(dict(vars(builtins), __import__=import_dependency))
            missing = module.importlib.metadata.PackageNotFoundError
            module.socket = SimpleNamespace(if_nameindex=lambda: [(1, "lo")])
            module.importlib = SimpleNamespace(metadata=SimpleNamespace(
                version=lambda name: "fixture-unavailable-version", PackageNotFoundError=missing))
            return module
        module = instrument()
        with self.assertRaisesRegex(module.Unavailable, "runtime=version-mismatch"):
            module.run(self.spec, [], self.models, "cpu", None, "probe")
        self.mutant('if versions[name] not in runtime["versions"]:')
        module = instrument()
        with self.assertRaisesRegex(ImportError, "control-reached-runtime-import"):
            module.run(self.spec, [], self.models, "cpu", None, "probe")

class ConsumerContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.repo = self.root / "repo"
        folder = self.repo / "shell/plugins/vgs.jarvis"
        folder.mkdir(parents=True)
        self.models = self.root / "prepared/models"
        self.models.mkdir(parents=True)
        self.python = self.root / "prepared/venv/bin/python"
        self.python.parent.mkdir(parents=True)
        self.python.symlink_to(sys.executable)
        self.ids = ["parakeet", "moonshine", "whisper", "kokoro", "piper",
                    "silero", "smart-turn", "wake", "nemotron"]
        (folder / "artifacts.json").write_text(json.dumps({"artifacts": [{"id": n} for n in self.ids]}))
        self.control = folder / "control.json"
        self.control.write_text("{}")
        # This is an external inference-program double. It tests the real
        # consumer's verdict, never actual model execution or performance.
        (folder / "measure-local").write_text(
            'import argparse,json,pathlib,sys\n'
            'p=argparse.ArgumentParser(); p.add_argument("--models"); p.add_argument("--artifact"); a=p.parse_args()\n'
            'c=json.loads((pathlib.Path(__file__).parent/"control.json").read_text())\n'
            'if not pathlib.Path(a.models).is_absolute() or not pathlib.Path(a.models).is_dir():\n'
            ' print("fixture-path-not-resolved",file=sys.stderr); sys.exit(42)\n'
            'r={"artifact_ids":[a.artifact],"warm_turn_seconds":0.1,"results":[{"decode_calls":1}],'
            '"models_path":a.models,"python_executable":sys.executable}\n'
            'if a.artifact=="wake": r.update(c.get("reading",{}))\n'
            'print(json.dumps(r))\n'
            'if a.artifact=="wake" and c.get("exit"):\n'
            ' print("fixture-child-error",file=sys.stderr); sys.exit(c["exit"])\n')
        self.consumer = self.repo / "scripts/fixtures/jarvis-local/run.py"
        self.consumer.parent.mkdir(parents=True)
        self.consumer_source = (REPO / "scripts/fixtures/jarvis-local/run.py").read_text()
        self.consumer.write_text(self.consumer_source)
        self.runner = self.repo / "scripts/check-jarvis-local.sh"
        self.runner_source = (REPO / "scripts/check-jarvis-local.sh").read_text()
        self.runner.write_text(self.runner_source)
        self.runner.chmod(0o755)
        helper = self.repo / "scripts/lib/jarvis-env.sh"
        helper.parent.mkdir(parents=True)
        helper.write_bytes((REPO / "scripts/lib/jarvis-env.sh").read_bytes())
        helper.chmod(0o755)
        self.env = {k: os.environ[k] for k in ("PATH", "HOME", "XDG_CONFIG_HOME",
                    "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR",
                    "TMPDIR", "LC_ALL", "VGS_TEST_RUN")}
        self.env["JARVIS_TEST_SCRATCH_ROOT"] = str(self.root)
        tools = self.root / "tools"
        tools.mkdir()
        # The shared world deliberately omits host mktemp. This neutral
        # scratch-provider double stays inside that world and its ownership.
        scratch_tool = tools / "mktemp"
        scratch_tool.write_text("#!/usr/bin/env python3\nimport tempfile\nprint(tempfile.mkdtemp())\n")
        scratch_tool.chmod(0o755)
        self.env["PATH"] = str(tools) + ":" + self.env["PATH"]

    def run_consumer(self):
        return subprocess.run([sys.executable, str(self.consumer), str(self.repo), str(self.models)],
                              env=self.env, capture_output=True, text=True, check=False)

    def test_consumer_verdict_rules(self):
        cases = [
            ("discovery-floor", {"ids": self.ids[:-1]},
             'if len(ids) < 9 or "nemotron" not in ids:', 1, "artifact discovery is incomplete"),
            ("required-member", {"ids": self.ids[:-1] + ["other"]},
             'if len(ids) < 9 or "nemotron" not in ids:', 1, "artifact discovery is incomplete"),
            ("child-exit", {"exit": 42},
             "if child.returncode:", 42, "fixture-child-error"),
            ("identity", {"reading": {"artifact_ids": ["wrong"]}},
             'if reading["artifact_ids"] != [name] or reading["warm_turn_seconds"] <= 0:', 1, "missing actual inference reading"),
            ("warm-time", {"reading": {"warm_turn_seconds": 0}},
             'if reading["artifact_ids"] != [name] or reading["warm_turn_seconds"] <= 0:', 1, "missing actual inference reading"),
            ("wake-decode", {"reading": {"results": [{"decode_calls": 0}]}},
             'if name == "wake" and reading["results"][0]["decode_calls"] <= 0:', 1, "wake decoder did not consume the clip"),
        ]
        for name, defect, needle, status, diagnostic in cases:
            with self.subTest(rule=name):
                self.consumer.write_text(self.consumer_source)
                ids = defect.get("ids", self.ids)
                (self.control.parent / "artifacts.json").write_text(json.dumps({"artifacts": [{"id": n} for n in ids]}))
                self.control.write_text(json.dumps(defect))
                result = self.run_consumer()
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn(diagnostic, result.stderr)
                self.assertNotIn("jarvis-local: actual-artifacts=ok", result.stdout)
                self.assertEqual(self.consumer_source.count(needle), 1)
                changed = self.consumer_source.replace(needle, "if False:")
                self.assertNotEqual(changed, self.consumer_source)
                self.consumer.write_text(changed)
                result = self.run_consumer()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("jarvis-local: actual-artifacts=ok", result.stdout)

    def test_runner_availability_and_relative_paths(self):
        result = subprocess.run([str(self.runner)], cwd=self.root, env=self.env,
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 77)
        self.assertIn("prepared-inputs-unavailable", result.stdout)
        needle = 'if [[ -z $models || -z $python || ! -x $python || ! -d $models ]]; then'
        self.assertEqual(self.runner_source.count(needle), 1)
        self.runner.write_text(self.runner_source.replace(needle, "if false; then"))
        result = subprocess.run([str(self.runner)], cwd=self.root, env=self.env,
                                capture_output=True, text=True, check=False)
        self.assertNotIn("prepared-inputs-unavailable", result.stdout)
        self.runner.write_text(self.runner_source)
        env = dict(self.env, JARVIS_LOCAL_MODELS="prepared/models",
                   JARVIS_LOCAL_PYTHON="prepared/venv/bin/python")
        result = subprocess.run([str(self.runner)], cwd=self.root, env=env,
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("jarvis-local: actual-artifacts=ok", result.stdout)
        readings = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        self.assertEqual([r["artifact_ids"][0] for r in readings], self.ids)
        self.assertTrue(all(r["models_path"] == str(self.models) for r in readings))
        self.assertTrue(all(r["python_executable"] == str(self.python) for r in readings))
        for needle, replacement in (
            ('models="$(cd -- "$models" && pwd -P)"', 'models="$models"'),
            ('python="$python_dir/$(basename -- "$python")"', 'python="$python"'),
        ):
            self.assertEqual(self.runner_source.count(needle), 1)
            changed = self.runner_source.replace(needle, replacement)
            self.assertNotEqual(changed, self.runner_source)
            self.runner.write_text(changed)
            result = subprocess.run([str(self.runner)], cwd=self.root, env=env,
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("jarvis-local: actual-artifacts=ok", result.stdout)
        self.runner.write_text(self.runner_source)
        env["JARVIS_LOCAL_MODELS"] = "prepared/missing-models"
        result = subprocess.run([str(self.runner)], cwd=self.root, env=env,
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 77)

    def test_unbounded_probe_control(self):
        program = self.control.parent / "measure-local"
        program.write_text(
            'import json\n'
            'class Unavailable(Exception): pass\n'
            'def sha256(path): return "fixture-digest"\n'
            'def manifest(path): return {"runtimes":{},"artifacts":[{"id":"moonshine","maxInputSamples":80000}]}\n'
            'def run(value, artifacts, models, provider, seconds, scope):\n'
            ' present="maxInputSamples" in artifacts[0]\n'
            ' print(json.dumps({"scope":scope,"seconds":seconds,"bound_present":present}),flush=True)\n'
            ' if present: raise RuntimeError("fixture-bound-still-active")\n'
            ' raise ValueError("inference=empty-transcript id=moonshine")\n')
        probe = self.consumer.parent / "probe-moonshine.py"
        source = (REPO / "scripts/fixtures/jarvis-local/probe-moonshine.py").read_text()
        probe.write_text(source)
        command = [sys.executable, str(probe), str(self.repo), str(self.models)]
        result = subprocess.run(command, env=self.env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("inference=empty-transcript", result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(records[-1], {"scope": "moonshine-unbounded", "seconds": 60, "bound_present": False})
        self.assertFalse((self.control.parent / "__pycache__").exists())
        needle = "sys.dont_write_bytecode = True"
        self.assertEqual(source.count(needle), 1)
        probe.write_text(source.replace(needle, "sys.dont_write_bytecode = False"))
        result = subprocess.run(command, env=self.env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertTrue((self.control.parent / "__pycache__").exists())
        needle = 'del artifact["maxInputSamples"]'
        self.assertEqual(source.count(needle), 1)
        probe.write_text(source.replace(needle, "pass  # bound removal disabled by control"))
        result = subprocess.run(command, env=self.env, text=True, capture_output=True, check=False)
        self.assertNotIn("inference=empty-transcript", result.stderr)
        self.assertIn("fixture-bound-still-active", result.stderr)


if __name__ == "__main__":
    namespace_entry()
    unittest.main()
