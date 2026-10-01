#!/usr/bin/env python3
"""The sandbox's radios on its private system bus.

Usage: world.py ADDRESS

ADDRESS is the sandbox system bus, where scripts/smoke/devices.sh has
started python-dbusmock's bluez5 and networkmanager templates. This
waits up to 10 s for both names, then plants one Bluetooth adapter with
one paired, connected device, and one Wi-Fi device that sees one access
point. It prints `world=planted`, or `world=failed reason=<key>` with
status 1.

The templates lack members Quickshell 0.3.1 reads, which the line
QS_DBUS_PROPERTY_BINDING names in src/bluetooth/adapter.hpp,
src/bluetooth/device.hpp and src/network/nm/*.hpp. A required property
missing from a GetAll answer logs `missing from property set` and leaves
the value unset, and NetworkManager's GetAllDevices is the call that
lists devices. Each gap is filled through dbusmock's own
org.freedesktop.DBus.Mock interface, AddProperty and AddMethod, so no
second fake owns any object: docs/architecture/runtime-devices.md.
"""

import sys
import time

import dbus

BLUEZ = "org.bluez"
NM = "org.freedesktop.NetworkManager"
MOCK = "org.freedesktop.DBus.Mock"
ADAPTER = "org.bluez.Adapter1"
DEVICE = "org.bluez.Device1"
NM_DEVICE = "org.freedesktop.NetworkManager.Device"
NM_WIRELESS = "org.freedesktop.NetworkManager.Device.Wireless"
NM_DISCONNECTED = 30
NM_INFRA = 2
AP_SEC_KEY_MGMT_PSK = 0x100

# What the row reads back: scripts/smoke/rows/device-fakes.sh.
ADAPTER_ID = "hci0"
ADAPTER_NAME = "VGS Smoke"
DEVICE_ADDRESS = "00:1B:66:AA:BB:01"
DEVICE_NAME = "Smoke Headphones"
WIFI_INTERFACE = "wlan0"
WIFI_SSID = "VGS Smoke Wi-Fi"


def refuse(reason):
    print(f"world=failed reason={reason}")
    sys.exit(1)


def wait_for(bus, names):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if all(bus.name_has_owner(name) for name in names):
            return
        time.sleep(0.05)
    refuse("names-absent names=" + ",".join(n for n in names if not bus.name_has_owner(n)))


def plant_bluez(bus):
    root = dbus.Interface(bus.get_object(BLUEZ, "/"), "org.bluez.Mock")
    adapter_path = root.AddAdapter(ADAPTER_ID, ADAPTER_NAME)
    adapter = dbus.Interface(bus.get_object(BLUEZ, adapter_path), MOCK)
    adapter.AddProperty(ADAPTER, "PowerState", dbus.String("on"))
    device_path = root.AddDevice(ADAPTER_ID, DEVICE_ADDRESS, DEVICE_NAME)
    root.PairDevice(ADAPTER_ID, DEVICE_ADDRESS)
    root.ConnectDevice(ADAPTER_ID, DEVICE_ADDRESS)
    device = dbus.Interface(bus.get_object(BLUEZ, device_path), MOCK)
    device.AddProperty(DEVICE, "Bonded", dbus.Boolean(True))
    device.UpdateProperties(DEVICE, {"Icon": dbus.String("audio-headphones")})


def plant_network(bus):
    root = dbus.Interface(bus.get_object(NM, "/org/freedesktop"), MOCK)
    manager = dbus.Interface(bus.get_object(NM, "/org/freedesktop/NetworkManager"), MOCK)
    manager.AddMethod(NM, "GetAllDevices", "", "ao", 'ret = [k for k in objects.keys() if "/Devices/" in k]')
    manager.AddProperty(NM, "ConnectivityCheckAvailable", dbus.Boolean(False))
    manager.AddProperty(NM, "ConnectivityCheckEnabled", dbus.Boolean(False))
    device_path = root.AddWiFiDevice(WIFI_INTERFACE, WIFI_INTERFACE, dbus.Int32(NM_DISCONNECTED))
    device = dbus.Interface(bus.get_object(NM, device_path), MOCK)
    device.AddProperty(NM_DEVICE, "HwAddress", dbus.String("11:22:33:44:55:66"))
    device.AddProperty(NM_DEVICE, "Autoconnect", dbus.Boolean(True))
    device.AddProperty(NM_DEVICE, "InterfaceFlags", dbus.UInt32(0))
    device.AddProperty(NM_WIRELESS, "LastScan", dbus.Int64(-1))
    device.AddProperty(NM_WIRELESS, "ActiveAccessPoint", dbus.ObjectPath("/"))
    root.AddAccessPoint(device_path, "ap0", WIFI_SSID, "00:11:22:33:44:01", dbus.UInt32(NM_INFRA),
                        dbus.UInt32(2437), dbus.UInt32(54000), dbus.Byte(82), dbus.UInt32(AP_SEC_KEY_MGMT_PSK))


def main():
    if len(sys.argv) != 2:
        refuse("usage")
    try:
        bus = dbus.bus.BusConnection(sys.argv[1])
    except dbus.DBusException as error:
        refuse(f"bus-unreachable error={error.get_dbus_name()}")
    wait_for(bus, (BLUEZ, NM))
    try:
        plant_bluez(bus)
        plant_network(bus)
    except dbus.DBusException as error:
        refuse(f"mock-call error={error.get_dbus_name()} message={error.get_dbus_message()!r}")
    print("world=planted")


if __name__ == "__main__":
    main()
