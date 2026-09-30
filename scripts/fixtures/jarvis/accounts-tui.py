# Run the actual accounts script on a private controlling terminal.
# Gum's stand-in consumes the test's scratch menu queue, never host input.
import errno
import fcntl
import os
import pty
import select
import subprocess
import sys
import termios
import time

master, slave = pty.openpty()
env = {name: os.environ[name] for name in (
    "PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
    "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")}
env["VGS_TUI_LIB"] = sys.argv[2]
env["VGS_PLUGIN_DIR"] = sys.argv[3]
env["OPENAI_API_KEY"] = "fixture-secret-private"
env["VGSH_RUNNER_PID"] = "999"

def terminal():
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

child = subprocess.Popen(["bash", sys.argv[1]], stdin=slave, stdout=slave,
                         stderr=slave, env=env, preexec_fn=terminal)
os.close(slave)
output = b""
deadline = time.monotonic() + 15  # Bound a script stuck waiting for fixture input.
try:
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.05)[0]:
            try:
                part = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not part:
                break
            output += part
        elif child.poll() is not None:
            break
    if child.poll() is None:
        child.kill()
    code = child.wait(timeout=2)
    sys.stdout.buffer.write(output)
    sys.exit(code)
finally:
    if child.poll() is None:
        child.kill()
        child.wait()
    os.close(master)
