#!/usr/bin/env python3
"""Run the vgs.displays brightness helper end to end against device fakes.

Every helper run goes through scripts/smoke/fixtures/devices/hid-fake.py
for the HID feature reports, stand-in.py for ddcutil and brightnessctl (the
only commands on the helper's PATH), and temporary sysfs, /dev, HOME and
XDG_RUNTIME_DIR trees. An audit hook installed before the helper starts
exits 97 before any open outside those trees and Python's own library,
before any subprocess, exec, posix_spawn or spawn of a program outside the
stand-ins, and before any os.system, fork or forkpty, so no row reaches a
real device or the host's commands. The in-process cases load the helper
as a module and replace fcntl.ioctl, the HID reports object or os.replace
with recorders; they open only temporary files. Expected bytes, ioctl
numbers, descriptors and argv are written out by hand, never computed by
the helper's own code. The descriptors are the bytes the Studio Display's
and Pro Display XDR's interfaces report in
/sys/class/hidraw/*/device/report_descriptor. The controls plant one
defect per rule in a copy of the helper and run the named test against it.
"""
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import time
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
REPO = SCRIPTS.parent
HELPER = REPO / "shell/plugins/vgs.displays/helper/brightness.py"
DEVICES = SCRIPTS / "smoke/fixtures/devices"
HID_FAKE = DEVICES / "hid-fake.py"
STAND_IN = DEVICES / "stand-in.py"
S08_WORLD = DEVICES / "hid-world.json"

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("brightness", HELPER)
helper = importlib.util.module_from_spec(_spec)
sys.modules["brightness"] = helper
_spec.loader.exec_module(helper)

GET_FEATURE_7 = 0xC0074807
SET_FEATURE_7 = 0xC0074806
XDR, STUDIO = "9243", "1114"
AUDIT_EXIT = 97
# The brightness interfaces of the owner's Studio Display (hidraw6) and Pro
# Display XDR (hidraw9): Monitor page 0x80 usage 0x01, report id 1, then
# VESA page 0x82 usage 0x10 with logical range 400..60000 / 400..50000.
STUDIO_BRIGHTNESS = ("05800901a101850106820009101690012760ea000067e1000001550e75209501b142050f0950150026204e66"
                     "1001550d7510b14206820009101690012760ea000067e1000001550e752095018102c0")
XDR_BRIGHTNESS = ("05800901a101850106820009101690012750c3000067e1000001550e75209501b142050f0950150026204e66"
                  "1001550d7510b14206820009101690012750c3000067e1000001550e752095018102c0")
# The Studio Display's vendor-page interface (hidraw4).
STUDIO_VENDOR = "0600ff0953a101850115002501750895190600ff09538102c0"

# Installed before the helper runs: any open outside the allowed roots, any
# program start outside the stand-in directory, and any os.system, fork or
# forkpty exits AUDIT_EXIT before the call happens. Opens under the device
# root print `audit: node=PATH`.
AUDIT = r"""
import json, os, runpy, sys
allowed, dev_root, stand_ins = json.loads(sys.argv[1])
def inside(path, roots):
    return any(path == r or path.startswith(r.rstrip("/") + "/") for r in roots)
def refuse(what):
    sys.stderr.write("audit: refused " + what + "\n"); sys.stderr.flush(); os._exit(97)
def program(path):
    path = os.path.abspath(os.fsdecode(path))
    if not inside(path, [stand_ins]):
        refuse("exec=" + path)
def hook(event, args):
    if event == "open" and not isinstance(args[0], int):
        path = os.path.abspath(os.fsdecode(args[0]))
        if not inside(path, allowed):
            refuse("open=" + path)
        if inside(path, [dev_root]):
            sys.stderr.write("audit: node=" + path + "\n")
    elif event == "subprocess.Popen":
        program(list(args[1])[0])
    elif event in ("os.exec", "os.posix_spawn"):
        program(args[0])
    elif event == "os.spawn":
        program(args[1])
    elif event in ("os.system", "os.fork", "os.forkpty"):
        refuse(event)
sys.argv = sys.argv[2:]
sys.addaudithook(hook)
runpy.run_path(sys.argv[0], run_name="__main__")
"""

# ddcutil 3.0.2 detect, laid out as ddc_report_display_by_dref and
# i2c_report_active_bus print it: three spaces per depth, `DRM_connector:`
# padded to 25, the reason of an invalid display at depth 1. A `|` ends a
# line where ddcutil leaves the trailing spaces of an empty EDID field.
DETECT = """Display 1
   I2C bus:  /dev/i2c-5
   DRM_connector:           card1-DP-1
   EDID synopsis:
      Mfg id:               DEL - Dell Inc.
      Model:                DELL U2720Q
      Product code:         16725  (0x4155)
      Serial number:        ABC123
      Binary serial number: 1112363076 (0x424d4c44)
      Manufacture year:     2021,  Week: 12
   VCP version:         2.1

Invalid display
   I2C bus:  /dev/i2c-6
   DRM_connector:           card1-DP-2
   EDID synopsis:
      Mfg id:               ACM - Acme Corporation
      Model:                ACME 27
      Product code:         4660  (0x1234)
      Serial number:        |
      Binary serial number: 0 (0x00000000)
      Manufacture year:     2020,  Week: 3
   This monitor does not support DDC/CI. (I2C slave address x37 is unresponsive.)

Invalid display
   I2C bus:  /dev/i2c-7
   DRM_connector:           card0-DP-5
   EDID synopsis:
      Mfg id:               APP - Apple Computer Inc
      Model:                ProDisplayXDR
      Product code:         44578  (0xae22)
      Serial number:        |
      Binary serial number: 51057411 (0x030b1303)
      Manufacture year:     2019,  Week: 47
   DDC communication failed

Invalid display
   I2C bus:  /dev/i2c-8
   DRM_connector:           card1-eDP-1
   EDID synopsis:
      Mfg id:               BOE - BOE
      Model:                |
      Product code:         2333  (0x091d)
      Serial number:        |
      Binary serial number: 0 (0x00000000)
      Manufacture year:     2022,  Week: 1
   This is a laptop display.  Laptop displays do not support DDC/CI.

""".replace("|\n", "\n")
NO_DISPLAYS = 'No displays found.\nRun "ddcutil environment" to check for system configuration problems.\n'
DDC_DP1 = {"id": "ddc:DP-1", "backend": "ddc", "label": "DELL U2720Q", "state": "ready", "percent": 75, "outputs": ["DP-1"]}
DDC_DP2 = {"id": "ddc:DP-2", "backend": "ddc", "label": "ACME 27", "state": "unsupported", "percent": None,
           "outputs": [], "detail": "This monitor does not support DDC/CI. (I2C slave address x37 is unresponsive.)"}
