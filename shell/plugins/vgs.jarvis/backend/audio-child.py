#!/usr/bin/env python3
"""Audio child bootstrap. fd 3 is a daemon-only lease; fd 4 reports readiness.

setpriv arms parent death before this bootstrap checks its expected parent.
The namespace init retains the lease and exits on EOF. Its death kills every
descendant, including a tool that forks or creates another process group.
See docs/architecture/jarvis-audio.md § Child lifetime.
"""
import os
import selectors
import subprocess
import sys


def main():
    mode, parent, *command = sys.argv[1:]
    if mode in ("outer", "exec"):
        if os.getppid() != int(parent):
            raise RuntimeError("parent-ended")
    if mode == "outer":
        os.set_inheritable(3, True)
        os.set_inheritable(4, True)
        os.execvp("unshare", ["unshare", "--map-current-user", "--pid", "--fork",
                             "--kill-child=KILL", "--", sys.executable, "-I",
                             __file__, "init", "0", *command])
    if mode == "exec":
        os.write(4, b"R")
        os.close(4)
        os.execvp(command[0], command)
    if mode != "init" or os.getpid() != 1:
        raise RuntimeError("namespace-init")
    # No tool starts if the outer parent's death raced unshare's fork.
    if os.read(3, 1) != b"S":
        raise RuntimeError("lease-ended")
    child = subprocess.Popen(
        ["setpriv", "--pdeathsig", "KILL", "--", sys.executable, "-I",
         __file__, "exec", str(os.getpid()), *command],
        env=dict(os.environ), pass_fds=(4,))
    os.close(4)
    selector = selectors.DefaultSelector()
    selector.register(3, selectors.EVENT_READ)
    while child.poll() is None:
        # This wait observes the lease while also reaping a naturally ended
        # tool. It is not a startup delay or a device-retry backoff.
        if selector.select(0.05):
            if os.read(3, 1) == b"":
                return 0
            raise RuntimeError("lease-data")
    return child.returncode if child.returncode >= 0 else 128 - child.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print("jarvis: audio-child=" + str(error), file=sys.stderr)
        sys.exit(70)
