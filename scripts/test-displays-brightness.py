#!/usr/bin/env python3
"""Run the vgs.displays brightness helper end to end against device fakes.

Every run goes through scripts/smoke/fixtures/devices/hid-fake.py for the
HID feature reports, stand-in.py for ddcutil and brightnessctl (the only
commands on the helper's PATH), and temporary sysfs, /dev, HOME and
XDG_RUNTIME_DIR trees. An audit hook installed before the helper starts
exits 97 on any open outside those trees and Python's own library, and on
any process start outside the stand-ins, so no row reaches a real device
or the host's commands. Expected bytes, ioctl numbers and argv are written
out by hand, never computed by the helper's own code. The controls plant
one defect per rule in a copy of the helper and run the named tests
against it.
"""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import sysconfig
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parent
REPO = SCRIPTS.parent
HELPER = REPO / "shell/plugins/vgs.displays/helper/brightness.py"
DEVICES = SCRIPTS / "smoke/fixtures/devices"
HID_FAKE = DEVICES / "hid-fake.py"
STAND_IN = DEVICES / "stand-in.py"
S08_WORLD = DEVICES / "hid-world.json"

GET_FEATURE_7 = 0xC0074807
SET_FEATURE_7 = 0xC0074806
XDR, STUDIO = "9243", "1114"
AUDIT_EXIT = 97

# Installed before the helper runs: any open outside the allowed roots and
# any process start outside the stand-in directory exits AUDIT_EXIT before
# the call happens. Opens under the device root print `audit: node=PATH`.
AUDIT = r"""
import json, os, runpy, sys
allowed, dev_root, stand_ins = json.loads(sys.argv[1])
def inside(path, roots):
    return any(path == r or path.startswith(r.rstrip("/") + "/") for r in roots)
def hook(event, args):
    if event == "open" and not isinstance(args[0], int):
        path = os.path.abspath(os.fsdecode(args[0]))
        if not inside(path, allowed):
            sys.stderr.write("audit: refused open=" + path + "\n"); sys.stderr.flush(); os._exit(97)
        if inside(path, [dev_root]):
            sys.stderr.write("audit: node=" + path + "\n")
    elif event == "subprocess.Popen":
        program = os.path.abspath(os.fsdecode(list(args[1])[0]))
        if not inside(program, [stand_ins]):
            sys.stderr.write("audit: refused exec=" + program + "\n"); sys.stderr.flush(); os._exit(97)
sys.argv = sys.argv[2:]
sys.addaudithook(hook)
runpy.run_path(sys.argv[0], run_name="__main__")
"""

