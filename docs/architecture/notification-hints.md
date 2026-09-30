# Notification hints

Covers: shell/plugins/vgs.notifications/tui/open.sh, scripts/test-notifications-open.sh

The four freedesktop hints any sender may add to a notification so that `vgs.notifications` draws a Lucide icon in a status tone and opens a file on a click. They are data the card stores with the notification, so a card in the history, or one restored after a shell restart, draws and clicks as it did live. The notifications plugin names no sender: `vgs.automations` is one, and any script can send them with `notify-send`. [D052](../decisions/D052-automations-engine.md) records the choice.

## The hints

Each is a string hint. `NotificationLogic.readHints` judges them and keeps each accepted one in the entry's role; `scripts/test-notifications-logic.js` pins each row with a control per rule.

| Hint | Role | Value | Effect |
|---|---|---|---|
| `x-vgs-icon` | `hintIcon` | A Lucide name, lower-case letters and digits joined by dashes, at most 64 characters | The card's media slot draws it, at its tier's `glyph` size, in place of the application icon; the sender's image and a rule's faces still win. A name the shipped set lacks leaves the slot out, and `Icon` logs it. |
| `x-vgs-tone` | `hintTone` | `success`, `warning`, `danger` or `info`, the design-system status tones | The icon's colour, from the plugin's own `tone` table in `Appearance.js`; the foreground without the hint. |
| `x-vgs-open` | `hintOpen` | An absolute path of at most 256 characters with no control character: the longest argument `shell.tui.run` hands a script | The file a click opens. |
| `x-vgs-click` | `hintClick` | `open` or `none` | `open`: a click opens `x-vgs-open`. `none`: a click only dismisses the card. Without it, a click opens the notification as any card's does: the sender's default action, then its window revealed ([D051](../decisions/D051-notification-actions-reveal-the-sender.md)). A pill of the sender's own and Dismiss ignore the hint. |

- A hint of another shape is refused whole: its role stays empty and the service logs `notifications: hints refused: app=<app> names=<hints>` once when the notification arrives.
- `x-vgs-click: open` without an accepted `x-vgs-open` is refused, so a card never promises a file it cannot open.
- A replacement notification brings its own hints; the card redraws with them.
- The state file stores the four roles. An entry may leave them out, as one stored before hints existed does, and reads back with each empty; the judge refuses a stored value the hint judge would refuse.

```bash
notify-send --app-name=Backup --urgency=critical \
  --hint=string:x-vgs-icon:circle-x --hint=string:x-vgs-tone:danger \
  --hint=string:x-vgs-open:/home/me/backup.log --hint=string:x-vgs-click:open \
  -- "Backup failed" "Exit code 3"
```

## The click

`NotificationLogic.clickRoute` answers what a choice on a card does once its hints are read: `open`, `dismiss` or `default`. Only an open, a click on the card or `invoke-latest`, reads the hints; a pill and Dismiss are `default`, which `NotificationLogic.choicePlan` plans. For `open`, the service runs its `open` floating TUI with the path as argv (`shell.tui.run("open", [path])`), then the card leaves. A refused run keeps the card and shows why in a core toast (`NotificationLogic.openOutcome`): `busy` while another notification's file is open, since the TUI is one key whatever the file and the capability keys a run by its script alone, and `launcher-missing` with no terminal. The file stays one click away. The TUI's presentation is `plain`, since the editor owns the window.

`tui/open.sh` runs `$EDITOR` on the file, split on white space so `code --wait` works, in the terminal the TUI opened. With `EDITOR` unset or empty it hands the file to `xdg-open`. The path is absolute, so no editor reads it as an option. A file that is gone or unreadable, such as a transcript the automations' history pruned, is refused with `notifications: refused: file=unreadable path=<path>`, and the window holds the refusal until a key. `$EDITOR` is the one the terminal's environment holds, as the presenter hands it on ([tui.md](tui.md)).

## Invariants

1. Only a hint of its shape reaches a card, and a click follows the stored hints. Enforced by `scripts/test-notifications-logic.js`, with a control per rule.
2. The open TUI opens only an absolute path it can read, through `$EDITOR` split into words or `xdg-open`, and hands on the opener's failure. Enforced by `scripts/test-notifications-open.sh`, with a control per rule.
3. A hinted card draws its icon, an `open` click hands the TUI the file, a click while another file is open keeps the card and shows a toast, and a `none` click opens nothing. The refusal table is `scripts/test-notifications-logic.js`'s, with a control per reply. Enforced by `scripts/smoke/rows/notifications.sh` in the nested sandbox, with a stand-in terminal and a stand-in `xdg-open`.
