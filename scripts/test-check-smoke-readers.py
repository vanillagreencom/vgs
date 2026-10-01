#!/usr/bin/env python3
"""One planted reader per rule of check-smoke-readers.py, the forms it must
pass, the unreadable directories, and the repository's own rows against a
coverage floor, with two required members: a copy of a notifications row
JSON reader running python3 itself, and a copy of the instance-guard row
running `qs list` itself. Each row builds a throwaway rows directory
holding one row, runs the check on it and asserts the exact set of rule
keys and lines, and the exit status."""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "check-smoke-readers.py")
ROWS = os.path.join(HERE, "smoke", "rows")
ENV = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}
READ = "import json,sys; print(json.load(sys.stdin))"

# rows: name, row text, the expected (rule key, line) findings.
CASES = [
    ("a probe reader through py_reply", f"r() {{ ipc smoke a | py_reply '{READ}'; }}\n", []),
    ("a program extending a quoted variable", f"r() {{ ipc smoke a | py_reply \"$prelude\"'{READ}' x; }}\n", []),
    ("a multi-line program", "r() { ipc smoke a | py_reply '\nimport json, sys\nd = json.load(sys.stdin)\nprint(d)'; }\n", []),
    ("json.loads over the whole stdin", "r() { ipc smoke a | py_reply 'import json,sys; print(json.loads(sys.stdin.read()))'; }\n", []),
    ("a shell comment naming the read", "# never json.load(sys.stdin) outside py_reply\nr() { :; }\n", []),
    ("a program that reads a file", "r() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])))' f; }\n", []),
    ("python3 counting text lines on stdin", "r() { ps -e | python3 -c 'import sys; print(sum(1 for l in sys.stdin if sys.argv[1] in l))' x; }\n", []),
    ("py_reply reading stdin as text, then parsing it", "r() { ipc smoke a | py_reply 'import json,sys; t=sys.stdin.read(); print(json.loads(t))'; }\n", []),
    ("python3 parses a probe reply", f"# a reader\nr() {{ ipc smoke a | python3 -c '{READ}'; }}\n", [("inline-reader", 2)]),
    ("python3 parses a compositor reply", f"r() {{ hypr -j clients | python3 -c '{READ}'; }}\n", [("inline-reader", 1)]),
    ("python3 parses a here-string", f"r() {{ python3 -c '{READ}' <<<\"$x\"; }}\n", [("inline-reader", 1)]),
    ("a multi-line python3 program", "r() { ipc smoke a | python3 -c '\nimport json, sys\nd = json.load(sys.stdin)\nprint(d)'; }\n", [("inline-reader", 3)]),
    ("python3 after a py_reply on the same line", f"r() {{ ipc smoke a | py_reply 'print(1)' | python3 -c '{READ}'; }}\n", [("inline-reader", 1)]),
    ("python3 reading stdin as text, then parsing it", "r() { ipc smoke a | python3 -c '\nimport json, sys\ntext = sys.stdin.read()\nprint(json.loads(text))'; }\n", [("inline-reader", 3)]),
    ("python3 decoding a stream of replies", "r() { { ipc smoke a; ipc smoke b; } | python3 -c 'import json,sys; t=sys.stdin.read(); print(json.JSONDecoder().raw_decode(t))'; }\n", [("inline-reader", 1)]),
    ("a python3 heredoc", "python3 - <<'PY'\nimport json, sys\nprint(json.load(sys.stdin))\nPY\n", [("inline-reader", 3)]),
    ("a program held in a variable", f"prog='{READ}'\nr() {{ ipc smoke a | py_reply \"$prog\"; }}\n", [("unowned-reader", 1)]),
    ("a read after py_reply's program closes", f"r() {{ ipc smoke a | py_reply 'print(1)' '{READ}'; }}\n", [("unowned-reader", 1)]),
    ("a read in a double-quoted program", "r() { ipc smoke a | py_reply \"import json,sys; print(json.load(sys.stdin))\"; }\n", [("unowned-reader", 1)]),
    ("a qs listing through qs_list", f"r() {{ qs_list -p x | py_reply '{READ}'; }}\n", []),
    ("a shell comment naming qs list", "# never qs list outside qs_list\nr() { :; }\n", []),
    ("a label saying qs lists", "expect \"qs lists the target\" 1 r\n", []),
    ("qs list read through py_reply", f"r() {{ :; }}\nc() {{ qs list -p x -j | py_reply '{READ}'; }}\n", [("raw-qs-list", 2)]),
    ("qs list read by python3", f"r() {{ qs list --all -j | python3 -c '{READ}'; }}\n", [("raw-qs-list", 1), ("inline-reader", 1)]),
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


def findings(result):
    found = []
    for line in result.stdout.splitlines():
        if not line.startswith("check-smoke-readers:"):
            rule, where = line.split(" ", 2)[:2]
            found.append((rule, where))
    return sorted(found)


def plant(root, text):
    rows = os.path.join(root, "rows")
    os.makedirs(rows, exist_ok=True)
    with open(os.path.join(rows, "row.sh"), "w") as row:
        row.write(text)
    return rows


with tempfile.TemporaryDirectory() as tmp:
    for index, (name, text, expected) in enumerate(CASES):
        rows = plant(os.path.join(tmp, str(index)), text)
        result = run([rows])
        if not expected:
            check(name, result.returncode == 0 and result.stdout.startswith("check-smoke-readers: ok files=1 "), result)
        else:
            want = sorted((rule, f"{os.path.join(rows, 'row.sh')}:{line}") for rule, line in expected)
            check(name, result.returncode == 1 and findings(result) == want, result)

    result = run([os.path.join(tmp, "missing")])
    check("a missing directory is unreadable", result.returncode == 2 and result.stdout.startswith("check-smoke-readers: unreadable: "), result)
    empty = os.path.join(tmp, "empty")
    os.makedirs(empty)
    result = run([empty])
    check("a directory with no row is unreadable", result.returncode == 2 and "no row found" in result.stdout, result)
    result = run([empty, empty])
    check("a second directory is refused", result.returncode == 2 and result.stdout.startswith("check-smoke-readers: refused: argument="), result)

    # The repository's rows pass, above a floor of the files and readers
    # they held when the rule landed, 39 rows and 264 reads, less a margin
    # for rows that go; a walk below it is a broken extractor, not a clean
    # tree.
    result = run([])
    counts = re.fullmatch(r"check-smoke-readers: ok files=(\d+) readers=(\d+)\n", result.stdout)
    check("the repository's rows pass above the coverage floor", result.returncode == 0 and counts is not None and int(counts.group(1)) >= 30 and int(counts.group(2)) >= 200, result)

    # The required member: a notifications row JSON reader, reverted to
    # python3 in a copy, is found where the row defines it.
    with open(os.path.join(ROWS, "notifications.sh")) as source:
        text = source.read()
    reader = "drawn_images() { ipc smoke layerItems vgs.notifications QQuickText text,visible | py_reply '"
    if text.count(reader) != 1:
        print(f"FAIL  the emoji reader is not defined once in {ROWS}/notifications.sh: the required member moved")
        failures += 1
    else:
        mutant = text.replace(reader, reader.replace("py_reply", "python3 -c"))
        rows = plant(os.path.join(tmp, "mutant"), mutant)
        result = run([rows])
        line = text[:text.index(reader)].count("\n") + 1
        want = [("inline-reader", f"{os.path.join(rows, 'row.sh')}:{line}")]
        check("the notifications JSON reader run through python3 is refused", result.returncode == 1 and findings(result) == want, result)

    # The required member: the instance-guard row's listing, reverted to a
    # raw qs list in a copy, is found where the row defines it.
    with open(os.path.join(ROWS, "instance-guard.sh")) as source:
        text = source.read()
    listing = 'instance_count() { qs_list -p "$1" |'
    if text.count(listing) != 1:
        print(f"FAIL  instance_count is not defined once in {ROWS}/instance-guard.sh: the required member moved")
        failures += 1
    else:
        mutant = text.replace(listing, 'instance_count() { "${shell_env[@]}" qs list -p "$repo/shell" -j 2>/dev/null |')
        rows = plant(os.path.join(tmp, "qs-list-mutant"), mutant)
        result = run([rows])
        line = text[:text.index(listing)].count("\n") + 1
        want = [("raw-qs-list", f"{os.path.join(rows, 'row.sh')}:{line}")]
        check("the instance-guard listing run through qs list is refused", result.returncode == 1 and findings(result) == want, result)

if failures:
    print(f"test-check-smoke-readers: failures={failures}")
    sys.exit(1)
print("test-check-smoke-readers: ok")
