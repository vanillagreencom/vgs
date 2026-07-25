#!/usr/bin/env python3
"""Read-only enumeration of feature reports on XDR USB interface 4 (vendor HID).

Uses usbfs control transfers: GET_REPORT (class, feature) only. No SET_REPORT,
no writes, no unknown requests. Safe per research brief section 2.
"""
import ctypes, fcntl, os, sys

USBDEVFS_CLAIMINTERFACE = 0x8004550F
USBDEVFS_RELEASEINTERFACE = 0x80045510
USBDEVFS_CONTROL = 0xC0185500

class usbdevfs_ctrltransfer(ctypes.Structure):
    _fields_ = [
        ("bRequestType", ctypes.c_uint8),
        ("bRequest", ctypes.c_uint8),
        ("wValue", ctypes.c_uint16),
        ("wIndex", ctypes.c_uint16),
        ("wLength", ctypes.c_uint16),
        ("timeout", ctypes.c_uint32),  # ms
        ("data", ctypes.c_void_p),
    ]

def main(path, iface):
    fd = os.open(path, os.O_RDWR)
    i = ctypes.c_uint(iface)
    try:
        fcntl.ioctl(fd, USBDEVFS_CLAIMINTERFACE, i)
    except OSError as e:
        print(f"claim iface {iface} failed: {e}", file=sys.stderr)
        return 1
    try:
        # Feature reports declared in the interface-4 descriptor.
        report_ids = [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
                      0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0xFC]
        for rid in report_ids:
            buf = ctypes.create_string_buffer(513)
            xfer = usbdevfs_ctrltransfer(
                bRequestType=0xA1,          # IN | class | interface
                bRequest=0x01,               # GET_REPORT
                wValue=(0x03 << 8) | rid,    # feature report
                wIndex=iface,
                wLength=512,
                timeout=800,
                data=ctypes.cast(buf, ctypes.c_void_p),
            )
            try:
                n = fcntl.ioctl(fd, USBDEVFS_CONTROL, xfer)
                data = bytes(buf.raw[:n])
                print(f"report 0x{rid:02X}: len={n} data={data.hex()}")
            except OSError as e:
                print(f"report 0x{rid:02X}: ERR {e.errno} ({e.strerror})")
    finally:
        try:
            fcntl.ioctl(fd, USBDEVFS_RELEASEINTERFACE, i)
        except OSError:
            pass
        os.close(fd)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1], int(sys.argv[2])))
