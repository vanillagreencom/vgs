#!/usr/bin/env python3
"""Local speech sidecar contract: segmentation, bounded decoding, wire, readiness.

Recognizer, voice activity and voice doubles test the sidecar's own calls, not
model quality; scripts/check-jarvis-local-speech.sh runs the real models. The
suite runs inside the shared Jarvis world. Each control loads a disposable copy
of the sidecar with one planted defect and must turn its case red.
"""
from array import array
import fcntl
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
PLUGIN = REPO / "shell/plugins/vgs.jarvis"
SOURCE = PLUGIN / "backend/local-speech.py"
# Loading the sidecar must leave no bytecode in the plugin tree.
sys.dont_write_bytecode = True


def namespace_entry():
    """Enter the existing environment owner rather than duplicate its rules."""
    if os.environ.get("JARVIS_TEST_ROOT"):
        return
    with tempfile.TemporaryDirectory(prefix="jarvis-local-speech-standins-") as name:
        result = subprocess.run(
            [str(REPO / "scripts/lib/jarvis-env.sh"), str(Path(name).resolve()), "--",
             sys.executable, str(Path(__file__).resolve())],
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}, check=False)
    raise SystemExit(result.returncode)


def load(text=None):
    """The sidecar module, or a disposable copy of it holding text."""
    path = SOURCE
    if text is not None:
        folder = Path(tempfile.mkdtemp(prefix="local-speech-mutant-"))
        (folder / "backend").mkdir()
        path = folder / "backend/local-speech.py"
        path.write_text(text)
    loader = importlib.machinery.SourceFileLoader("local_speech_" + str(abs(hash(str(path)))), str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    value = importlib.util.module_from_spec(spec)
    loader.exec_module(value)
    return value


def mutant(needle, replacement):
    text = SOURCE.read_text()
    if text.count(needle) != 1:
        raise AssertionError("control needle must match once: " + needle)
    changed = text.replace(needle, replacement)
    if changed == text:
        raise AssertionError("control changed nothing: " + needle)
    return load(changed)


def level(total, quiet=()):
    """Unit samples with silent [start, end) windows."""
    samples = array("f", [1.0]) * total
    for start, end in quiet:
        samples[start:end] = array("f", [0.0]) * (end - start)
    return samples


class Vad:
    """Reports the scripted segments after the whole input was offered."""

    def __init__(self, segments):
        self.segments = list(segments)
        self.offered = 0
        self.queue = []

    def reset(self):
        self.offered = 0
        self.queue = []

    def accept_waveform(self, window):
        if len(window) != 512:
            raise AssertionError("the VAD takes whole 512-sample windows")
        self.offered += len(window)

    def flush(self):
        self.queue = [type("Segment", (), {"start": s, "samples": [0.0] * n})() for s, n in self.segments]

    def empty(self):
        return not self.queue

    @property
    def front(self):
        return self.queue[0]

    def pop(self):
        self.queue.pop(0)


class Recognizer:
    """Fresh streams only; text(index, samples) scripts each chunk's result."""

    def __init__(self, text=lambda index, samples: f"w{index}"):
        self.text = text
        self.sizes = []
        self.created = 0

    def create_stream(self):
        self.created += 1
        owner = self

        class Stream:
            accepted = None
            result = None

            def accept_waveform(self, rate, samples):
                if rate != 16000 or self.accepted is not None:
                    raise AssertionError("one 16 kHz input per fresh stream")
                self.accepted = samples

        return Stream()

    def decode_stream(self, stream):
        index = len(self.sizes)
        self.sizes.append(len(stream.accepted))
        stream.result = type("Result", (), {"text": self.text(index, stream.accepted)})()


class Voice:
    def __init__(self, rate=22050, samples=None, error=None):
        self.rate, self.samples, self.error = rate, samples, error

    def generate(self, text, sid, speed):
        if self.error is not None:
            raise self.error
        samples = self.samples if self.samples is not None else [0.25] * 2205
        return type("Audio", (), {"sample_rate": self.rate, "samples": samples})()


def speech(m, segments, bound, recognizer=None, voice=None, rate=22050):
    return m.Speech(recognizer or Recognizer(), bound, Vad(segments), voice or Voice(rate), rate, lambda s: s)


def frame(header, payload=b""):
    head = json.dumps(header).encode()
    return struct.pack(">II", len(head), len(payload)) + head + payload


def floats(count, value=0.5):
    return (array("f", [value]) * count).tobytes()


def answers(data):
    out, offset = [], 0
    while offset < len(data):
        head, size = struct.unpack(">II", data[offset:offset + 8])
        header = json.loads(data[offset + 8:offset + 8 + head])
        out.append((header, data[offset + 8 + head:offset + 8 + head + size]))
        offset += 8 + head + size
    return out


def serve(m, messages, model):
    output = io.BytesIO()
    m.serve(io.BytesIO(b"".join(frame(*message) for message in messages)), output, model)
    return answers(output.getvalue())


# Segmentation rows: name, padded speech spans, input length, bound, silent
# windows, expected chunks. Expected values are written out, not computed.
PLANS = [
    ("whisper bound keeps the final shorter segment", [(0, 960000)], 960000, 464000, (),
     [(0, 464000), (464000, 928000), (928000, 960000)]),
    ("moonshine 60 s fills twelve bounds", [(0, 960000)], 960000, 80000, (),
     [(i * 80000, (i + 1) * 80000) for i in range(12)]),
    ("moonshine final shorter chunk kept", [(0, 200000)], 200000, 80000, (),
     [(0, 80000), (80000, 160000), (160000, 200000)]),
    ("neighbours share a chunk that fits", [(0, 30000), (40000, 70000)], 70000, 80000, (), [(0, 70000)]),
    ("neighbours that do not fit stay apart", [(0, 30000), (50000, 90000)], 90000, 80000, (),
     [(0, 30000), (50000, 90000)]),
    ("a long span is cut at its quietest frame", [(0, 100000)], 100000, 80000, [(60160, 60480)],
     [(0, 60480), (60480, 100000)]),
    ("no speech plans no chunk", [], 48000, 80000, (), []),
]


def plan_case(m, row):
    name, speech_spans, total, bound, silent, expected = row
    chunks = m.plan(speech_spans, bound, level(total, silent))
    if chunks != expected:
        raise AssertionError(f"{name}: {chunks}")
    for (start, end), following in zip(chunks, chunks[1:] + [None]):
        if not 0 < end - start <= bound or (following and following[0] < end):
            raise AssertionError(f"{name}: chunk outside the bound or order {start, end}")
    for span_start, span_end in speech_spans:
        for sample in range(span_start, span_end, 997):
            if not any(start <= sample < end for start, end in chunks):
                raise AssertionError(f"{name}: speech sample {sample} not decoded")


def spans_case(m):
    got = m.spans([(1000, 2000), (7000, 1000), (20000, 500)], 21000, 3200)
    if got != [(0, 11200), (16800, 21000)]:
        raise AssertionError(f"padded spans {got}")
    try:
        m.spans([(5000, 10), (1000, 10)], 9000, 0)
    except RuntimeError as error:
        if str(error) != "vad=segment-order":
            raise
    else:
        raise AssertionError("out-of-order segments accepted")


def transcribe_cases(m):
    # The 464000-sample decoder keeps its final shorter segment on fresh streams.
    recognizer = Recognizer()
    text = speech(m, [(0, 960000)], 464000, recognizer).transcribe(level(960000))
    if (recognizer.sizes, recognizer.created, text) != ([464000, 464000, 32000], 3, "w0 w1 w2"):
        raise AssertionError(f"bounded decoding {recognizer.sizes} {recognizer.created} {text!r}")
    # No bound decodes the whole speech span once.
    recognizer = Recognizer()
    speech(m, [(4000, 8000)], None, recognizer).transcribe(level(48000))
    if recognizer.sizes != [8000 + 2 * 3200]:
        raise AssertionError(f"unbounded decoding {recognizer.sizes}")
    if speech(m, [], 80000).transcribe(level(16000)) != "":
        raise AssertionError("silence is not an empty transcript")
    for name, script, cause in [
            ("empty", lambda index, samples: "" if index == 1 else "w", "chunk-empty index=1"),
            ("failed", lambda index, samples: (_ for _ in ()).throw(RuntimeError("decode")) if index == 2 else "w",
             "chunk-failed index=2")]:
        try:
            text = speech(m, [(0, 240000)], 80000, Recognizer(script)).transcribe(level(240000))
        except m.Failed as failure:
            if str(failure) != cause:
                raise AssertionError(f"{name}: cause {failure}")
        else:
            raise AssertionError(f"{name} chunk became a final: {text!r}")


def wire_cases(m):
    model = speech(m, [(0, 16000)], 80000)
    out = serve(m, [({"type": "audio", "id": 1}, floats(8000)), ({"type": "audio", "id": 1}, floats(8000)),
                    ({"type": "end", "id": 1},)], model)
    if [h for h, _ in out] != [{"type": "final", "id": 1, "text": "w0"}] or model.vad.offered != 16384:
        raise AssertionError(f"utterance {out} {model.vad.offered}")
    # An abort drops the utterance; its later frames crossed the abort.
    out = serve(m, [({"type": "audio", "id": 2}, floats(4)), ({"type": "abort", "id": 2},),
                    ({"type": "audio", "id": 2}, floats(4)), ({"type": "end", "id": 2},),
                    ({"type": "end", "id": 3},)], speech(m, [], 80000))
    if [h for h, _ in out] != [{"type": "final", "id": 3, "text": ""}]:
        raise AssertionError(f"abort {out}")
    out = serve(m, [({"type": "speak", "id": 4}, "Hello.".encode())], model)
    audio = b"".join(p for h, p in out if h["type"] == "audio")
    if out[-1][0] != {"type": "spoken", "id": 4, "rate": 22050} or array("f", audio).tolist() != [0.25] * 2205:
        raise AssertionError(f"speak {[h for h, _ in out]}")
    out = serve(m, [({"type": "speak", "id": 5}, "Hello.".encode())],
                speech(m, [], 80000, voice=Voice(error=RuntimeError("voice"))))
    if [h for h, _ in out] != [{"type": "failed", "id": 5, "cause": "synthesis-failed"}]:
        raise AssertionError(f"synthesis failure {out}")
    for name, voice, cause in [("rate", Voice(rate=16000), "synthesis-rate value=16000"),
                               ("silent", Voice(samples=[0.0] * 10), "synthesis-empty")]:
        out = serve(m, [({"type": "speak", "id": 6}, "Hi.".encode())], speech(m, [], 80000, voice=voice))
        if [h for h, _ in out] != [{"type": "failed", "id": 6, "cause": cause}]:
            raise AssertionError(f"{name}: {out}")


def bound_case(m):
    m.UTTERANCE_SAMPLES = 10
    out = serve(m, [({"type": "audio", "id": 1}, floats(8)), ({"type": "audio", "id": 1}, floats(8)),
                    ({"type": "end", "id": 1},)], speech(m, [(0, 16)], 80000))
    if [h for h, _ in out] != [{"type": "failed", "id": 1, "cause": "utterance-too-long"}]:
        raise AssertionError(f"utterance bound {out}")


# Wire violations: each frame list must end the sidecar with this protocol key.
VIOLATIONS = [
    ("unknown type", [frame({"type": "hello", "id": 1})], "message=invalid type=hello"),
    ("extra key", [frame({"type": "end", "id": 1, "text": "x"})], "message=invalid type=end"),
    ("payload on end", [frame({"type": "end", "id": 1}, b"abcd")], "message=invalid type=end"),
    ("audio without payload", [frame({"type": "audio", "id": 1})], "message=invalid type=audio"),
    ("boolean id", [frame({"type": "end", "id": True})], "id=invalid"),
    ("reused speak id", [frame({"type": "end", "id": 3}), frame({"type": "speak", "id": 3}, b"a")],
     "speak=invalid"),
    ("blank sentence", [frame({"type": "speak", "id": 1}, b" ")], "speak=invalid"),
    ("sentence not UTF-8", [frame({"type": "speak", "id": 1}, b"\xff")], "speak=invalid"),
    ("partial sample", [frame({"type": "audio", "id": 1}, b"abc")], "audio=partial-sample"),
    ("oversized header", [struct.pack(">II", 4097, 0) + b"{" * 4097], "frame=too-large"),
    ("oversized payload", [struct.pack(">II", 2, 65537) + b"{}" + bytes(65537)], "frame=too-large"),
    ("truncated", [frame({"type": "end", "id": 1})[:-1]], "frame=truncated"),
    ("non-object header", [struct.pack(">II", 2, 0) + b"[]"], "header=invalid"),
]


def violation_cases(m):
    for name, data, key in VIOLATIONS:
        try:
            m.serve(io.BytesIO(b"".join(data)), io.BytesIO(), speech(m, [], 80000))
        except m.Protocol as error:
            if str(error) != key:
                raise AssertionError(f"{name}: {error}")
        else:
            raise AssertionError(f"{name}: accepted")


class Setup:
    """setup-local's surface the sidecar uses, answering a fixed status."""

    def __init__(self, tone):
        self.tone = tone
        self.HERE = PLUGIN

    def measurement(self):
        return None

    def status(self, judge, state, data):
        return {"tone": self.tone}


def readiness_cases(m):
    with tempfile.TemporaryDirectory() as name:
        state = Path(name)
        try:
            m.load(Setup("warning"), state, state)
        except m.NotReady as error:
            if str(error) != "runtime-not-ready":
                raise
        else:
            raise AssertionError("a not-ready runtime loaded")
        with (state / "local-setup.lock").open("a") as setup:
            fcntl.flock(setup, fcntl.LOCK_EX)
            try:
                m.hold(state).close()
            except m.NotReady as error:
                if str(error) != "setup-busy":
                    raise
            else:
                raise AssertionError("the sidecar started while setup ran")


def roles_case(m):
    value = json.loads((PLUGIN / "artifacts.json").read_text())
    by_id = {a["id"]: a for a in value["artifacts"]}
    if "small" not in value["tiers"]:
        raise AssertionError("tier discovery is broken: no small tier")
    for tier, row in value["tiers"].items():
        chosen = m.roles([by_id[n] for n in row["artifacts"]], tier)
        if set(chosen) != {"stt", "tts", "vad"}:
            raise AssertionError(f"{tier}: {chosen}")
    try:
        m.roles([by_id["moonshine"], by_id["parakeet"], by_id["piper"], by_id["silero"]], "x")
    except RuntimeError as error:
        if str(error) != "tier=duplicate-role role=stt tier=x":
            raise
    else:
        raise AssertionError("two recognizers accepted")


def run(program, parent, state):
    return subprocess.run([sys.executable, "-I", str(program), "--state", str(state), "--data", str(state),
                           "--parent", str(parent)], env={"PATH": os.environ["PATH"], "LC_ALL": "C"},
                          capture_output=True, check=False)


def main_cases(source):
    """The real entry point: not ready exits 77 with a keyed frame; a foreign parent exits 1."""
    with tempfile.TemporaryDirectory() as name:
        root = Path(name)
        program = root / "backend/local-speech.py"
        program.parent.mkdir()
        program.write_text(source)
        for file in ("setup-local", "measure-local", "artifacts.json"):
            (root / file).write_bytes((PLUGIN / file).read_bytes())
        (root / "fixtures").mkdir()
        for file in ("probe.wav", "probe.txt"):
            (root / "fixtures" / file).write_bytes((PLUGIN / "fixtures" / file).read_bytes())
        state = root / "state"
        state.mkdir()
        result = run(program, os.getpid(), state)
        if result.returncode != 77 or answers(result.stdout) != [({"type": "failed", "cause": "runtime-not-ready"}, b"")]:
            raise AssertionError(f"not ready: {result.returncode} {result.stdout!r} {result.stderr!r}")
        result = run(program, os.getpid() + 1, state)
        if result.returncode != 1 or b"parent=ended" not in result.stderr or result.stdout:
            raise AssertionError(f"foreign parent: {result.returncode} {result.stderr!r}")


def guarded(check, *args):
    def case(m):
        check(m, *args)
    return case


# Controls: name, needle, replacement, the case that must turn red.
CONTROLS = [
    ("bound split", "while end - start > bound:", "while False:", guarded(plan_case, PLANS[0])),
    ("final chunk", "    if current is not None:\n        chunks.append(current)\n    return chunks",
     "    return chunks", guarded(plan_case, PLANS[2])),
    ("merge bound", "if current is not None and end - current[0] <= bound:", "if current is not None:",
     guarded(plan_case, PLANS[4])),
    ("quiet cut", "if least is None or energy < least:", "if least is None:", guarded(plan_case, PLANS[5])),
    ("padding", "low, high = max(0, start - pad), min(total, start + length + pad)",
     "low, high = start, start + length", spans_case),
    ("segment order", "if length <= 0 or start < previous:", "if length <= 0:", spans_case),
    ("fresh stream", "stream = self.recognizer.create_stream()",
     "stream = getattr(self, 'kept', None) or self.recognizer.create_stream(); self.kept = stream",
     transcribe_cases),
    ("empty chunk", "if not text:", "if False:", transcribe_cases),
    ("failed chunk", 'raise Failed(f"chunk-failed index={index}") from error', "continue", transcribe_cases),
    ("input order", 'return " ".join(texts)', 'return " ".join(reversed(texts))', transcribe_cases),
    ("crossed message", "if ident not in utterances:\n            continue", "if False:\n            continue",
     wire_cases),
    ("synthesis empty", "if not samples or not all(math.isfinite(v) for v in samples) or not any(samples):",
     "if False:", wire_cases),
    ("utterance bound", "if len(buffer) + len(payload) // 4 > UTTERANCE_SAMPLES:", "if False:", bound_case),
    ("message shape", "or set(header) != SHAPES[kind][0] ", "", violation_cases),
    ("frame bound", "if not 0 < head <= HEADER_BYTES or size > PAYLOAD_BYTES:", "if not 0 < head:",
     violation_cases),
    ("readiness", 'if setup.status(judge, state, data)["tone"] != "ok":', "if False:", readiness_cases),
    ("setup lock", "fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)", "fcntl.flock(lock, fcntl.LOCK_UN)",
     readiness_cases),
    ("one role each", "if role in found:", "if False:", roles_case),
]


RUNNER = REPO / "scripts/check-jarvis-local-speech.sh"
GUARD = 'if [[ -z $models || -z $python || ! -x $python || ! -d $models ]]; then'


def runner_case(source):
    """The real-model row: 77 without prepared inputs; resolved paths and the
    consumer's status pass through. A stand-in world owner and interpreter."""
    with tempfile.TemporaryDirectory() as name:
        root = Path(name).resolve()
        (root / "scripts/lib").mkdir(parents=True)
        runner = root / "scripts/check-jarvis-local-speech.sh"
        runner.write_text(source)
        (root / "scripts/lib/jarvis-env.sh").write_text('#!/bin/bash\nshift 2\nexec "$@"\n')
        (root / "prepared/models").mkdir(parents=True)
        (root / "prepared/venv/bin").mkdir(parents=True)
        (root / "prepared/interpreter").write_text('#!/bin/bash\nprintf "%s\\n" "$0" "$@" > "$(dirname "$0")/../../argv"\nexit 3\n')
        (root / "prepared/venv/bin/python").symlink_to(root / "prepared/interpreter")
        for path in (runner, root / "scripts/lib/jarvis-env.sh", root / "prepared/interpreter"):
            path.chmod(0o755)
        # validate runs this row on the host, outside the world, so it gets the
        # system tools; the stand-ins above reach no model, device or network.
        env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": str(root)}
        result = subprocess.run([str(runner)], cwd=root, env=env, capture_output=True, text=True, check=False)
        if result.returncode != 77 or "reason=prepared-inputs-unavailable" not in result.stdout:
            raise AssertionError(f"no inputs: {result.returncode} {result.stdout!r}")
        env.update(JARVIS_LOCAL_MODELS="prepared/models", JARVIS_LOCAL_PYTHON="prepared/venv/bin/python")
        result = subprocess.run([str(runner)], cwd=root, env=env, capture_output=True, text=True, check=False)
        argv = (root / "prepared/argv").read_text().splitlines() if (root / "prepared/argv").exists() else []
        if result.returncode != 3 or argv != [str(root / "prepared/venv/bin/python"),
                                               str(root / "scripts/fixtures/jarvis-local-speech/real.py"),
                                               str(root), str(root / "prepared/models")]:
            raise AssertionError(f"prepared inputs: {result.returncode} {argv} {result.stderr!r}")
        env["JARVIS_LOCAL_MODELS"] = "prepared/missing"
        result = subprocess.run([str(runner)], cwd=root, env=env, capture_output=True, text=True, check=False)
        if result.returncode != 77:
            raise AssertionError(f"missing models: {result.returncode}")


class LocalSpeech(unittest.TestCase):
    def test_plans(self):
        m = load()
        for row in PLANS:
            with self.subTest(row=row[0]):
                plan_case(m, row)
        spans_case(m)

    def test_transcription(self):
        transcribe_cases(load())

    def test_wire(self):
        m = load()
        wire_cases(m)
        violation_cases(m)
        bound_case(load())

    def test_readiness(self):
        m = load()
        readiness_cases(m)
        roles_case(m)

    def test_entry_point(self):
        main_cases(SOURCE.read_text())

    def test_runner(self):
        runner_case(RUNNER.read_text())

    def test_controls(self):
        for name, needle, replacement, case in CONTROLS:
            with self.subTest(control=name):
                # The copy loads first, so only the planted defect can redden the case.
                copy = mutant(needle, replacement)
                with self.assertRaises(Exception, msg="must-fail control stayed green: " + name):
                    case(copy)
        text = SOURCE.read_text()
        with self.assertRaises(AssertionError, msg="must-fail control stayed green: parent check"):
            main_cases(text.replace("if os.getppid() != args.parent:", "if False:", 1))
        source = RUNNER.read_text()
        for needle, replacement in ((GUARD, "if false; then"),
                                    ('models="$(cd -- "$models" && pwd -P)"', 'models="$models"'),
                                    ('python="$python_dir/$(basename -- "$python")"', 'python="$(readlink -f -- "$python")"')):
            self.assertEqual(source.count(needle), 1, needle)
            with self.assertRaises(AssertionError, msg="must-fail control stayed green: " + needle):
                runner_case(source.replace(needle, replacement))
        print(f"jarvis-local-speech: controls={len(CONTROLS) + 4}", flush=True)


if __name__ == "__main__":
    namespace_entry()
    unittest.main(verbosity=1)
