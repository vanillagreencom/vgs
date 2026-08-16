# D009: The validation manifest keeps a second reader; the grammar does not

[← Decision Index](INDEX.md)

**Date**: 2026-08-15
**Status**: Active
**Research**: VGS-144

**Context**: VGS-123 made `scripts/validate` the only parser of
`scripts/lib/validation-grammar.conf` and deleted the second one, because two
readers of one definition had disagreed three times about invalid or ambiguous
input. `scripts/lib/validation_manifest.py` now decodes `--dump-grammar` instead
of parsing the definition. The same move is available one level down: the runner
could grow a `--dump-manifest` and `manifest_rows` could stop parsing the
`MANIFEST_EOF` heredoc, leaving one reader of the rows as well. VGS-144 carried
that as an open question rather than an obvious cleanup, and this records the
answer so it is not re-argued from scratch.

**Decision**: The manifest stays read twice — by `scripts/validate` to decide
what runs, and by `manifest_rows` to decide what the guard checks. The grammar
stays read once. The dividing line is what the second reader is FOR, not how
much it costs.

**Rationale**:
- **The guard is an inventory cross-check, and an inventory taken from the
  audited party's own report is not one.** `check-validation-inventory.py` exists
  to answer VGS-50 ("is every executable check under `scripts/` actually run?")
  and VGS-30 ("is every documented command runnable exactly as written?"). Both
  answers are computed from the row set. If the row set arrives from the runner,
  a runner that silently drops a row reports a consistent, wrong answer to the
  only check that would have noticed.
- **The grammar had no equivalent to lose.** Nothing downstream of the grammar is
  an inventory of the runner's own behaviour; the runner must parse the
  definition before it can run at all, and a runner that mis-reads it mis-reads
  it for everyone. That coverage was replaceable by behaviour — mutated grammars
  driven through the runner in `scripts/test-validate.sh`. The row set is not
  replaceable the same way: a dropped row is not a malformed input anyone can
  enumerate.
- **`--list` does not carry per-row tags**, so collapsing means new runner
  surface (`--dump-manifest`) whose only consumer is the guard. The grammar dump
  was already needed to end a real divergence; this one would be built to enable
  one.
- The known cost is accepted and bounded: two readers of the rows can disagree,
  and the agreement tests are an ENUMERATION — the same shape
  `scripts/lib/validation-grammar.conf`'s header rejects for grammar
  conformance. They are `scripts/test-validate.sh`'s
  parser-agreement case (`--list all` compared against `manifest_rows`) and
  `scripts/test-validation-inventory.sh`'s reader-agreement table, plus the
  shared `row-*` diagnostics in the grammar, which both readers are pinned to
  rather than to each other.

**Revisit When**: the runner grows a `--dump-manifest` for a second consumer (the
cost of collapsing changes); the two readers diverge on a row in a way the
agreement tests did not catch (the enumeration's incompleteness has bitten, and
the trade should be re-weighed with that evidence); or the guard stops being an
inventory of the runner's own coverage.

**Verification**: `scripts/test-validate.sh` § parser agreement compares the two
readers' COMMAND SEQUENCES on the shipped manifest — the tag half is what
`--list` cannot carry, so it is checked separately;
`scripts/test-validation-inventory.sh` § reader agreement drives eleven
malformed, duplicate and control-character rows through both readers, with their
tags, and requires an identical classification. The three control-character rows
(`\v`, `\f`, `\r`) require more than agreement: each must be TAKEN by both
readers and its command listed, since two readers that both refused the row
would agree perfectly while the shared whitespace set was broken in the one
direction those rows exist to catch.

**References**: VGS-123 (one runner, one manifest), VGS-144 (deferred review
findings). CI invokes the manifest's commands as individually named steps rather
than running the runner — the shape that makes a self-concealing local run
unable to reach `main` — which is stated in
[`.github/instructions/ci.instructions.md`](../../.github/instructions/ci.instructions.md)
and `.github/workflows/ci.yml`'s header;
[D007](D007-ci-single-job-economics.md) decides the surrounding shape (one suite
job, no lanes or nightly, `ci-ok` as the stable required context).
