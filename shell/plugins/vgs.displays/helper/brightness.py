#!/usr/bin/env python3
"""Read and set display brightness: one run, one JSON answer on stdout.

Usage:
  brightness.py list --outputs FILE|-
  brightness.py set ID PERCENT

QML cannot ioctl a hidraw node and ddcutil is an external program, so the
vgs.displays service runs this once per read or write. It never talks to
Hyprland: `list` reads the outputs the caller passes, a JSON array as
`hyprctl -j monitors all` prints it, from FILE or from stdin for `-`. Each
element needs a string `name`; `model` and `serial` are read when they are
strings.

`list` answers {"backends": {"ddc": STATE, "backlight": STATE},
"displays": [DISPLAY...]}. A backend STATE is {"state": S}, S one of
`ready`, `missing` (its command is not on PATH), `module-not-loaded`
(ddc: no VGS_SYSFS_ROOT/module/i2c_dev), `no-access` (ddc: /dev/i2c-*
nodes exist under VGS_DEV_ROOT and none is readable and writable) or
`error`, which adds "detail", the error object of the failed command.
A DISPLAY is {"id", "backend", "label", "state", "percent", "output"}:
- backend: `hidraw` (an Apple display's USB HID feature report), `ddc`
  (ddcutil) or `backlight` (brightnessctl over a kernel backlight).
- state: `ready`; `no-access` (hidraw: no interface opens read-write;
  ddc: its bus node is not readable and writable); `no-answer` (no
  in-range reply to the brightness read); `unsupported` (ddcutil reports
  no DDC/CI). percent is an integer 0-100 when ready, else null.
- output: the output name it lights, or null when unassigned. An Apple
  display maps by its USB serial equal to one output's serial; else, when
  it is the only physical device of its product and exactly one output has
  the product's model, to that output. A DDC display maps to the output
  named by its DRM connector. A kernel backlight maps to the output named
  by its DRM connector parent; else, when it is the only backlight left
  unmapped and exactly one internal-panel output (eDP, LVDS, DSI) is left
  unclaimed, to that panel.
- An Apple display adds "product" and "identity" {"parent", "serial"}:
  parent is the sysfs path, relative to VGS_SYSFS_ROOT, of the USB device
  its hidraw interfaces hang under, which tells two units of one product
  apart when their serials are absent or equal. With no USB device above
  the interface, as in the smoke's HID fake, parent is the HID device's
  own directory. A kernel backlight under that USB device is used in place
  of hidraw, under the backlight's id.

Ids: `hidraw:<parent>`, `ddc:<DRM connector>` (`ddc:i2c-<bus>` with no
connector), `backlight:<name>`. `set` clamps PERCENT to 0-100, writes it
and answers {"id", "percent"}.

Failure prints {"error": KEY, ...} on stdout: exit 2 for a usage error,
exit 1 for any other.

Apple protocol (v1 bin/vshell_helper.py:340-358,9866-10052): feature
report id 1, 7 bytes, raw brightness in bytes 1..4 unsigned little-endian,
read with HIDIOCGFEATURE(7) and written with HIDIOCSFEATURE(7). Each
interface is probed with a zeroed report 1; only an answer from half the
product's minimum up to the 60000 ceiling counts, and among answering
interfaces one whose report descriptor declares usage page 0x82, usage
0x0001 is preferred.

DDC: `ddcutil detect` is cached for 30 s at
$XDG_RUNTIME_DIR/vgs/displays/ddc-detect.json and never reused across a
hotplug: the cache holds a key over every VGS_SYSFS_ROOT/class/drm
connector's name and EDID bytes and every class/i2c-dev bus name, so a
plugged, unplugged or swapped monitor or a renumbered bus misses it. With
no XDG_RUNTIME_DIR nothing is cached. A cache file that does not parse is
a miss and is rewritten.

Seams: VGS_SYSFS_ROOT (default /sys) and VGS_DEV_ROOT (default /dev) root
every sysfs read and node open. VGS_HID_FAKE names the unix socket of
scripts/smoke/fixtures/devices/hid-fake.py, whose header holds the
protocol; every feature-report ioctl goes there instead of ioctl(2). It
needs both roots set, so no node under the real /dev is opened.
"""

import errno
import fcntl
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass


@dataclass(frozen=True)
class Product:
    label: str
    model: str  # the model Hyprland reports for the output
    raw_min: int
    raw_max: int