DETECT = """Display 1
   I2C bus:  /dev/i2c-5
   DRM connector:           card1-DP-1
   EDID synopsis:
      Mfg id:               DEL - Dell Inc.
      Model:                DELL U2720Q
      Serial number:        ABC123
   VCP version:         2.1

Display 2
   I2C bus:  /dev/i2c-6
   DRM_connector:           card1-DP-2
   EDID synopsis:
      Model:                ACME 27
   This monitor does not support DDC/CI.

Invalid display
   I2C bus:  /dev/i2c-7
   DRM connector:           card1-eDP-1
   DDC communication failed
"""


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

    def hidraw(self, name, product, serial, raw=None, usb=None, interface=0, descriptor=None):
        """One hidraw interface; with USB a port, linked under that USB device
        as the kernel does; without, planted by the fake alone. RAW None is an
        interface without report 1."""
        if usb is not None:
            hid = self.usb(usb, product, serial) / f"{usb}:1.{interface}" / f"0003:05AC:{product.upper()}.{len(self.devices) + 1:04X}"
            (hid / "hidraw" / name).mkdir(parents=True)
            (hid / "hidraw" / name / "device").symlink_to("../..")
            (self.sys / "class/hidraw").mkdir(parents=True, exist_ok=True)
            (self.sys / "class/hidraw" / name).symlink_to(os.path.relpath(hid / "hidraw" / name, self.sys / "class/hidraw"))
        device = {"name": name, "vendor": "05ac", "product": product, "hidName": "Apple display", "serial": serial,
                  "reports": {} if raw is None else {"1": report(raw)}}
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
    def ddc(self, buses=(5, 6, 7), mode=0o600, module=True):
        if module:
            (self.sys / "module/i2c_dev").mkdir(parents=True, exist_ok=True)
        for bus in buses:
            node = self.dev / f"i2c-{bus}"
            node.write_text("")
            node.chmod(mode)
            (self.sys / "class/i2c-dev" / f"i2c-{bus}").mkdir(parents=True, exist_ok=True)
        for connector in ("card1-DP-1", "card1-DP-2"):
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
        rows = ((XDR, 60000, "ready", 100), (XDR, 60001, "no-answer", None), (STUDIO, 60001, "no-answer", None),
                (STUDIO, 60000, "ready", 100), (XDR, 200, "ready", 0), (XDR, 199, "no-answer", None),
                (XDR, 25000, "ready", 50))
        for product, raw, state, percent in rows:
            with self.subTest(product=product, raw=raw):
                world = self.world()
                world.hidraw("hidraw0", product, "S1", raw=raw, usb="1-2")
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

    def test_descriptor_preference(self):
        rows = (
            ("short usage page and usage", "05820901a101", True),
            ("extended usage", "0b01008200a101", True),
            ("another usage on the page", "05820910a101", False),
            ("the usage on another page", "05800901a101", False),
            ("a long item before the usage", "fe0200aabb05820901", True),
        )
        for name, descriptor, preferred in rows:
            with self.subTest(descriptor=name):
                world = self.world()
                world.hidraw("hidraw0", XDR, "S1", raw=12800, usb="1-2", interface=0, descriptor="05010906a101")
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
        world = self.world()
        world.start(S08_WORLD)
        shown = self.only(world.listing(), "hidraw")
        self.assertEqual(shown, {"id": "hidraw:class/hidraw/hidraw0/device", "backend": "hidraw",
                                 "label": "Apple Pro Display XDR", "state": "ready", "percent": 50, "output": None,
                                 "product": XDR, "identity": {"parent": "class/hidraw/hidraw0/device",
                                                              "serial": "VGSSMOKEXDR01"}})
        self.assertEqual(world.set(shown["id"], 50), (0, {"id": shown["id"], "percent": 50}))
        self.assertEqual(world.stored("hidraw0"), "01706200000000")

    def test_output_mapping(self):
        xdr1 = {"name": "DP-1", "model": "ProDisplayXDR", "serial": "S1"}
        xdr2 = {"name": "DP-2", "model": "ProDisplayXDR", "serial": "OTHER"}
        studio = {"name": "DP-3", "model": "StudioDisplay", "serial": ""}
        rows = (
            ("serial match", [("S1", "1-2")], [xdr2, xdr1], ["DP-1"]),
            ("unique model", [("", "1-2")], [xdr1, studio], ["DP-1"]),
            ("two outputs of the model", [("", "1-2")], [xdr1, xdr2], [None]),
            ("two units of the product", [("", "1-2"), ("", "1-3")], [xdr1], [None, None]),
            ("serial beats model", [("S1", "1-2"), ("", "1-3")], [xdr1], ["DP-1", None]),
            ("no outputs", [("S1", "1-2")], [], [None]),
            ("another model", [("", "1-2")], [studio], [None]),
        )
        for name, units, outputs, expected in rows:
            with self.subTest(case=name):
                world = self.world()
                for index, (serial, port) in enumerate(units):
                    world.hidraw(f"hidraw{index}", XDR, serial, raw=25000, usb=port)
                world.start()
                self.assertEqual([d["output"] for d in world.listing(outputs)["displays"]], expected)

    def test_outputs_from_stdin(self):
        world = self.world()
        world.hidraw("hidraw0", XDR, "S1", raw=25000, usb="1-2")
        world.start()
        status, answer, _ = world.helper("list", "--outputs", "-", stdin=json.dumps([{"name": "DP-9", "serial": "S1"}]))
        self.assertEqual((status, answer["displays"][0]["output"]), (0, "DP-9"))


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
            "state": "ready", "percent": 30, "output": "DP-1", "product": XDR,
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
             {"intel_backlight": "eDP-1", "acpi_video0": "eDP-2"}),
            ("the one panel is claimed", [{"name": "eDP-1"}, {"name": "DP-1"}], {"intel_backlight": "eDP-1", "acpi_video0": None}),
            ("lone internal panel", [{"name": "eDP-2"}], {"intel_backlight": None, "acpi_video0": None}),
            ("no outputs", [], {"intel_backlight": None, "acpi_video0": None}),
        )
        for name, outputs, expected in rows:
            with self.subTest(case=name):
                answer = world.listing(outputs)
                self.assertEqual(answer["backends"]["backlight"], {"state": "ready"})
                self.assertEqual({d["id"].split(":", 1)[1]: d["output"] for d in answer["displays"]}, expected)
                self.assertEqual({d["id"]: d["percent"] for d in answer["displays"]},
                                 {"backlight:intel_backlight": 50, "backlight:acpi_video0": 70})
        world.reply("brightnessctl", ["-l", "-m", "-c", "backlight"], "intel_backlight,backlight,12000,50%,24000\n")
        (world.sys / "class/backlight/acpi_video0").unlink()
        self.assertEqual(world.listing([{"name": "eDP-2"}])["displays"][0]["output"], "eDP-2")
        self.assertEqual(world.set("backlight:intel_backlight", 70), (0, {"id": "backlight:intel_backlight", "percent": 70}))
        self.assertEqual(world.calls("brightnessctl")[-1], ["-d", "intel_backlight", "set", "70%"])

    def test_refusals(self):
        world = self.world()
        world.backlight("intel_backlight", "devices/pci0000:00/0000:00:02.0/drm/card1/card1-eDP-1")
        world.start()
        self.assertEqual(world.listing()["backends"]["backlight"], {"state": "missing"})
        world.stand_in("brightnessctl")
        world.reply("brightnessctl", ["-l", "-m", "-c", "backlight"], "intel_backlight backlight 50%\n")
        status, answer, _ = world.helper("list", "--outputs", "-", stdin="[]")
        self.assertEqual((status, answer["error"]), (1, "brightnessctl-unparsed"))
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
        self.assertEqual([d for d in answer["displays"] if d["backend"] == "ddc"], [
            {"id": "ddc:DP-1", "backend": "ddc", "label": "DELL U2720Q", "state": "ready", "percent": 75, "output": "DP-1"},
            {"id": "ddc:DP-2", "backend": "ddc", "label": "ACME 27", "state": "unsupported", "percent": None, "output": None},
        ])
        self.assertEqual(world.set("ddc:DP-1", 40), (0, {"id": "ddc:DP-1", "percent": 40}))
        self.assertEqual(world.calls("ddcutil"), [
            ["detect"], ["--bus", "5", "getvcp", "10", "--brief"], ["--bus", "5", "getvcp", "10", "--brief"],
            ["--bus", "5", "setvcp", "10", "32"]])
        self.assertEqual(world.set("ddc:DP-9", 40)[1]["error"], "unknown-id")
        world.reply("ddcutil", ["--bus", "5", "getvcp", "10", "--brief"], "", status=1)
        self.assertEqual([d["state"] for d in world.listing()["displays"]], ["no-answer", "unsupported"])
        world.reply("ddcutil", ["detect"], "", status=1)
        (world.run_dir / "vgs/displays/ddc-detect.json").unlink()
        self.assertEqual(world.listing()["backends"]["ddc"]["state"], "error")

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
            ("29 s old is reused", lambda: age(29), 0),
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


