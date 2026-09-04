# config/vshell/

Shipped seed defaults, the feature dependency manifest, and the bundled plugins that are VGS product UI. Loading, override and dependency invariants: [../../docs/architecture/plugins.md](../../docs/architecture/plugins.md).

- Files here are shipped defaults, never live user state. Mutable state belongs under `~/.config/vshell/`.
- A bundled plugin keeps a stable id and uses the sanctioned imports: `qs.Common`, `qs.Widgets`, `qs.Services`, `qs.Modules.Plugins`. A bundled plugin must not import another feature's directory.
- Keep plugin UI on VGS theme tokens rather than hardcoded colours and sizes, and reach the helper through `Paths.vshellCli`.
- Every distribution-installable command shipped code probes for is declared under `features` in `dependencies.json`, or listed with its reason in that file's `undeclared` map. `scripts/check-command-declarations.py` fails on anything in neither place, and on a stale exclusion.
- Do not add a probe for a command that exists only in a private dotfiles repository. A private wrapper belongs behind a user setting the shipped code already passes through.