DDC_DP5 = {"id": "ddc:DP-5", "backend": "ddc", "label": "ProDisplayXDR", "state": "unsupported", "percent": None,
           "outputs": [], "detail": "DDC communication failed"}


def report(raw):
    """Feature report 1 holding RAW, little-endian, as hex."""
    return "01" + raw.to_bytes(4, "little").hex() + "0000"


class World:
    """A temporary machine: sysfs, /dev, stand-ins and a running HID fake."""

    def __init__(self, scratch):
        self.root = Path(scratch)
        self.sys = self.root / "sys"
        self.dev = self.root / "dev"
        self.bin = self.root / "bin"
        self.state = self.root / "state"
        self.run_dir = self.root / "run"
        for path in (self.sys, self.dev, self.bin, self.state / "replies", self.run_dir, self.root / "home"):
            path.mkdir(parents=True, exist_ok=True)
        self.devices = []
        self.fake = None
        self.socket = self.root / "hid.sock"
        self.log = self.root / "hid.log"

    # --- HID ---------------------------------------------------------------
    def usb(self, port, product, serial):
        """A USB device directory, `devices/.../usb1/<port>`."""
        path = self.sys / "devices/pci0000:00/0000:00:14.0/usb1" / port
        path.mkdir(parents=True, exist_ok=True)
        (path.parent / "idVendor").write_text("1d6b\n")
        (path / "idVendor").write_text("05ac\n")
        (path / "idProduct").write_text(product + "\n")
        (path / "serial").write_text(serial + "\n")
        return path

    def hidraw(self, name, product, serial, raw=None, usb=None, interface=0, descriptor=None, stored=None,
               in_world=True):
        """One hidraw interface; with USB a port, linked under that USB device
        as the kernel does; without, planted by the fake alone. RAW None is an
        interface without report 1; STORED is report 1's hex in place of RAW's.
        Out of the world, sysfs and /dev hold it and the fake answers ENOENT."""
        hid = None
        if usb is not None:
            hid = self.usb(usb, product, serial) / f"{usb}:1.{interface}" / f"0003:05AC:{product.upper()}.{len(self.devices) + 1:04X}"
            (hid / "hidraw" / name).mkdir(parents=True)
            (hid / "hidraw" / name / "device").symlink_to("../..")
            (self.sys / "class/hidraw").mkdir(parents=True, exist_ok=True)
            (self.sys / "class/hidraw" / name).symlink_to(os.path.relpath(hid / "hidraw" / name, self.sys / "class/hidraw"))
        if not in_world:
            (hid / "uevent").write_text(f"HID_ID=0003:000005AC:0000{product.upper()}\nHID_NAME=Apple display\nHID_UNIQ={serial}\n")
            (self.dev / name).write_text("")
            return
        reports = {"1": stored} if stored is not None else {} if raw is None else {"1": report(raw)}
        device = {"name": name, "vendor": "05ac", "product": product, "hidName": "Apple display", "serial": serial,
                  "reports": reports}
        if descriptor is not None:
            device["descriptor"] = descriptor
        self.devices.append(device)

    def start(self, world=None):
        if world is None:
            world = self.root / "world.json"
            world.write_text(json.dumps({"devices": self.devices}))
        self.fake = subprocess.Popen(
            [sys.executable, str(HID_FAKE), str(self.socket), str(world), str(self.dev), str(self.sys), str(self.log)],
            stdout=subprocess.PIPE, text=True, env={"PATH": "/usr/bin:/bin"})
        line = self.fake.stdout.readline()
        if line != "hid-fake=listening\n":
            raise AssertionError(f"hid fake did not start: {line!r}")

    def stop(self):
        if self.fake is not None:
            self.fake.terminate()
            self.fake.wait(timeout=10)
            self.fake.stdout.close()

    def requests(self, code=None):
        if not self.log.exists():
            return []
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [r for r in rows if code is None or r["request"]["request"] == code]

    def stored(self, name):
        """The last report SET_FEATURE wrote to NAME, as hex."""
        writes = [r["request"]["data"] for r in self.requests(SET_FEATURE_7) if r["request"]["device"] == name]
        return writes[-1] if writes else None

    # --- commands ----------------------------------------------------------
    def stand_in(self, name):
        shim = self.bin / name
        shim.write_text(f"#!/bin/sh\nexec '{sys.executable}' '{STAND_IN}' {name} '{self.state}' \"$@\"\n")
        shim.chmod(0o755)

    def reply(self, name, argv, stdout, status=0):
        path = self.state / "replies" / f"{name}.json"
        rows = json.loads(path.read_text()) if path.exists() else []
        rows = [row for row in rows if row["argv"] != argv] + [{"argv": argv, "stdout": stdout, "status": status}]
        path.write_text(json.dumps(rows))

    def calls(self, name):
        path = self.state / "calls" / f"{name}.calls"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    # --- sysfs for DDC and backlights --------------------------------------
    def ddc(self, buses=(5, 6, 7, 8), mode=0o600, module=True):
        if module:
            (self.sys / "module/i2c_dev").mkdir(parents=True, exist_ok=True)
        for bus in buses:
            node = self.dev / f"i2c-{bus}"
            node.write_text("")
            node.chmod(mode)
            (self.sys / "class/i2c-dev" / f"i2c-{bus}").mkdir(parents=True, exist_ok=True)
        for connector in ("card1-DP-1", "card1-DP-2", "card0-DP-5", "card1-eDP-1"):
            (self.sys / "class/drm" / connector).mkdir(parents=True, exist_ok=True)
            (self.sys / "class/drm" / connector / "edid").write_bytes(connector.encode())
        self.stand_in("ddcutil")
        self.reply("ddcutil", ["detect"], DETECT)
        self.reply("ddcutil", ["--bus", "5", "getvcp", "10", "--brief"], "VCP 10 C 60 80")

    def backlight(self, name, parent):
        """A kernel backlight whose device is PARENT, relative to sysfs."""
        real = self.sys / parent / name
        real.mkdir(parents=True)
        (real / "device").symlink_to("..")
        (self.sys / "class/backlight").mkdir(parents=True, exist_ok=True)
        (self.sys / "class/backlight" / name).symlink_to(os.path.relpath(real, self.sys / "class/backlight"))

    # --- the helper --------------------------------------------------------
    def env(self, **overrides):
        env = {"PATH": str(self.bin), "HOME": str(self.root / "home"), "LC_ALL": "C",
               "XDG_RUNTIME_DIR": str(self.run_dir), "VGS_SYSFS_ROOT": str(self.sys),
               "VGS_DEV_ROOT": str(self.dev), "VGS_HID_FAKE": str(self.socket)}
        env.update(overrides)
        return {k: v for k, v in env.items() if v is not None}

    def helper(self, *args, stdin=None, script=HELPER, **overrides):
        """(exit status, JSON answer or None, audit lines) of one helper run."""
        stdlib = [sysconfig.get_paths()[k] for k in ("stdlib", "platstdlib")]
        allowed = [str(self.root), str(script)] + stdlib
        audit = json.dumps([allowed, str(self.dev), str(self.bin)])
        done = subprocess.run([sys.executable, "-I", "-c", AUDIT, audit, str(script), *args], input=stdin,
                              env=self.env(**overrides), text=True, capture_output=True, check=False)
        audit_lines = [line for line in done.stderr.splitlines() if line.startswith("audit: ")]
        if done.returncode == AUDIT_EXIT:
            raise AssertionError("helper reached outside the fakes: " + done.stderr)
        try:
            answer = json.loads(done.stdout)
        except ValueError:
            raise AssertionError(f"helper printed no JSON (exit {done.returncode}): {done.stdout!r} {done.stderr!r}")
        return done.returncode, answer, audit_lines

    def listing(self, outputs=(), **overrides):
        path = self.root / "outputs.json"
        path.write_text(json.dumps(list(outputs)))
        status, answer, _ = self.helper("list", "--outputs", str(path), **overrides)
        if status != 0:
            raise AssertionError(f"list exited {status}: {answer}")
        return answer

    def set(self, id_, percent, **overrides):
        return self.helper("set", id_, str(percent), **overrides)[:2]


