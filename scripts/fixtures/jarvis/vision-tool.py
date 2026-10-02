#!/usr/bin/env python3
"""Stand-in for grim, slurp, tesseract and magick in the J09 world, copied
under each name. grim, slurp and tesseract reach no compositor and read no
screen; magick runs the host's ImageMagick, which reads and writes files.

Each call appends its name, argv, environment, pid, parent, process group
and parent-death signal to vision-fixture/calls.jsonl in its world, then acts
as vision-fixture/modes.json says for its name, after a count of its earlier
calls:

grim draws the mapped clients of the stand-in hyprctl's state file
($XDG_RUNTIME_DIR/fixture-hyprland.json), later ones on top, over each
output's background, as grim 1.5.0 composes an image: the box of `-g`, of
`-o`'s output or of every output, in layout orientation, (int)(size * scale)
pixels for `-s`. vision-fixture/scene.json names each output's layout box
and each window's colour by address. A pixel takes the colour of the
rectangle holding its centre. Its mode may set code and stderr; hold, which
marks grim.held and never exits; size, a wrong [width, height]; corrupt,
image data no decoder reads; pad, bytes of an extra chunk; nofile, an exit 0
that writes no file; states, the state file each call writes after its
image, by call count; lock, a call count after which it creates
vision-fixture/locked. It records its image's SHA-256. slurp prints its
mode's stdout, stderr and code. tesseract records its input file's SHA-256
and prints its mode's stdout. magick holds, or exits with its mode's code
and stderr, or with garbage writes bytes no decoder reads to its PNG32:
output; with no mode it runs the host's ImageMagick.
"""
import ctypes
import hashlib
import json
import math
import os
import signal
import struct
import sys
import zlib

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vision-fixture")
NAME = os.path.basename(__file__)
PR_GET_PDEATHSIG = 2
LIBC = ctypes.CDLL(None, use_errno=True)
# The host's ImageMagick, by fixed path: the world's PATH holds stand-ins.
MAGICK = ["/usr/bin/magick", "/bin/magick"]


def deathsig():
    value = ctypes.c_int(0)
    if LIBC.prctl(PR_GET_PDEATHSIG, ctypes.byref(value), 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl")
    return value.value


def mark(name, value):
    path = os.path.join(ROOT, name)
    with open(path + ".tmp", "w") as out:
        json.dump(value, out)
    os.rename(path + ".tmp", path)


def sha(path):
    with open(path, "rb") as source:
        return hashlib.sha256(source.read()).hexdigest()


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)


def png(width, height, rows, mode):
    head = chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    data = b"\x00garbage" if mode.get("corrupt") else zlib.compress(b"".join(b"\x00" + bytes(row) for row in rows))
    extra = chunk(b"tEXt", b"Comment\x00" + b"x" * mode["pad"]) if "pad" in mode else b""
    return b"\x89PNG\r\n\x1a\n" + head + extra + chunk(b"IDAT", data) + chunk(b"IEND", b"")


def span(start, end, origin, scale, limit):
    # Pixels whose centre lies in [start, end) of layout space.
    low = math.ceil((start - origin) * scale - 0.5)
    high = math.ceil((end - origin) * scale - 0.5)
    return max(0, low), min(limit, high)


def grim(argv, mode, count):
    scale, output, region = None, None, None
    args = list(argv)
    target = args.pop()
    while args:
        flag = args.pop(0)
        value = args.pop(0)
        if flag == "-s":
            scale = float(value)
        elif flag == "-o":
            output = value
        elif flag == "-g":
            place, size = value.split(" ")
            x, y = place.split(",")
            w, h = size.split("x")
            region = [int(x), int(y), int(w), int(h)]
        else:
            raise SystemExit("grim stand-in: flag " + flag)
    with open(os.path.join(ROOT, "scene.json")) as source:
        scene = json.load(source)
    with open(os.path.join(os.environ["XDG_RUNTIME_DIR"], "fixture-hyprland.json")) as source:
        state = json.load(source)
    outputs = scene["outputs"]
    if output is not None:
        box = next(o["box"] for o in outputs if o["name"] == output)
    elif region is not None:
        box = region
    else:
        x0 = min(o["box"][0] for o in outputs)
        y0 = min(o["box"][1] for o in outputs)
        x1 = max(o["box"][0] + o["box"][2] for o in outputs)
        y1 = max(o["box"][1] + o["box"][3] for o in outputs)
        box = [x0, y0, x1 - x0, y1 - y0]
    width, height = mode.get("size", [int(box[2] * scale), int(box[3] * scale)])
    rows = [bytearray(4 * width) for _ in range(height)]

    def fill(rect, rgba):
        xa, xb = span(rect[0], rect[0] + rect[2], box[0], scale, width)
        ya, yb = span(rect[1], rect[1] + rect[3], box[1], scale, height)
        for y in range(ya, yb):
            rows[y][4 * xa:4 * xb] = bytes(rgba) * max(0, xb - xa)

    for o in outputs:
        fill(o["box"], scene["background"] + [255])
    for client in state["clients"]:
        if client["mapped"]:
            fill(client["at"] + client["size"], scene["colors"][client["address"]] + [255])
    data = png(width, height, rows, mode)
    with open(target, "wb") as out:
        out.write(data)
    mark("grim.%d.json" % count, {"sha256": hashlib.sha256(data).hexdigest(), "file": target})
    states = mode.get("states", [])
    if count < len(states) and states[count] is not None:
        with open(os.path.join(os.environ["XDG_RUNTIME_DIR"], "fixture-hyprland.json"), "w") as out:
            json.dump(states[count], out)
    if mode.get("lock") is not None and count >= mode["lock"]:
        open(os.path.join(ROOT, "locked"), "w").close()


def main():
    argv = sys.argv[1:]
    calls = os.path.join(ROOT, "calls.jsonl")
    with open(calls) as source:
        count = sum(1 for line in source if json.loads(line)["name"] == NAME)
    record = {"name": NAME, "argv": argv, "env": dict(os.environ), "pid": os.getpid(), "parent": os.getppid(),
              "group": os.getpgid(0), "deathsig": deathsig()}
    if NAME == "tesseract":
        record["input"] = sha(argv[0])
    with open(calls, "a") as out:
        out.write(json.dumps(record) + "\n")
    with open(os.path.join(ROOT, "modes.json")) as source:
        mode = json.load(source).get(NAME, {})
    if NAME == "magick" and mode.get("garbage"):
        with open(argv[-1][len("PNG32:"):], "wb") as out:
            out.write(b"not a png")
        return 0
    if NAME == "magick" and not mode:
        real = next((path for path in MAGICK if os.path.exists(path)), None)
        if real is None:
            raise SystemExit("magick stand-in: no host ImageMagick")
        os.execv(real, [real] + argv)
    if mode.get("hold"):
        mark(NAME + ".held", {"pid": os.getpid()})
        while True:
            signal.pause()
    if mode.get("code", 0) == 0 and NAME == "grim" and not mode.get("nofile"):
        grim(argv, mode, count)
    sys.stdout.write(mode.get("stdout", ""))
    sys.stderr.write(mode.get("stderr", ""))
    return mode.get("code", 0)


if __name__ == "__main__":
    sys.exit(main())
