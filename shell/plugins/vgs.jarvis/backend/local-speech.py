#!/usr/bin/env python3
"""Local speech sidecar: speech to text and text to speech for one conversation.

LocalSpeech.js starts it as the selected runtime's interpreter, inside a
private network namespace, as `python -I local-speech.py --state DIR --data DIR
--parent PID`. It holds setup's lock shared, so setup cannot replace the runtime
under it, and loads only after setup's readiness judge answers ready.

Wire, both directions: frames of a u32be header length, a u32be payload length,
a UTF-8 JSON object header and the payload bytes. Audio is float32 little-endian
mono. Ids are positive integers; each new request takes a larger id.
  in:  {type:"audio", id} + 16 kHz samples; {type:"end", id}; {type:"abort", id};
       {type:"speak", id} + one sentence's UTF-8 text
  out: {type:"ready"} once; {type:"final", id, text}; {type:"audio", id} + samples;
       {type:"spoken", id, rate}; {type:"failed", id?, cause}
A failed frame without an id ends the sidecar. A message for an utterance the
sidecar already answered crossed that answer and is dropped. Stdin EOF exits 0;
the runtime not ready exits 77; a protocol violation exits 65; other failures 1.
Contract: docs/architecture/jarvis-local-speech.md.
"""
import argparse
from array import array
import fcntl
import importlib.machinery
import importlib.util
import json
import math
import os
from pathlib import Path
import struct
import sys

HERE = Path(__file__).resolve().parent
# The plugin directory is never written, not even bytecode for setup-local.
sys.dont_write_bytecode = True
RATE = 16000
# Every header and audio payload, both directions.
HEADER_BYTES = 4096
PAYLOAD_BYTES = 64 * 1024
# Plan § 3.10 bounds maxUtteranceSeconds at 120; the VAD buffer holds as much.
UTTERANCE_SAMPLES = 120 * RATE
# Speech kept beside each detected segment, and the frame a cut is chosen by.
PAD_SAMPLES = 3200
CUT_FRAME = 320
VAD_WINDOW = 512
SPEECH_TO_TEXT = ("moonshine", "parakeet")
TEXT_TO_SPEECH = ("piper", "kokoro")


class Protocol(Exception):
    """The daemon sent a frame outside the wire contract."""


class NotReady(Exception):
    """The runtime is not installed, not verified or being set up."""


class Failed(Exception):
    """One request failed; its keyed cause reaches the daemon."""


def spans(segments, total, pad):
    """Pad detected speech within the input and merge what then overlaps."""
    merged = []
    previous = 0
    for start, length in segments:
        if length <= 0 or start < previous:
            raise RuntimeError("vad=segment-order")
        previous = start
        low, high = max(0, start - pad), min(total, start + length + pad)
        if merged and low <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], high))
        else:
            merged.append((low, high))
    return merged


def quiet(samples, low, high):
    """The cut ending the least energetic frame in (low, high]; ties keep the latest."""
    cut, least = high, None
    end = high
    while end - CUT_FRAME >= low:
        energy = sum(value * value for value in samples[end - CUT_FRAME:end])
        if least is None or energy < least:
            cut, least = end, energy
        end -= CUT_FRAME
    return cut


