# D016: A catalog entry owns only the commands it declares, and an install that exports more stays off PATH

[← Decision Index](INDEX.md)

**Date**: 2026-09-10 **Status**: Active **Research**: — **Refines**: [D011](D011-mise-owns-agent-harnesses.md), [D014](D014-command-provenance-and-duplicates.md)

**Context**: [D014](D014-command-provenance-and-duplicates.md) tests a catalog row against the one command the row declares, and treats two copies of that command as the failure to resolve. A package is not only the command VGS asked for. The Cursor Agent package ships `node`, `rg`, `cursor-askpass` and a dozen more beside its own binary, and mise's registry entry exports the whole package directory. mise's bin path sits ahead of `/usr/bin`, so `node -v` reported the package's 24.5.0 while `/usr/bin/node` was 26.8.1 and `npm` printed a Node-version warning on every invocation, with nothing on the machine saying why. `rg` was replaced the same way. Both replacements reached every process the session started, on every machine that installed the row.

**Decision**: A catalog entry owns the command it declares and the file inside the package that command runs, and nothing else. An entry whose install exports more than that keeps its install off PATH: the package spec carries mise's `bin_path=`, so the install exports no executable, and an `exec` field names the file under the install root that the stub and the launcher run directly. `mise x` resolves nothing for such a package, so the absolute path is the only way in; the stub builds it from `mise where`, which is the shape its `present` probe already used.

`mise_export_conflicts` in `bin/vshell_mise.py` enforces this on every stub refresh, which is also what runs after `vshell update run tools`. For each catalog entry it asks mise which executables the install exports, subtracts the ones the entry declares, and reports each remainder that also answers somewhere else on PATH. The declared set is derived from the entry; there is no second list and no exemption list.

**Rationale**:

- The declaration already exists. `command` and the file the stub runs are what the catalog says an entry is for, so the rule needs no new vocabulary and cannot drift from the rows it judges.
- Only mise knows what an install exports, and it answers with `mise bin-paths --json`. A directory scan in VGS would be a second, disagreeing copy of that answer.
- The remainder is reported only when the command answers elsewhere as well. A package's private helper that nothing else provides shadows nothing, and reporting it would train the owner to ignore the notice.
- mise's own shims are symlinks to the mise binary, so a hit there is a second spelling of the install under test rather than a second copy of the command. Passing them over is what keeps the `node` case pointing at `/usr/bin/node`.
- `bin_path=` on the registry name is one bracket option and keeps mise's registry the owner of the download URL and the version list. Respelling the whole `http` entry in the catalog would copy a URL template and a version regex that mise already maintains.
- No version is pinned. The overridden entry still installs `latest`, as [D011](D011-mise-owns-agent-harnesses.md) requires.

**Revisit When**: mise's `http` backend can export a named subset of a package directory, which would let an entry publish its own command without the absolute-path launch; or a catalog entry legitimately owns more than one command on PATH, which would move the declared set off the `command` and `exec` pair.

**Verification**: `test_a_package_kept_off_path_runs_by_absolute_path` and `test_an_install_may_not_export_a_command_the_entry_does_not_own` in `scripts/check-dev-tools.py`. The second is table-driven over an undeclared export that shadows a distribution command, a declared one that does not count, an undeclared one nothing else provides, an entry kept off PATH entirely, and one visible only through a mise shim. Each rule fails when its behaviour is removed: dropping the declared-set subtraction, dropping the answers-elsewhere test, dropping the shim rule, reading a failed or misshapen `mise bin-paths` as no conflicts, dropping the absolute-path branch from the stub, and accepting an install mise reports with no path. `test_catalog_is_consistent` fails an entry carrying `exec` without `bin_path=`, or the reverse.

**References**: [D011](D011-mise-owns-agent-harnesses.md) (mise owns harnesses, and pins nothing), [D014](D014-command-provenance-and-duplicates.md) (the duplicate-command rule this widens), VGS-291.