APPLE_VENDOR = "05ac"
PRODUCTS = {
    "9243": Product("Apple Pro Display XDR", "ProDisplayXDR", 400, 50000),
    "1114": Product("Apple Studio Display", "StudioDisplay", 400, 60000),
}
PROBE_CEILING = 60000
REPORT_ID = 1
REPORT_LEN = 7
BRIGHTNESS_USAGE = (0x82, 0x0001)
# The errnos an interface without brightness answers a report-1 read with:
# a stalled control request (EPIPE), a failed or timed-out transfer, or a
# report the device does not hold (the HID fake's EIO).
PROBE_MISSES = {errno.EIO, errno.EPIPE, errno.EINVAL, errno.ETIMEDOUT}
DDC_CACHE_SECONDS = 30
INTERNAL_PANEL = re.compile(r"^(eDP|LVDS|DSI)-")
DRM_CONNECTOR = re.compile(r"^card\d+-(.+)$")


def ioc_read_write(nr, size):
    return (3 << 30) | (size << 16) | (ord("H") << 8) | nr


HIDIOCGFEATURE = ioc_read_write(0x07, REPORT_LEN)
HIDIOCSFEATURE = ioc_read_write(0x06, REPORT_LEN)


class Failure(Exception):
    """A refusal: its fields are the JSON error object."""

    def __init__(self, key, exit_status=1, **fields):
        super().__init__(key)
        self.exit_status = exit_status
        self.fields = {"error": key, **fields}


def encode(raw):
    return bytes([REPORT_ID]) + raw.to_bytes(4, "little") + bytes(REPORT_LEN - 5)


def decode(report):
    return int.from_bytes(report[1:5], "little")


def clamp_percent(percent):
    return max(0, min(100, percent))


def raw_from_percent(percent, product):
    span = product.raw_max - product.raw_min
    return product.raw_min + round(clamp_percent(percent) * span / 100)


def percent_from_raw(raw, product):
    span = product.raw_max - product.raw_min
    return clamp_percent(round((raw - product.raw_min) * 100 / span))


def probe_in_range(raw, product):
    return product.raw_min // 2 <= raw <= PROBE_CEILING


def declares_brightness(descriptor):
    """Whether a HID report descriptor holds the Usage BRIGHTNESS_USAGE."""
    page, at = None, 0
    while at < len(descriptor):
        prefix = descriptor[at]
        if prefix == 0xFE:  # long item: size byte, tag byte, data
            at += 3 + (descriptor[at + 1] if at + 1 < len(descriptor) else 0)
            continue
        size = (0, 1, 2, 4)[prefix & 3]
        value = int.from_bytes(descriptor[at + 1:at + 1 + size], "little")
        item = prefix & 0xFC
        if item == 0x04:  # global Usage Page
            page = value
        elif item == 0x08:  # local Usage; a 4-byte one carries its own page
            usage = (value >> 16, value & 0xFFFF) if size == 4 else (page, value)
            if usage == BRIGHTNESS_USAGE:
                return True
        at += 1 + size
    return False


@dataclass(frozen=True)
class Roots:
    sysfs: str
    dev: str
    hid_fake: str | None

    @staticmethod
    def from_env(env):
        fake = env.get("VGS_HID_FAKE") or None
        if fake and not (env.get("VGS_SYSFS_ROOT") and env.get("VGS_DEV_ROOT")):
            raise Failure("seam-incomplete", detail="VGS_HID_FAKE needs VGS_SYSFS_ROOT and VGS_DEV_ROOT")
        return Roots(os.path.realpath(env.get("VGS_SYSFS_ROOT") or "/sys"),
                     env.get("VGS_DEV_ROOT") or "/dev", fake)

    def sys(self, *parts):
        return os.path.join(self.sysfs, *parts)

    def node(self, name):
        return os.path.join(self.dev, name)

    def resolve(self, *parts):
        """The real path of a sysfs entry, refused when it leaves the root."""
        path = os.path.realpath(self.sys(*parts))
        if os.path.commonpath([path, self.sysfs]) != self.sysfs:
            raise Failure("sysfs-escape", path=self.sys(*parts), target=path)
        return path


