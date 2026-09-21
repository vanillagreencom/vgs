# .github/workflows/

CI and the review-gate writer. Both are kendex-shaped and the review gate reads the repository default branch.

- CI runs the same checks `scripts/validate` lists, as named steps in one job. A step that runs a script the tree does not hold is a defect.
- The `CI / ci-ok` context name stays stable: the merge queue and branch rules require it.
- The review-gate writer refuses any branch but the repository default. Work on a non-default branch gets no gate.
