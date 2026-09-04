"""Read indexed file blobs without following working-tree paths.

Blob reads prevent symlinks from redirecting a scan to host files or devices.
Undecodable content is returned with its cause for the caller to classify.
Git failures, unresolved index stages and malformed batch streams raise.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import NamedTuple

# Repository redirection variables can override git -C and target another index.
GIT_REDIRECTS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CEILING_DIRECTORIES",
)

# Config injection is independent of repository location. Prefix matching covers
# numbered GIT_CONFIG_KEY and GIT_CONFIG_VALUE variables.
GIT_CONFIG_INJECTORS = ("GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT")
GIT_CONFIG_PREFIXES = ("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")


def git_env(hermetic: bool = False) -> dict[str, str]:
    """Return the environment with known git repository and config redirects removed.

    hermetic also disables user and system configuration.
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

# Symlink blobs contain link paths; submodule gitlinks have no local file blob.
REGULAR_MODES = {"100644", "100755"}

# Limit blobs per batch so captured output does not hold the whole repository.
CHUNK = 200


class GitError(SystemExit):
    """A git call that failed, or answered something no caller can act on."""


def git(root: Path, *arguments: str, stdin: bytes | None = None) -> bytes:
    """Run git in root, check its status and return stdout bytes.

    Callers decode paths with surrogateescape to preserve non-UTF-8 path bytes.
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
    """Return all indexed paths at stage zero, regardless of mode.

    Unresolved merge stages raise so the caller does not select one conflict side.
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
    """Return text and decoding failures for regular indexed entries.

    Reject other modes so callers account for excluded paths. Batch reads limit
    captured output to a chunk; subprocess.run pumps input and output concurrently.
    """
    files: dict[str, str] = {}
    undecodable: dict[str, str] = {}
    irregular = [e for e in entries if e.mode not in REGULAR_MODES]
    if irregular:
        raise GitError(
            f"{len(irregular)} of {len(entries)} entries are not regular files "
            f"(first: {irregular[0].path}, mode {irregular[0].mode}). Deciding what to "
            f"read is the caller's, and dropping them here would hide the category"
        )
    wanted_all = [(e.sha, e.path) for e in entries]
    for start in range(0, len(wanted_all), CHUNK):
        _read_chunk(root, wanted_all[start : start + CHUNK], files, undecodable)
    # Per-batch integrity cannot detect entries omitted before the batch call.
    # Account for every requested entry across the complete sweep.
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
        # Records pair by order because distinct paths can share a blob. Validate
        # echoed identity and length before assigning text to a path.
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
        try:
            size = int(header[2])
        except ValueError:
            raise GitError(
                f"`git cat-file --batch` gave a size of '{header[2]}' for {path} "
                f"({sha}), which is not a number. NOTHING can be read past a record "
                f"whose length cannot be known"
            ) from None
        blob = stream[end + 1 : end + 1 + size]
        # A slice beyond the buffer end does not raise on a truncated final record.
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
