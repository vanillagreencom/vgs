#!/usr/bin/env python3
"""Read and set display brightness: one run, one JSON answer on stdout.

Usage:
  brightness.py list --outputs FILE|-
  brightness.py set ID PERCENT

QML cannot ioctl a hidraw node and ddcutil is an external program, so the
vgs.displays service runs this once per read or write. It never talks to
Hyprland: `list` reads the outputs the caller passes, a JSON array as
`hyprctl -j monitors all` prints it, from FILE or from stdin for `-`. Each
element needs a string `name`; `make`, `model` and `serial` are read when
they are strings.

`list` answers {"backends": {"ddc": STATE, "backlight": STATE},
"displays": [DISPLAY...]}. A backend STATE is {"state": S}, S one of
`ready`, `missing` (its command is not on PATH), `module-not-loaded`
(ddc: no VGS_SYSFS_ROOT/module/i2c_dev), `no-access` (ddc: /dev/i2c-*
nodes exist under VGS_DEV_ROOT and none is readable and writable) or
`error` (ddc: `ddcutil detect` failed; backlight: `brightnessctl` failed or
printed a line that does not parse), which adds "detail", the error
object. A failed backend lists no display and the others still list.
A DISPLAY is {"id", "backend", "label", "state", "percent", "outputs"}:
- backend: `hidraw` (an Apple display's USB HID feature report), `ddc`
  (ddcutil) or `backlight` (brightnessctl over a kernel backlight).
- state: `ready`; `no-access` (hidraw: an interface refuses a read-write
  open and none answers; ddc: its bus node is not readable and writable);
  `no-answer` (no in-range reply to the brightness read); `error` (hidraw:
  no interface answers and one failed with an errno no probe miss gives);
  `unsupported` (ddcutil reports an invalid display, DDC/CI off or absent).
  `error` and `unsupported` add "detail", the reason. percent is an
  integer 0-100 when ready, else null.
- outputs: the names of the outputs it lights, empty when unassigned.
  Outputs sharing make, model and a non-empty serial are one physical
  monitor, as a tiled Pro Display XDR shows on two connectors. An Apple
  display maps to the one monitor whose serial equals its USB serial; else,
  when it is the only physical device of its product and exactly one
  monitor has the product's model, to that monitor. Hyprland reports an
  Apple display's EDID binary serial in hex and its EDID holds no serial
  string, so on the Studio Display and Pro Display XDR the model rule is
  the one that fires. A DDC display maps to the output named by its DRM
  connector. A kernel backlight maps to the output named by its DRM
  connector parent; else, when it is the only backlight left unmapped and
  exactly one internal-panel output (eDP, LVDS, DSI) is left unclaimed, to
  that panel.
- An Apple display adds "product" and "identity" {"parent", "serial"}:
  parent is the sysfs path, relative to VGS_SYSFS_ROOT, of the USB device
  its hidraw interfaces hang under, which tells two units of one product
  apart when their serials are absent or equal. With no USB device above
  the interface, as in the smoke's HID fake, parent is the HID device's
  own directory. A kernel backlight under that USB device is used in place
  of hidraw, under the backlight's id.

Ids: `hidraw:<parent>`, `ddc:<DRM connector>` (`ddc:i2c-<bus>` with no
connector), `backlight:<name>`. `set` clamps PERCENT to 0-100, writes it
and answers {"id", "percent"}; a display that is not ready fails it with
{"error": "state", "state": S}, S the state `list` reports.

Failure prints {"error": KEY, ...} on stdout: exit 2 for a usage error,
exit 1 for any other.

Apple protocol (v1 bin/vshell_helper.py:340-358,9866-10052): feature
report id 1, 7 bytes, raw brightness in bytes 1..4 unsigned little-endian,
read with HIDIOCGFEATURE(7) and written with HIDIOCSFEATURE(7). Each
interface is probed with a zeroed report 1; only a reply of at least 5
bytes with id 1 and a value from half the product's minimum up to the
60000 ceiling counts. Among answering interfaces, one whose report
descriptor declares usage page 0x82 (VESA Virtual Controls), usage 0x10
(Brightness) is preferred, as the brightness interface of both displays
does inside a Monitor page 0x80 collection.

DDC: `ddcutil detect` exits 0 whatever it finds. Its `Display N` blocks are
DDC displays; its `Invalid display` blocks are `unsupported`, except a
laptop panel's, which the backlight drives, and one whose EDID
manufacturer is APP and model is the model of an Apple display this run
lists, which the HID backend drives. The detect result is cached for 30 s
at $XDG_RUNTIME_DIR/vgs/displays/ddc-detect.json and never reused across a
hotplug: the cache holds a key over every VGS_SYSFS_ROOT/class/drm
connector's name and EDID bytes and every class/i2c-dev bus name, so a
plugged, unplugged or swapped monitor or a renumbered bus misses it. The
cache is best effort: with no XDG_RUNTIME_DIR, or a cache that cannot be
read, parsed or written, the run detects and lists as without one. A
write goes through a unique temporary file in the cache directory.

Seams: VGS_SYSFS_ROOT (default /sys) and VGS_DEV_ROOT (default /dev) root
every sysfs read and node open. VGS_HID_FAKE names the unix socket of
scripts/smoke/fixtures/devices/hid-fake.py, whose header holds the
protocol; every feature-report ioctl goes there instead of ioctl(2). It
needs both roots set, so no node under the real /dev is opened.
"""