def plan(speech, bound, samples):
    """Chunks of at most bound samples, in input order, covering every speech span.

    Neighbouring spans share a chunk while it fits. A longer span is cut at
    its quietest frame in the second half of each bound; its final shorter
    part is kept as the last chunk.
    """
    chunks = []
    current = None
    for start, end in speech:
        if current is not None and end - current[0] <= bound:
            current = (current[0], end)
            continue
        if current is not None:
            chunks.append(current)
        while end - start > bound:
            cut = quiet(samples, start + bound // 2, start + bound)
            chunks.append((start, cut))
            start = cut
        current = (start, end)
    if current is not None:
        chunks.append(current)
    return chunks


def detect(vad, samples, waveform):
    """Silero segments as (start, length), from the whole utterance."""
    vad.reset()
    for offset in range(0, len(samples), VAD_WINDOW):
        window = samples[offset:offset + VAD_WINDOW]
        if len(window) < VAD_WINDOW:
            window.extend(array("f", bytes(4 * (VAD_WINDOW - len(window)))))
        vad.accept_waveform(waveform(window))
    vad.flush()
    segments = []
    while not vad.empty():
        segments.append((vad.front.start, len(vad.front.samples)))
        vad.pop()
    return segments


class Speech:
    """The loaded models of one tier and the input bound of its recognizer."""

    def __init__(self, recognizer, bound, vad, tts, rate, waveform):
        self.recognizer = recognizer
        self.bound = bound
        self.vad = vad
        self.tts = tts
        self.rate = rate
        self.waveform = waveform

    def transcribe(self, samples):
        """Decode each chunk on a fresh stream, in order; join the texts once.

        No detected speech is an empty transcript. An empty or failed chunk
        fails the utterance; its neighbours never stand in for it.
        """
        speech = spans(detect(self.vad, samples, self.waveform), len(samples), PAD_SAMPLES)
        bound = self.bound if self.bound is not None else max(1, len(samples))
        texts = []
        for index, (start, end) in enumerate(plan(speech, bound, samples)):
            try:
                stream = self.recognizer.create_stream()
                stream.accept_waveform(RATE, self.waveform(samples[start:end]))
                self.recognizer.decode_stream(stream)
                text = stream.result.text.strip()
            except (RuntimeError, ValueError) as error:
                raise Failed(f"chunk-failed index={index}") from error
            if not text:
                raise Failed(f"chunk-empty index={index}")
            texts.append(text)
        return " ".join(texts)

    def speak(self, text):
        """One sentence's samples at the voice's declared rate."""
        try:
            audio = self.tts.generate(text, sid=0, speed=1.0)
        except (RuntimeError, ValueError) as error:
            raise Failed("synthesis-failed") from error
        if audio.sample_rate != self.rate:
            raise Failed(f"synthesis-rate value={audio.sample_rate}")
        samples = array("f", audio.samples)
        if not samples or not all(math.isfinite(v) for v in samples) or not any(samples):
            raise Failed("synthesis-empty")
        return self.rate, samples


def little(samples):
    """Wire samples are little-endian whatever the host order."""
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def read_exact(reader, size):
    data = b""
    while len(data) < size:
        part = reader.read(size - len(data))
        if not part:
            return data
        data += part
    return data


def frames(reader):
    """Yield (header, payload) until EOF at a frame boundary."""
    while True:
        prefix = read_exact(reader, 8)
        if not prefix:
            return
        if len(prefix) != 8:
            raise Protocol("frame=truncated")
        head, size = struct.unpack(">II", prefix)
        if not 0 < head <= HEADER_BYTES or size > PAYLOAD_BYTES:
            raise Protocol("frame=too-large")
        body = read_exact(reader, head + size)
        if len(body) != head + size:
            raise Protocol("frame=truncated")
        try:
            header = json.loads(body[:head].decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise Protocol("header=invalid") from None
        if not isinstance(header, dict):
            raise Protocol("header=invalid")
        yield header, body[head:]


def send(writer, header, payload=b""):
    head = json.dumps(header, separators=(",", ":")).encode("utf-8")
    writer.write(struct.pack(">II", len(head), len(payload)) + head + payload)
    writer.flush()


# The keys each inbound type carries, and whether it carries a payload.
SHAPES = {"audio": ({"type", "id"}, True), "end": ({"type", "id"}, False),
          "abort": ({"type", "id"}, False), "speak": ({"type", "id"}, True)}


def serve(reader, writer, speech):
    """Answer requests in arrival order until EOF."""
    highest = 0
    utterances = {}
    for header, payload in frames(reader):
        kind = header.get("type")
        if kind not in SHAPES or set(header) != SHAPES[kind][0] or (payload != b"") != SHAPES[kind][1]:
            raise Protocol(f"message=invalid type={kind}")
        ident = header["id"]
        if type(ident) is not int or ident <= 0:
            raise Protocol("id=invalid")
        fresh = ident > highest
        highest = max(highest, ident)
        if kind == "speak":
            try:
                text = payload.decode("utf-8")
            except UnicodeDecodeError:
                raise Protocol("speak=invalid") from None
            if not fresh or not text.strip():
                raise Protocol("speak=invalid")
            try:
                rate, samples = speech.speak(text)
            except Failed as failure:
                send(writer, {"type": "failed", "id": ident, "cause": str(failure)})
                continue
            data = little(samples).tobytes()
            for offset in range(0, len(data), PAYLOAD_BYTES):
                send(writer, {"type": "audio", "id": ident}, data[offset:offset + PAYLOAD_BYTES])
            send(writer, {"type": "spoken", "id": ident, "rate": rate})
            continue
        if fresh:
            utterances[ident] = array("f")
        if ident not in utterances:
            continue
        if kind == "abort":
            del utterances[ident]
        elif kind == "audio":
            if len(payload) % 4:
                raise Protocol("audio=partial-sample")
            buffer = utterances[ident]
            if len(buffer) + len(payload) // 4 > UTTERANCE_SAMPLES:
                del utterances[ident]
                send(writer, {"type": "failed", "id": ident, "cause": "utterance-too-long"})
                continue
            received = array("f")
            received.frombytes(payload)
            buffer.extend(little(received))
        else:
            samples = utterances.pop(ident)
            try:
                send(writer, {"type": "final", "id": ident, "text": speech.transcribe(samples)})
            except Failed as failure:
                send(writer, {"type": "failed", "id": ident, "cause": str(failure)})


def module(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    value = importlib.util.module_from_spec(spec)
    loader.exec_module(value)
    return value


def hold(state):
    """Hold setup's lock shared; the caller keeps it for its lifetime."""
    lock = (state / "local-setup.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise NotReady("setup-busy") from None
    return lock


def roles(artifacts, tier):
    """The tier's recognizer, voice activity model and voice, one each."""
    found = {}
    for artifact in artifacts:
        engine = artifact["engine"]
        role = ("stt" if engine in SPEECH_TO_TEXT else "tts" if engine in TEXT_TO_SPEECH
                else "vad" if engine == "silero" else None)
        if role is None:
            continue
        if role in found:
            raise RuntimeError(f"tier=duplicate-role role={role} tier={tier}")
        found[role] = artifact
    if set(found) != {"stt", "tts", "vad"}:
        raise RuntimeError(f"tier=missing-role tier={tier}")
    return found


def load(setup, state, data):
    """Load the ready tier through setup's readiness judge and pinned loaders.

    setup is the setup-local module: its status is the one readiness judge,
    and its artifact judge owns the upstream loader for each export.
    """
    judge = setup.measurement()
    if setup.status(judge, state, data)["tone"] != "ok":
        raise NotReady("runtime-not-ready")
    tier = json.loads((state / "local-ready.json").read_text())["tier"]
    value = judge.manifest(setup.HERE / "artifacts.json")
    artifacts, provider = setup.selected(value, tier)
    chosen = roles(artifacts, tier)
    import numpy as np
    import sherpa_onnx as sherpa
    models = {role: judge.load(artifact, data / "models", provider, np, sherpa) for role, artifact in chosen.items()}
    return Speech(models["stt"], chosen["stt"].get("maxInputSamples"), models["vad"], models["tts"],
                  chosen["tts"]["outputSampleRate"], lambda samples: np.frombuffer(samples, dtype=np.float32))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--parent", type=int, required=True)
    args = parser.parse_args()
    # setpriv armed parent death before this check; a parent that already
    # ended would leave this process unowned.
    if os.getppid() != args.parent:
        raise RuntimeError("parent=ended")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    writer = sys.stdout.buffer
    try:
        lock = hold(args.state)
        speech = load(module("jarvis_setup", HERE.parent / "setup-local"), args.state, args.data)
    except NotReady as error:
        send(writer, {"type": "failed", "cause": str(error)})
        return 77
    with lock:
        send(writer, {"type": "ready"})
        serve(sys.stdin.buffer, writer, speech)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Protocol as error:
        print(f"jarvis-local-speech: protocol={error}", file=sys.stderr)
        sys.exit(65)
    except BrokenPipeError:
        sys.exit(0)
