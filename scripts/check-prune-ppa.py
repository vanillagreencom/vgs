#!/usr/bin/env python3
"""Check the PPA prune selector: what it deletes, keeps, refuses and waits for.

The selector is destructive and runs unattended after every release, so each
case here drives scripts/prune-ppa.py against a fake archive and asserts the
deletions it requested.
"""

import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("prune_ppa", ROOT / "scripts" / "prune-ppa.py")
prune_ppa = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prune_ppa)

CURRENT = "0.5.0-1~ubuntu26.04.1"
failures = []


def check(label, actual, expected):
    if actual != expected:
        failures.append(f"{label}: expected {expected!r}, got {actual!r}")


class FakeSource:
    def __init__(self, version, status="Published", name="vgs-shell"):
        self.source_package_version = version
        self.source_package_name = name
        self.status = status
        self.deletions = []

    def requestDeletion(self, removal_comment=None):  # noqa: N802 - Launchpad's own name
        self.deletions.append(removal_comment)


class FakeBinary:
    def __init__(self, version, architecture, name="vgs-shell", status="Published"):
        self.binary_package_version = version
        self.binary_package_name = name
        self.status = status
        self.distro_arch_series_link = (
            f"https://api.launchpad.net/devel/ubuntu/resolute/{architecture}"
        )


class FakeArchive:
    def __init__(self, sources, binaries=()):
        self._sources = list(sources)
        self._binaries = list(binaries)
        self.binary_queries = 0

    def getPublishedSources(self):  # noqa: N802 - Launchpad's own name
        return self._sources

    def getPublishedBinaries(self, status=None):  # noqa: N802 - Launchpad's own name
        # Launchpad honours the status filter, so a caller that drops it sees
        # the unbuilt and retired binaries this archive also publishes.
        self.binary_queries += 1
        return [b for b in self._binaries if status is None or b.status == status]


def both_architectures(version=CURRENT, **kwargs):
    return [FakeBinary(version, "amd64", **kwargs), FakeBinary(version, "arm64", **kwargs)]


# Every wait case carries these too, because a real PPA still publishes the
# previous release while this one builds.
OLDER = both_architectures("0.4.0-1~ubuntu26.04.1")


def deleted(sources):
    return sorted(s.source_package_version for s in sources if s.deletions)


def run(sources, binaries, **kwargs):
    archive = FakeArchive(sources, binaries)
    code = prune_ppa.prune(archive, "0.5.0", sleep=lambda _seconds: None, **kwargs)
    return archive, code


# label; publication versions with statuses; expected exit code; expected deletions.
CASES = (
    (
        "an older release and its retired binaries go",
        [(CURRENT, "Published"), ("0.4.0-1~ubuntu26.04.1", "Superseded")],
        0,
        ["0.4.0-1~ubuntu26.04.1"],
    ),
    (
        "this release stays, whatever its Ubuntu revision",
        [(CURRENT, "Superseded"), ("0.5.0-1~ubuntu26.04.2", "Published")],
        0,
        [],
    ),
    (
        "a newer release stops the run and deletes nothing",
        [("0.6.0-1~ubuntu26.04.1", "Published"), ("0.4.0-1~ubuntu26.04.1", "Superseded")],
        1,
        [],
    ),
    (
        "a deleted publication is left alone",
        [(CURRENT, "Published"), ("0.4.0-1~ubuntu26.04.1", "Deleted")],
        0,
        [],
    ),
)


def case_selector():
    for label, rows, want_code, want_deleted in CASES:
        sources = [FakeSource(version, status) for version, status in rows]
        _archive, code = run(sources, both_architectures())
        check(f"{label}: exit", code, want_code)
        check(f"{label}: deleted", deleted(sources), want_deleted)


def stale_pair():
    return [FakeSource(CURRENT), FakeSource("0.4.0-1~ubuntu26.04.1", "Superseded")]


def case_every_architecture_must_publish_first():
    # Each row also publishes OLDER, so only this release's own published
    # binaries can satisfy the wait.
    # label; binaries beyond OLDER; expected exit code; expected deletions.
    for label, binaries, want_code, want_deleted in (
        ("no architecture published", [], 1, []),
        ("only amd64 published", [FakeBinary(CURRENT, "amd64")], 1, []),
        ("another package's binaries do not count", both_architectures(name="vgs-shell-assets"), 1, []),
        ("binaries still building do not count", both_architectures(status="Pending"), 1, []),
        ("both architectures published", both_architectures(), 0, ["0.4.0-1~ubuntu26.04.1"]),
    ):
        sources = stale_pair()
        ticks = iter([0.0, 10.0, 3000.0])
        _archive, code = run(sources, OLDER + binaries, timeout=2700, clock=lambda: next(ticks))
        check(f"{label}: exit", code, want_code)
        check(f"{label}: deleted", deleted(sources), want_deleted)


def case_binaries_landing_during_the_wait():
    sources = stale_pair()
    late = FakeArchive(sources, binaries=[])

    def publish_on_second_query(status=None):
        late.binary_queries += 1
        landed = both_architectures() if late.binary_queries > 1 else [FakeBinary(CURRENT, "amd64")]
        return [b for b in OLDER + landed if status is None or b.status == status]

    late.getPublishedBinaries = publish_on_second_query
    ticks = iter([0.0, 10.0, 20.0, 30.0])
    code = prune_ppa.prune(late, "0.5.0", sleep=lambda _s: None, clock=lambda: next(ticks))
    check("binaries land during the wait: exit", code, 0)
    check("binaries land during the wait: deleted", deleted(sources), ["0.4.0-1~ubuntu26.04.1"])


def case_dry_run_deletes_nothing():
    sources = stale_pair()
    archive, code = run(sources, [], dry_run=True)
    check("dry run: exit", code, 0)
    check("dry run: deleted", deleted(sources), [])
    check("dry run: waits for no binaries", archive.binary_queries, 0)


def case_version_comparison_is_debians():
    check("0.10.0 is newer than 0.9.0", prune_ppa.version_older("0.10.0-1~ubuntu26.04.1", "0.9.0-1~"), False)
    check("0.9.0 is older than 0.10.0", prune_ppa.version_older("0.9.0-1~ubuntu26.04.1", "0.10.0-1~"), True)


def main() -> int:
    cases = (
        case_selector,
        case_every_architecture_must_publish_first,
        case_binaries_landing_during_the_wait,
        case_dry_run_deletes_nothing,
        case_version_comparison_is_debians,
    )
    for case in cases:
        case()
    if failures:
        for failure in failures:
            print(f"check-prune-ppa: FAIL: {failure}", file=sys.stderr)
        return 1
    print(f"check-prune-ppa: ok ({len(CASES) + 13} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
