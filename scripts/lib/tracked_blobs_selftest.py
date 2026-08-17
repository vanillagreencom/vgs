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
    """The VCS-access arms: git failing, and a blob that cannot be produced.

    These were the two rules the "every rule has a control" claim did not cover.
    Both fail LOUDLY by design — a check that cannot read the tree has nothing to
    report — so each is asserted to raise rather than to return something a
    caller might treat as an empty, clean answer.
    """
    failures: list[str] = []
    # A THROWAWAY directory, like the rest of this file. A fixed name under the
    # shared temp dir leaked on every run and, worse, made the fixture's validity
    # depend on TMPDIR sitting outside any checkout — with it inside one, git
    # walks UP and succeeds, and the arm accuses this module of the fixture's
    # fault. `git_env` strips GIT_CEILING_DIRECTORIES, so that upward walk is not
    # otherwise stopped: the fixture is asserted repo-less before it is trusted.
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

    # EVERY BLOB ASKED FOR IS ACCOUNTED FOR. A chunk loop that slices one short
    # per round is invisible to every per-chunk check — git is asked for N-1 and
    # answers N-1 — so only the per-sweep total sees it. Driven by asking for two
    # blobs through a stub that answers for one.
    # The chunk reader is stubbed to drop its last entry, which is what a slice
    # off by one does. Stubbing the STREAM instead would trip the per-chunk
    # truncation check first and prove nothing about this arm.
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

    # THE LIBRARY'S OWN ENVIRONMENT HYGIENE, which is the production path: the
    # guard inherits whatever CI or a shell hands it. Asserting the LISTING is
    # what kills a missing `env=git_env()` — a redirected READ does not write, so
    # an index-unchanged assertion alone passes. The config-injection channel is
    # driven in the same block, since `-C` and GIT_CONFIG_GLOBAL do not cover it.
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

    # THE CONFIG-INJECTION CHANNEL bites on a WRITE, so it needs its own fixture:
    # `GIT_CONFIG_PARAMETERS` survives `-C` and GIT_CONFIG_GLOBAL alike, and an
    # injected `core.excludesFile` makes `git add -A` stage nothing at all.
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

    # THE MODE FILTER IS THE CALLER'S, and handing a non-regular entry here is
    # refused rather than silently dropped — dropping it is what hid 8,509
    # symlinks from the accounting, since this function can only count what it
    # was asked to read. Paired with the regular entry, which must still read.
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
