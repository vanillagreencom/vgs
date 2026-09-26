# Guard exclusion lists

Reasoned exception data for the repository's own guards, read by the checks in `scripts/` and by the commit-guards chain. No runtime code reads these files.

- Each list is `pattern<TAB>reason`, matching full repository paths, and a leading `!` carves a path back in. The reason is the only thing a later reader gets, so it states why the exception exists, not that one was needed.
- `doc-limits-excludes` is the documented exception path for a document that cannot fit its class. The checker has no per-file allowance, so a document either fits or is excluded; there is no third outcome and no way to raise one file's ceiling. An exclusion removes size pressure permanently, so it records what would otherwise have to change to lift it.
- Most rows exclude content this repository does not own, such as vendored trees and kendex render output. A row for a first-party document is the exception the policy allows, and its reason carries the size history that forced it.