class Case(unittest.TestCase):
    def world(self):
        scratch = tempfile.mkdtemp(prefix="vgs-brightness-")
        self.addCleanup(shutil.rmtree, scratch)
        world = World(os.path.realpath(scratch))
        self.addCleanup(world.stop)
        return world

    def only(self, answer, backend):
        shown = [d for d in answer["displays"] if d["backend"] == backend]
        self.assertEqual(len(shown), 1, answer)
        return shown[0]


class Hid(Case):
    def test_bytes_and_ioctl_numbers(self):
        # raw = 400 + percent * (max - 400) / 100, bytes 1..4 little-endian.
        rows = (
            (XDR, 0, "01900100000000"), (XDR, 50, "01706200000000"), (XDR, 100, "0150c300000000"),
            (STUDIO, 0, "01900100000000"), (STUDIO, 50, "01f87500000000"), (STUDIO, 100, "0160ea00000000"),
            (XDR, 150, "0150c300000000"), (XDR, -5, "01900100000000"),
        )
        for product, percent, expected in rows:
            with self.subTest(product=product, percent=percent):
                world = self.world()
                world.hidraw("hidraw0", product, "S1", raw=25000, usb="1-2")
                world.start()
                [shown] = world.listing()["displays"]
                status, answer = world.set(shown["id"], percent)
                self.assertEqual((status, answer), (0, {"id": shown["id"], "percent": max(0, min(100, percent))}))
                self.assertEqual(world.stored("hidraw0"), expected)
                self.assertEqual([r["request"]["data"] for r in world.requests(GET_FEATURE_7)][0], "01000000000000")
                self.assertEqual({r["request"]["request"] for r in world.requests()}, {GET_FEATURE_7, SET_FEATURE_7})
                self.assertEqual(self.only(world.listing(), "hidraw")["percent"], max(0, min(100, percent)))

    def test_probe_accepts_only_in_range_answers(self):
        rows = ((XDR, 60000, None, "ready", 100), (XDR, 60001, None, "no-answer", None),
                (STUDIO, 60001, None, "no-answer", None), (STUDIO, 60000, None, "ready", 100),
                (XDR, 200, None, "ready", 0), (XDR, 199, None, "no-answer", None), (XDR, 25000, None, "ready", 50),
                (XDR, None, "01a861", "no-answer", None),          # 3 bytes: id and half the value
                (XDR, None, "02a86100000000", "no-answer", None))  # report id 2 holding 25000
        for product, raw, stored, state, percent in rows:
            with self.subTest(product=product, raw=raw, stored=stored):
                world = self.world()
                world.hidraw("hidraw0", product, "S1", raw=raw, stored=stored, usb="1-2")
                world.start()
                shown = self.only(world.listing(), "hidraw")
                self.assertEqual((shown["state"], shown["percent"]), (state, percent))

    def test_probing_finds_the_answering_interface(self):
        world = self.world()
        world.hidraw("hidraw0", XDR, "S1", raw=None, usb="1-2", interface=0)
        world.hidraw("hidraw1", XDR, "S1", raw=12800, usb="1-2", interface=1)
        world.start()
        shown = self.only(world.listing(), "hidraw")
        self.assertEqual((shown["state"], shown["percent"]), ("ready", 25))
        self.assertEqual(world.set(shown["id"], 100)[0], 0)
        self.assertEqual((world.stored("hidraw0"), world.stored("hidraw1")), (None, "0150c300000000"))

    def test_probe_error_is_the_interface_only(self):
        world = self.world()
        world.hidraw("hidraw0", XDR, "S1", usb="1-2", interface=0, in_world=False)
        world.hidraw("hidraw1", XDR, "S1", raw=12800, usb="1-2", interface=1)
        world.hidraw("hidraw2", XDR, "S2", usb="1-3", in_world=False)
        world.hidraw("hidraw3", XDR, "S3", raw=None, usb="1-4")
        world.start()
        shown = world.listing()["displays"]
        self.assertEqual([(d["state"], d["percent"]) for d in shown], [("ready", 25), ("error", None), ("no-answer", None)])
        self.assertRegex(shown[1]["detail"], r"^hidraw2: ENOENT ")
        self.assertNotIn("detail", shown[2])
        self.assertEqual(world.set(shown[1]["id"], 50)[1], {"error": "state", "state": "error", "id": shown[1]["id"]})

    def test_descriptor_preference(self):
        rows = (
            ("the Studio Display's brightness interface", STUDIO_BRIGHTNESS, True),
            ("the Pro Display XDR's brightness interface", XDR_BRIGHTNESS, True),
            ("an extended usage 0x00820010", "0b10008200a101", True),
            ("a long item before the usage", "fe0200aabb05820910", True),
            ("asdcontrol's hiddev code 0x820001", "05800901a10185010682000901", False),
            ("usage 0x10 on the Monitor page", "05800910a101", False),
            ("the Studio Display's vendor interface", STUDIO_VENDOR, False),
        )
        for name, descriptor, preferred in rows:
            with self.subTest(descriptor=name):
                world = self.world()
                world.hidraw("hidraw0", XDR, "S1", raw=12800, usb="1-2", interface=0, descriptor=STUDIO_VENDOR)
                world.hidraw("hidraw1", XDR, "S1", raw=37600, usb="1-2", interface=1, descriptor=descriptor)
                world.start()
                shown = self.only(world.listing(), "hidraw")
                self.assertEqual(shown["percent"], 75 if preferred else 25)
                world.set(shown["id"], 0)
                self.assertEqual(world.stored("hidraw1" if preferred else "hidraw0"), "01900100000000")

    def test_units_stay_distinct_by_usb_parent(self):
        rows = (("no serials", "", ""), ("equal serials", "SAME", "SAME"))
        for name, first, second in rows:
            with self.subTest(case=name):
                world = self.world()
                world.hidraw("hidraw0", XDR, first, raw=12800, usb="1-2", interface=0)
                world.hidraw("hidraw1", XDR, first, raw=None, usb="1-2", interface=1)
                world.hidraw("hidraw2", XDR, second, raw=37600, usb="1-3", interface=0)
                world.start()
                shown = world.listing()["displays"]
                parents = ["devices/pci0000:00/0000:00:14.0/usb1/1-2", "devices/pci0000:00/0000:00:14.0/usb1/1-3"]
                self.assertEqual([d["identity"] for d in shown],
                                 [{"parent": parents[0], "serial": first}, {"parent": parents[1], "serial": second}])
                self.assertEqual([(d["id"], d["percent"]) for d in shown],
                                 [("hidraw:" + parents[0], 25), ("hidraw:" + parents[1], 75)])
                world.set("hidraw:" + parents[1], 100)
                self.assertEqual((world.stored("hidraw0"), world.stored("hidraw2")), (None, "0150c300000000"))

    def test_s08_world_without_usb_parent(self):
        # The smoke world: a Pro Display XDR and two Studio Displays with one
        # serial, which only their HID devices' own directories tell apart.
        world = self.world()
        world.start(S08_WORLD)
        shown = [d for d in world.listing()["displays"] if d["backend"] == "hidraw"]
        parent = "class/hidraw/{}/device".format
        self.assertEqual(shown, [
            {"id": "hidraw:" + parent("hidraw0"), "backend": "hidraw", "label": "Apple Pro Display XDR", "state": "ready",
             "percent": 50, "outputs": [], "product": XDR, "identity": {"parent": parent("hidraw0"), "serial": "VGSSMOKEXDR01"}},
            {"id": "hidraw:" + parent("hidraw1"), "backend": "hidraw", "label": "Apple Studio Display", "state": "ready",
             "percent": 50, "outputs": [], "product": STUDIO, "identity": {"parent": parent("hidraw1"), "serial": "VGSSMOKESTUDIO"}},
            {"id": "hidraw:" + parent("hidraw2"), "backend": "hidraw", "label": "Apple Studio Display", "state": "ready",
             "percent": 70, "outputs": [], "product": STUDIO, "identity": {"parent": parent("hidraw2"), "serial": "VGSSMOKESTUDIO"}}])
        self.assertEqual(world.set(shown[0]["id"], 50), (0, {"id": shown[0]["id"], "percent": 50}))
        self.assertEqual(world.stored("hidraw0"), "01706200000000")
        self.assertEqual(world.set(shown[2]["id"], 100), (0, {"id": shown[2]["id"], "percent": 100}))
        self.assertEqual((world.stored("hidraw1"), world.stored("hidraw2")), (None, "0160ea00000000"))

    def test_output_mapping(self):
        xdr1 = {"name": "DP-1", "model": "ProDisplayXDR", "serial": "S1"}
        xdr2 = {"name": "DP-2", "model": "ProDisplayXDR", "serial": "OTHER"}
        studio = {"name": "DP-3", "model": "StudioDisplay", "serial": ""}
        # The owner's rig as `hyprctl -j monitors all` reports it: the XDR is
        # tiled over DP-1 and DP-5 and both carry the EDID binary serial.
        tiled = [{"name": n, "make": "Apple Computer Inc", "model": "ProDisplayXDR", "serial": "0x030B1303"}
                 for n in ("DP-1", "DP-5")]
        rig_studio = {"name": "DP-2", "make": "Apple Computer Inc", "model": "StudioDisplay", "serial": "0xE6BB516A"}
        rows = (
            ("serial match", [(XDR, "S1", "1-2")], [xdr2, xdr1], [["DP-1"]]),
            ("unique model", [(XDR, "", "1-2")], [xdr1, studio], [["DP-1"]]),
            ("two monitors of the model", [(XDR, "", "1-2")], [xdr1, xdr2], [[]]),
            ("two units of the product", [(XDR, "", "1-2"), (XDR, "", "1-3")], [xdr1], [[], []]),
            ("serial beats model", [(XDR, "S1", "1-2"), (XDR, "", "1-3")], [xdr1], [["DP-1"], []]),
            ("no outputs", [(XDR, "S1", "1-2")], [], [[]]),
            ("another model", [(XDR, "", "1-2")], [studio], [[]]),
            ("a tiled XDR and a Studio Display",
             [(XDR, "C020106008NJLC0AX", "1-2"), (STUDIO, "00008030-0003681A3685802E", "1-3")],
             tiled + [rig_studio], [["DP-1", "DP-5"], ["DP-2"]]),
        )
        for name, units, outputs, expected in rows:
            with self.subTest(case=name):
                world = self.world()
                for index, (product, serial, port) in enumerate(units):
                    world.hidraw(f"hidraw{index}", product, serial, raw=25000, usb=port)
                world.start()
                self.assertEqual([d["outputs"] for d in world.listing(outputs)["displays"]], expected)

    def test_outputs_from_stdin(self):
        world = self.world()
        world.hidraw("hidraw0", XDR, "S1", raw=25000, usb="1-2")
        world.start()
        status, answer, _ = world.helper("list", "--outputs", "-", stdin=json.dumps([{"name": "DP-9", "serial": "S1"}]))
        self.assertEqual((status, answer["displays"][0]["outputs"]), (0, ["DP-9"]))


