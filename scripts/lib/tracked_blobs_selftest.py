"""Controls for indexed blob reads and git isolation.

Exercise git failures, unresolved merges and malformed batch streams. Stub
git for stream errors that a real git process cannot emit on demand.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import tracked_blobs  # noqa: E402

REPO_ROOT = HERE.parents[1]

def blob_controls() -> list[str]:
    """Require git failure and missing-blob errors to raise."""
    failures: list[str] = []
    # Assert that this temporary directory is outside a repository. Git can walk
    # to an ancestor when TMPDIR is inside a checkout.
    with tempfile.TemporaryDirectory() as absent:
        outside = subprocess.run(
            ["git", "-C", absent, "rev-parse", "--show-toplevel"],
            capture_output=True, env=tracked_blobs.git_env(),
        )
        if outside.returncode == 0:
            failures.append(
                f"the not-a-repository fixture is inside a repository "
                f"({outside.stdout.decode().strip()}), so the arm below would accuse "
                f"tracked_blobs of what the fixture did. Point TMPDIR outside a checkout"
            )
        else:
            try:
                tracked_blobs.git(Path(absent), "ls-files", "-s", "-z")
            except SystemExit as error:
                if "NOTHING was read" not in str(error):
                    failures.append(f"git failing did not say nothing was read: {error}")
            else:
                failures.append(
                    "git exiting non-zero returned normally, so a listing that never "
                    "happened is indistinguishable from a tree with no files in it"
                )

    # `cat-file --batch` answers "<sha> missing" for an object that is not
    # there, which is two fields where a blob record has three. Reading on would
    # take the next file's bytes as this one's content.
    try:
        tracked_blobs.blob_texts(
            REPO_ROOT, [tracked_blobs.Entry("100644", "0" * 40, "ghost.md")]
        )
    except SystemExit as error:
        if "not a blob record" not in str(error):
            failures.append(f"a missing object was not named as such: {error}")
    except Exception as error:  # noqa: BLE001 - a reader defect must still read as one
        failures.append(
            f"a missing object escaped as {type(error).__name__}: {error}. The record "
            f"is checked so the operator gets a sentence, not a traceback"
        )
    else:
        failures.append(
            "a sha with no object behind it was accepted, so cat-file's answer is "
            "parsed as content and every file after it shifts"
        )
    # Use a real merge conflict to test refusal of nonzero index stages.
    with tempfile.TemporaryDirectory() as workdir:
        root = Path(workdir)
        env = tracked_blobs.git_env(hermetic=True)
        run = lambda *a: subprocess.run(  # noqa: E731 - one shape, five call sites
            ["git", "-C", str(root), *a], check=True, env=env, capture_output=True
        )
        run("init", "-q")
        (root / "f.md").write_text("# base\n", encoding="utf-8")
        run("add", "-A")
        run("-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "base")
        run("checkout", "-q", "-b", "other")
        (root / "f.md").write_text("# theirs\n", encoding="utf-8")
        run("add", "-A")
        run("-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "theirs")
        run("checkout", "-q", "-")
        (root / "f.md").write_text("# ours\n", encoding="utf-8")
        run("add", "-A")
        run("-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "ours")
        # The isolated git config needs an identity to begin a merge.
        merge = subprocess.run(
            ["git", "-C", str(root), "-c", "user.email=a@b", "-c", "user.name=a",
             "merge", "other"],
            env=env, capture_output=True, text=True,
        )
        if merge.returncode == 0:
            failures.append("the conflict fixture merged cleanly, so it proves nothing")
        try:
            tracked_blobs.tracked_entries(root)
        except SystemExit as error:
            if "mid-merge" not in str(error):
                failures.append(f"a conflicted index was refused for the wrong reason: {error}")
        else:
            failures.append(
                "a conflicted index was read as if resolved, so the guard judges one "
                "side of an unfinished merge — bytes in no commit and not on disk"
            )

    # Drop an entry in the chunk reader, not the byte stream, to isolate sweep
    # accounting from per-chunk truncation checks.
    real_chunk = tracked_blobs._read_chunk
    tracked_blobs._read_chunk = lambda root, wanted, files, undec: real_chunk(
        root, wanted[:-1], files, undec
    )
    entries = [
        entry for entry in tracked_blobs.tracked_entries(REPO_ROOT)
        if entry.mode in tracked_blobs.REGULAR_MODES
    ][:4]
    try:
        tracked_blobs.blob_texts(REPO_ROOT, entries)
    except SystemExit as error:
        if "accounted for" not in str(error):
            failures.append(f"a short sweep was reported as something else: {error}")
    except Exception as error:  # noqa: BLE001 - a reader defect must read as one
        failures.append(f"a short sweep escaped as {type(error).__name__}: {error}")
    else:
        failures.append(
            "a sweep that read fewer blobs than it asked for was accepted, so files "
            "vanish from it and the count in the ok line is simply smaller — which "
            "nothing else can tell from a repo that has fewer files"
        )
    finally:
        tracked_blobs._read_chunk = real_chunk

    # Assert returned paths as well as unchanged indexes; a redirected read writes
    # nothing. Config injection needs its own coverage.
    with tempfile.TemporaryDirectory() as workdir:
        victim, fixture = Path(workdir) / "victim", Path(workdir) / "fixture"
        env = tracked_blobs.git_env(hermetic=True)
        for repo, name in ((victim, "kept.md"), (fixture, "a.md")):
            repo.mkdir()
            (repo / name).write_text("# x\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True, env=env)
            subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, env=env)
        index = victim / ".git" / "index"
        before = index.read_bytes()
        prior = {
            name: os.environ.get(name)
            for name in ("GIT_INDEX_FILE", "GIT_CONFIG_PARAMETERS")
        }
        os.environ["GIT_INDEX_FILE"] = str(index)
        os.environ["GIT_CONFIG_PARAMETERS"] = "'core.excludesFile'='/dev/null'"
        try:
            listed = [entry.path for entry in tracked_blobs.tracked_entries(fixture)]
        finally:
            for name, value in prior.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
        if listed != ["a.md"]:
            failures.append(
                f"tracked_entries listed {listed} for the fixture, so an absolute "
                f"GIT_INDEX_FILE in the environment reached the library and it swept a "
                f"repository nobody asked about"
            )
        if index.read_bytes() != before:
            failures.append("reading through the library rewrote another repo's index")

    # An injected excludesFile affects git add despite isolated user config.
    with tempfile.TemporaryDirectory() as workdir:
        repo = Path(workdir) / "repo"
        repo.mkdir()
        (repo / "kept.md").write_text("# x\n", encoding="utf-8")
        (Path(workdir) / "ignore-all").write_text("*\n", encoding="utf-8")
        prior = os.environ.get("GIT_CONFIG_PARAMETERS")
        os.environ["GIT_CONFIG_PARAMETERS"] = (
            f"'core.excludesFile'='{Path(workdir) / 'ignore-all'}'"
        )
        try:
            env = tracked_blobs.git_env(hermetic=True)
            subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True, env=env)
            subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, env=env)
            staged = [entry.path for entry in tracked_blobs.tracked_entries(repo)]
        finally:
            if prior is None:
                os.environ.pop("GIT_CONFIG_PARAMETERS", None)
            else:
                os.environ["GIT_CONFIG_PARAMETERS"] = prior
        if staged != ["kept.md"]:
            failures.append(
                f"an injected core.excludesFile reached the fixture and it staged "
                f"{staged}, so a control can pass on a tree that never held its fixture "
                f"— GIT_CONFIG_PARAMETERS is not covered by -C or GIT_CONFIG_GLOBAL"
            )

    # Pair rejected non-regular modes with readable regular files.
    link = tracked_blobs.Entry("120000", "0" * 40, "link.md")
    try:
        tracked_blobs.blob_texts(REPO_ROOT, [link])
    except SystemExit as error:
        if "not regular files" not in str(error):
            failures.append(f"a non-regular entry was refused for the wrong reason: {error}")
    else:
        failures.append(
            "a non-regular entry was accepted and dropped, so the caller's scope "
            "decision is made here where nothing can count what it removed"
        )
    regular = [e for e in tracked_blobs.tracked_entries(REPO_ROOT) if e.mode == "100644"][:1]
    if regular and not tracked_blobs.blob_texts(REPO_ROOT, regular)[0]:
        failures.append("a regular entry stopped being read, so the refusal above proves nothing")

    # A DESYNCED STREAM must fail rather than pair each path with another file's
    # text. Driven through a stubbed git, because a real one cannot be made to
    # answer out of order; each case is one field of the record git echoes back.
    real = tracked_blobs.git
    for case, reply, wanted in (
        ("a record for a sha nobody asked for", b"%s blob 2\nhi\n", "desynced"),
        ("a tree where a blob was asked", b"%(sha)s tree 2\nhi\n", "desynced"),
        ("a record shorter than it declared", b"%(sha)s blob 9\nhi\n", "truncated"),
        ("bytes beyond the last record", b"%(sha)s blob 2\nhi\nextra\n", "beyond"),
        ("a size that is not a number", b"%(sha)s blob xx\nhi\n", "not a number"),
    ):
        sha = "a" * 40
        payload = reply % ({b"sha": sha.encode()} if b"%(sha)s" in reply else b"b" * 40)
        tracked_blobs.git = lambda *_a, **_k: payload
        try:
            tracked_blobs.blob_texts(
                REPO_ROOT, [tracked_blobs.Entry("100644", sha, "one.md")]
            )
        except SystemExit as error:
            if wanted not in str(error):
                failures.append(f"{case} was reported as something else: {error}")
        except Exception as error:  # noqa: BLE001 - a reader defect must read as one
            failures.append(f"{case} escaped as {type(error).__name__}: {error}")
        else:
            failures.append(
                f"{case} was accepted, so paths are paired with text the stream never "
                f"said belonged to them and every finding after it names the wrong file"
            )
        finally:
            tracked_blobs.git = real
    return failures



def selftest() -> int:
    failures = blob_controls()
    for failure in failures:
        print(f"tracked_blobs selftest: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("tracked_blobs selftest: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(selftest())
