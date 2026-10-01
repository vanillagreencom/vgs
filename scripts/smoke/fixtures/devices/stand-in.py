#!/usr/bin/env python3
"""A device command's stand-in in the smoke sandbox's shim directory.

Usage: stand-in.py NAME STATE ARG...

scripts/smoke/devices.sh writes $shim/NAME as a two-line script that
runs this with NAME, its state directory STATE and the caller's argv.
No stand-in runs the host's command: each records its argv and answers
from files a row plants under STATE.

- Every call appends its argv as one JSON list line to
  STATE/calls/NAME.calls. A bluetoothctl transcript also appends each
  stdin line it reads, as {"stdin": LINE}.
- rfkill keeps STATE/rfkill.json, {"devices": [{"id", "type", "device",
  "soft", "hard"}]} with "blocked" or "unblocked", as its only state: it
  lists it as util-linux's rfkill does and block, unblock and toggle
  change the soft state of the devices an ID, a TYPE or `all` selects.
  A hard block is never changed, as on real hardware.
- bluetoothctl with no argument replays STATE/replies/bluetoothctl
  .transcript.json, a list of {"out": TEXT}, printed at once, and
  {"in": LINE}, which reads one stdin line and ends with status 1 when it
  differs; past the last step it records stdin until EOF.
- Any other call answers from STATE/replies/NAME.json, a list of
  {"argv", "stdout", "stderr", "status"} rows, the first whose argv
  equals the call's. A call no row answers prints the line
  `stand-in: name=NAME reply=none argv=<json>` on stderr and exits 1, so
  a caller never reads an answer no row planted.
"""

import json
import os
import sys

# util-linux rfkill's type names and the label `rfkill list` prints.
RFKILL_LABELS = {"wlan": "Wireless LAN", "bluetooth": "Bluetooth", "uwb": "Ultra-Wideband", "wimax": "WiMAX",
                 "wwan": "Wireless WAN", "gps": "GPS", "fm": "FM", "nfc": "NFC"}


def append(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as out:
        out.write(json.dumps(value) + "\n")


def refuse(name, key, detail=""):
    print(f"stand-in: name={name} {key}", file=sys.stderr)
    if detail:
        print(detail, file=sys.stderr)
    sys.exit(1)


def load_rfkill(state):
    with open(os.path.join(state, "rfkill.json")) as source:
        return json.load(source)


def save_rfkill(state, doc):
    path = os.path.join(state, "rfkill.json")
    with open(path + ".next", "w") as out:
        json.dump(doc, out)
    os.replace(path + ".next", path)


def rfkill_selected(devices, selector):
    if selector.isdigit():
        return [d for d in devices if d["id"] == int(selector)]
    if selector != "all" and selector not in RFKILL_LABELS:
        return None
    return [d for d in devices if selector == "all" or d["type"] == selector]


def rfkill(state, argv):
    doc = load_rfkill(state)
    devices = doc["devices"]
    if not argv:
        print("ID TYPE      DEVICE    SOFT      HARD")
        for d in devices:
            print(f"{d['id']:>2} {d['type']:<9} {d['device']:<9} {d['soft']:<9} {d['hard']}")
        return
    if argv in (["-J"], ["--json"]):
        print(json.dumps({"rfkilldevices": devices}, indent=3))
        return
    verb, rest = argv[0], argv[1:]
    if verb == "list" and len(rest) <= 1:
        shown = devices if not rest else rfkill_selected(devices, rest[0])
        if shown is None:
            refuse("rfkill", f"selector={rest[0]} reason=unknown")
        for d in shown:
            print(f"{d['id']}: {d['device']}: {RFKILL_LABELS[d['type']]}")
            print(f"\tSoft blocked: {'yes' if d['soft'] == 'blocked' else 'no'}")
            print(f"\tHard blocked: {'yes' if d['hard'] == 'blocked' else 'no'}")
        return
    if verb in ("block", "unblock", "toggle") and len(rest) == 1:
        chosen = rfkill_selected(devices, rest[0])
        if chosen is None:
            refuse("rfkill", f"selector={rest[0]} reason=unknown")
        for d in chosen:
            blocked = {"block": True, "unblock": False, "toggle": d["soft"] != "blocked"}[verb]
            d["soft"] = "blocked" if blocked else "unblocked"
        save_rfkill(state, doc)
        return
    refuse("rfkill", "usage=unsupported argv=" + json.dumps(argv))


def transcript(state, path):
    with open(path) as source:
        steps = json.load(source)
    calls = os.path.join(state, "calls", "bluetoothctl.calls")
    for step in steps:
        if "out" in step:
            sys.stdout.write(step["out"])
            sys.stdout.flush()
            continue
        line = sys.stdin.readline()
        if line == "":
            refuse("bluetoothctl", "transcript=ended-early want=" + json.dumps(step["in"]))
        line = line.rstrip("\n")
        append(calls, {"stdin": line})
        if line != step["in"]:
            refuse("bluetoothctl", "transcript=diverged want=" + json.dumps(step["in"]) + " got=" + json.dumps(line))
    for line in sys.stdin:
        append(calls, {"stdin": line.rstrip("\n")})


def replies(name, state, argv):
    path = os.path.join(state, "replies", name + ".json")
    rows = []
    if os.path.exists(path):
        with open(path) as source:
            rows = json.load(source)
    for row in rows:
        if row["argv"] == argv:
            sys.stdout.write(row.get("stdout", ""))
            sys.stderr.write(row.get("stderr", ""))
            sys.exit(row.get("status", 0))
    refuse(name, "reply=none argv=" + json.dumps(argv))


def main():
    if len(sys.argv) < 3:
        print("stand-in: usage=NAME STATE ARG...", file=sys.stderr)
        sys.exit(2)
    name, state, argv = sys.argv[1], sys.argv[2], sys.argv[3:]
    append(os.path.join(state, "calls", name + ".calls"), argv)
    if name == "rfkill":
        rfkill(state, argv)
        return
    script = os.path.join(state, "replies", "bluetoothctl.transcript.json")
    if name == "bluetoothctl" and not argv and os.path.exists(script):
        transcript(state, script)
        return
    replies(name, state, argv)


if __name__ == "__main__":
    main()