import contextlib
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
import tempfile
import time
from dataclasses import dataclass


@dataclass(frozen=True)
class Product:
    label: str
    model: str  # the model Hyprland and the EDID report for the output
    raw_min: int
    raw_max: int


APPLE_VENDOR = "05ac"
APPLE_EDID_MANUFACTURER = "APP"
PRODUCTS = {
    "9243": Product("Apple Pro Display XDR", "ProDisplayXDR", 400, 50000),
    "1114": Product("Apple Studio Display", "StudioDisplay", 400, 60000),
}
PROBE_CEILING = 60000
REPORT_ID = 1
REPORT_LEN = 7
BRIGHTNESS_USAGE = (0x82, 0x0010)
# The errnos an interface without brightness answers a report-1 read with:
# a stalled control request (EPIPE), a failed or timed-out transfer, or a
# report the device does not hold (the HID fake's EIO). Any other errno is
# that interface's error, never the run's.
PROBE_MISSES = {errno.EIO, errno.EPIPE, errno.EINVAL, errno.ETIMEDOUT}
DDC_CACHE_SECONDS = 30
DDC_CACHE_FORMAT = 2
# ddcutil 3.0.2 detect block headers (ddc_display_ref_reports.c); a block
# under any other header (phantom, busy, removed, DDC disabled) is skipped.
DDC_HEADERS = ((re.compile(r"^Display \d+$"), True), (re.compile(r"^Invalid display$"), False))
# An invalid block whose reason names a laptop panel is the backlight's.
DDC_LAPTOP = "laptop display"
DDC_LABEL = re.compile(r"^[A-Za-z0-9_ /]+:")
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


@dataclass(frozen=True)
class Unavailable:
    """Why an interface or display gives no brightness: a display state."""
    state: str  # no-access, no-answer or error
    detail: str | None = None


def errno_detail(name, error):
    return f"{name}: {errno.errorcode.get(error.errno, error.errno)} {os.strerror(error.errno)}"


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


def open_node(roots, iface):
    """A read-write fd on the interface's node, or Unavailable."""
    try:
        return os.open(roots.node(iface.name), os.O_RDWR | os.O_CLOEXEC)
    except PermissionError:
        return Unavailable("no-access")
    except OSError as error:
        return Unavailable("error", errno_detail(iface.name, error))


def probe(roots, reports, iface):
    """The raw brightness an interface answers, or Unavailable."""
    fd = open_node(roots, iface)
    if isinstance(fd, Unavailable):
        return fd
    try:
        result, report = reports.call(iface.name, fd, HIDIOCGFEATURE, encode(0))
    except OSError as error:
        if error.errno in PROBE_MISSES:
            return Unavailable("no-answer")
        return Unavailable("error", errno_detail(iface.name, error))
    finally:
        os.close(fd)
    raw = decode(report)
    if result < 5 or report[0] != REPORT_ID or not probe_in_range(raw, PRODUCTS[iface.product]):
        return Unavailable("no-answer")
    return raw


def control_interface(roots, reports, group):
    """(interface, raw) of the group's brightness control, or Unavailable:
    no-access over error over no-answer, the details of that state joined."""
    readings = [(iface, probe(roots, reports, iface)) for iface in group]
    answered = [(iface, raw) for iface, raw in readings if not isinstance(raw, Unavailable)]
    if answered:
        preferred = [pair for pair in answered if declares_brightness(pair[0].descriptor)]
        return (preferred or answered)[0]
    misses = [raw for _, raw in readings]
    for state in ("no-access", "error"):
        details = [miss.detail for miss in misses if miss.state == state]
        if details:
            return Unavailable(state, "; ".join(d for d in details if d) or None)
    return Unavailable("no-answer")


