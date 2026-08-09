# D005: `dependencies.json` declares presence; capability probes cover the rest

[← Decision Index](INDEX.md)

**Date**: 2026-08-08
**Status**: Active
**Research**: —

## Context

`config/vshell/dependencies.json` is the single source of truth for what VGS
needs installed. It declares **presence only**: `feature_status()` in
`bin/vshell-helper` answers each entry with `command_exists()`.

VGS-78 established one real version floor and wrote it into the manifest as a
`$comment`:

> jq >= 1.5 (2015-08-16): the release that introduced regex builtins at all.

That was an improvement — the assumption previously had no home at all (bare
`'jq'` in `packaging/arch/PKGBUILD`, `"jq": { "skip": "hard dependency" }` in
`packaging/optional-packages.json`) — but it created the defect this decision
resolves: **a constraint that is declared and never checked**. Nothing reads it.
`vshell deps status` cannot report it, the six-distro generator cannot emit it,
and no check fails when it is violated. A comment that looks like a constraint is
worse than no comment, because it reads as coverage.

Facts established before choosing (2026-08-08):

- **It is the only one.** The manifest declares 67 probed commands across ~20
  feature groups. `jq` is the sole entry with a documented minimum. Quickshell is
  version-*pinned* by packaging and by API (`AGENTS.md`: "Quickshell 0.3.0 only";
  `D001`), not `>=`-constrained, and nothing in the tree probes its version.
- **It is inert on every reachable system.** Debian's own package history
  (`sources.debian.org/api/src/jq/`): jessie 1.4, stretch 1.5, buster 1.5,
  bullseye 1.6, bookworm 1.6, trixie 1.7.1, sid 1.8.2. A jq below 1.5 needs
  Debian jessie or older — EOL since 2020. Arch, Fedora, Gentoo, Void and nixpkgs
  are all further ahead.
- **The general facility is expensive at both ends.** Emitting a version
  constraint needs six syntaxes, and three cannot express one usefully: nixpkgs'
  list form (`pkgs.jq`) has no constraint slot, Void's xbps wants a package
  revision (`jq>=1.5_1`), and Gentoo needs the atom rewritten
  (`>=app-misc/jq-1.5`). `gen-package-metadata.py` would need per-distro
  "cannot express this" waivers for a constraint no distro violates.
- **Version strings are a fragile proxy.** Each of the 67 commands has its own
  `--version` shape, several write to stderr, and some have no version flag. Any
  parser needs a third "could not determine" state, and a mis-parse reports a
  working system as broken — a worse failure than the gap being closed.

## Decision

**`dependencies.json` gains no version-constraint syntax.** It declares presence,
and its `$comment` now says so explicitly and points at where the real check
lives, rather than implying a constraint nothing enforces.

**Where VGS needs more than presence, the check is a capability probe**, in
`bin/vshell-helper`'s `CAPABILITY_PROBES` table: run the installed command and
ask it to do the thing VGS actually depends on.

```python
"jq": {
    "argv": ["jq", "-ne", '("a" | test("a")) and (("ab" | gsub("b"; "c"; "i")) == "ac")'],
    "requirement": "needs regex builtins (jq >= 1.5)",
},
```

`feature_status()` reports a failed probe in the existing `missing` list, phrased
`jq (installed but unusable: needs regex builtins (jq >= 1.5))`, and also breaks
it out under a new `unusable` key. So `vshell deps status`, the capture modal's
toast and every other existing consumer report it without knowing the mechanism
exists, and a machine consumer can tell "reinstall this" from "upgrade this".

Three rules make it a check rather than another comment:

1. **A probe that cannot be run counts as satisfied.** If the binary vanished
   between the presence check and the probe, or the probe times out, VGS does not
   claim the command is unusable. Reporting a working system as broken on the
   strength of a probe that never executed is the false negative the whole
   mechanism exists to avoid.
2. **An absent command is never probed.** It is already reported as missing;
   telling someone to upgrade something they have not installed is worse than
   silence.
3. **The bar for a second entry is a documented minimum that a *reachable* system
   can violate.** Presence-only stays the default. Without that bar this becomes
   a version-constraint facility by accretion, which is what was rejected.

## Rationale

- A capability probe tests the requirement; a version comparison tests a proxy
  for it. jq 1.4 fails `test("a")` — that *is* the constraint, stated exactly.
- The general facility would be built for a population of one, and its cost lands
  in six packaging formats and 67 version-string parsers, none of which any
  reachable system needs.
- The mechanism is general even though its table has one row: adding a probe is a
  table entry, not a special case, so the second real constraint costs a few
  lines rather than a redesign.
- It is a *runtime* check, which is where the question is actually asked. A user
  whose helpers misbehave runs `vshell deps status`; a build-time version
  assertion would not reach them.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Versioned constraints in `dependencies.json`, probed by `deps status` and emitted by the packaging generator | Three of six packaging formats cannot express a constraint usefully; 67 `--version` shapes to parse, each a false-negative risk; one real constraint to justify all of it |
| A machine-readable `minimumVersions` key that nothing reads | Reproduces the exact defect being fixed, in a more official-looking form |
| A `jq`-specific `if` in `feature_status()` | A one-off special case in a manifest describing dozens of dependencies, which the issue explicitly ruled out |
| Leave it as prose and accept it is advisory | The declaration is the only record of the constraint; leaving it unchecked is what VGS-89 exists to correct |
| Do nothing — the constraint is inert anyway | True today and possibly forever, but "inert" is a claim about the world that nothing re-checks; the probe costs one subprocess per `deps status` |

## Verification

```bash
# The shipped probe, against the jq installed here.
jq --version
jq -ne '("a" | test("a")) and (("ab" | gsub("b"; "c"; "i")) == "ac")'; echo "exit=$?"

# What a user with an unusable jq sees (probe forced to fail):
bin/vshell deps status | head -1
# base: missing: jq (installed but unusable: needs regex builtins (jq >= 1.5))

# The mechanism's own coverage, including the two ways it must NOT fire:
scripts/check-vshell-helper.py       # test_capability_probe_reporting
```

`test_capability_probe_reporting` was mutation-proved: dropping the unusable
entries from `missing`, probing an absent command, and treating an unrunnable
probe as evidence each turn it red.

## Revisit When

- A second command needs more than presence. One entry is a table; three or four
  with genuinely version-shaped constraints would be the signal that a real
  constraint facility has earned its cost.
- A packaging target VGS ships to starts shipping a jq (or any dependency) below
  a floor VGS needs — at which point the packaging-side constraint stops being
  unrepresentable-and-pointless and becomes unrepresentable-and-needed.
- Quickshell's minimum stops being a pin and becomes a range.

## References

- VGS-89 — the issue this decision resolves
- VGS-78 — added the `$comment` this replaces, and established the jq 1.5 fact
  from `builtin.c` at tags `jq-1.4` / `jq-1.5` / `jq-1.6`
- `bin/vshell-helper` — `CAPABILITY_PROBES`, `capability_probe_ok`,
  `_unusable_commands`
- `config/vshell/dependencies.json` — `features.base.$comment`
- [D001](D001-quickshell-0-3-0-upstream-defects.md) — why Quickshell is a pin
  rather than a minimum
