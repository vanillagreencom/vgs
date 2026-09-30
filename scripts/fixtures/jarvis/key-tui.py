# Drive the actual add-key script on a private terminal. Input waits for each
# prompt, so secret bytes are never sent while the terminal still echoes.
import errno
import os
import pty
import select
import subprocess
import sys
import time

master, slave = pty.openpty()
env = {name: os.environ[name] for name in (
    "PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
    "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")}
env["VGS_TUI_LIB"] = sys.argv[2]
env["VGS_PLUGIN_DIR"] = sys.argv[3]
def terminal():
    import fcntl
    import termios
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
child = subprocess.Popen(["bash", sys.argv[1]], stdin=slave, stdout=slave,
                         stderr=slave, env=env, preexec_fn=terminal)
os.close(slave)
steps = [(b"Provider: ", b"fixture\n"), (b"Account label: ", b"test\n"),
         (b"Origin (for example https://api.openai.com): ", b"https://fixture.invalid\n"),
         (b"Password: ", b"test-key-must-stay-private\n")]
output = b""
deadline = time.monotonic() + 10  # Bound an interactive fixture that misses a prompt.
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
            if steps and steps[0][0] in output:
                os.write(master, steps.pop(0)[1])
        elif child.poll() is not None:
            break
    if child.poll() is None:
        child.kill()
    code = child.wait(timeout=2)
    sys.stdout.buffer.write(output)
    metadata_refusal = len(sys.argv) == 5 and sys.argv[4] == "--expect-metadata-refusal"
    sys.exit(code if not steps or (metadata_refusal and len(steps) == 1) else 90)
finally:
    if child.poll() is None:
        child.kill()
        child.wait()
    os.close(master)
