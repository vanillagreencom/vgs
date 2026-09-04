#!/usr/bin/env python3
"""Unit tests for `vshell brightness` backend selection, device identity, udev
rule generation, and the Apple/DDC/EDID parsers in bin/vshell-helper.

These are pure-logic tests -- no hardware, no root, no external tools. Run:

    scripts/check-brightness.py
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def _load_helper():
    path = REPO / "bin" / "vshell-helper"
    loader = importlib.machinery.SourceFileLoader("vshell_helper", str(path))
    spec = importlib.util.spec_from_loader("vshell_helper", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


H = _load_helper()

_failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        _failures.append(msg)
        print(f"  FAIL: {msg}")
    else:
        print(f"  ok: {msg}")



def test_udev_generation() -> None:
    print("udev rule generation:")
    text = H._apple_udev_rules_text()
    shipped_path = REPO / "config" / "vshell" / "udev" / "60-vshell-apple-displays.rules"
    check(shipped_path.exists(), "shipped rule file exists")
    if shipped_path.exists():
        check(
            shipped_path.read_text() == text,
            "shipped rule matches generator (run `vshell brightness install-udev --print > ...` to refresh)",
        )
    for product, spec in H.APPLE_DISPLAYS.items():
        check(f'ATTRS{{idProduct}}=="{product}"' in text, f"rule targets product {product}")
    rule_lines = [ln for ln in text.splitlines() if ln.startswith("SUBSYSTEM==")]
    check(all("DEVPATH==" not in ln for ln in rule_lines), "no DEVPATH / interface-path pinning on rules")
    check(":1.2/" not in text and ":1.7/" not in text, "no hardcoded interface numbers")
    uaccess_rules = sum(1 for ln in rule_lines if 'TAG+="uaccess"' in ln)
    check(uaccess_rules == 2 * len(H.APPLE_DISPLAYS), "uaccess tag on hiddev + hidraw per display")
    check("SUBSYSTEM==\"hidraw\"" in text, "covers hidraw subsystem (works without CONFIG_USB_HIDDEV)")
    # No trailing inline comments on rule lines (udev rejects them).
    for line in text.splitlines():
        if line.startswith("SUBSYSTEM=="):
            check(line.rstrip().endswith('"'), f"rule line has no trailing comment: {line[:40]}...")



def test_backend_selection() -> None:
    print("backend selection + dedup:")
    check(H._BACKEND_PRIORITY["backlight"] < H._BACKEND_PRIORITY["ddc"] < H._BACKEND_PRIORITY["apple"],
          "priority order backlight < ddc < apple")

    devs = [
        {"id": "apple-studio", "class": "apple", "serial": "SN-XYZ", "currentPercent": 50},
        {"id": "intel_backlight", "class": "backlight", "serial": "SN-XYZ", "currentPercent": 60},
    ]
    out = H._dedup_devices(devs)
    check(len(out) == 1, "same-serial duplicate collapsed to one device")
    check(out and out[0]["class"] == "backlight", "kept the higher-priority backlight backend")

    out2 = H._dedup_devices([
        {"id": "apple-studio", "class": "apple", "serial": "SAME", "currentPercent": 1},
        {"id": "ddc-x", "class": "ddc", "serial": "SAME", "currentPercent": 2},
    ])
    check(len(out2) == 1 and out2[0]["class"] == "ddc", "ddc wins over apple for same serial")

    out3 = H._dedup_devices([
        {"id": "a", "class": "apple", "serial": "S1"},
        {"id": "b", "class": "ddc", "serial": "S2"},
        {"id": "c", "class": "backlight", "serial": ""},
        {"id": "d", "class": "apple", "serial": ""},
    ])
    check(len(out3) == 4, "distinct/serial-less devices all preserved")



def test_target_resolution() -> None:
    print("target resolution:")
    devices = [
        {"id": "intel_backlight", "name": "intel_backlight", "class": "backlight",
         "connector": "eDP-1", "monitorName": "", "label": "Intel Backlight",
         "available": True, "role": "", "product": None},
        {"id": "apple-studio", "name": "apple-studio", "class": "apple", "product": "1114",
         "connector": "DP-2", "monitorName": "Apple Studio Display", "label": "Apple Studio Display",
         "available": True, "role": "primary"},
        {"id": "ddc-del-u2720q-abc", "name": "ddc-del-u2720q-abc", "class": "ddc", "product": None,
         "connector": "DP-1", "monitorName": "DELL U2720Q", "label": "DELL U2720Q",
         "available": True, "role": ""},
    ]

    def rid(target):
        r = H._resolve_targets(target, devices)
        return [d["id"] for d in r]

    check(rid("apple-studio") == ["apple-studio"], "resolve by stable id")
    check(rid("apple-xdr") == [], "unknown alias with no matching device -> empty")
    check(rid("DP-1") == ["ddc-del-u2720q-abc"], "resolve by connector name")
    check(rid("primary") == ["apple-studio"], "resolve role 'primary'")
    check(rid("") == ["apple-studio"], "empty target -> primary display")
    check(rid("dell") == ["ddc-del-u2720q-abc"], "resolve by monitor-name substring")
    check(set(rid("all")) == {"intel_backlight", "apple-studio", "ddc-del-u2720q-abc"}, "'all' targets every device")

    devices2 = [{"id": "apple-studio-3685802e", "name": "apple-studio-3685802e", "class": "apple",
                 "product": "1114", "connector": "", "monitorName": "Apple Studio Display",
                 "label": "Apple Studio Display", "available": True, "role": "primary"}]
    check([d["id"] for d in H._resolve_targets("apple-studio", devices2)] == ["apple-studio-3685802e"],
          "legacy alias apple-studio maps to product 1114 device")


def test_primary_connector() -> None:
    print("primary connector:")
    original_exists = H.command_exists
    original_run = H.run
    original_socket = os.environ.get("NIRI_SOCKET")
    os.environ["NIRI_SOCKET"] = "/run/user/1000/niri.wayland-1.sock"
    H.command_exists = lambda command: command == "niri"
    H.run = lambda argv, **_kwargs: H.subprocess.CompletedProcess(
        argv, 0, '{"name":"DP-3"}\n' if argv[-1] == "focused-output" else "{}\n", ""
    )
    try:
        check(H._primary_connector() == "DP-3", "Niri focused output is primary")
    finally:
        H.command_exists = original_exists
        H.run = original_run
        if original_socket is None:
            os.environ.pop("NIRI_SOCKET", None)
        else:
            os.environ["NIRI_SOCKET"] = original_socket

    os.environ["NIRI_SOCKET"] = "/run/user/1000/stale-niri.sock"
    H.command_exists = lambda command: command in {"niri", "hyprctl"}
    def stale_niri_run(argv, **_kwargs):
        if argv[0] == "niri":
            return H.subprocess.CompletedProcess(argv, 1, "", "stale socket")
        return H.subprocess.CompletedProcess(
            argv, 0, '[{"name":"DP-1","focused":true,"x":0,"y":0}]\n', ""
        )
    H.run = stale_niri_run
    try:
        check(H._primary_connector() == "DP-1", "stale Niri socket falls back to Hyprland")
    finally:
        H.command_exists = original_exists
        H.run = original_run
        if original_socket is None:
            os.environ.pop("NIRI_SOCKET", None)
        else:
            os.environ["NIRI_SOCKET"] = original_socket



def test_apple_codec() -> None:
    print("apple HID codec + range:")
    for raw in (400, 30200, 60000):
        buf = H._apple_encode(raw)
        check(len(buf) == H.APPLE_REPORT_LEN and buf[0] == H.APPLE_REPORT_ID, f"encode {raw} shape")
        check(H._apple_decode(buf) == raw, f"decode round-trips {raw}")
    # Studio feature report: 01 60 ea 00 00 00 00 encodes 60000.
    check(H._apple_decode(bytes.fromhex("0160ea00000000")) == 60000, "decodes real Studio report 0x60ea -> 60000")
    # Per-display descriptor maxima (centi-nits): XDR 500.00, Studio 600.00.
    check(H.APPLE_DISPLAYS["9243"]["max"] == 50000, "XDR descriptor max 50000")
    check(H.APPLE_DISPLAYS["1114"]["max"] == 60000, "Studio descriptor max 60000")
    spec = H.APPLE_DISPLAYS["1114"]
    check(H._apple_raw_in_range(60000, spec), "60000 in range")
    check(H._apple_raw_in_range(400, spec), "400 in range")
    check(not H._apple_raw_in_range(138240, spec), "138240 (wrong interface) rejected")
    # An XDR with a stored value above its display maximum must remain detectable.
    xdr_spec = H.APPLE_DISPLAYS["9243"]
    check(H._apple_raw_in_range(60000, xdr_spec), "XDR tolerates stored 60000 on probe")
    check(not H._apple_raw_in_range(138240, xdr_spec), "XDR still rejects wrong-interface value")
    check(H._raw_from_percent(100, 400, 60000) == 60000, "100% -> raw max")
    check(H._raw_from_percent(0, 400, 60000) == 400, "0% -> raw min")
    check(H._percent_from_raw(60000, 400, 60000) == 100, "raw max -> 100%")
    check(H._raw_from_percent(100, 400, 50000) == 50000, "XDR 100% -> raw 50000")
    check(H._percent_from_raw(60000, 400, 50000) == 100, "overdriven raw clamps to 100%")



DDC_DETECT_SAMPLE = """Display 1
   I2C bus:  /dev/i2c-5
   DRM connector:           card1-DP-1
   EDID synopsis:
      Mfg id:               DEL  (Dell Inc.)
      Model:                DELL U2720Q
      Product code:         16725  (0x4155)
      Serial number:        ABC123
   VCP version:         2.1