class FeatureReports:
    """The feature-report ioctl: ioctl(2) on the node, or the HID fake's socket."""

    def __init__(self, fake):
        self.fake = fake
        self.stream = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if self.stream is not None:
            self.stream.close()

    def call(self, name, fd, request, report):
        """(result, report after the call), or OSError with the ioctl's errno."""
        if self.fake is None:
            buffer = bytearray(report)
            result = fcntl.ioctl(fd, request, buffer, True)
            return result, bytes(buffer)
        if self.stream is None:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(self.fake)
            self.stream = sock.makefile("rwb")
            sock.close()
        self.stream.write((json.dumps({"device": name, "request": request, "data": report.hex()}) + "\n").encode())
        self.stream.flush()
        line = self.stream.readline()
        if not line:
            raise Failure("hid-fake-closed", socket=self.fake)
        reply = json.loads(line)
        if "errno" in reply:
            raise OSError(reply["errno"], os.strerror(reply["errno"]))
        return reply["result"], bytes.fromhex(reply["data"])


@dataclass(frozen=True)
class Interface:
    name: str  # hidrawN
    product: str
    serial: str
    parent: str  # relative to the sysfs root: the USB device, else the HID device
    descriptor: bytes


def read_bytes(path):
    with open(path, "rb") as source:
        return source.read()


def read_uevent(path):
    lines = read_bytes(path).decode(errors="replace").splitlines()
    fields = dict(line.split("=", 1) for line in lines if "=" in line)
    match = re.fullmatch(r"([0-9A-Fa-f]+):([0-9A-Fa-f]+):([0-9A-Fa-f]+)", fields.get("HID_ID", ""))
    if match is None:
        raise Failure("uevent-unreadable", path=path)
    return f"{int(match[2], 16):04x}", f"{int(match[3], 16):04x}", fields.get("HID_UNIQ", "")


def usb_parent(roots, device):
    """The USB device directory above a HID device, else the HID device itself."""
    at = device
    while at != roots.sysfs:
        if os.path.isfile(os.path.join(at, "idVendor")):
            return os.path.relpath(at, roots.sysfs)
        at = os.path.dirname(at)
    return os.path.relpath(device, roots.sysfs)


def apple_interfaces(roots):
    base = roots.sys("class", "hidraw")
    if not os.path.isdir(base):
        return []
    found = []
    for name in sorted(os.listdir(base), key=lambda n: (len(n), n)):
        device = roots.resolve("class", "hidraw", name, "device")
        vendor, product, serial = read_uevent(os.path.join(device, "uevent"))
        if vendor != APPLE_VENDOR or product not in PRODUCTS:
            continue
        descriptor = os.path.join(device, "report_descriptor")
        found.append(Interface(name, product, serial, usb_parent(roots, device),
                               read_bytes(descriptor) if os.path.exists(descriptor) else b""))
    return found


def physical_displays(interfaces):
    """Interfaces grouped into physical displays: USB parent plus serial."""
    groups = {}
    for iface in interfaces:
        key = (iface.parent, iface.serial)
        groups.setdefault(key, []).append(iface)
    return list(groups.values())


def open_read_write(path):
    """An fd, or None when the node refuses read-write access."""
    try:
        return os.open(path, os.O_RDWR | os.O_CLOEXEC)
    except PermissionError:
        return None


def probe(roots, reports, iface):
    """The raw brightness an interface answers, or `no-access` / `no-answer`."""
    fd = open_read_write(roots.node(iface.name))
    if fd is None:
        return "no-access"
    try:
        result, report = reports.call(iface.name, fd, HIDIOCGFEATURE, encode(0))
    except OSError as error:
        if error.errno in PROBE_MISSES:
            return "no-answer"
        raise Failure("hid-read", node=iface.name, detail=os.strerror(error.errno)) from error
    finally:
        os.close(fd)
    raw = decode(report)
    if result < 5 or report[0] != REPORT_ID or not probe_in_range(raw, PRODUCTS[iface.product]):
        return "no-answer"
    return raw


def control_interface(roots, reports, group):
    """(interface, raw) of the group's brightness control, or a state string."""
    readings = [(iface, probe(roots, reports, iface)) for iface in group]
    answered = [(iface, raw) for iface, raw in readings if isinstance(raw, int)]
    if not answered:
        return "no-access" if any(raw == "no-access" for _, raw in readings) else "no-answer"
    preferred = [pair for pair in answered if declares_brightness(pair[0].descriptor)]
    return (preferred or answered)[0]


