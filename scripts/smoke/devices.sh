# Sourced by harness.sh; owns the sandbox's device fakes, the stand-ins
# for device commands and the guards a device row starts behind
# (docs/architecture/validation-smoke-devices.md). No smoke row may reach
# the host's audio, radios, network, VPN, DDC or hidraw: the sandbox shares
# the host's devices and files.
#
# The contract a row builds on:
# - devices_env_words, which the harness puts in every sandbox process's
#   environment: PIPEWIRE_RUNTIME_DIR names the sandbox runtime dir, and
#   VGS_DEV_ROOT, VGS_SYSFS_ROOT and VGS_HID_FAKE name the brightness
#   helper's device tree, sysfs tree and feature-report socket under the
#   sandbox.
# - The stand-ins, device_stand_in_names, each $shim/<name>, first on
#   every sandbox shell's PATH for the whole run: each records its argv
#   and answers from files a row plants, never the host's command
#   (scripts/smoke/fixtures/devices/stand-in.py). device_reply plants an
#   answer, device_reply_clear removes a stand-in's planted answers,
#   device_transcript a bluetoothctl session, device_calls reads the
#   record. A row that needs a stand-in to answer its own way stands over
#   it with sentinel_stand_over and puts it back with sentinel_restore,
#   as with the authentication sentinels.
# - devices_up starts the fakes once per run, on a row's first call, and
#   leaves them up: python-dbusmock's bluez5 and networkmanager templates
#   on the sandbox system bus with one adapter, one device and one Wi-Fi
#   device planted, a private PipeWire and WirePlumber with null nodes
#   only, and the HID feature-report fake. Quickshell's Bluetooth,
#   Networking and Pipewire singletons look for their service once, when
#   a plugin first reads them, so a row calls it before it enables a
#   plugin that reads one (docs/architecture/runtime-devices.md).
# - devices_ready ROW, a device row's first line: devices_up, then
#   devices_guard over the running shell. A missing prerequisite or a
#   guard that reads a leak records ROW not measured and returns 1, and
#   the row returns; an unreadable shell environment or a fake that fails
#   to start fails the row.
devices_dir="$sandbox/devices"
devices_dev_root="$devices_dir/dev"
devices_sysfs_root="$devices_dir/sys"
devices_hid_socket="$rt_dir/hid-fake.sock"
devices_hid_log="$devices_dir/hid-fake.calls"
devices_fixtures="$repo/scripts/smoke/fixtures/devices"
devices_env_words=(PIPEWIRE_RUNTIME_DIR="$rt_dir" VGS_DEV_ROOT="$devices_dev_root"
  VGS_SYSFS_ROOT="$devices_sysfs_root" VGS_HID_FAKE="$devices_hid_socket")
device_stand_in_names=(rfkill tailscale ddcutil brightnessctl nmcli pactl bluetoothctl systemctl udevadm modprobe xdg-open gum)
mkdir -p -- "$devices_dir/calls" "$devices_dir/replies"

# devices_write_stand_ins: every stand-in written into $shim, and rfkill's
# state reset to the fixture's two unblocked radios. The harness calls it
# before the first shell starts, so no shell ever resolves one of these
# names on the host. The interpreter is resolved once, here, so a row's
# PATH cannot change what a stand-in runs.
devices_write_stand_ins() {
  local python name
  python="$(command -v python3)" || { printf 'qml-smoke: status=not-measured missing=python3\n'; exit 77; }
  cp -- "$devices_fixtures/rfkill.json" "$devices_dir/rfkill.json"
  for name in "${device_stand_in_names[@]}"; do
    printf '#!/usr/bin/env bash\nexec %q %q %q %q "$@"\n' "$python" "$devices_fixtures/stand-in.py" "$name" "$devices_dir" >"$shim/$name"
    chmod 755 "$shim/$name"
  done
}

