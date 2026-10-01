#!/usr/bin/env python3
"""The smoke sandbox's HID feature-report fake, the brightness helper's ioctl seam.

Usage: hid-fake.py SOCKET WORLD DEV_ROOT SYSFS_ROOT LOG

A FIFO cannot answer HIDIOCGFEATURE, so a helper that finds VGS_HID_FAKE
in its environment sends each feature-report ioctl here in place of the
ioctl on /dev/hidrawN. WORLD is a JSON file, {"devices": [{"name":
"hidraw0", "vendor": "05ac", "product": "9243", "hidName", "serial",
"reports": {"1": HEX}, "descriptor": HEX (optional)}]}. At start this
plants, for each device, an empty DEV_ROOT/NAME and
SYSFS_ROOT/class/hidraw/NAME/device/uevent with the HID_ID, HID_NAME and
HID_UNIQ lines the kernel writes, plus report_descriptor when the world
gives one; it then listens on SOCKET and prints `hid-fake=listening`.

The protocol is one JSON object per line each way. A request is
{"device": NAME, "request": IOCTL, "data": HEX}, IOCTL the number the
helper would pass to ioctl(2) and HEX the buffer it would pass. The reply
is {"result": N, "data": HEX}, the ioctl's return value and the buffer
after it, or {"errno": E}:
- HIDIOCGFEATURE(len), _IOC(READ|WRITE, 'H', 0x07, len), answers the
  device's stored report whose id is data[0], cut or zero-padded to len,
  with result its stored length up to len; EIO for a report the device
  does not hold.
- HIDIOCSFEATURE(len), nr 0x06, stores data as the report data[0] names,
  with result len.
- ENOENT for a device the world does not hold, ENOTTY for any other
  ioctl, EINVAL when len differs from the buffer's length.
Every request and its reply is appended to LOG as one JSON line.
"""

import errno
import json
import os
import socketserver
import sys
import threading

IOC_READ_WRITE = 3
HID_TYPE = ord("H")
NR_GET_FEATURE = 0x07
NR_SET_FEATURE = 0x06


def plant(world, dev_root, sysfs_root):
    devices = {}
    for device in world["devices"]:
        name = device["name"]
        os.makedirs(dev_root, exist_ok=True)
        open(os.path.join(dev_root, name), "w").close()
        hid = os.path.join(sysfs_root, "class", "hidraw", name, "device")
        os.makedirs(hid, exist_ok=True)
        with open(os.path.join(hid, "uevent"), "w") as out:
            out.write(f"HID_ID=0003:0000{device['vendor'].upper()}:0000{device['product'].upper()}\n")
            out.write(f"HID_NAME={device['hidName']}\n")
            out.write(f"HID_UNIQ={device['serial']}\n")
        if "descriptor" in device:
            with open(os.path.join(hid, "report_descriptor"), "wb") as out:
                out.write(bytes.fromhex(device["descriptor"]))
        devices[name] = {int(k): bytes.fromhex(v) for k, v in device["reports"].items()}
    return devices


def answer(devices, request):
    if not isinstance(request, dict) or set(request) != {"device", "request", "data"} or not isinstance(request["request"], int):
        return {"errno": errno.EINVAL}
    device = devices.get(request["device"])
    if device is None:
        return {"errno": errno.ENOENT}
    try:
        code, data = request["request"], bytes.fromhex(request["data"])
    except (TypeError, ValueError):
        return {"errno": errno.EINVAL}
    direction, size, kind, nr = code >> 30, (code >> 16) & 0x3FFF, (code >> 8) & 0xFF, code & 0xFF
    if direction != IOC_READ_WRITE or kind != HID_TYPE or nr not in (NR_GET_FEATURE, NR_SET_FEATURE):
        return {"errno": errno.ENOTTY}
    if size != len(data) or size == 0:
        return {"errno": errno.EINVAL}
    if nr == NR_SET_FEATURE:
        device[data[0]] = data
        return {"result": size, "data": data.hex()}
    stored = device.get(data[0])
    if stored is None:
        return {"errno": errno.EIO}
    return {"result": min(len(stored), size), "data": stored[:size].ljust(size, b"\0").hex()}


def main():
    if len(sys.argv) != 6:
        print("hid-fake: usage=SOCKET WORLD DEV_ROOT SYSFS_ROOT LOG", file=sys.stderr)
        sys.exit(2)
    sock, world_path, dev_root, sysfs_root, log = sys.argv[1:]
    with open(world_path) as source:
        devices = plant(json.load(source), dev_root, sysfs_root)
    lock = threading.Lock()

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            for line in self.rfile:
                try:
                    request = json.loads(line)
                except ValueError:
                    reply = {"errno": errno.EINVAL}
                    request = {"unparsed": line.decode(errors="replace").rstrip("\n")}
                else:
                    with lock:
                        reply = answer(devices, request)
                with lock, open(log, "a") as out:
                    out.write(json.dumps({"request": request, "reply": reply}) + "\n")
                self.wfile.write((json.dumps(reply) + "\n").encode())
                self.wfile.flush()

    class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True

    if os.path.exists(sock):
        os.unlink(sock)
    with Server(sock, Handler) as server:
        print("hid-fake=listening", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
