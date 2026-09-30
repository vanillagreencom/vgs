#!/usr/bin/env python3
"""One planted row per form check-smoke-terminal.py must find or pass, the
unreadable directories, and the repository's own rows. Each row builds a
throwaway rows directory holding one row, runs the check on it and asserts
the rule key, the line and the exit status."""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "check-smoke-terminal.py")
ROWS = os.path.join(HERE, "smoke", "rows")
ENV = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}

# rows: name, row text, expected finding line or None.
CASES = [
    ("a heredoc that writes its own stand-in", "set -euo pipefail\ncat >\"$shim/xdg-terminal-exec\" <<'EOF'\n#!/usr/bin/env bash\nEOF\n", 2),
    ("a copy over the stand-in", "cp -- \"$sandbox/mine\" \"$shim/xdg-terminal-exec\"\n", 1),
    ("a direct run of the stand-in", "terminal_stand_in\n\"$shim\"/xdg-terminal-exec -- sh -c true\n", 2),
    ("a comment naming the stand-in", "# the stand-in xdg-terminal-exec harness.sh writes\nterminal_stand_in\n", None),
    ("an indented comment naming it", "f() {\n  # records what xdg-terminal-exec was handed\n  :\n}\n", None),
    ("the harness's writer called", "terminal_stand_in windowless\n", None),
]

failures = 0


def run(args):
    return subprocess.run([sys.executable, CHECK, *args], capture_output=True, text=True, env=ENV)


def check(name, condition, result):
    global failures
    if condition:
        print(f"ok    {name}")
    else:
        failures += 1
        print(f"FAIL  {name}: exit={result.returncode}\n{result.stdout}{result.stderr}")


with tempfile.TemporaryDirectory() as tmp:
    for index, (name, text, line) in enumerate(CASES):
        rows = os.path.join(tmp, str(index), "rows")
        os.makedirs(rows)
        with open(os.path.join(rows, "row.sh"), "w") as row:
            row.write(text)
        result = run([rows])
        if line is None:
            check(name, result.returncode == 0 and result.stdout == "check-smoke-terminal: ok files=1\n", result)
        else:
            found = [l for l in result.stdout.splitlines() if not l.startswith("check-smoke-terminal:")]
            want = f"terminal-writer {os.path.join(rows, 'row.sh')}:{line}"
            check(name, result.returncode == 1 and found == [want], result)

    result = run([os.path.join(tmp, "missing")])
    check("a missing directory is unreadable", result.returncode == 2 and result.stdout.startswith("check-smoke-terminal: unreadable: "), result)
    empty = os.path.join(tmp, "empty")
    os.makedirs(empty)
    result = run([empty])
    check("a directory with no row is unreadable", result.returncode == 2 and result.stdout == f"check-smoke-terminal: unreadable: {empty}: no row found\n", result)

rows = sorted(n for n in os.listdir(ROWS) if n.endswith(".sh"))
result = run([])
check(f"the repository's {len(rows)} rows pass", len(rows) > 0 and result.returncode == 0 and result.stdout == f"check-smoke-terminal: ok files={len(rows)}\n", result)

if failures:
    print(f"test-check-smoke-terminal: failures={failures}")
    sys.exit(1)
print(f"test-check-smoke-terminal: ok cases={len(CASES) + 3}")
