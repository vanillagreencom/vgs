#!/usr/bin/env python3
"""Report how long the last landings on a branch took, from open to land.

  scripts/landing-times.py [--last N] [--repo OWNER/REPO] [--branch NAME]

A landing is one entry of GitHub's repository activity for the branch
(`GET /repos/{repo}/activity?ref=refs/heads/{branch}`): a `push`, the way a
lane fast-forwards main, or a `pr_merge` or `merge_queue_merge`, the way a
pull request lands. Branch creation, deletion and force pushes are not
landings and are passed over. The activity feed holds about the last 90 days.

  - A push opened at the earliest author date among the commits it added,
    read from the compare of its before and after commits: the first commit
    of the work it landed. A rebase keeps author dates.
  - A pull request opened when it was created, read from the pull request
    the merge commit belongs to.
  - Both landed at the activity's timestamp.
  - Ready is when the work was done: a push's latest commit author date, a
    pull request's creation. Wait, ready to land, is the time validation,
    review and landing added after the work.

Output, one line per landing, newest first, then a summary:

  landing=<sha12> kind=push|pr [pr=<n>] opened=<iso> landed=<iso> minutes=<m> wait_minutes=<m> [commits=<n>]
  landing=<sha12> kind=push|pr status=not-measured reason=<what>
  landing-times: repo=<r> branch=<b> landings=<N> measured=<M> median_minutes=<m> push_median_minutes=<m> pr_median_minutes=<m> median_wait_minutes=<m> min_minutes=<m> max_minutes=<m>

A median with no reading prints `-`. Minutes carry one decimal. Every read
goes through `gh api`, so the caller's gh login decides what it can see.

Exit 0 when every one of the N landings was measured. Exit 77 when gh is
missing or the activity feed cannot be read, or when a landing could not be
measured or fewer than N landings exist; the summary still prints. Exit 2 on
invalid arguments.
"""
import argparse
import json
import shutil
import statistics
import subprocess
import sys
from datetime import datetime

LANDING_KINDS = {"push": "push", "pr_merge": "pr", "merge_queue_merge": "pr"}
PAGE = 100


class Unreadable(Exception):
    pass


def gh_api(endpoint, with_next=False):
    """The JSON body of one `gh api` read. With with_next, also the URL the
    response's Link header names as rel="next", or None."""
    argv = ["gh", "api", "--include", endpoint] if with_next else ["gh", "api", endpoint]
    done = subprocess.run(argv, capture_output=True, text=True)
    if done.returncode != 0:
        raise Unreadable(f"gh-api endpoint={endpoint} status={done.returncode} {done.stderr.strip()}")
    body, next_url = done.stdout, None
    if with_next:
        head, _, body = done.stdout.replace("\r\n", "\n").partition("\n\n")
        for line in head.split("\n"):
            name, _, value = line.partition(":")
            if name.strip().lower() != "link":
                continue
            for link in value.split(","):
                target, _, rel = link.partition(";")
                if 'rel="next"' in rel:
                    next_url = target.strip().strip("<>")
    try:
        data = json.loads(body)
    except json.JSONDecodeError as error:
        raise Unreadable(f"gh-api endpoint={endpoint} json={error.msg}")
    return (data, next_url) if with_next else data


