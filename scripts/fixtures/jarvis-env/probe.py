#!/usr/bin/env python3
"""Synthetic isolation probes, authored 2026-09-30.

Source: docs/plans/v2-jarvis-plan.md, Testing strategy.
These are OS behavior probes, not provider protocol recordings. No schema or
vendor version applies. D-Bus cases use org.freedesktop.DBus's standard API.
"""
import errno
import fcntl
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
from urllib.parse import quote


def child(args):
    """Run a probe child with the world's explicit environment."""
    return subprocess.run(args, env=dict(os.environ), cwd=os.environ["HOME"],
                          capture_output=True, text=True, timeout=10)


def bus_call(kind, method, *args):
    return child(["gdbus", "call", "--" + kind, "--timeout", "2",
                  "--dest", "org.freedesktop.DBus",
                  "--object-path", "/org/freedesktop/DBus",
                  "--method", "org.freedesktop.DBus." + method, *args])


mode = sys.argv[1]
if mode == "outbound":
    # This address belongs only to the suite's outer, already isolated world.
    # It is never installed or contacted in the host network namespace.
    try:
        with socket.create_connection(("192.0.2.1", int(sys.argv[2])), timeout=2):
            print("outbound=connected")
    except OSError as error:
        print("outbound=blocked errno=" + str(error.errno), file=sys.stderr)
        sys.exit(1 if error.errno == errno.ENETUNREACH else 2)
