# bin/

`bin/vshell` is a thin dispatcher; `bin/vshell-helper` is the single-file Python CLI that owns parsing, generation, privileged writes and the subsystems the runtime shells out for. Boundaries and invariants: [../docs/architecture/helper.md](../docs/architecture/helper.md).

- The helper is deliberately one large file. Do not propose splitting it into modules as a review finding — heavy logic living here rather than in QML is the design. Review it for behaviour, not architecture.
- Execute external tools with argv arrays, never a shell string built from user data, and never log secrets or raw frame payloads.
- Keep `bin/vshell` a dispatcher; new behaviour goes in the helper.
- `bin/vshell_niri.py`, `bin/vshell_niri_kdl.py` and `bin/vshell_theme_color.py` are importable modules with no entry point of their own, reached only through the helper.