def parse_time(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def minutes(opened, landed):
    return round((landed - opened).total_seconds() / 60, 1)


def fmt(value):
    return "-" if value is None else f"{value:.1f}"


def median(values):
    return statistics.median(values) if values else None


def landings(repo, branch, last):
    """The newest `last` landing activities, newest first. The feed is read
    page by page, following its Link header, until enough landings are
    found or it ends."""
    found = []
    endpoint = f"repos/{repo}/activity?ref=refs/heads/{branch}&per_page={PAGE}"
    while endpoint and len(found) < last:
        page, endpoint = gh_api(endpoint, with_next=True)
        if not isinstance(page, list):
            raise Unreadable("gh-api activity shape=not-a-list")
        found.extend(entry for entry in page if entry.get("activity_type") in LANDING_KINDS)
    return found[:last]


def measure(repo, entry):
    kind = LANDING_KINDS[entry["activity_type"]]
    after = entry.get("after") or ""
    landed = parse_time(entry["timestamp"])
    head = {"sha": after[:12], "kind": kind, "landed": landed}
    if kind == "pr":
        pulls = gh_api(f"repos/{repo}/commits/{after}/pulls")
        merged = [pull for pull in pulls if pull.get("merge_commit_sha") == after] or pulls
        if not merged:
            return {**head, "reason": "no-pull-request"}
        pull = merged[0]
        opened = parse_time(pull["created_at"])
        return {**head, "pr": pull["number"], "opened": opened, "ready": opened, "commits": None}
    before = entry.get("before") or ""
    if not before.strip("0"):
        return {**head, "reason": "no-before-commit"}
    compare = gh_api(f"repos/{repo}/compare/{before}...{after}")
    dates = [parse_time(commit["commit"]["author"]["date"]) for commit in compare.get("commits", [])]
    if not dates:
        return {**head, "reason": "no-commits"}
    if compare.get("total_commits", len(dates)) > len(dates):
        return {**head, "reason": f"commits-truncated total={compare['total_commits']} listed={len(dates)}"}
    return {**head, "opened": min(dates), "ready": max(dates), "commits": len(dates)}


def default_repo():
    done = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], capture_output=True, text=True)
    if done.returncode != 0 or not done.stdout.strip():
        raise Unreadable(f"repo=unresolved {done.stderr.strip()}")
    return done.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--last", type=int, default=10)
    parser.add_argument("--repo")
    parser.add_argument("--branch", default="main")
    args = parser.parse_args()
    if args.last < 1:
        parser.error("--last must be a positive integer")
    if shutil.which("gh") is None:
        print("landing-times: status=not-measured reason=gh-missing")
        return 77
    try:
        repo = args.repo or default_repo()
        entries = landings(repo, args.branch, args.last)
    except Unreadable as error:
        print(f"landing-times: status=not-measured reason={error}")
        return 77
    readings = []
    for entry in entries:
        try:
            result = measure(repo, entry)
        except Unreadable as error:
            result = {"sha": (entry.get("after") or "")[:12], "kind": LANDING_KINDS[entry["activity_type"]], "reason": str(error).splitlines()[0]}
        except (KeyError, TypeError, ValueError) as error:
            result = {"sha": (entry.get("after") or "")[:12], "kind": LANDING_KINDS[entry["activity_type"]], "reason": f"shape={type(error).__name__}:{error}"}
        if "reason" in result:
            print(f"landing={result['sha']} kind={result['kind']} status=not-measured reason={result['reason']}")
            continue
        taken = minutes(result["opened"], result["landed"])
        wait = minutes(result["ready"], result["landed"])
        readings.append((result["kind"], taken, wait))
        pr = f" pr={result['pr']}" if "pr" in result else ""
        commits = "" if result["commits"] is None else f" commits={result['commits']}"
        print(f"landing={result['sha']} kind={result['kind']}{pr} opened={iso(result['opened'])} landed={iso(result['landed'])} minutes={taken:.1f} wait_minutes={wait:.1f}{commits}")
    values = [taken for _, taken, _ in readings]
    summary = {
        "median_minutes": median(values),
        "push_median_minutes": median([taken for kind, taken, _ in readings if kind == "push"]),
        "pr_median_minutes": median([taken for kind, taken, _ in readings if kind == "pr"]),
        "median_wait_minutes": median([wait for _, _, wait in readings]),
        "min_minutes": min(values) if values else None,
        "max_minutes": max(values) if values else None,
    }
    fields = " ".join(f"{key}={fmt(value)}" for key, value in summary.items())
    print(f"landing-times: repo={repo} branch={args.branch} landings={len(entries)} measured={len(readings)} {fields}")
    return 0 if len(readings) == args.last else 77


if __name__ == "__main__":
    sys.exit(main())