elif mode == "lock":
    with open(sys.argv[2], "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("locked", flush=True)
        # A real wait: the descendant stays alive after its parent ends.
        time.sleep(60)
elif mode == "acquire":
    with open(sys.argv[2], "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
elif mode == "orphan":
    process = subprocess.Popen(["python3", __file__, "lock", sys.argv[2]],
                               env=dict(os.environ), cwd=os.environ["HOME"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    assert process.stdout.readline().strip() == "locked"
    print(os.environ["JARVIS_TEST_ROOT"])
elif mode in ("cancel", "cli-timeout", "timeout-world"):
    # Keep stderr inherited: a leaked descendant retains the caller's output
    # pipe as well as this lock. A finite lifetime lets broken controls end.
    process = subprocess.Popen(["/usr/bin/python3", __file__, "lock", sys.argv[2]],
                               env=dict(os.environ), cwd=os.environ["HOME"],
                               stdout=subprocess.PIPE, text=True)
    assert process.stdout.readline().strip() == "locked"
    record = {"root": os.environ.get("JARVIS_TEST_ROOT")}
    if mode == "cli-timeout":
        Path(sys.argv[3]).write_text(json.dumps(record))
    print(json.dumps(record), flush=True)
    # This real wait exposes ignored cancellation. The marker can only be
    # emitted when the fixture survives until its own, unrequested exit.
    time.sleep(2)
    if mode == "cli-timeout":
        Path(sys.argv[3]).write_text(json.dumps({**record, "expired": True}))
    print("fixture=expired", flush=True)
elif mode == "namespace":
    kinds = ("user", "net", "pid")
    mine = [os.readlink("/proc/self/ns/" + kind) for kind in kinds]
    assert all(actual != parent for actual, parent in zip(mine, sys.argv[2:]))
    assert socket.if_nameindex() == [(1, "lo")]
    result = child(["python3", "-c",
                    "import os; print('\\n'.join(os.readlink('/proc/self/ns/' + k)"
                    " for k in ('user', 'net', 'pid')))"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == mine
elif mode == "environment":
    assert "JARVIS_PARENT_ONLY" not in os.environ
    assert "JARVIS_TEST_SCRATCH_ROOT" not in os.environ
    assert not set(os.environ).intersection({
        "TMUX", "DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE",
        "VGSH_RUNNER_PID", "SSH_AUTH_SOCK", "NODE_OPTIONS", "BASH_ENV", "ENV",
        "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR", "CODEX_HOME",
    })
    assert os.environ["VGS_TEST_RUN"] == "1"
    assert os.environ["LC_ALL"] == "C"
    assert os.environ["TZ"] == "UTC"
elif mode == "scratch-parent":
    root = Path(os.environ["JARVIS_TEST_ROOT"])
    assert root.is_absolute() and root == root.resolve()
    assert root.is_dir() and not root.is_symlink()
    assert root.stat().st_mode & 0o777 == 0o700
    assert root.parent == Path(sys.argv[2]).resolve()
    assert "JARVIS_TEST_SCRATCH_ROOT" not in os.environ
    assert os.environ["TMPDIR"] == str(root / "tmp")
    print(root)
elif mode == "directory":
    key, suffix = sys.argv[2:]
    root = Path(os.environ["JARVIS_TEST_ROOT"])
    expected = root / suffix
    assert Path(os.environ[key]) == expected
    assert expected.is_dir() and not expected.is_symlink()
    assert expected.stat().st_mode & 0o077 == 0
    assert Path.cwd() == Path(os.environ["HOME"])
    if suffix != "run":
        assert not list(expected.iterdir())
elif mode == "path":
    root = Path(os.environ["JARVIS_TEST_ROOT"])
    assert os.environ["PATH"].split(":") == [str(root / "standins"), str(root / "tools")]
    # Expected command set, independent of the helper's declaration.
    assert {p.name for p in (root / "tools").iterdir()} == {
        "bash", "sh", "env", "node", "python3", "cat", "mkdir", "rm", "cp", "mv",
        "ln", "chmod", "sleep", "readlink", "dirname", "basename", "stat", "grep",
        "sed", "awk", "sort", "cut", "wc", "true", "false", "timeout", "gdbus", "tmux",
    }
    for name in ("pw-record", "pw-cat", "pipewire", "wpctl", "hyprctl", "qs",
                 "secret-tool", "busctl", "systemctl", "systemd-run", "notify-send",
                 "pacman", "apt", "dnf", "curl", "wget", "uv", "chromium",
                 "agent-browser", "claude", "codex", "copilot"):
        assert shutil.which(name) is None, name
elif mode == "loopback-client":
    with socket.create_connection(("127.0.0.1", int(sys.argv[2])), timeout=2) as stream:
        stream.sendall(b"fixture")
        assert stream.recv(16) == b"reply"
elif mode == "loopback":
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        server.listen()
        server.settimeout(5)
        process = subprocess.Popen(["python3", __file__, "loopback-client",
                                    str(server.getsockname()[1])],
                                   env=dict(os.environ), cwd=os.environ["HOME"])
        with server.accept()[0] as stream:
            assert stream.recv(16) == b"fixture"
            stream.sendall(b"reply")
        assert process.wait(timeout=5) == 0
elif mode == "buses":
    ids = []
    for kind in ("session", "system"):
        address = os.environ["DBUS_" + kind.upper() + "_BUS_ADDRESS"]
        assert address.startswith("unix:path=" + quote(os.environ["XDG_RUNTIME_DIR"] + "/" + kind + ".bus", safe="/") + ",")
        result = bus_call(kind, "GetId")
        assert result.returncode == 0, result.stderr
        ids.append(result.stdout)
        result = bus_call(kind, "NameHasOwner", "org.freedesktop.secrets")
        assert result.returncode == 0 and result.stdout.strip() == "(false,)"
    assert ids[0] != ids[1]
elif mode == "activation":
    directory = Path(os.environ["XDG_DATA_HOME"]) / "dbus-1/services"
    directory.mkdir(parents=True)
    (directory / "org.vgs.JarvisFixture.service").write_text(
        "[D-BUS Service]\nName=org.vgs.JarvisFixture\nExec=/bin/false\n")
    for kind in ("session", "system"):
        result = bus_call(kind, "StartServiceByName", "org.vgs.JarvisFixture", "0")
        assert result.returncode != 0
        assert "org.freedesktop.DBus.Error.ServiceUnknown" in result.stderr, result.stderr
elif mode in ("tmux", "tmux-safe"):
    # The helper must ignore even a scratch home's config. Mutations can
    # select this file safely without reading /etc or a live user's config.
    (Path(os.environ["HOME"]) / ".tmux.conf").write_text("set -g @jarvis_fixture loaded\n")
    result = child(["tmux", "new-session", "-d", "-s", "fixture", "sleep 60"])
    assert result.returncode == 0, result.stderr
    options = sys.argv[2:] if mode == "tmux-safe" else []
    result = child(["tmux", *options, "display-message", "-p", "#{socket_path}"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == os.environ["JARVIS_TEST_TMUX_SOCKET"]
    result = child(["tmux", "show-option", "-gqv", "@jarvis_fixture"])
    assert result.returncode == 0 and result.stdout.strip() == ""
elif mode in ("tmux-override", "tmux-getopt"):
    # Values remain scratch-only even when the wrapper's guard is mutated.
    config = Path(os.environ["HOME"]) / ".tmux.conf"
    config.write_text("set -g @jarvis_fixture loaded\n")
    shapes = {
        "socket": ["-S", "{socket}"],
        "label": ["-L", "override"],
        "config": ["-f", "{config}"],
        "cluster-socket": ["-uS", "{socket}"],
        "attached-socket": ["-uS{socket}"],
        "cluster-config": ["-2f", "{config}"],
        "attached-config": ["-2f{config}"],
        "cluster-label": ["-uL", "override"],
        "post-feature-socket": ["-T", "256", "-S", "{socket}"],
        "post-attached-feature-config": ["-T256", "-f", "{config}"],
        "post-cluster-feature-label": ["-uT", "256", "-L", "override"],
        "post-command-socket": ["-c", "printf fixture", "-S", "{socket}"],
        "unknown": ["-Z"],
        "missing-value": ["-T"],
    }
    shape = sys.argv[2]
    socket_path = os.environ["XDG_RUNTIME_DIR"] + "/override.sock"
    options = [arg.format(socket=socket_path, config=config) for arg in shapes[shape]]
    command = [] if shape in ("post-command-socket", "unknown", "missing-value") else [
        "new-session", "-d", "-s", "fixture", "sleep 60"]
    if mode == "tmux-getopt":
        # Prove that the vendor really parses the bypass forms before using
        # them as guard controls. Both possible targets are private sockets.
        binary = os.environ["JARVIS_TEST_ROOT"] + "/bootstrap/tmux"
        base = [binary, "-f", "/dev/null", "-S", os.environ["JARVIS_TEST_TMUX_SOCKET"]]
        result = child([*base, *options, *command])
        assert result.returncode == 0, result.stderr
        if "socket" in shape:
            if shape == "post-command-socket":
                assert result.stdout == "fixture"
            else:
                assert Path(socket_path).is_socket()
        elif "config" in shape:
            result = child([*base, "show-option", "-gqv", "@jarvis_fixture"])
            assert result.returncode == 0 and result.stdout.strip() == "loaded"
    else:
        result = child(["tmux", *options, *command])
        assert result.returncode == 2, result
        assert result.stderr.splitlines()[0] == "jarvis-env: tmux=override-refused"
elif mode == "tmux-command":
    result = child(["tmux", "-uc", "printf '%s' '-S value'"])
    assert result.returncode == 0, result.stderr
    assert result.stdout == "-S value"
elif mode == "audio":
    runtime = os.environ["XDG_RUNTIME_DIR"]
    assert os.environ["PIPEWIRE_RUNTIME_DIR"] == runtime
    assert os.environ["PIPEWIRE_REMOTE"] == "jarvis-test-no-pipewire"
    assert os.environ["PULSE_RUNTIME_PATH"] == runtime
    assert os.environ["PULSE_SERVER"] == "unix:" + runtime + "/no-pulse"
    assert not (Path(runtime) / "jarvis-test-no-pipewire").exists()
    assert not (Path(runtime) / "no-pulse").exists()
else:
    raise AssertionError("unknown probe: " + mode)