class InProcess(unittest.TestCase):
    """The helper loaded as a module, with the system call replaced."""

    def scratch(self):
        root = tempfile.mkdtemp(prefix="vgs-brightness-")
        self.addCleanup(shutil.rmtree, root)
        return Path(os.path.realpath(root))

    def test_real_ioctl_call(self):
        calls = []

        def ioctl(fd, request, buffer, mutate):
            calls.append((fd, request, type(buffer), mutate, bytes(buffer)))
            buffer[1:5] = bytes.fromhex("a8610000")
            return 7

        with mock.patch.object(helper.fcntl, "ioctl", ioctl):
            answer = helper.FeatureReports(None).call("hidraw9", 41, GET_FEATURE_7, bytes.fromhex("01000000000000"))
        self.assertEqual(calls, [(41, GET_FEATURE_7, bytearray, True, bytes.fromhex("01000000000000"))])
        self.assertEqual(answer, (7, bytes.fromhex("01a86100000000")))

    def test_short_write_fails(self):
        root = self.scratch()
        (root / "dev").mkdir()
        (root / "dev/hidraw0").write_text("")
        roots = helper.Roots(str(root), str(root / "dev"), None)
        iface = helper.Interface("hidraw0", XDR, "S1", "usb", b"")

        class Reports:
            def __init__(self, result):
                self.result, self.seen = result, []

            def call(self, name, fd, request, report):
                self.seen.append((name, request, report.hex()))
                return self.result, report

        whole = Reports(7)
        helper.write_raw(roots, whole, "hidraw:usb", iface, 400)
        self.assertEqual(whole.seen, [("hidraw0", SET_FEATURE_7, "01900100000000")])
        for result in (0, 5, 6):
            with self.subTest(result=result):
                with self.assertRaises(helper.Failure) as caught:
                    helper.write_raw(roots, Reports(result), "hidraw:usb", iface, 400)
                self.assertEqual((caught.exception.fields["error"], caught.exception.fields["node"]), ("hid-write", "hidraw0"))

    def test_cache_temporary_files_are_unique(self):
        cache = self.scratch() / "run/vgs/displays/ddc-detect.json"
        sources = []
        replace = os.replace

        def recording(source, target):
            sources.append(source)
            replace(source, target)

        with mock.patch.object(helper.os, "replace", recording):
            for n in (1, 2):
                helper.write_cache(str(cache), {"n": n})
        self.assertEqual(len(set(sources)), 2, sources)
        self.assertEqual({os.path.dirname(s) for s in sources}, {str(cache.parent)})
        self.assertNotIn(str(cache) + ".next", sources)
        self.assertEqual(json.loads(cache.read_text()), {"n": 2})
        self.assertEqual(os.listdir(cache.parent), ["ddc-detect.json"])


