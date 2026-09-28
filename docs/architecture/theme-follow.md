# Theme follow

Covers: scripts/test-vgsh-follow.sh

How a package that changed after its apply reaches the theme file. Apply itself is [theme-apply.md](theme-apply.md); the runner, the lock and install are [themes.md](themes.md).

## Follow

Apply copies a package; a later change to the package reaches the theme file through a follow. A shipped package changes with a VGS update, an installed one with `vgsh theme update`.

- **Record.** Once the theme file holds the package's bytes, apply writes `${XDG_STATE_HOME:-~/.local/state}/vgs/applied.json`, `{ "schemaVersion": 1, "name", "file", "package" }`, by rename. `file` is the sha256 of the `theme.json` bytes apply wrote. `package` is a sha256 digest of the package's content: `theme.json`, `terminal.json` or its absence, and each file directly under `targets/`, in name order, each framed by its name and length. `backgrounds/` holds no colours and stays out. Apply computes the digest before anything moves, so a `targets/` that cannot be read refuses the apply with `reason=unreadable`. The runner owns `applied.json`; the core never reads it, and apply never reads it.
- **`vgsh theme follow`.** Under the lock, follow reads the record and answers one `follow` outcome. `none`: no record, or, for update, a record naming another package. `edited`: the theme file is absent or its sha256 is not `file`, a hand edit the follow leaves. `unavailable`: the recorded name resolves to no accepted package. `current`: the package's digest equals `package`. `reapplied`: follow runs apply for the recorded name, whose result it reports.
- **Result.** The follow result is the apply result with `follow` beside it: `{ state, shell, targets, theme, reason, follow }`. `state` is `unchanged` when nothing ran, and `theme` is the recorded name or null. Text mode prints the apply's target lines when it re-applied, then `ok follow=<outcome> theme=<name|-> state=<state>`, or `partial ...`. Refusals print `vgsh: refused: follow=applied reason=<key>`: `busy` with exit 75, `lock-failed`, and `unreadable`, `unparseable` or `malformed` for a record or a theme file that cannot be read or judged; a re-apply's refusals are apply's. Exit codes are apply's.
- **Callers.** `vgsh theme update <name>` follows for that package alone: [themes.md § Install](themes.md#install). The shell follows at the end of every plugin scan, the first at start: [theme-capability.md § Capability](theme-capability.md#capability).

## Invariants

1. Apply records the package's name, the hash of the bytes it wrote and its content digest; follow re-applies a package whose `theme.json`, `terminal.json` or curated file changed under an unedited theme file, and not for a background; follow and update leave a hand-edited or deleted theme file byte for byte; follow answers `none` with no record, `current` for an unchanged package and `unavailable` for a package that is gone; a malformed record refuses the follow and the list, and a held lock refuses the follow as busy. Enforced by `scripts/test-vgsh-follow.sh`, with judge copies that write no record, take every package as current, leave curated files out of the digest, ignore the edit check and ignore the lock as its controls.