Invalid display
   I2C bus:  /dev/i2c-7
   EDID synopsis:
      Mfg id:               BNQ
      Model:                BenQ GW2480
   DDC communication failed
"""


def test_ddc_parsers() -> None:
    print("ddc parsers:")
    displays = H._parse_ddc_detect(DDC_DETECT_SAMPLE)
    check(len(displays) == 2, "parsed two display blocks")
    d0 = displays[0]
    check(d0["bus"] == 5, "bus parsed from /dev/i2c-5")
    check(d0["connector"] == "DP-1", "connector stripped of cardN- prefix")
    check(d0["mfg"] == "DEL", "mfg id first token")
    check(d0["model"] == "DELL U2720Q", "model parsed")
    check(d0["serial"] == "ABC123", "serial parsed")
    check(d0["product_code"] == "16725", "product code first token")
    check(not d0["invalid"], "first display valid")
    check(displays[1]["invalid"], "second display flagged invalid")
    check(H._ddc_stable_id(d0) == "ddc-del-dell-u2720q-abc123", "stable id from mfg+model+serial")

    # Two identical serial-less monitors must get distinct ids (QML keys by id).
    a = {"mfg": "ACM", "model": "Foo 27", "serial": "", "connector": "DP-1", "bus": 4}
    b = {"mfg": "ACM", "model": "Foo 27", "serial": "", "connector": "DP-2", "bus": 5}
    check(H._ddc_stable_id(a) != H._ddc_stable_id(b), "serial-less identical models get distinct ids")
    check(H._ddc_stable_id(a) == "ddc-acm-foo-27-dp-1", "serial-less id disambiguated by connector")

    check(H._parse_ddc_getvcp("VCP 10 C 75 100") == (75, 100), "getvcp --brief parse")
    check(H._parse_ddc_getvcp("VCP code 0x10 (Brightness): current value = 42, max value = 100") == (42, 100),
          "getvcp verbose parse")
    check(H._parse_ddc_getvcp("no vcp here") is None, "unparseable getvcp -> None")



def _build_edid(mfg: str, product: int, serial_num: int, name: str, serial_str: str) -> bytes:
    data = bytearray(128)
    data[0:8] = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    val = ((ord(mfg[0]) - ord("A") + 1) << 10) | ((ord(mfg[1]) - ord("A") + 1) << 5) | (ord(mfg[2]) - ord("A") + 1)
    data[8] = (val >> 8) & 0xFF
    data[9] = val & 0xFF
    data[10] = product & 0xFF
    data[11] = (product >> 8) & 0xFF
    data[12] = serial_num & 0xFF
    data[13] = (serial_num >> 8) & 0xFF
    data[14] = (serial_num >> 16) & 0xFF
    data[15] = (serial_num >> 24) & 0xFF

    def descriptor(tag: int, text: str) -> bytes:
        block = bytearray(18)
        block[3] = tag
        payload = text.encode("ascii")[:13]
        block[5:5 + len(payload)] = payload
        if len(payload) < 13:
            block[5 + len(payload)] = 0x0A
        return bytes(block)

    data[54:72] = descriptor(0xFC, name)
    data[72:90] = descriptor(0xFF, serial_str)
    return bytes(data)


def test_edid_parser() -> None:
    print("edid parser:")
    # EDID text descriptors hold at most 13 ASCII chars.
    edid = _build_edid("APP", 0x9243, 0x01020304, "Pro Disp XDR", "C02XYZ")
    parsed = H._parse_edid(edid)
    check(parsed.get("mfg") == "APP", "Apple mfg id decoded")
    check(parsed.get("product") == 0x9243, "product code decoded")
    check(parsed.get("name") == "Pro Disp XDR", "monitor name descriptor decoded")
    check(parsed.get("serial") == "C02XYZ", "serial descriptor decoded")
    check(H._parse_edid(b"") == {}, "empty EDID -> empty dict")

    edid2 = _build_edid("DEL", 0x4155, 0, "DELL U2720Q", "")
    check(H._parse_edid(edid2).get("mfg") == "DEL", "Dell mfg id decoded")


def main() -> int:
    for test in (
        test_udev_generation,
        test_backend_selection,
        test_target_resolution,
        test_primary_connector,
        test_apple_codec,
        test_ddc_parsers,
        test_edid_parser,
    ):
        test()
    print()
    if _failures:
        print(f"FAILED: {len(_failures)} check(s)")
        for f in _failures:
            print(f"  - {f}")
        return 1
    print("all brightness checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
