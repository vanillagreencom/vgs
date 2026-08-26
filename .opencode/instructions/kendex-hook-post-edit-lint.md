# Safety: post-edit-lint

**Safety: Run workspace linter after editing source files. Currently supports Rust (cargo clippy).**
Catches lint errors immediately after edits rather than waiting for commit time.
After executing Edit|Write operations, the agent must verify this constraint is met.
