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
        def module():
            loader = importlib.machinery.SourceFileLoader("local_measure", str(self.program))
            spec = importlib.util.spec_from_loader(loader.name, loader)
            value = importlib.util.module_from_spec(spec)
            loader.exec_module(value)
            return value

        class Recognizer:
            def create_stream(self):
                class Stream:
                    def accept_waveform(self, rate, samples):
                        self.result = type("Result", (), {"text": ""})()
                return Stream()

            def decode_stream(self, stream):
                stream.result.text = "external recognizer result"

        artifact = {"engine": "parakeet", "id": "parakeet"}
        self.assertEqual(module().infer(artifact, Recognizer(), [0.1], "", self.spec, None),
                         {"text": "external recognizer result", "chunk_samples": [1], "input_samples": 1})
        text = SOURCE.read_text()
        needle = "            model.decode_stream(stream)\n            if not stream.result.text.strip():"
        self.assertEqual(text.count(needle), 1)
        changed = text.replace(needle, "            pass  # decode call removed by control\n            if not stream.result.text.strip():")
        self.assertNotEqual(text, changed)
        self.program.write_text(changed)
        with self.assertRaisesRegex(ValueError, "inference=empty-transcript"):
            module().infer(artifact, Recognizer(), [0.1], "", self.spec, None)

    def load_module(self):
        loader = importlib.machinery.SourceFileLoader("local_contract", str(self.program))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
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


if __name__ == "__main__":
    namespace_entry()
    unittest.main()