# device_reply NAME STATUS STDOUT ARGV...: NAME's stand-in answers the call
# whose argv is ARGV with STDOUT, a newline added when it lacks one, and
# STATUS. A later reply for the same argv replaces the earlier reply.
device_reply() { # NAME STATUS STDOUT ARGV...
  python3 - "$devices_dir/replies/$1.json" "$2" "$3" "${@:4}" <<'PY'
import json, os, sys
path, status, stdout, argv = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
rows = json.load(open(path)) if os.path.exists(path) else []
rows = [row for row in rows if row["argv"] != argv]
rows.append({"argv": argv, "stdout": stdout if stdout == "" or stdout.endswith("\n") else stdout + "\n", "status": status})
with open(path + ".next", "w") as out:
    json.dump(rows, out)
os.replace(path + ".next", path)
PY
}
# device_reply_clear NAME: removes all planted replies for NAME.
device_reply_clear() { # NAME
  rm -f -- "$devices_dir/replies/$1.json"
}
# device_transcript STEPS_JSON: the session bluetoothctl with no argument,
# or with `--agent CAPABILITY`, replays, steps as stand-in.py reads them;
# `-` removes it.
device_transcript() { # STEPS_JSON|-
  if [[ $1 == - ]]; then rm -f -- "$devices_dir/replies/bluetoothctl.transcript.json"; return; fi
  printf '%s\n' "$1" >"$devices_dir/replies/bluetoothctl.transcript.json"
}
# device_calls NAME: every call NAME's stand-in recorded, as one JSON list,
# `[]` before the first.
device_calls() { # NAME
  python3 - "$devices_dir/calls/$1.calls" <<'PY'
import json, os, sys
path = sys.argv[1]
print(json.dumps([json.loads(line) for line in open(path)] if os.path.exists(path) else []))
PY
}
# rfkill_state [DIR]: the rfkill stand-in's radios as [[type, soft,
# hard], ...], from the state directory DIR, the harness's by default.
rfkill_state() { python3 -c 'import json,sys; print(json.dumps([[d["type"], d["soft"], d["hard"]] for d in json.load(open(sys.argv[1]))["devices"]]))' "${1:-$devices_dir}/rfkill.json"; }

