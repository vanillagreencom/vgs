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
    def __init__(self, version):
        self.binary_package_version = version


class FakeArchive:
    def __init__(self, sources, binaries=()):
        self._sources = list(sources)
        self._binaries = list(binaries)
        self.binary_queries = 0

    def getPublishedSources(self):  # noqa: N802 - Launchpad's own name
        return self._sources

    def getPublishedBinaries(self, status=None):  # noqa: N802 - Launchpad's own name
        self.binary_queries += 1
        return self._binaries


def deleted(sources):
    return sorted(s.source_package_version for s in sources if s.deletions)


# label; publication versions with statuses; expected exit code; expected deletions.
CASES = (
    (
        "an older release and its retired binaries go",
        [("0.5.0-1~ubuntu26.04.1", "Published"), ("0.4.0-1~ubuntu26.04.1", "Superseded")],
        0,
        ["0.4.0-1~ubuntu26.04.1"],
    ),
    (
        "this release stays, whatever its Ubuntu revision",
        [("0.5.0-1~ubuntu26.04.1", "Superseded"), ("0.5.0-1~ubuntu26.04.2", "Published")],
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
        [("0.5.0-1~ubuntu26.04.1", "Published"), ("0.4.0-1~ubuntu26.04.1", "Deleted")],
        0,
        [],
    ),
)


def case_selector():
    for label, rows, want_code, want_deleted in CASES:
        sources = [FakeSource(version, status) for version, status in rows]
        archive = FakeArchive(sources, binaries=[FakeBinary("0.5.0-1~ubuntu26.04.1")])
        code = prune_ppa.prune(archive, "0.5.0", sleep=lambda _seconds: None)
        check(f"{label}: exit", code, want_code)
        check(f"{label}: deleted", deleted(sources), want_deleted)


def case_waits_for_this_release_binaries():
    sources = [FakeSource("0.5.0-1~ubuntu26.04.1"), FakeSource("0.4.0-1~ubuntu26.04.1", "Superseded")]
    archive = FakeArchive(sources, binaries=[])
    ticks = iter([0.0, 10.0, 3000.0])
    code = prune_ppa.prune(archive, "0.5.0", timeout=2700, sleep=lambda _s: None, clock=lambda: next(ticks))
    check("no published binaries: exit", code, 1)
    check("no published binaries: deleted", deleted(sources), [])

    sources = [FakeSource("0.5.0-1~ubuntu26.04.1"), FakeSource("0.4.0-1~ubuntu26.04.1", "Superseded")]
    late = FakeArchive(sources, binaries=[])

    def publish_on_second_query(status=None):
        late.binary_queries += 1
        return [FakeBinary("0.5.0-1~ubuntu26.04.1")] if late.binary_queries > 1 else []

    late.getPublishedBinaries = publish_on_second_query
    ticks = iter([0.0, 10.0, 20.0, 30.0])
    code = prune_ppa.prune(late, "0.5.0", sleep=lambda _s: None, clock=lambda: next(ticks))
    check("binaries land during the wait: exit", code, 0)
    check("binaries land during the wait: deleted", deleted(sources), ["0.4.0-1~ubuntu26.04.1"])


def case_dry_run_deletes_nothing():
    sources = [FakeSource("0.5.0-1~ubuntu26.04.1"), FakeSource("0.4.0-1~ubuntu26.04.1", "Superseded")]
    archive = FakeArchive(sources, binaries=[])
    code = prune_ppa.prune(archive, "0.5.0", dry_run=True, sleep=lambda _s: None)
    check("dry run: exit", code, 0)
    check("dry run: deleted", deleted(sources), [])
    check("dry run: waits for no binaries", archive.binary_queries, 0)


def case_version_comparison_is_debian_s():
    check("0.10.0 is newer than 0.9.0", prune_ppa.version_older("0.10.0-1~ubuntu26.04.1", "0.9.0-1~"), False)
    check("0.9.0 is older than 0.10.0", prune_ppa.version_older("0.9.0-1~ubuntu26.04.1", "0.10.0-1~"), True)


def main() -> int:
    for case in (
        case_selector,
        case_waits_for_this_release_binaries,
        case_dry_run_deletes_nothing,
        case_version_comparison_is_debian_s,
    ):
        case()
    if failures:
        for failure in failures:
            print(f"check-prune-ppa: FAIL: {failure}", file=sys.stderr)
        return 1
    print(f"check-prune-ppa: ok ({len(CASES) + 5} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
