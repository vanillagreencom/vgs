# D027: Chromium follows the theme through its GTK mode alone

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Superseded by D029

**Research**: VGS-487

**Context**: Chromium, Google Chrome and Brave on Linux draw their frame in one of three modes the user picks under Appearance: GTK, QT or Classic. In GTK mode the browser reads its colours from GTK, which reads the `gtk3` and `gtk4` targets' import in `gtk.css`. In Classic mode the browser draws the colour the user picks inside it. The one input outside the browser that sets its theme colour is the managed policy `BrowserThemeColor`, read from a JSON file under `/etc/chromium/policies/managed/`, `/etc/opt/chrome/policies/managed/` or `/etc/brave/policies/managed/`. Those directories are root-owned. `chromium --refresh-platform-policy --no-startup-window` makes a running browser read the policy again. Upstream Chromium has no command-line switch that sets a theme colour: the change proposing `--set-theme-color` was abandoned. Theme apply runs as the user and writes only into its state directory, the include lines and links of D021 and D022, and the settings keys of D024. A target's schema refuses an absolute wiring path.

**Decision**: Of the two options, a privileged writer of the policy file and GTK mode only, the owner chose GTK mode only. No target writes Chromium's colour. A browser of the Chromium family follows the theme in its GTK mode, through the GTK targets, and keeps its own colour in Classic mode. Theme apply asks for no privilege and writes nothing under `/etc`.

**Rationale**:

- The GTK targets already carry the palette, so a user who wants the theme in the browser picks GTK once in its Appearance settings.
- A managed policy file is machine-wide: it sets the colour for every user of the machine and shows the browser as managed by an organisation. A theme apply is one user's choice.
- A privileged writer puts a `sudo` or `pkexec` step into every apply, which a background apply or a session without a password agent cannot answer.
- A symlink from `/etc` into the user's state directory needs root once, then hands every process of the user control over the browser's managed policy, including the policies that are not colours.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| A privileged writer: apply installs a root-owned 0644 policy file through `pkexec` or `sudo -n`, then refreshes the policy | Every apply asks for privilege, and one user's theme becomes a machine-wide managed policy. |
| A symlink from the policy directory to a file in the state directory | Any process of the user can then write any managed policy, not just the colour. |
| The `--set-theme-color` command-line switch | Upstream Chromium does not ship it. |

**Revisit When**: Chromium reads a theme colour from a file or setting the user owns, or the owner accepts a privileged step in theme apply.

**Verification**: `scripts/test-theme-render.js` refuses a target whose wiring names an absolute path, such as one under `/etc`. `themes/targets/` holds no Chromium target.

**References**: [D021](D021-theme-apply-writes-beside-each-destination.md), [D022](D022-theme-apply-keeps-managed-links-in-application-directories.md), [D024](D024-theme-apply-sets-one-theme-key-in-an-application-settings-file.md), [theme-browsers.md](../architecture/theme-browsers.md), [theme-toolkits.md](../architecture/theme-toolkits.md)
