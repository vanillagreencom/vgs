"""Self-test for `tracked_blobs`, run as `python3 scripts/lib/tracked_blobs_selftest.py`.

Beside the library, like `section_pointers_selftest.py` and
`prose_blocks_selftest.py`. What it pins is the module's one promise — that
"what git TRACKS" means this repository, at this index, with the bytes git
actually sent — so every control here drives a failure the module must REFUSE
rather than answer:

  * git exiting non-zero must raise, not return an empty listing;
  * an index mid-merge must raise, not answer from one side of the conflict;
  * a `cat-file --batch` stream that desyncs, lies about a length, or runs long
    must raise, not pair paths with another file's text.

The stream cases drive a stubbed `git`, because a real one cannot be made to
answer out of order. The mutation set they were run red against is recorded in
`scripts/test-section-pointers.py`.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import tracked_blobs  # noqa: E402

REPO_ROOT = HERE.parents[1]

def blob_controls() -> list[str]:
    """The VCS-access arms: git failing, and a blob that cannot be produced.

    These were the two rules the "every rule has a control" claim did not cover.
    Both fail LOUDLY by design — a check that cannot read the tree has nothing to
    report — so each is asserted to raise rather than to return something a
    caller might treat as an empty, clean answer.
    """
    failures: list[str] = []
    absent = Path(tempfile.gettempdir()) / "vgs-150-not-a-repo"
    absent.mkdir(exist_ok=True)
    try:
        tracked_blobs.git(absent, "ls-files", "-s", "-z")
    except SystemExit as error:
        if "NOTHING was read" not in str(error):
            failures.append(f"git failing did not say nothing was read: {error}")
    else:
        failures.append(
            "git exiting non-zero returned normally, so a listing that never happened "
            "is indistinguishable from a tree with no files in it"
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
    # A MID-MERGE INDEX IS REFUSED, not answered from one side. `ls-files -s`
    # emits stages 1/2/3 for a conflicted path and the last write won, so the
    # caller judged "theirs" — bytes in no commit and not on disk. Built as a
    # real conflict, because the stage field is what has to be read.
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
        # The identity goes on the MERGE too: under the hermetic env there is no
        # user config, and git refuses to begin a merge it cannot commit — the
        # fixture then produced no conflict at all and the control failed clean.
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

    # A DESYNCED STREAM must fail rather than pair each path with another file's
    # text. Driven through a stubbed git, because a real one cannot be made to
    # answer out of order; each case is one field of the record git echoes back.
    real = tracked_blobs.git
    for case, reply, wanted in (
        ("a record for a sha nobody asked for", b"%s blob 2\nhi\n", "desynced"),
        ("a tree where a blob was asked", b"%(sha)s tree 2\nhi\n", "desynced"),
        ("a record shorter than it declared", b"%(sha)s blob 9\nhi\n", "truncated"),
        ("bytes beyond the last record", b"%(sha)s blob 2\nhi\nextra\n", "beyond"),
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
