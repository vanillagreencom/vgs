# CodeRabbit configuration schema

`schema.v2.json` is CodeRabbit's own published JSON Schema for `.coderabbit.yaml`,
fetched verbatim from:

    https://storage.googleapis.com/coderabbit_public_assets/schema.v2.json

(also served at `https://coderabbit.ai/integrations/schema.v2.json` — byte-identical).

## Why it is vendored rather than fetched

`scripts/check-coderabbit-config.py` validates the repo's `.coderabbit.yaml`
against it on every run, including in CI. Fetching it at check time would make
the check depend on a third-party endpoint: an outage would either fail the
build for a reason unrelated to the change, or — worse, and the exact defect
VGS-42 exists to remove — get "handled" with a skip that reads as a pass.
A vendored copy makes the check offline, deterministic, and reviewable.

## Refreshing it

    curl -fsSL -o third_party/coderabbit-schema/schema.v2.json \
      https://storage.googleapis.com/coderabbit_public_assets/schema.v2.json

Then re-run `scripts/check-coderabbit-config.py`. If the refreshed schema uses
a JSON Schema keyword the validator does not implement, the check FAILS and
names it — silently ignoring an unknown constraint would under-validate the
config while still reporting success.