def write_raw(roots, reports, iface, raw):
    fd = open_read_write(roots.node(iface.name))
    if fd is None:
        raise Failure("state", state="no-access", node=iface.name)
    try:
        result, _ = reports.call(iface.name, fd, HIDIOCSFEATURE, encode(raw))
    except OSError as error:
        raise Failure("hid-write", node=iface.name, detail=os.strerror(error.errno)) from error
    finally:
        os.close(fd)
    if result != REPORT_LEN:
        raise Failure("hid-write", node=iface.name, detail=f"wrote {result} of {REPORT_LEN} bytes")


def run(argv):
    done = subprocess.run(argv, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise Failure("command", argv=argv, status=done.returncode, detail=done.stderr.strip())
    return done.stdout


def readable_writable(path):
    return os.access(path, os.R_OK | os.W_OK)


# --- kernel backlight ---------------------------------------------------------

@dataclass(frozen=True)
class Backlight:
    name: str
    percent: int
    path: str  # the real sysfs path of class/backlight/NAME


def backlights(roots):
    """Every kernel backlight brightnessctl lists, or the backend state `missing`."""
    base = roots.sys("class", "backlight")
    if not os.path.isdir(base) or not os.listdir(base):
        return []
    command = shutil.which("brightnessctl")
    if command is None:
        return "missing"
    found = []
    # -l lists every device; without it brightnessctl prints the first alone.
    for line in run([command, "-l", "-m", "-c", "backlight"]).splitlines():
        fields = line.split(",")
        if len(fields) != 5 or not re.fullmatch(r"\d+%", fields[3]):
            raise Failure("brightnessctl-unparsed", line=line)
        found.append(Backlight(fields[0], clamp_percent(int(fields[3][:-1])),
                               roots.resolve("class", "backlight", fields[0])))
    return found


def backlight_connector(roots, light):
    match = DRM_CONNECTOR.match(os.path.basename(roots.resolve("class", "backlight", light.name, "device")))
    return match[1] if match else None


# --- DDC ----------------------------------------------------------------------

def parse_detect(text):
    """ddcutil detect's valid displays: {"bus", "connector", "model", "unsupported"}."""
    displays, current = [], None
    for line in text.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            current = None
            if re.match(r"Display\s+\d+", line):
                current = {"bus": None, "connector": None, "model": "", "unsupported": False}
                displays.append(current)
            continue
        if current is None:
            continue
        item = line.strip()
        bus = re.match(r"I2C bus:\s+/dev/i2c-(\d+)", item)
        if bus:
            current["bus"] = int(bus[1])
        elif re.match(r"DRM[ _]connector:", item):
            current["connector"] = re.sub(r"^card\d+-", "", item.split(":", 1)[1].strip()) or None
        elif item.startswith("Model:"):
            current["model"] = item.split(":", 1)[1].strip()
        elif "does not support DDC" in item or "DDC communication failed" in item:
            current["unsupported"] = True
    return [d for d in displays if d["bus"] is not None]


def parse_getvcp(text):
    """(current, max) from `getvcp 10 --brief`, or None."""
    match = re.search(r"^VCP 10 C (\d+) (\d+)$", text, re.MULTILINE)
    if match is None or int(match[2]) == 0:
        return None
    return int(match[1]), int(match[2])


def hotplug_key(roots):
    digest = hashlib.sha256()
    drm = roots.sys("class", "drm")
    for name in sorted(os.listdir(drm)) if os.path.isdir(drm) else []:
        if not DRM_CONNECTOR.match(name):
            continue
        edid = os.path.join(drm, name, "edid")
        digest.update(b"drm\0" + name.encode() + b"\0" + (read_bytes(edid) if os.path.exists(edid) else b"") + b"\0")
    buses = roots.sys("class", "i2c-dev")
    for name in sorted(os.listdir(buses)) if os.path.isdir(buses) else []:
        digest.update(b"i2c\0" + name.encode() + b"\0")
    return digest.hexdigest()


def ddc_cache_path(env):
    runtime = env.get("XDG_RUNTIME_DIR")
    return os.path.join(runtime, "vgs", "displays", "ddc-detect.json") if runtime else None


def read_cache(cache):
    """The cache document, or None when there is none or it does not parse."""
    try:
        with open(cache) as source:
            held = json.load(source)
    except (FileNotFoundError, ValueError):
        return None
    return held if isinstance(held, dict) and {"key", "at", "displays"} <= held.keys() else None


def detect(ddcutil, roots, env, now):
    key = hotplug_key(roots)
    cache = ddc_cache_path(env)
    held = read_cache(cache) if cache else None
    if held and held["key"] == key and 0 <= now - held["at"] < DDC_CACHE_SECONDS:
        return held["displays"]
    displays = parse_detect(run([ddcutil, "detect"]))
    if cache:
        os.makedirs(os.path.dirname(cache), mode=0o700, exist_ok=True)
        with open(cache + ".next", "w") as out:
            json.dump({"key": key, "at": now, "displays": displays}, out)
        os.replace(cache + ".next", cache)
    return displays


def ddc_id(found):
    return "ddc:" + (found["connector"] or f"i2c-{found['bus']}")


def ddc_command(roots):
    """(ddcutil path, None) when DDC can run, else (None, backend state)."""
    ddcutil = shutil.which("ddcutil")
    if ddcutil is None:
        return None, "missing"
    if not os.path.isdir(roots.sys("module", "i2c_dev")):
        return None, "module-not-loaded"
    nodes = [n for n in os.listdir(roots.dev) if re.fullmatch(r"i2c-\d+", n)] if os.path.isdir(roots.dev) else []
    if nodes and not any(readable_writable(roots.node(n)) for n in nodes):
        return None, "no-access"
    return ddcutil, None


def ddc_read(ddcutil, bus):
    """(current, max), or None when the display does not answer."""
    try:
        return parse_getvcp(run([ddcutil, "--bus", str(bus), "getvcp", "10", "--brief"]))
    except Failure:
        return None


def ddc_display_state(ddcutil, roots, found):
    """(state, percent) of one detected display."""
    if found["unsupported"]:
        return "unsupported", None
    if not readable_writable(roots.node(f"i2c-{found['bus']}")):
        return "no-access", None
    reading = ddc_read(ddcutil, found["bus"])
    if reading is None:
        return "no-answer", None
    return "ready", clamp_percent(round(reading[0] * 100 / reading[1]))


# --- list ---------------------------------------------------------------------

def read_outputs(source):
    try:
        if source == "-":
            outputs = json.load(sys.stdin)
        else:
            with open(source) as handle:
                outputs = json.load(handle)
    except (OSError, ValueError) as error:
        raise Failure("outputs", exit_status=2, detail=str(error)) from error
    if not isinstance(outputs, list) or not all(isinstance(o, dict) and isinstance(o.get("name"), str) for o in outputs):
        raise Failure("outputs", exit_status=2, detail="want a JSON array of objects with a string name")
    return [{key: o[key] for key in ("name", "model", "serial") if isinstance(o.get(key), str)} for o in outputs]


def entry(id_, backend, label, state, percent, output, **extra):
    return {"id": id_, "backend": backend, "label": label, "state": state,
            "percent": percent if state == "ready" else None, "output": output, **extra}


def apple_output(group, groups, outputs):
    serial = group[0].serial
    by_serial = [o["name"] for o in outputs if serial and o.get("serial") == serial]
    if len(by_serial) == 1:
        return by_serial[0]
    product = group[0].product
    same_product = [g for g in groups if g[0].product == product]
    by_model = [o["name"] for o in outputs if o.get("model") == PRODUCTS[product].model]
    if len(same_product) == 1 and len(by_model) == 1:
        return by_model[0]
    return None


def apple_entries(roots, reports, outputs, lights):
    """One entry per physical Apple display; removes from lights each it uses."""
    shown = []
    groups = physical_displays(apple_interfaces(roots))
    for group in groups:
        first = group[0]
        product = PRODUCTS[first.product]
        extra = {"product": first.product, "identity": {"parent": first.parent, "serial": first.serial}}
        output = apple_output(group, groups, outputs)
        inside = roots.sys(first.parent) + os.sep
        kernel = next((light for light in lights if light.path.startswith(inside)), None)
        if kernel is not None:
            lights.remove(kernel)
            shown.append(entry("backlight:" + kernel.name, "backlight", product.label, "ready",
                               kernel.percent, output, **extra))
            continue
        chosen = control_interface(roots, reports, group)
        state, percent = (chosen, None) if isinstance(chosen, str) else ("ready", percent_from_raw(chosen[1], product))
        shown.append(entry("hidraw:" + first.parent, "hidraw", product.label, state, percent, output, **extra))
    return shown


def backlight_entries(roots, outputs, lights):
    names = {o["name"] for o in outputs}
    placed = {light.name: backlight_connector(roots, light) for light in lights}
    placed = {name: connector if connector in names else None for name, connector in placed.items()}
    unplaced = [name for name, connector in placed.items() if connector is None]
    internal = [n for n in names if INTERNAL_PANEL.match(n) and n not in placed.values()]
    if len(unplaced) == 1 and len(internal) == 1:
        placed[unplaced[0]] = internal[0]
    return [entry("backlight:" + light.name, "backlight", light.name, "ready", light.percent, placed[light.name])
            for light in lights]


def ddc_entries(roots, env, outputs, now):
    """(backend state, entries)."""
    ddcutil, state = ddc_command(roots)
    if ddcutil is None:
        return {"state": state}, []
    try:
        detected = detect(ddcutil, roots, env, now)
    except Failure as failure:
        return {"state": "error", "detail": failure.fields}, []
    names = {o["name"] for o in outputs}
    shown = []
    for found in detected:
        state, percent = ddc_display_state(ddcutil, roots, found)
        output = found["connector"] if found["connector"] in names else None
        shown.append(entry(ddc_id(found), "ddc", found["model"] or ddc_id(found), state, percent, output))
    return {"state": "ready"}, shown


def list_displays(roots, reports, env, outputs, now):
    lights = backlights(roots)
    light_state = {"state": lights if isinstance(lights, str) else "ready"}
    lights = [] if isinstance(lights, str) else lights
    shown = apple_entries(roots, reports, outputs, lights)
    shown += backlight_entries(roots, outputs, lights)
    ddc_backend, ddc_shown = ddc_entries(roots, env, outputs, now)
    return {"backends": {"ddc": ddc_backend, "backlight": light_state}, "displays": shown + ddc_shown}


# --- set ----------------------------------------------------------------------

def set_hidraw(roots, reports, target, parent, percent):
    for group in physical_displays(apple_interfaces(roots)):
        if group[0].parent != parent:
            continue
        chosen = control_interface(roots, reports, group)
        if isinstance(chosen, str):
            raise Failure("state", state=chosen, id=target)
        write_raw(roots, reports, chosen[0], raw_from_percent(percent, PRODUCTS[group[0].product]))
        return
    raise Failure("unknown-id", id=target)


def set_ddc(roots, env, target, percent, now):
    ddcutil, state = ddc_command(roots)
    if ddcutil is None:
        raise Failure("state", state=state, id=target)
    found = next((d for d in detect(ddcutil, roots, env, now) if ddc_id(d) == target), None)
    if found is None:
        raise Failure("unknown-id", id=target)
    reading = ddc_read(ddcutil, found["bus"])
    if reading is None:
        raise Failure("state", state="no-answer", id=target)
    run([ddcutil, "--bus", str(found["bus"]), "setvcp", "10", str(round(percent / 100 * reading[1]))])


def set_backlight(target, name, percent):
    command = shutil.which("brightnessctl")
    if command is None:
        raise Failure("state", state="missing", id=target)
    run([command, "-d", name, "set", f"{percent}%"])


def set_brightness(roots, reports, env, target, percent, now):
    backend, _, rest = target.partition(":")
    percent = clamp_percent(percent)
    if not rest:
        raise Failure("unknown-id", id=target)
    if backend == "hidraw":
        set_hidraw(roots, reports, target, rest, percent)
    elif backend == "ddc":
        set_ddc(roots, env, target, percent, now)
    elif backend == "backlight":
        set_backlight(target, rest, percent)
    else:
        raise Failure("unknown-id", id=target)
    return {"id": target, "percent": percent}


def usage(detail):
    return Failure("usage", exit_status=2, detail=detail,
                   usage="brightness.py list --outputs FILE|- | brightness.py set ID PERCENT")


def main(argv, env):
    roots = Roots.from_env(env)
    with FeatureReports(roots.hid_fake) as reports:
        if len(argv) == 3 and argv[0] == "list" and argv[1] == "--outputs":
            return list_displays(roots, reports, env, read_outputs(argv[2]), time.time())
        if len(argv) == 3 and argv[0] == "set":
            if not re.fullmatch(r"-?\d+", argv[2]):
                raise usage("PERCENT must be an integer")
            return set_brightness(roots, reports, env, argv[1], int(argv[2]), time.time())
        raise usage("unknown command")


if __name__ == "__main__":
    try:
        answer = main(sys.argv[1:], os.environ)
    except Failure as failure:
        print(json.dumps(failure.fields))
        sys.exit(failure.exit_status)
    except OSError as error:
        print(json.dumps({"error": "os", "path": error.filename, "detail": error.strerror}))
        sys.exit(1)
    print(json.dumps(answer))
