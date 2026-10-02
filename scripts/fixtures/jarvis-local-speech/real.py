"""Actual-model consumer of the speech sidecar. No model or network stand-ins.

Each CPU tier's recognizer, voice activity model and voice run the bundled
clip through the sidecar's own segmentation, bounded decoding, synthesis and
wire. A missing input exits 77 through the artifact judge; it never makes a
smaller passing test.
"""
from array import array
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import re
import struct
import sys

repo, models = map(Path, sys.argv[1:])
plugin = repo / "shell/plugins/vgs.jarvis"


def module(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    value = importlib.util.module_from_spec(spec)
    loader.exec_module(value)
    return value


judge = module("jarvis_measure", plugin / "measure-local")
sidecar = module("jarvis_local_speech", plugin / "backend/local-speech.py")


class Recorded:
    """Delegates to the real recognizer and records each input the sidecar hands it."""

    def __init__(self, recognizer):
        self.recognizer = recognizer
        self.sizes = []

    def create_stream(self):
        return RecordedStream(self.recognizer.create_stream(), self.sizes)

    def decode_stream(self, stream):
        self.recognizer.decode_stream(stream.stream)


class RecordedStream:
    def __init__(self, stream, sizes):
        self.stream = stream
        self.sizes = sizes

    def accept_waveform(self, rate, samples):
        self.sizes.append(len(samples))
        self.stream.accept_waveform(rate, samples)

    @property
    def result(self):
        return self.stream.result


def frame(header, payload=b""):
    head = json.dumps(header).encode()
    return struct.pack(">II", len(head), len(payload)) + head + payload


def answers(data):
    out, offset = [], 0
    while offset < len(data):
        head, size = struct.unpack(">II", data[offset:offset + 8])
        out.append((json.loads(data[offset + 8:offset + 8 + head]), data[offset + 8 + head:offset + 8 + head + size]))
        offset += 8 + head + size
    return out


def heard(text, words, label):
    found = re.findall(r"\w+", text.lower())
    if not all(word in found for word in words):
        raise RuntimeError(f"transcript-mismatch {label}: {text!r}")


try:
    value = judge.manifest(plugin / "artifacts.json")
    import numpy as np
    import sherpa_onnx as sherpa
    raw, text = judge.clip(value)
    clip = array("f", (np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768).tobytes())
    words = value["fixture"]["transcriptWords"]
    for tier in ("small", "medium"):
        row = value["tiers"][tier]
        by_id = {a["id"]: a for a in value["artifacts"]}
        chosen = sidecar.roles([by_id[name] for name in row["artifacts"]], tier)
        judge.verify(value, models, list(chosen.values()))
        loaded = {role: judge.load(a, models, row["provider"], np, sherpa) for role, a in chosen.items()}
        recognizer = Recorded(loaded["stt"])
        bound = chosen["stt"].get("maxInputSamples")
        speech = sidecar.Speech(recognizer, bound, loaded["vad"], loaded["tts"], chosen["tts"]["outputSampleRate"],
                                lambda samples: np.frombuffer(samples, dtype=np.float32))
        heard(speech.transcribe(clip), words, tier + " clip")
        # 60 s of repeated speech, built as measure-local builds its long input.
        total = 60 * sidecar.RATE
        long = array("f", bytes(4 * (total % len(clip)))) + clip * (total // len(clip))
        recognizer.sizes.clear()
        heard(speech.transcribe(long), words, tier + " 60 s")
        if bound is not None and (not recognizer.sizes or max(recognizer.sizes) > bound):
            raise RuntimeError(f"bound-exceeded {tier}: {recognizer.sizes}")
        payload = sidecar.little(array("f", clip)).tobytes()
        stream = b"".join(frame({"type": "audio", "id": 1}, payload[at:at + sidecar.PAYLOAD_BYTES])
                          for at in range(0, len(payload), sidecar.PAYLOAD_BYTES))
        stream += frame({"type": "end", "id": 1}) + frame({"type": "speak", "id": 2}, text.encode())
        output = io.BytesIO()
        sidecar.serve(io.BytesIO(stream), output, speech)
        replies = answers(output.getvalue())
        final = [h for h, _ in replies if h["type"] == "final"]
        spoken = [h for h, _ in replies if h["type"] == "spoken"]
        audio = sum(len(p) for h, p in replies if h["type"] == "audio")
        if len(final) != 1 or spoken != [{"type": "spoken", "id": 2, "rate": chosen["tts"]["outputSampleRate"]}] or audio < 4 * spoken[0]["rate"]:
            raise RuntimeError(f"wire-mismatch {tier}: {[h for h, _ in replies][-3:]} audio={audio}")
        heard(final[0]["text"], words, tier + " wire")
        print(json.dumps({"tier": tier, "chunk_samples": recognizer.sizes, "bound": bound, "spoken_bytes": audio}), flush=True)
        del loaded, speech, recognizer
except judge.Unavailable as error:
    print(f"jarvis-local-speech: status=not-measured {error}", file=sys.stderr)
    sys.exit(77)
except sidecar.Failed as error:
    print(f"jarvis-local-speech: failed={error}", file=sys.stderr)
    sys.exit(1)
print("jarvis-local-speech: actual-models=ok", flush=True)