# devices_state: `down` before devices_up, `up` once every fake answered,
# `missing=<a,b>` for absent prerequisites, `failed=<key>` for a fake that
# did not start. devices_pid maps pipewire, wireplumber, bluez, network
# and hid to the pid devices_up spawned; each is its own process group,
# which the teardown stops.
devices_state=down
declare -gA devices_pid=()
devices_up() {
  local missing=() name planted
  case "$devices_state" in
    up) return 0 ;;
    missing=*) return 77 ;;
    failed=*) return 1 ;;
  esac
  for name in pipewire wireplumber; do command -v "$name" >/dev/null 2>&1 || missing+=("$name"); done
  python3 -c 'import dbusmock' >/dev/null 2>&1 || missing+=(python-dbusmock)
  if [[ ${#missing[@]} -gt 0 ]]; then
    devices_state="missing=$(IFS=,; echo "${missing[*]}")"
    return 77
  fi
  # PIPEWIRE_CONFIG_DIR names the fixture directory alone, so no host
  # fragment reaches the daemon; clients keep the host's client.conf,
  # which the sandbox daemon does not read.
  spawn "$devices_dir/pipewire.log" "${shell_env[@]}" PIPEWIRE_CONFIG_DIR="$devices_fixtures/pipewire" pipewire
  devices_pid[pipewire]="$spawn_pid"
  for _ in $(seq 1 50); do [[ -S $rt_dir/pipewire-0 ]] && break; sleep 0.1; done
  if [[ ! -S $rt_dir/pipewire-0 ]]; then devices_failed pipewire "$devices_dir/pipewire.log"; return 1; fi
  mkdir -p -- "$home/.config/wireplumber/wireplumber.conf.d"
  cp -- "$devices_fixtures/wireplumber/90-vgs-smoke.conf" "$home/.config/wireplumber/wireplumber.conf.d/"
  spawn "$devices_dir/wireplumber.log" "${shell_env[@]}" wireplumber --profile vgs-smoke
  devices_pid[wireplumber]="$spawn_pid"
  spawn "$devices_dir/bluez.log" "${shell_env[@]}" python3 -m dbusmock --system --template bluez5
  devices_pid[bluez]="$spawn_pid"
  spawn "$devices_dir/network.log" "${shell_env[@]}" python3 -m dbusmock --system --template networkmanager
  devices_pid[network]="$spawn_pid"
  planted="$("${shell_env[@]}" python3 "$devices_fixtures/world.py" "unix:path=$rt_dir/system-bus" 2>&1)" || true
  if [[ $planted != world=planted ]]; then
    printf '%s\n' "$planted" >"$devices_dir/world.log"
    devices_failed world "$devices_dir/world.log"
    return 1
  fi
  spawn "$devices_dir/hid-fake.log" "${shell_env[@]}" python3 "$devices_fixtures/hid-fake.py" \
    "$devices_hid_socket" "$devices_fixtures/hid-world.json" "$devices_dev_root" "$devices_sysfs_root" "$devices_hid_log"
  devices_pid[hid]="$spawn_pid"
  for _ in $(seq 1 50); do [[ -S $devices_hid_socket ]] && break; sleep 0.1; done
  if [[ ! -S $devices_hid_socket ]]; then devices_failed hid-fake "$devices_dir/hid-fake.log"; return 1; fi
  for name in pipewire wireplumber bluez network hid; do
    local log="$devices_dir/$name.log"
    [[ $name == hid ]] && log="$devices_dir/hid-fake.log"
    if ! kill -0 "${devices_pid[$name]}" 2>/dev/null; then devices_failed "$name" "$log"; return 1; fi
  done
  devices_state=up
}
devices_failed() { # KEY LOG
  devices_state="failed=$1"
  fail "devices_up: the $1 fake did not start: $2"
  tail -n 20 -- "$2" | sed 's/^/        /'
}

# devices_guard PID: `inside` when process PID's environment keeps every
# device it can reach inside the sandbox, else the first rule it breaks as
# `leak=<rule> value=<value>`. It exits non-zero with a reason on stderr
# when its environment cannot be read. The rules, one table: system-bus, its
# DBUS_SYSTEM_BUS_ADDRESS is the sandbox's system bus; pipewire-runtime,
# PIPEWIRE_RUNTIME_DIR lies in the sandbox runtime dir; hardware-root,
# VGS_DEV_ROOT, VGS_SYSFS_ROOT and VGS_HID_FAKE each lie in the sandbox
# or its runtime dir; path-shim, every stand-in name resolves on its PATH
# to $shim/<name>. An unset variable breaks its rule.
devices_guard() { # PID
  python3 - "$1" "$rt_dir" "$sandbox" "$shim" "${device_stand_in_names[@]}" <<'PY'
import os, sys
pid, rt, sandbox, shim, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
try:
    raw = open(f"/proc/{pid}/environ", "rb").read()
except OSError:
    print("devices_guard: environ=unreadable pid=" + pid, file=sys.stderr)
    sys.exit(1)
env = dict(item.split("=", 1) for item in raw.decode(errors="replace").split("\0") if "=" in item)
def within(path, roots):
    real = os.path.realpath(path)
    return any(real == os.path.realpath(r) or real.startswith(os.path.realpath(r) + os.sep) for r in roots)
def resolves(name):
    for directory in env.get("PATH", "").split(":"):
        candidate = os.path.join(directory or ".", name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return "none"
checks = [("system-bus", "DBUS_SYSTEM_BUS_ADDRESS", lambda v: v == f"unix:path={rt}/system-bus"),
          ("pipewire-runtime", "PIPEWIRE_RUNTIME_DIR", lambda v: within(v, [rt]))]
checks += [("hardware-root", var, lambda v: within(v, [sandbox, rt])) for var in ("VGS_DEV_ROOT", "VGS_SYSFS_ROOT", "VGS_HID_FAKE")]
for rule, var, holds in checks:
    value = env.get(var)
    if value is None or not holds(value):
        print(f"leak={rule} value={var}={value if value is not None else 'unset'}")
        sys.exit()
for name in names:
    found = resolves(name)
    if found != os.path.join(shim, name):
        print(f"leak=path-shim value={name}={found}")
        sys.exit()
print("inside")
PY
}
# devices_ready ROW: devices_up, then devices_guard over the running
# shell, shell_qs_pid. Returns 0 with both in order; otherwise ROW is not
# measured for missing prerequisites or a leak, or failed when no shell
# pid can be checked, a guard cannot read it, or a fake did not start.
devices_ready() { # ROW
  local status=0 reading
  devices_up || status=$?
  case "$status" in
    0) ;;
    77) not_measured "$1" "$devices_state"; return 1 ;;
    *) return 1 ;;
  esac
  if [[ -z ${shell_qs_pid:-} ]]; then
    fail "$1: the device guard has no shell pid to read"
    return 1
  fi
  reading="$(devices_guard "$shell_qs_pid")" || { fail "$1: the device guard could not read pid $shell_qs_pid"; return 1; }
  if [[ $reading != inside ]]; then not_measured "$1" "$reading"; return 1; fi
  ok "$1: the shell (pid $shell_qs_pid) reaches the sandbox's buses, PipeWire, device roots and stand-ins only"
}