class Backlights(Case):
    def test_kernel_backlight_preferred_over_hidraw(self):
        world = self.world()
        world.hidraw("hidraw0", XDR, "S1", raw=25000, usb="1-2")
        world.backlight("appledisplay0", "devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2:1.0")
        world.stand_in("brightnessctl")
        world.reply("brightnessctl", ["-l", "-m", "-c", "backlight"], "appledisplay0,backlight,30,30%,100\n")
        world.reply("brightnessctl", ["-d", "appledisplay0", "set", "40%"], "")
        world.start()
        answer = world.listing([{"name": "DP-1", "model": "ProDisplayXDR"}])
        self.assertEqual(answer["displays"], [{
            "id": "backlight:appledisplay0", "backend": "backlight", "label": "Apple Pro Display XDR",
            "state": "ready", "percent": 30, "outputs": ["DP-1"], "product": XDR,
            "identity": {"parent": "devices/pci0000:00/0000:00:14.0/usb1/1-2", "serial": "S1"}}])
        self.assertEqual(world.requests(), [])
        self.assertEqual(world.set("backlight:appledisplay0", 40), (0, {"id": "backlight:appledisplay0", "percent": 40}))
        self.assertEqual(world.calls("brightnessctl")[-1], ["-d", "appledisplay0", "set", "40%"])

    def test_listing_parsing_mapping_and_set(self):
        world = self.world()
        world.backlight("intel_backlight", "devices/pci0000:00/0000:00:02.0/drm/card1/card1-eDP-1")
        world.backlight("acpi_video0", "devices/LNXSYSTM:00/LNXVIDEO:00")
        world.stand_in("brightnessctl")
        world.reply("brightnessctl", ["-l", "-m", "-c", "backlight"],
                    "intel_backlight,backlight,12000,50%,24000\nacpi_video0,backlight,7,70%,10\n")
        world.reply("brightnessctl", ["-d", "intel_backlight", "set", "70%"], "")
        world.start()
        rows = (
            ("connector parent, then the panel left", [{"name": "eDP-1"}, {"name": "eDP-2"}],
             {"intel_backlight": ["eDP-1"], "acpi_video0": ["eDP-2"]}),
            ("the one panel is claimed", [{"name": "eDP-1"}, {"name": "DP-1"}], {"intel_backlight": ["eDP-1"], "acpi_video0": []}),
            ("lone internal panel", [{"name": "eDP-2"}], {"intel_backlight": [], "acpi_video0": []}),
            ("no outputs", [], {"intel_backlight": [], "acpi_video0": []}),
        )
        for name, outputs, expected in rows:
            with self.subTest(case=name):
                answer = world.listing(outputs)
                self.assertEqual(answer["backends"]["backlight"], {"state": "ready"})
                self.assertEqual({d["id"].split(":", 1)[1]: d["outputs"] for d in answer["displays"]}, expected)
                self.assertEqual({d["id"]: d["percent"] for d in answer["displays"]},
                                 {"backlight:intel_backlight": 50, "backlight:acpi_video0": 70})
        world.reply("brightnessctl", ["-l", "-m", "-c", "backlight"], "intel_backlight,backlight,12000,50%,24000\n")
        (world.sys / "class/backlight/acpi_video0").unlink()
        self.assertEqual(world.listing([{"name": "eDP-2"}])["displays"][0]["outputs"], ["eDP-2"])
        self.assertEqual(world.set("backlight:intel_backlight", 70), (0, {"id": "backlight:intel_backlight", "percent": 70}))
        self.assertEqual(world.calls("brightnessctl")[-1], ["-d", "intel_backlight", "set", "70%"])

    def test_failure_keeps_other_backends(self):
        world = self.world()
        world.hidraw("hidraw0", XDR, "S1", raw=25000, usb="1-2")
        world.backlight("intel_backlight", "devices/pci0000:00/0000:00:02.0/drm/card1/card1-eDP-1")
        world.ddc()
        world.start()
        self.assertEqual(world.listing()["backends"]["backlight"], {"state": "missing"})
        world.stand_in("brightnessctl")
        rows = (("a failed brightnessctl", "", 1, "command"),
                ("a line that does not parse", "intel_backlight backlight 50%\n", 0, "brightnessctl-unparsed"))
        for name, stdout, status, key in rows:
            with self.subTest(case=name):
                world.reply("brightnessctl", ["-l", "-m", "-c", "backlight"], stdout, status=status)
                answer = world.listing()
                self.assertEqual((answer["backends"]["backlight"]["state"], answer["backends"]["backlight"]["detail"]["error"]),
                                 ("error", key))
                self.assertEqual([d["id"] for d in answer["displays"]],
                                 ["hidraw:devices/pci0000:00/0000:00:14.0/usb1/1-2", "ddc:DP-1", "ddc:DP-2"])
        world.reply("brightnessctl", ["-d", "intel_backlight", "set", "5%"], "", status=1)
        status, answer = world.set("backlight:intel_backlight", 5)
        self.assertEqual((status, answer["error"], answer["status"]), (1, "command", 1))