class Access(Case):
    def test_access_states(self):
        rows = (
            ("ready", {}, {"state": "ready"}, ["ready", "unsupported"]),
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
        world = self.world()
        world.ddc()
        (world.dev / "i2c-5").chmod(0o400)
        world.start()
        self.assertEqual([d["state"] for d in world.listing()["displays"]], ["no-access", "unsupported"])

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
        rows = (("an open outside the roots", "open('/proc/self/stat').close()"),
                ("a command outside the stand-ins", "import subprocess; subprocess.run(['/usr/bin/true'])"))
        for name, code in rows:
            with self.subTest(case=name):
                script = world.root / "probe.py"
                script.write_text(code + "\nprint('{}')\n")
                with self.assertRaisesRegex(AssertionError, "reached outside the fakes"):
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
        ("descriptor ignored", "preferred = [pair for pair in answered if declares_brightness(pair[0].descriptor)]",
         "preferred = []", "Hid.test_descriptor_preference"),
        ("cache ignores hotplug", 'held["key"] == key and', "True and", "Ddc.test_detect_cache_and_hotplug"),
        ("cache ignores age", "0 <= now - held[\"at\"] < DDC_CACHE_SECONDS", "True", "Ddc.test_detect_cache_and_hotplug"),
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
        helper = root / "shell/plugins/vgs.displays/helper/brightness.py"
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_text(helper_text)
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