# device_fds PID PATTERN: the paths process PID holds open that match the
# extended regex PATTERN, as one sorted JSON list, from /proc/PID/fd.
device_fds() { # PID PATTERN
  python3 - "$1" "$2" <<'PY'
import json, os, re, sys
pid, pattern = sys.argv[1], re.compile(sys.argv[2])
held = set()
for fd in os.listdir(f"/proc/{pid}/fd"):
    try:
        target = os.readlink(f"/proc/{pid}/fd/{fd}")
    except OSError:
        continue
    if pattern.search(target):
        held.add(target)
print(json.dumps(sorted(held)))
PY
}
# devices_system_tree: the tree the sandbox copy of bin/vgsh-system
# resolves every path and command in, $sandbox/system-root, and the
# copy's `prefix=` line rewritten to it, so the core's system-step probe
# reads the fakes and never the host's /sys and /dev. Its sys and dev link
# the fakes' sysfs and device trees, usr/bin links the coreutils the steps
# run and the udevadm, systemctl and gum stand-ins, and it holds the rules
# and record directories and a boot id. Prints `prefixed` once the copy
# names the tree, made on the first call and kept; else the first problem,
# `missing=<tool>` or `prefix-line-count=<n>`, and returns 1. The harness
# makes it before the first shell starts; a row that applies a step adds
# its own sudo and stat to usr/bin.
devices_system_root="$sandbox/system-root"
devices_system_tree() {
  local tool found bin="$devices_system_root/usr/bin"
  if grep -q -x -F -- "prefix=$devices_system_root" "$repo/bin/vgsh-system"; then echo prefixed; return 0; fi
  mkdir -p -- "$bin" "$devices_system_root/etc/udev/rules.d" "$devices_system_root/var/lib" "$devices_system_root/proc/sys/kernel/random"
  ln -sfn -- "$devices_sysfs_root" "$devices_system_root/sys"
  ln -sfn -- "$devices_dev_root" "$devices_system_root/dev"
  for tool in awk bash cat chmod env flock id install mkdir mv readlink rm sed sha256sum sleep kill tee touch; do
    found="$(command -v "$tool")" || { echo "missing=$tool"; return 1; }
    ln -sfn -- "$found" "$bin/$tool"
  done
  for tool in udevadm systemctl gum; do ln -sfn -- "$shim/$tool" "$bin/$tool"; done
  printf '11111111-2222-3333-4444-555555555555\n' >"$devices_system_root/proc/sys/kernel/random/boot_id"
  python3 - "$repo/bin/vgsh-system" "$devices_system_root" <<'PY'
import sys
path, root = sys.argv[1:]
text = open(path).read()
if text.count("\nprefix=\n") != 1:
    print("prefix-line-count=%d" % text.count("\nprefix=\n")); sys.exit(1)
open(path, "w").write(text.replace("\nprefix=\n", "\nprefix=" + root + "\n"))
print("prefixed")
PY
}
# hid_fake_call DEVICE IOCTL HEX: one request to the HID fake, as the
# brightness helper sends it, and the reply as one JSON line.
hid_fake_call() { # DEVICE IOCTL HEX
  python3 - "$devices_hid_socket" "$1" "$2" "$3" <<'PY'
import json, socket, sys
path, device, request, data = sys.argv[1], sys.argv[2], int(sys.argv[3], 0), sys.argv[4]
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
    s.connect(path)
    s.sendall((json.dumps({"device": device, "request": request, "data": data}) + "\n").encode())
    print(s.makefile().readline().strip())
PY
}