class Ddc(Case):
    def test_detect_getvcp_and_set(self):
        world = self.world()
        world.ddc()
        world.reply("ddcutil", ["--bus", "5", "setvcp", "10", "32"], "")
        world.start()
        answer = world.listing([{"name": "DP-1"}, {"name": "eDP-1"}])
        self.assertEqual(answer["backends"]["ddc"], {"state": "ready"})
        self.assertEqual(answer["displays"], [DDC_DP1, DDC_DP2, DDC_DP5])
        self.assertEqual(world.set("ddc:DP-1", 40), (0, {"id": "ddc:DP-1", "percent": 40}))
        self.assertEqual(world.calls("ddcutil"), [
            ["detect"], ["--bus", "5", "getvcp", "10", "--brief"], ["--bus", "5", "getvcp", "10", "--brief"],
            ["--bus", "5", "setvcp", "10", "32"]])
        self.assertEqual(world.set("ddc:DP-9", 40)[1]["error"], "unknown-id")
        world.reply("ddcutil", ["--bus", "5", "getvcp", "10", "--brief"], "", status=1)
        self.assertEqual([d["state"] for d in world.listing()["displays"]], ["no-answer", "unsupported", "unsupported"])

    def test_set_judges_state_as_list_does(self):
        world = self.world()
        world.ddc()
        world.start()
        (world.dev / "i2c-5").chmod(0o400)
        shown = {d["id"]: d["state"] for d in world.listing()["displays"]}
        self.assertEqual(shown, {"ddc:DP-1": "no-access", "ddc:DP-2": "unsupported", "ddc:DP-5": "unsupported"})
        before = len(world.calls("ddcutil"))
        for id_, state in shown.items():
            with self.subTest(id=id_):
                self.assertEqual(world.set(id_, 10), (1, {"error": "state", "state": state, "id": id_}))
        self.assertEqual(world.calls("ddcutil")[before:], [])

    def test_detect_empty_and_failed(self):
        world = self.world()
        world.ddc()
        world.reply("ddcutil", ["detect"], NO_DISPLAYS)
        world.start()
        self.assertEqual(world.listing(), {"backends": {"ddc": {"state": "ready"}, "backlight": {"state": "ready"}},
                                           "displays": []})
        world.reply("ddcutil", ["detect"], "", status=1)
        (world.run_dir / "vgs/displays/ddc-detect.json").unlink()
        answer = world.listing()
        self.assertEqual((answer["backends"]["ddc"]["state"], answer["displays"]), ("error", []))

    def test_apple_blocks_left_to_hid(self):
        rows = ((XDR, ["hidraw", "ddc:DP-1", "ddc:DP-2"]), (STUDIO, ["hidraw", "ddc:DP-1", "ddc:DP-2", "ddc:DP-5"]))
        for product, expected in rows:
            with self.subTest(product=product):
                world = self.world()
                world.hidraw("hidraw0", product, "S1", raw=25000, usb="1-2")
                world.ddc()
                world.start()
                shown = world.listing()["displays"]
                self.assertEqual([d["backend"] if d["backend"] == "hidraw" else d["id"] for d in shown], expected)

    def test_detect_cache_and_hotplug(self):
        world = self.world()
        world.ddc()
        world.start()
        cache = world.run_dir / "vgs/displays/ddc-detect.json"

        def detects():
            return world.calls("ddcutil").count(["detect"])

        def age(seconds):
            held = json.loads(cache.read_text())
            held["at"] = time.time() - seconds
            cache.write_text(json.dumps(held))

        rows = (
            ("first run detects", lambda: None, 1),
            ("a fresh cache is reused", lambda: None, 0),
            ("20 s old is reused", lambda: age(20), 0),
            ("31 s old detects", lambda: age(31), 1),
            ("an EDID change detects", lambda: (world.sys / "class/drm/card1-DP-2/edid").write_bytes(b"other"), 1),
            ("a new connector detects", lambda: (world.sys / "class/drm/card1-HDMI-A-1").mkdir(), 1),
            ("a new i2c bus detects", lambda: (world.sys / "class/i2c-dev/i2c-9").mkdir(), 1),
            ("a cache from the future detects", lambda: age(-60), 1),
            ("a cache that does not parse detects", lambda: cache.write_text("{"), 1),
            ("a non-connector entry is not a hotplug", lambda: (world.sys / "class/drm/version").mkdir(), 0),
        )
        for name, change, runs in rows:
            with self.subTest(case=name):
                before = detects()
                change()
                world.listing()
                self.assertEqual(detects() - before, runs)
        before = detects()
        world.listing(XDG_RUNTIME_DIR=None)
        world.listing(XDG_RUNTIME_DIR=None)
        self.assertEqual(detects() - before, 2)

    def test_cache_is_best_effort(self):
        world = self.world()
        world.ddc()
        world.start()
        (world.run_dir / "vgs").write_text("")
        for _ in range(2):
            answer = world.listing()
            self.assertEqual((answer["backends"]["ddc"], [d["id"] for d in answer["displays"]]),
                             ({"state": "ready"}, ["ddc:DP-1", "ddc:DP-2", "ddc:DP-5"]))
        self.assertEqual(world.calls("ddcutil").count(["detect"]), 2)

    def test_concurrent_cold_runs(self):
        world = self.world()
        world.ddc()
        world.start()
        with ThreadPoolExecutor(8) as pool:
            runs = list(pool.map(lambda _: world.helper("list", "--outputs", "-", stdin="[]"), range(8)))
        self.assertEqual([status for status, _, _ in runs], [0] * 8)
        cache = world.run_dir / "vgs/displays"
        self.assertEqual(os.listdir(cache), ["ddc-detect.json"])
        self.assertEqual(len(json.loads((cache / "ddc-detect.json").read_text())["displays"]), 3)


