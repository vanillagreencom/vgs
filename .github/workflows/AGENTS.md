# .github/workflows/

CI and the review-gate writer. Both are kendex-shaped and the review gate reads the repository default branch.

- CI runs every `scripts/validate` area but `qml`, which needs a Wayland session, plus the kendex guards, as named steps in one job. A step that runs a script the tree does not hold is a defect.
- The review-gate writer reads its definition from the repository default branch, which is `main`, and gates pull requests against it.
