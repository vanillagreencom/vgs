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
proven by `scripts/lib/tracked_blobs_selftest.py`, beside it, which drives every
failure this module must REFUSE rather than answer: a failed git call, an index
mid-merge, and a `cat-file` stream that desyncs, truncates or runs long.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import NamedTuple

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

# CONFIG injection, not repo location — a separate channel with its own reason
# to be here. `-C` does not override it and neither does GIT_CONFIG_GLOBAL or
# GIT_CONFIG_SYSTEM, so `GIT_CONFIG_PARAMETERS="'core.excludesFile'='/x'"` makes
# `git add -A` stage nothing while every other precaution holds. Git exports it
# into every hook and alias subprocess whenever `-c` is in play, which is the
# same reachability as the index escape above. Prefix names are matched rather
# than listed, because GIT_CONFIG_KEY_n/VALUE_n are unbounded in n.
GIT_CONFIG_INJECTORS = ("GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT")
GIT_CONFIG_PREFIXES = ("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")


def git_env(hermetic: bool = False) -> dict[str, str]:
    """The ambient environment with every repo-redirecting variable removed.

    `hermetic` also silences user and system config. That alone did NOT stop a
    fixture inheriting a `core.excludesFile` that quietly declines to add its own
    fixtures — `GIT_CONFIG_PARAMETERS` says the same thing through a channel
    those two do not cover, which is why it is scrubbed above.
    """
    env = {
        name: value
        for name, value in os.environ.items()
        if name not in GIT_REDIRECTS
        and name not in GIT_CONFIG_INJECTORS
        and not name.startswith(GIT_CONFIG_PREFIXES)
    }
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

# Blobs per `cat-file --batch` round. Bounds the bytes held at once without
# giving up batching, and 200 is where the curve flattens — measured over this
# repo's 9,748 blobs, identical results at every size (2,673 decoded, of which
# 2,585 are citers, and 7,075 undecodable):
#
#     whole stream   214 MB   0.182 s      100   107 MB   0.266 s
#              1000  127 MB   0.201 s      200   109 MB   0.244 s
#               500  124 MB   0.215 s
#
# The fork count stays in the tens rather than the thousands, and records are
# still zipped by ORDER within each round, so every integrity check below
# applies per chunk exactly as it did per sweep.
CHUNK = 200


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


class Entry(NamedTuple):
    """One tracked path as `git ls-files -s` describes it."""

    mode: str
    sha: str
    path: str


def tracked_entries(root: Path) -> list[Entry]:
    """Every tracked path, symlinks and all, at index stage 0.

    The full listing, unfiltered by mode: a caller's exclusion tables index on
    files, not on blobs, so a path excluded from READING must still be visible
    as TRACKED.

    A MID-MERGE INDEX IS REFUSED. During an unresolved merge `ls-files -s` emits
    the same path three times, at stages 1, 2 and 3 — base, ours, theirs — all
    with mode 100644. Reading them all left the last write standing, so the
    caller judged the THEIRS side: bytes that are in no commit, in no PR, and
    not on disk either, with no diagnostic and a blob count inflated by the
    duplicates. Refusing is the same posture this module takes for a failed git
    call: say why nothing can be concluded rather than answer about one side.
    """
    entries, conflicted = [], []
    for entry in git(root, "ls-files", "-s", "-z").decode("utf-8", "surrogateescape").split("\0"):
        if not entry:
            continue
        fields, path = entry.split("\t", 1)
        mode, sha, stage = fields.split(" ")
        if stage != "0":
            conflicted.append(path)
        else:
            entries.append(Entry(mode, sha, path))
    if conflicted:
        named = ", ".join(sorted(set(conflicted))[:5])
        raise GitError(
            f"the index is mid-merge: {len(set(conflicted))} path(s) are at a conflict "
            f"stage ({named}). Nothing here can be concluded from one side of an "
            f"unresolved merge — finish or abort it, then re-run"
        )
    return entries


def blob_texts(
    root: Path, entries: list[Entry]
) -> tuple[dict[str, str], dict[str, str]]:
    """(text by path, undecodable path -> reason) for the regular files in `entries`.

    The caller filters `entries` first; everything reaching here is read.

    ASKED IN CHUNKS, and the chunk size is the whole of the memory story. One
    `cat-file --batch` for all 9,748 blobs is correct in shape — per-blob forks
    would be thousands of processes — but capturing its 90.5 MB answer whole
    peaked at 215 MB RSS to keep 23.5 MB of text, because 74% of the stream is
    binary assets that decode-fail and are dropped. Chunking bounds the captured
    bytes to one round — 214 MB down to 109 — without giving up batching, and
    without the writer thread an incremental reader would need:
    `subprocess.run(input=...)` pumps stdin and stdout concurrently, so it cannot
    deadlock the way a hand-rolled close-stdin-then-read loop does. An
    incremental reader measured 83 MB; the remaining 26 is not worth a thread in
    a validation script.
    """
    files: dict[str, str] = {}
    undecodable: dict[str, str] = {}
    wanted_all = [(e.sha, e.path) for e in entries if e.mode in REGULAR_MODES]
    for start in range(0, len(wanted_all), CHUNK):
        _read_chunk(root, wanted_all[start : start + CHUNK], files, undecodable)
    # EVERY BLOB ASKED FOR LANDS IN EXACTLY ONE BUCKET — the partitioned-
    # collection shape collected.py calls `unaccounted`. The per-chunk checks
    # below are internally consistent by construction: ask git for 199 shas and
    # it answers 199 records, so a loop that slices one short per round is
    # invisible to all of them. Fifteen files then vanish from the sweep and the
    # count in the ok line is simply smaller, which nothing else can tell from a
    # repo that has fifteen fewer files. Only a per-SWEEP total sees it.
    if len(files) + len(undecodable) != len(wanted_all):
        raise GitError(
            f"{len(wanted_all)} blobs were asked for and "
            f"{len(files) + len(undecodable)} came back accounted for. The chunk loop "
            f"lost some between rounds, so the sweep is short by an amount no per-chunk "
            f"check can see — NOTHING can be concluded from it"
        )
    return files, undecodable


def _read_chunk(root, wanted, files: dict[str, str], undecodable: dict[str, str]) -> None:
    """One `cat-file --batch` round, appending into the caller's two maps."""
    stream = git(
        root, "cat-file", "--batch", stdin="".join(f"{sha}\n" for sha, _ in wanted).encode()
    )
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