class Access(Case):
    def test_access_states(self):
        rows = (
            ("ready", {}, {"state": "ready"}, ["ready", "unsupported", "unsupported"]),
            ("ddcutil missing", {"stand_in": False}, {"state": "missing"}, []),
            ("i2c-dev not loaded", {"module": False}, {"state": "module-not-loaded"}, []),
            ("nodes present, none RW", {"mode": 0o400}, {"state": "no-access"}, []),
        )
        for name, change, backend, states in rows:
            with self.subTest(case=name):
                world = self.world()
                world.ddc(mode=change.get("mode", 0o600), module=change.get("module", True))
                if change.get("stand_in") is False:
                    (world.bin / "ddcutil").unlink()
                world.start()
                answer = world.listing()
                self.assertEqual(answer["backends"]["ddc"], backend)
                self.assertEqual([d["state"] for d in answer["displays"]], states)
                if backend["state"] != "ready":
                    self.assertEqual(world.calls("ddcutil"), [])
                    self.assertEqual(world.set("ddc:DP-1", 10)[1], {"error": "state", "state": backend["state"], "id": "ddc:DP-1"})

    def test_hidraw_read_write_access(self):
        world = self.world()
        world.hidraw("hidraw0", XDR, "S1", raw=25000, usb="1-2")
        world.start()
        (world.dev / "hidraw0").chmod(0o444)
        shown = self.only(world.listing(), "hidraw")
        self.assertEqual((shown["state"], shown["percent"]), ("no-access", None))
        self.assertEqual(world.requests(), [])
        self.assertEqual(world.set(shown["id"], 50), (1, {"error": "state", "state": "no-access", "id": shown["id"]}))
        (world.dev / "hidraw0").chmod(0o644)
        self.assertEqual(self.only(world.listing(), "hidraw")["state"], "ready")


class Seam(Case):
    def test_no_real_node_opens(self):
        world = self.world()
        world.hidraw("hidraw0", XDR, "S1", raw=25000, usb="1-2")
        world.ddc()
        world.reply("ddcutil", ["--bus", "5", "setvcp", "10", "40"], "")
        world.start()
        status, _, audit = world.helper("list", "--outputs", "-", stdin="[]")
        self.assertEqual(status, 0)
        self.assertIn(f"audit: node={world.dev}/hidraw0", audit)
        self.assertEqual(world.set("ddc:DP-1", 50)[0], 0)

    def test_fake_needs_both_roots(self):
        world = self.world()
        # A name no host holds, so even a broken guard opens nothing real.
        world.hidraw("hidraw917", XDR, "S1", raw=25000, usb="1-2")
        world.start()
        for missing in ("VGS_DEV_ROOT", "VGS_SYSFS_ROOT"):
            with self.subTest(missing=missing):
                status, answer, audit = world.helper("list", "--outputs", "-", stdin="[]", **{missing: None})
                self.assertEqual((status, answer["error"]), (1, "seam-incomplete"))
                self.assertEqual(audit, [])

    def test_audit_hook_refuses(self):
        world = self.world()
        rows = (("an open outside the roots", "open('/proc/self/stat').close()", "open=/proc/self/stat"),
                ("a subprocess outside the stand-ins", "import subprocess; subprocess.run(['/usr/bin/true'])",
                 "exec=/usr/bin/true"),
                ("os.system", "import os; os.system('/usr/bin/true')", "os.system"),
                ("os.posix_spawn", "import os; os.posix_spawn('/usr/bin/true', ['true'], {})", "exec=/usr/bin/true"),
                ("os.execv", "import os; os.execv('/usr/bin/true', ['true'])", "exec=/usr/bin/true"),
                ("os.spawnv", "import os; os.spawnv(os.P_WAIT, '/usr/bin/true', ['true'])", "os.fork"),
                ("os.fork", "import os; os.fork()", "os.fork"))
        for name, code, refusal in rows:
            with self.subTest(case=name):
                script = world.root / "probe.py"
                script.write_text(code + "\nprint('{}')\n")
                with self.assertRaisesRegex(AssertionError, "reached outside the fakes: audit: refused " + refusal):
                    world.helper(script=script)


class Usage(Case):
    def test_usage_errors(self):
        world = self.world()
        world.start()
        rows = (
            (["set", "hidraw:x", "abc"], 2, "usage"),
            (["set", "hidraw:x"], 2, "usage"),
            (["list"], 2, "usage"),
            (["list", "--outputs", "-"], 2, "outputs"),
            (["set", "hidraw:x", "50"], 1, "unknown-id"),
            (["set", "nothing", "50"], 1, "unknown-id"),
            (["set", "ddc:", "50"], 1, "unknown-id"),
        )
        for argv, status, key in rows:
            with self.subTest(argv=argv):
                got, answer, _ = world.helper(*argv, stdin='{"name": "DP-1"}')
                self.assertEqual((got, answer["error"]), (status, key))