def write_raw(roots, reports, target, iface, raw):
    fd = open_node(roots, iface)
    if isinstance(fd, Unavailable):
        raise Failure("state", state=fd.state, id=target)
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
    """(backend state, every kernel backlight brightnessctl lists)."""
    base = roots.sys("class", "backlight")
    if not os.path.isdir(base) or not os.listdir(base):
        return {"state": "ready"}, []
    command = shutil.which("brightnessctl")
    if command is None:
        return {"state": "missing"}, []
    found = []
    try:
        # -l lists every device; without it brightnessctl prints the first alone.
        for line in run([command, "-l", "-m", "-c", "backlight"]).splitlines():
            fields = line.split(",")
            if len(fields) != 5 or not re.fullmatch(r"\d+%", fields[3]):
                raise Failure("brightnessctl-unparsed", line=line)
            found.append(Backlight(fields[0], clamp_percent(int(fields[3][:-1])),
                                   roots.resolve("class", "backlight", fields[0])))
    except Failure as failure:
        return {"state": "error", "detail": failure.fields}, []
    return {"state": "ready"}, found


def backlight_connector(roots, light):
    match = DRM_CONNECTOR.match(os.path.basename(roots.resolve("class", "backlight", light.name, "device")))
    return match[1] if match else None


# --- DDC ----------------------------------------------------------------------

def parse_detect(text):
    """ddcutil detect's displays with a bus: {"bus", "connector", "mfg",
    "model", "supported", "detail"}. A laptop panel's invalid block is
    dropped."""
    displays, current = [], None
    for line in text.splitlines():
        if not line.strip():
            continue
        item = line.strip()
        if not line[0].isspace():
            supported = next((ok for header, ok in DDC_HEADERS if header.match(item)), None)
            current = None if supported is None else {
                "bus": None, "connector": None, "mfg": "", "model": "", "supported": supported, "reasons": []}
            if current is not None:
                displays.append(current)
            continue
        if current is None:
            continue
        bus = re.match(r"I2C bus:\s+/dev/i2c-(\d+)$", item)
        if bus:
            current["bus"] = int(bus[1])
        elif re.match(r"DRM[ _]connector:", item):
            current["connector"] = re.sub(r"^card\d+-", "", item.split(":", 1)[1].strip()) or None
        elif item.startswith("Mfg id:"):
            current["mfg"] = (item.split(":", 1)[1].split() or [""])[0]
        elif item.startswith("Model:"):
            current["model"] = item.split(":", 1)[1].strip()
        elif len(line) - len(line.lstrip()) == 3 and not DDC_LABEL.match(item):
            current["reasons"].append(item)
    shown = []
    for d in displays:
        reasons = d.pop("reasons")
        if d["bus"] is None or (not d["supported"] and any(DDC_LAPTOP in r for r in reasons)):
            continue
        d["detail"] = None if d["supported"] else ("; ".join(reasons) or "ddcutil reports an invalid display")
        shown.append(d)
    return shown


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
    """The cache document, or None when it cannot be read or does not parse."""
    try:
        with open(cache) as source:
            held = json.load(source)
    except (OSError, ValueError):
        return None
    if not isinstance(held, dict) or held.get("format") != DDC_CACHE_FORMAT:
        return None
    return held if {"key", "at", "displays"} <= held.keys() else None


def write_cache(cache, document):
    """Best effort: a cache that cannot be written is left as it was."""
    directory = os.path.dirname(cache)
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        fd, temp = tempfile.mkstemp(dir=directory, prefix=".ddc-detect.", suffix=".json")
    except OSError:
        return
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(document, out)
        os.replace(temp, cache)
    except OSError:
        with contextlib.suppress(OSError):
            os.unlink(temp)


def detect(ddcutil, roots, env, now):
    key = hotplug_key(roots)
    cache = ddc_cache_path(env)
    held = read_cache(cache) if cache else None
    if held and held["key"] == key and 0 <= now - held["at"] < DDC_CACHE_SECONDS:
        return held["displays"]
    displays = parse_detect(run([ddcutil, "detect"]))
    if cache:
        write_cache(cache, {"format": DDC_CACHE_FORMAT, "key": key, "at": now, "displays": displays})
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


def ddc_display_state(ddcutil, roots, found):
    """(state, (current, max) when ready, detail): the one judge of a DDC
    display's state, for `list` and `set` both."""
    if not found["supported"]:
        return "unsupported", None, found["detail"]
    if not readable_writable(roots.node(f"i2c-{found['bus']}")):
        return "no-access", None, None
    try:
        reading = parse_getvcp(run([ddcutil, "--bus", str(found["bus"]), "getvcp", "10", "--brief"]))
    except Failure:
        reading = None
    if reading is None:
        return "no-answer", None, None
    return "ready", reading, None


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
    return [{key: o[key] for key in ("name", "make", "model", "serial") if isinstance(o.get(key), str)}
            for o in outputs]


def monitors(outputs):
    """Outputs grouped into physical monitors: one tiled monitor shows as
    several outputs with the same make, model and non-empty serial."""
    screens = {}
    for o in outputs:
        key = (o.get("make"), o.get("model"), o["serial"]) if o.get("serial") else (o["name"],)
        screen = screens.setdefault(key, {"model": o.get("model"), "serial": o.get("serial"), "names": []})
        screen["names"].append(o["name"])
    return list(screens.values())


