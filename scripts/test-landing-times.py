#!/usr/bin/env python3
"""Controls for scripts/landing-times.py.

Each row runs the script against a stand-in `gh` first on PATH, which
answers `gh api` from a table of canned responses the row plants and fails
any endpoint the table lacks, so no row reads GitHub. The rows cover a
two-page activity feed read through its Link header, the landing kinds and
the ones passed over, the push's first and latest commit, the pull
request's creation, the medians, fewer landings than asked for, an
unreadable compare, a truncated compare, an unreadable feed and a missing
gh. The controls run copies of the script with one rule removed, each of
which a row must fail: the Link header not followed, the first commit taken
as the latest, a force push counted as a landing, and a truncated compare
measured.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "landing-times.py")
REPO = "acme/shell"
PYTHON = sys.executable

STUB = r'''#!PYTHON
import json, os, sys
table = json.load(open(os.environ["STUB_TABLE"]))
args = sys.argv[1:]
if args[:1] == ["repo"]:
    print(table.get("repo", "acme/shell")); sys.exit(0)
if args[:1] != ["api"]:
    sys.exit(3)
include = "--include" in args
endpoint = [a for a in args[1:] if a != "--include"][0]
answer = table["api"].get(endpoint)
if answer is None:
    sys.stderr.write("stub gh: no answer for " + endpoint + "\n"); sys.exit(1)
if include:
    sys.stdout.write("HTTP/2.0 200 OK\r\n")
    if answer.get("next"):
        sys.stdout.write('Link: <' + answer["next"] + '>; rel="next", <https://api.github.com/x?page=9>; rel="last"\r\n')
    sys.stdout.write("\r\n")
sys.stdout.write(json.dumps(answer["body"]))
'''

failures = []


def ok(name):
    print(f"  ok    {name}")


def fail(name, detail):
    failures.append(name)
    print(f"  FAIL  {name}: {detail}")


def commit(date):
    return {"commit": {"author": {"date": date}}}


def activity(kind, before, after, timestamp):
    return {"activity_type": kind, "before": before, "after": after, "timestamp": timestamp}


FEED = f"repos/{REPO}/activity?ref=refs/heads/main&per_page=100"
PAGE2 = f"https://api.github.com/repositories/1/activity?ref=refs%2Fheads%2Fmain&per_page=100&after=CURSOR"
A, B, C, D, E, F = ("a" * 40, "b" * 40, "c" * 40, "d" * 40, "e" * 40, "f" * 40)


def base_table():
    """Page one: a push, a force push and a branch creation; page two: a
    pull request merge and an older push."""
    return {
        FEED: {"next": PAGE2, "body": [
            activity("push", B, C, "2026-09-30T12:00:00Z"),
            activity("force_push", A, E, "2026-09-30T11:30:00Z"),
            activity("branch_creation", "0" * 40, F, "2026-09-30T11:20:00Z"),
        ]},
        PAGE2: {"body": [
            activity("pr_merge", A, B, "2026-09-30T11:00:00Z"),
            activity("push", D, A, "2026-09-30T10:00:00Z"),
        ]},
        f"repos/{REPO}/compare/{B}...{C}": {"body": {"total_commits": 3, "commits": [
            commit("2026-09-30T10:30:00Z"), commit("2026-09-30T09:00:00Z"), commit("2026-09-30T11:00:00Z")]}},
        f"repos/{REPO}/compare/{A}...{E}": {"body": {"total_commits": 1, "commits": [commit("2026-09-30T11:25:00Z")]}},
        f"repos/{REPO}/commits/{B}/pulls": {"body": [
            {"number": 7, "merge_commit_sha": "9" * 40, "created_at": "2026-09-29T00:00:00Z"},
            {"number": 8, "merge_commit_sha": B, "created_at": "2026-09-30T10:30:00Z"}]},
        f"repos/{REPO}/compare/{D}...{A}": {"body": {"total_commits": 1, "commits": [commit("2026-09-30T09:40:00Z")]}},
    }


def run(script, table, args, gh=True):
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = os.path.join(tmp, "bin")
        os.mkdir(bin_dir)
        if gh:
            stub = os.path.join(bin_dir, "gh")
            with open(stub, "w") as handle:
                handle.write(STUB.replace("PYTHON", PYTHON, 1))
            os.chmod(stub, 0o755)
        table_path = os.path.join(tmp, "table.json")
        with open(table_path, "w") as handle:
            json.dump({"api": table}, handle)
        env = {"PATH": bin_dir, "HOME": tmp, "LC_ALL": "C", "STUB_TABLE": table_path}
        done = subprocess.run([PYTHON, script] + args, capture_output=True, text=True, env=env)
        return done.returncode, done.stdout.splitlines(), done.stderr


def expect(name, script, table, args, want_exit, lines, gh=True, quiet=False):
    """Run and assert the exit status and that each line is a whole line of
    the output. Returns whether the row held; quiet rows report nothing,
    for the controls."""
    status, out, err = run(script, table, args, gh)
    missing = [line for line in lines if line not in out]
    held = status == want_exit and not missing
    if not quiet:
        if held:
            ok(name)
        else:
            fail(name, f"exit={status} want={want_exit} missing={missing} out={out} err={err.strip()}")
    return held


def rows(script, quiet=False):
    """Every row, run against SCRIPT. Returns the names of rows that failed."""
    failed = []

    def row(name, *args, **kwargs):
        if not expect(name, script, *args, quiet=quiet, **kwargs):
            failed.append(name)

    row("three landings over two pages: a push, a pull request and a push, newest first",
        base_table(), ["--last", "3", "--repo", REPO], 0, [
            f"landing={C[:12]} kind=push opened=2026-09-30T09:00:00Z landed=2026-09-30T12:00:00Z minutes=180.0 wait_minutes=60.0 commits=3",
            f"landing={B[:12]} kind=pr pr=8 opened=2026-09-30T10:30:00Z landed=2026-09-30T11:00:00Z minutes=30.0 wait_minutes=30.0",
            f"landing={A[:12]} kind=push opened=2026-09-30T09:40:00Z landed=2026-09-30T10:00:00Z minutes=20.0 wait_minutes=20.0 commits=1",
            f"landing-times: repo={REPO} branch=main landings=3 measured=3 median_minutes=30.0 push_median_minutes=100.0 pr_median_minutes=30.0 median_wait_minutes=30.0 min_minutes=20.0 max_minutes=180.0",
        ])
    row("the newest landing alone reads only the first page",
        {k: v for k, v in base_table().items() if k != PAGE2}, ["--last", "1", "--repo", REPO], 0, [
            f"landing-times: repo={REPO} branch=main landings=1 measured=1 median_minutes=180.0 push_median_minutes=180.0 pr_median_minutes=- median_wait_minutes=60.0 min_minutes=180.0 max_minutes=180.0",
        ])
    row("the repository defaults to the one gh resolves",
        base_table(), ["--last", "1"], 0, [
            f"landing-times: repo={REPO} branch=main landings=1 measured=1 median_minutes=180.0 push_median_minutes=180.0 pr_median_minutes=- median_wait_minutes=60.0 min_minutes=180.0 max_minutes=180.0",
        ])
    row("fewer landings than asked for is not measured",
        base_table(), ["--last", "5", "--repo", REPO], 77, [
            f"landing-times: repo={REPO} branch=main landings=3 measured=3 median_minutes=30.0 push_median_minutes=100.0 pr_median_minutes=30.0 median_wait_minutes=30.0 min_minutes=20.0 max_minutes=180.0",
        ])
    unreadable = base_table()
    del unreadable[f"repos/{REPO}/compare/{B}...{C}"]
    row("a push whose compare cannot be read is named and not measured",
        unreadable, ["--last", "3", "--repo", REPO], 77, [
            f"landing={C[:12]} kind=push status=not-measured reason=gh-api endpoint=repos/{REPO}/compare/{B}...{C} status=1 stub gh: no answer for repos/{REPO}/compare/{B}...{C}",
            f"landing-times: repo={REPO} branch=main landings=3 measured=2 median_minutes=25.0 push_median_minutes=20.0 pr_median_minutes=30.0 median_wait_minutes=25.0 min_minutes=20.0 max_minutes=30.0",
        ])
    truncated = base_table()
    truncated[f"repos/{REPO}/compare/{B}...{C}"]["body"]["total_commits"] = 300
    row("a compare that lists fewer commits than it holds is not measured",
        truncated, ["--last", "1", "--repo", REPO], 77, [
            f"landing={C[:12]} kind=push status=not-measured reason=commits-truncated total=300 listed=3",
        ])
    row("an unreadable activity feed is not measured",
        {}, ["--last", "1", "--repo", REPO], 77, [
            f"landing-times: status=not-measured reason=gh-api endpoint={FEED} status=1 stub gh: no answer for {FEED}",
        ])
    row("no gh is not measured", {}, ["--repo", REPO], 77,
        ["landing-times: status=not-measured reason=gh-missing"], gh=False)
    row("a count below one is refused", {}, ["--last", "0", "--repo", REPO], 2, [])
    return failed


print("landing-times rows")
rows(SCRIPT)

# Each control removes one rule from a copy of the script; the rows must
# then fail, or the rule is not covered.
controls = [
    ("the Link header not followed", "    while endpoint and len(found) < last:\n        page, endpoint = gh_api(endpoint, with_next=True)",
     "    while endpoint and len(found) < last:\n        page, _ = gh_api(endpoint, with_next=True)\n        endpoint = None"),
    ("the first commit taken as the latest", '"opened": min(dates)', '"opened": max(dates)'),
    ("a force push counted as a landing", 'LANDING_KINDS = {"push": "push",', 'LANDING_KINDS = {"push": "push", "force_push": "push",'),
    ("a truncated compare measured", 'if compare.get("total_commits", len(dates)) > len(dates):', "if False:"),
]
source = open(SCRIPT).read()
print("landing-times controls")
with tempfile.TemporaryDirectory() as tmp:
    for name, old, new in controls:
        if source.count(old) != 1:
            fail(f"control: {name}", "the rule's text was not found once in the script")
            continue
        copy = os.path.join(tmp, "landing-times.py")
        with open(copy, "w") as handle:
            handle.write(source.replace(old, new))
        if rows(copy, quiet=True):
            ok(f"control: {name} fails a row")
        else:
            fail(f"control: {name}", "every row still passed")

if failures:
    print(f"test-landing-times: failed={len(failures)}")
    sys.exit(1)
print("test-landing-times: ok")