class Controls(unittest.TestCase):
    """One defect per rule, planted in a mirror tree's copy of the helper."""

    PLANTS = (
        ("big-endian encoder", 'raw.to_bytes(4, "little")', 'raw.to_bytes(4, "big")', "Hid.test_bytes_and_ioctl_numbers"),
        ("wrong write ioctl", "HIDIOCSFEATURE = ioc_read_write(0x06, REPORT_LEN)",
         "HIDIOCSFEATURE = ioc_read_write(0x07, REPORT_LEN)", "Hid.test_bytes_and_ioctl_numbers"),
        ("product plus serial grouping", "key = (iface.parent, iface.serial)", "key = (iface.product, iface.serial)",
         "Hid.test_units_stay_distinct_by_usb_parent"),
        ("hardcoded interface", "for iface in group]", "for iface in group[:1]]",
         "Hid.test_probing_finds_the_answering_interface"),
        ("probe ceiling", "raw <= PROBE_CEILING", "raw <= PROBE_CEILING + 1", "Hid.test_probe_accepts_only_in_range_answers"),
        ("short report accepted", "result < 5 or ", "", "Hid.test_probe_accepts_only_in_range_answers"),
        ("other report id accepted", "report[0] != REPORT_ID or ", "", "Hid.test_probe_accepts_only_in_range_answers"),
        ("every probe errno a miss", "if error.errno in PROBE_MISSES:", "if True:", "Hid.test_probe_error_is_the_interface_only"),
        ("a probe errno fails the run", '            return Unavailable("no-answer")\n        return Unavailable("error", errno_detail(iface.name, error))',
         '            return Unavailable("no-answer")\n        raise', "Hid.test_probe_error_is_the_interface_only"),
        ("descriptor ignored", "preferred = [pair for pair in answered if declares_brightness(pair[0].descriptor)]",
         "preferred = []", "Hid.test_descriptor_preference"),
        ("asdcontrol's usage code", "BRIGHTNESS_USAGE = (0x82, 0x0010)", "BRIGHTNESS_USAGE = (0x82, 0x0001)",
         "Hid.test_descriptor_preference"),
        ("one output per monitor", 'key = (o.get("make"), o.get("model"), o["serial"]) if o.get("serial") else (o["name"],)',
         'key = (o["name"],)', "Hid.test_output_mapping"),
        ("ioctl given an immutable buffer", "result = fcntl.ioctl(fd, request, buffer, True)",
         "result = fcntl.ioctl(fd, request, bytes(buffer))", "InProcess.test_real_ioctl_call"),
        ("ioctl answer dropped", "return result, bytes(buffer)", "return result, bytes(report)", "InProcess.test_real_ioctl_call"),
        ("short write accepted", "if result != REPORT_LEN:", "if False:", "InProcess.test_short_write_fails"),
        ("shared cache temporary name", 'fd, temp = tempfile.mkstemp(dir=directory, prefix=".ddc-detect.", suffix=".json")',
         'temp = cache + ".next"; fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)',
         "InProcess.test_cache_temporary_files_are_unique"),
        ("cache ignores hotplug", 'held["key"] == key and', "True and", "Ddc.test_detect_cache_and_hotplug"),
        ("cache ignores age", "0 <= now - held[\"at\"] < DDC_CACHE_SECONDS", "True", "Ddc.test_detect_cache_and_hotplug"),
        ("cache write failure fails the run", "    except OSError:\n        return\n", "    except ZeroDivisionError:\n        return\n",
         "Ddc.test_cache_is_best_effort"),
        ("invalid displays dropped", '(re.compile(r"^Invalid display$"), False)', '(re.compile(r"^Invalid display$"), None)',
         "Ddc.test_detect_getvcp_and_set"),
        ("laptop panel listed", "any(DDC_LAPTOP in r for r in reasons)", "False", "Ddc.test_detect_getvcp_and_set"),
        ("Apple block listed twice", 'if found["mfg"] == APPLE_EDID_MANUFACTURER and found["model"] in apple_models:',
         "if False:", "Ddc.test_apple_blocks_left_to_hid"),
        ("set judges state its own way", "    state, reading, _ = ddc_display_state(ddcutil, roots, found)",
         '    state, reading, _ = "ready", parse_getvcp(run([ddcutil, "--bus", str(found["bus"]), "getvcp", "10", "--brief"])), None',
         "Ddc.test_set_judges_state_as_list_does"),
        ("backlight failure fails the run",
         '    except Failure as failure:\n        return {"state": "error", "detail": failure.fields}, []\n    return {"state": "ready"}, found',
         '    except ZeroDivisionError as failure:\n        return {"state": "error", "detail": failure.fields}, []\n    return {"state": "ready"}, found',
         "Backlights.test_failure_keeps_other_backends"),
        ("seam without roots", "if fake and not (", "if False and not (", "Seam.test_fake_needs_both_roots"),
        ("kernel backlight ignored", "if kernel is not None:", "if False:", "Backlights.test_kernel_backlight_preferred_over_hidraw"),
    )

    def mirror(self, scratch, helper_text):
        root = Path(scratch)
        for rel in ("scripts/smoke/fixtures/devices/hid-fake.py", "scripts/smoke/fixtures/devices/stand-in.py",
                    "scripts/smoke/fixtures/devices/hid-world.json"):
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / rel, root / rel)
        shutil.copy(Path(__file__), root / "scripts/test-displays-brightness.py")
        copy = root / "shell/plugins/vgs.displays/helper/brightness.py"
        copy.parent.mkdir(parents=True, exist_ok=True)
        copy.write_text(helper_text)
        return root

    def run_tests(self, root, tests):
        return subprocess.run([sys.executable, "-B", str(root / "scripts/test-displays-brightness.py"), *tests],
                              env={"PATH": "/usr/bin:/bin", "HOME": str(root), "LC_ALL": "C"},
                              text=True, capture_output=True, check=False)

    def test_mirror_passes_unplanted(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = self.mirror(scratch, HELPER.read_text())
            result = self.run_tests(root, sorted({plant[3] for plant in self.PLANTS}))
            self.assertEqual(result.returncode, 0, result.stderr[-3000:])

    def test_each_plant_turns_its_test_red(self):
        source = HELPER.read_text()
        for name, old, new, test in self.PLANTS:
            with self.subTest(plant=name), tempfile.TemporaryDirectory() as scratch:
                self.assertEqual(source.count(old), 1, name)
                changed = source.replace(old, new)
                self.assertNotEqual(changed, source)
                result = self.run_tests(self.mirror(scratch, changed), [test])
                self.assertNotEqual(result.returncode, 0, f"{name} left {test} green")
                self.assertIn("FAILED", result.stderr, result.stderr[-2000:])


if __name__ == "__main__":
    if os.geteuid() == 0:
        print("test-displays-brightness: refused=root\nfile modes cannot deny root, so the access rows cannot fail")
        sys.exit(1)
    unittest.main()