def entry(id_, backend, label, state, percent, outputs, detail=None, **extra):
    shown = {"id": id_, "backend": backend, "label": label, "state": state,
             "percent": percent if state == "ready" else None, "outputs": outputs, **extra}
    if detail is not None:
        shown["detail"] = detail
    return shown


def apple_outputs(group, groups, screens):
    serial = group[0].serial
    by_serial = [m for m in screens if serial and m["serial"] == serial]
    if len(by_serial) == 1:
        return by_serial[0]["names"]
    product = group[0].product
    same_product = [g for g in groups if g[0].product == product]
    by_model = [m for m in screens if m["model"] == PRODUCTS[product].model]
    if len(same_product) == 1 and len(by_model) == 1:
        return by_model[0]["names"]
    return []


def apple_entries(roots, reports, outputs, lights):
    """One entry per physical Apple display; removes from lights each it uses."""
    shown = []
    screens = monitors(outputs)
    groups = physical_displays(apple_interfaces(roots))
    for group in groups:
        first = group[0]
        product = PRODUCTS[first.product]
        extra = {"product": first.product, "identity": {"parent": first.parent, "serial": first.serial}}
        names = apple_outputs(group, groups, screens)
        inside = roots.sys(first.parent) + os.sep
        kernel = next((light for light in lights if light.path.startswith(inside)), None)
        if kernel is not None:
            lights.remove(kernel)
            shown.append(entry("backlight:" + kernel.name, "backlight", product.label, "ready",
                               kernel.percent, names, **extra))
            continue
        chosen = control_interface(roots, reports, group)
        if isinstance(chosen, Unavailable):
            shown.append(entry("hidraw:" + first.parent, "hidraw", product.label, chosen.state, None, names,
                               chosen.detail, **extra))
        else:
            shown.append(entry("hidraw:" + first.parent, "hidraw", product.label, "ready",
                               percent_from_raw(chosen[1], product), names, **extra))
    return shown


def backlight_entries(roots, outputs, lights):
    names = {o["name"] for o in outputs}
    placed = {light.name: backlight_connector(roots, light) for light in lights}
    placed = {name: connector if connector in names else None for name, connector in placed.items()}
    unplaced = [name for name, connector in placed.items() if connector is None]
    internal = [n for n in names if INTERNAL_PANEL.match(n) and n not in placed.values()]
    if len(unplaced) == 1 and len(internal) == 1:
        placed[unplaced[0]] = internal[0]
    return [entry("backlight:" + light.name, "backlight", light.name, "ready", light.percent,
                  [placed[light.name]] if placed[light.name] else []) for light in lights]


def ddc_entries(roots, env, outputs, apple_models, now):
    """(backend state, entries). A block of an Apple display this run lists
    is the HID backend's and is skipped."""
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
        if found["mfg"] == APPLE_EDID_MANUFACTURER and found["model"] in apple_models:
            continue
        state, reading, detail = ddc_display_state(ddcutil, roots, found)
        percent = clamp_percent(round(reading[0] * 100 / reading[1])) if reading else None
        shown.append(entry(ddc_id(found), "ddc", found["model"] or ddc_id(found), state, percent,
                           [found["connector"]] if found["connector"] in names else [], detail))
    return {"state": "ready"}, shown


def list_displays(roots, reports, env, outputs, now):
    light_state, lights = backlights(roots)
    shown = apple_entries(roots, reports, outputs, lights)
    apple_models = {PRODUCTS[d["product"]].model for d in shown}
    shown += backlight_entries(roots, outputs, lights)
    ddc_backend, ddc_shown = ddc_entries(roots, env, outputs, apple_models, now)
    return {"backends": {"ddc": ddc_backend, "backlight": light_state}, "displays": shown + ddc_shown}


# --- set ----------------------------------------------------------------------

def set_hidraw(roots, reports, target, parent, percent):
    for group in physical_displays(apple_interfaces(roots)):
        if group[0].parent != parent:
            continue
        chosen = control_interface(roots, reports, group)
        if isinstance(chosen, Unavailable):
            raise Failure("state", state=chosen.state, id=target)
        write_raw(roots, reports, target, chosen[0], raw_from_percent(percent, PRODUCTS[group[0].product]))
        return
    raise Failure("unknown-id", id=target)


def set_ddc(roots, env, target, percent, now):
    ddcutil, state = ddc_command(roots)
    if ddcutil is None:
        raise Failure("state", state=state, id=target)
    found = next((d for d in detect(ddcutil, roots, env, now) if ddc_id(d) == target), None)
    if found is None:
        raise Failure("unknown-id", id=target)
    state, reading, _ = ddc_display_state(ddcutil, roots, found)
    if state != "ready":
        raise Failure("state", state=state, id=target)
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
