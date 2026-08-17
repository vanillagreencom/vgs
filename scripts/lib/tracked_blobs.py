"""Read what git TRACKS, never what the working tree happens to hold.

Split out of `scripts/check-section-pointers.py`, which is about pointers and
should not also be about how bytes are obtained. The rule here is one sentence
with a security answer behind it:

    a check that asks "what does this repo contain?" must read the blob, not
    the path.

`Path.read_text()` FOLLOWS SYMLINKS, and 8,509 of this repo's tracked paths are
symlinks. Reading paths meant the pointer guard read `.claude/CLAUDE.md` straight
through to AGENTS.md and counted one file's pointers twice; it also meant a PR
could add a small tracked link to a host file, or to an endless device such as
/dev/zero, and have a CI step read it before the size ratchet ever saw the diff.
A blob cannot be redirected anywhere.

It removes an error arm as well. Reading paths needs `except OSError`, which
catches the one case a caller wants to skip — here a symlink to a directory —
along with every case it must not: a dangling link, a permission error, a path
absent from the checkout. Each of those dropped a file silently while the check
printed ok. Reading blobs leaves exactly ONE skip, a blob that is not UTF-8
text, and that one is RETURNED rather than discarded so the caller can decide
whether a given non-text file is a binary to ignore or a defect to report.

No `__main__` and no executable bit: a library reached only by import, like
`scripts/lib/collected.py`, so it carries no manifest row. Its behaviour is
proven by the must-fail controls its caller owns — `scripts/test-section-
pointers-e2e.py` tracks a clean file, rewrites it on disk, and asserts the guard
still judges the tracked bytes.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

# Environment variables that RE-AIM git at another repository. Every one is
# deleted before any git call here, because `-C <path>` does NOT override them:
# an absolute `GIT_INDEX_FILE` pointed elsewhere makes `git -C fixture add -A`
# write the fixture's paths into THAT repository's index, leaving it referencing
# blobs that live in the fixture's object store — `git status` there then answers
# `fatal: unable to read <sha>`. Verified both directions before this was
# written: the RELATIVE `GIT_INDEX_FILE=.git/index` that git exports to hooks is
# re-resolved by `-C` and is harmless, and git exports neither GIT_DIR nor
# GIT_WORK_TREE to hooks at all. So the trigger is an ABSOLUTE variable — the
# shape of tooling that drives a checkout other than its own, which is the
# pattern this repo's `.worktrees/` layout uses.
GIT_REDIRECTS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CEILING_DIRECTORIES",
)


def git_env(hermetic: bool = False) -> dict[str, str]:
    """The ambient environment with every repo-redirecting variable removed.

    `hermetic` also silences user and system config, so a fixture repository
    cannot inherit a `core.excludesFile` that quietly declines to add its own
    fixtures.
    """
    env = {name: value for name, value in os.environ.items() if name not in GIT_REDIRECTS}
    if hermetic:
        env["GIT_CONFIG_GLOBAL"] = os.devnull
        env["GIT_CONFIG_SYSTEM"] = os.devnull
    return env

# Index modes worth reading. 120000 is a SYMLINK, whose blob is the link target
# — a path, not prose — and 160000 a submodule gitlink, which has no blob here.
#
# THIS IS SCOPE, NOT SAFETY, and the distinction matters: sweeping a symlink's
# blob would be harmless noise, because a blob is what gets read. What makes a
# link safe is `cat-file` below, not this set. Widening it back would not
# reintroduce the hazard, so nothing here pretends to guard one.
REGULAR_MODES = {"100644", "100755"}


class GitError(SystemExit):
    """A git call that failed, or answered something no caller can act on."""


def git(root: Path, *arguments: str, stdin: bytes | None = None) -> bytes:
    """Run git in `root` and return stdout, with its exit status checked.

    Paths decode with `surrogateescape` at every call site rather than the
    default strict: git hands back raw bytes, and a path that is not valid UTF-8
    would otherwise abort the caller with a traceback about decoding rather than
    anything to do with its own subject. `surrogateescape` round-trips such a
    path exactly and never raises — the same "diagnose, do not crash" posture as
    the stderr decode below (VGS-110: a collection step checks its producer).
    """
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        input=stdin,
        capture_output=True,
        check=False,
        env=git_env(),
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise GitError(
            f"`git {' '.join(arguments)}` failed ({result.returncode}): {detail}. "
            f"NOTHING was read, so this is not a clean result"
        )
    return result.stdout


def tracked_entries(root: Path) -> list[tuple[str, str, str]]:
    """(mode, blob sha, path) for every tracked path, symlinks and all.

    The full listing, unfiltered: a caller's exclusion tables index on files, not
    on blobs, so a path excluded from READING must still be visible as TRACKED.
    """
    entries = []
    for entry in git(root, "ls-files", "-s", "-z").decode("utf-8", "surrogateescape").split("\0"):
        if not entry:
            continue
        fields, path = entry.split("\t", 1)
        mode, sha, _stage = fields.split(" ")
        entries.append((mode, sha, path))
    return entries


def blob_texts(
    root: Path, entries: list[tuple[str, str, str]]
) -> tuple[dict[str, str], dict[str, str]]:
    """(text by path, undecodable path -> reason) for the regular files in `entries`.

    The caller filters `entries` first; everything reaching here is read.
    """
    wanted = [(sha, path) for mode, sha, path in entries if mode in REGULAR_MODES]
    if not wanted:
        return {}, {}

    # One `cat-file --batch` for the whole sweep: per-blob processes would be
    # thousands of forks. Records come back in the order the shas went in, so
    # they are zipped against `wanted` rather than keyed by sha — two identical
    # files share one sha and would otherwise collapse into a single entry.
    stream = git(
        root, "cat-file", "--batch", stdin="".join(f"{sha}\n" for sha, _ in wanted).encode()
    )
    files: dict[str, str] = {}
    undecodable: dict[str, str] = {}
    offset = 0
    for sha, path in wanted:
        end = stream.find(b"\n", offset)
        if end == -1:
            raise GitError(
                f"`git cat-file --batch` ended before {path}. NOTHING can be "
                f"concluded from a truncated read"
            )
        header = stream[offset:end].decode("utf-8", "replace").split()
        # EVERY FIELD GIT ECHOES IS CHECKED, because the pairing is positional.
        # Records are zipped against `wanted` by ORDER — keying by sha would
        # collapse two identical files into one entry — so the echoed sha, type
        # and length are the only evidence the order actually held. Without them
        # a desynced stream pairs each path with a DIFFERENT file's text, and
        # the guard reports findings against paths that never carried them.
        if len(header) != 3:
            raise GitError(
                f"`git cat-file --batch` answered '{' '.join(header)}' for {path} "
                f"({sha}), which is not a blob record"
            )
        if header[0] != sha or header[1] != "blob":
            raise GitError(
                f"`git cat-file --batch` answered for {header[0]} ({header[1]}) where "
                f"{sha} (blob) was asked, at {path}. The stream has desynced, so every "
                f"path after this one would carry another file's text"
            )
        size = int(header[2])
        blob = stream[end + 1 : end + 1 + size]
        # Slicing past the end CANNOT raise, so a truncated final record would
        # otherwise arrive as a short but complete-looking string; the `end == -1`
        # guard above only fires for a record that has a successor.
        if len(blob) != size:
            raise GitError(
                f"`git cat-file --batch` declared {size} bytes for {path} and sent "
                f"{len(blob)}. NOTHING can be concluded from a truncated read"
            )
        offset = end + 1 + size + 1
        try:
            files[path] = blob.decode("utf-8")
        except UnicodeDecodeError as error:
            undecodable[path] = f"not UTF-8 text ({error.reason} at byte {error.start})"
    if offset != len(stream):
        raise GitError(
            f"`git cat-file --batch` sent {len(stream) - offset} bytes beyond the "
            f"{len(wanted)} records asked for, so the stream and the request do not "
            f"describe the same thing"
        )
    return files, undecodable
