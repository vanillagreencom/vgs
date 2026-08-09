# Overlays and dependencies

## Boundary
| Kind | VGS | Local overlay |
|------|-----|---------------|
| Shell UX | Default modules, widgets, helpers, bundled plugins | Extra commands and local labels |
| Defaults | Shipped `*.default.json` seeds | Mutable `~/.config/vshell/*.json` state |
| Dependencies | Feature groups and checks | Installed package set |
| Backends | Generic commands/adapters | Personal scripts, accounts, secrets |
| Machine prefs | Safe defaults | Monitors, geometry, profiles |

## Local overlay paths
| Path | Role |
|------|------|
| `~/.config/vshell/settings.json` | Mutable user shell settings; not tracked |
| `~/.config/vshell/plugin_settings.json` | Mutable user plugin enablement/settings; not tracked |
| `~/.config/vshell/plugins/` | User plugin overrides; takes precedence over bundled plugins |
| `~/.config/vshell-local/menu.json` | Menu categories/items overlay |
| `~/.config/vshell-local/webapps.json` | Generated webapp menu items |

### Overriding a bundled id
A user package replaces a shipped package for a **bundled id** only if its manifest says that is
what it means:

```json
{ "id": "vgsMenu", "overrides": "vgsMenu" }
```

`overrides` accepts the id, a list of ids, or `true` ("whatever id I declare"). Declaring it is
the whole trust decision — the loader never infers an override from a name match.

| The package | What VGS does |
|-------------|---------------|
| Declares the override | Replaces the shipped package, and inherits **always-available**: auto-enabled without the user turning it on, and `disablePlugin` refuses it |
| Reuses a bundled id without `overrides` | Stays inert. The shipped package keeps the id, and a one-time toast names the collision |

Always-available exists because an override that owns the id and never starts is a product surface
that goes dark — `vgsMenu` is the app launcher and the shell ships no fallback. It is *not* extended
to a bare collision, because auto-loading a package the user never enabled purely because its id
matches something VGS happens to ship is a decision nobody made. Scan order does not matter: the
bundled directory can be read after the user one, and a colliding package that got the id first is
reclaimed when the shipped manifest is parsed.

Because always-available packages cannot be disabled, Settings → Plugins does not offer them a
disable toggle at all — it shows an "Always on" badge instead of a control that can only refuse
(`Modules/Settings/PluginListItem.qml`). `vshell ipc call plugins disable <id>` answers
`PLUGIN_ALWAYS_AVAILABLE: <id>`, distinct from `PLUGIN_DISABLE_FAILED`.

Enabled is not the same as loaded, and an override still has to provide the surface the shipped
package did. **The swap is gated:** `_onManifestParsed` runs the override's `startupCheck` and
compiles its components *before* the shipped package is unloaded. If the gate fails, `requires_shell`
is incompatible, or a component fails to compile, the override is demoted — the shipped package keeps
(or takes back) the id and stays loaded, and a toast names the override and the reason. That toast is
emitted only once the shipped package has actually loaded: restoring it means re-reading its
manifest, which is asynchronous, so "the version bundled with VGS is still in use" said at the moment
the read *started* would be a claim about a plugin that may never load. `PluginService` tracks the
promotion and reports the real outcome — bounded by a deadline so a promotion that settles neither
way still reaches the user (VGS-75). It also names the package that actually took the id: with
several overrides claiming one id the promoted candidate can be another user package, not the shipped
one, so the message reads "the version bundled with VGS is still in use" only when that is what
loaded. Demotion is
available whenever a shipped manifest for the id is still on disk, so it does not depend on which
directory was scanned first. `requires_shell` is judged once shell version detection (asynchronous)
has produced a version; an override that took the id before then is rechecked and demoted when the
version lands. An override that loads but drops
its daemon surface or its `toggle()` is still a way to disable the launcher: the dock and bar buttons
then report "App launcher unavailable" via `PluginService.toggleAppLauncher()` instead of doing
nothing.

`_bundledPluginIds` tracks ids seen from the bundled directory and is cleared when the last bundled
manifest for an id disappears, so a shipped package that is removed stops making a same-id user
package auto-enabled and undisableable.

A **bundled** manifest's `requires_shell` is audited, never enforced: refusing to load a shipped
package would take its product surface offline, which is worse than an unmet declaration. An
unsatisfiable one is still a bug, because an override is normally a copy of the shipped manifest and
inherits the constraint — every bundled manifest declared `>=1.0.0` against a 0.1.0 shell, which made
overriding any bundled plugin impossible while looking like nothing was wrong.
`PluginService._auditBundledRequirement` logs it at runtime and
`scripts/test-bundled-override.js` fails the build for it (VGS-76). The runtime audit walks every
known manifest, not only the ones that won their id: a shipped manifest shadowed by an override holds
no record in `availablePlugins`, and that is precisely the configuration the audit is meant to
explain.

### Rescanning

`vshell ipc call plugin-scan scan` only reads manifest paths it has never seen — a path already in
`knownManifests` is skipped, so **editing a manifest in place is not picked up by a scan**. Use
`plugin-scan rescan <id>`, which re-reads *every* manifest claiming that id, drops the
blocked/demoted flags, and lets the policy arbitrate again from scratch. Rescanning only the owner's
path could never change an override's outcome, since the package that lost the id is exactly the one
that is never re-read (VGS-75). `rescan <id>` accepts an id that currently has **no** owner, as long
as a manifest claiming it is still known — an id left empty by a demotion or a collision is the state
the command exists to repair, and it is the state in which the id has no record to look up.

Ownership is settled by id; identity is by path. Precedence is source priority (user > bundled >
system), and **within one source the manifest path breaks the tie** — two user packages claiming one
id resolve to the same owner whichever of the two asynchronous manifest reads finishes first. Sorting
the reads cannot provide that, because `FileView` completion order is not the order they were
started in.

Whether a swap has to **tear the running package down** is judged by manifest path too
(`PluginService._displacesLoadedPackage`), never by source. Two packages in one directory are still
two packages, and a takeover the loader does not recognise is one it never unloads — the old
package's components stay installed while `availablePlugins` points at the new record. `loaded` is a flag on the info record, and
re-parsing a manifest builds a new record, so `PluginService._relinkLoadedRecord` hands the loaded
registration to the new record for the same path. Without it `availablePlugins` and `loadedPlugins`
held two records that disagreed, and the plugin could never load again — silently. A collision that
ends with no package owning a bundled id is reported as an error naming every candidate path, never
as a quiet unload.

## Menu overlay schema
```json
{
  "categories": [
    { "id": "local", "label": "Local", "icon": "*", "description": "Local actions" }
  ],
  "items": [
    {
      "category": "local",
      "title": "Action",
      "subtitle": "What it does",
      "icon": "*",
      "keywords": ["search"],
      "argv": ["command", "arg"]
    }
  ]
}
```

`{home}` expands to `$HOME` in `argv`.

## Webapp overlay schema
```json
{ "items": [ { "category": "webapps", "title": "App", "argv": ["command"] } ] }
```

## Dependency manifest
Path: `config/vshell/dependencies.json`.

Commands:
```bash
vshell deps status --json
vshell deps check capture --json
```

The `undeclared` map at the top of the file records commands shipped code probes
but deliberately does not declare, one reason each. Nothing reads it at runtime;
it is what tells a deliberate exclusion from drift. Adding a new probe means
declaring the command under `features` or adding it there.

`scripts/check-command-declarations.py` enforces that, in both directions: a
probe that is neither declared nor excluded fails, and so does an exclusion for
a command nothing probes any more. It scans `shutil.which()` in shipped Python,
`command -v` in shipped shell, and argv-head literals in shipped QML/JS. Its
coverage boundary — including what it deliberately does not scan, such as argv
built from a variable and the inside of an `sh -c` payload — is written in the
script's module docstring.

Manifest entries use `commands` for unconditional tools, `anyCommands` for
same-purpose alternatives, `compositorCommands` for complete
Hyprland/Niri-specific command lists, and `requiresFeatures` to depend on
another feature group rather than restating its commands — a group whose
requirement is unavailable reports `@<feature>` in its own `missing` list. `vshell deps` selects only the active
compositor branch; without an active session, any fully available branch is
accepted.

Feature groups:
| Feature | Purpose |
|---------|---------|
| `base` | Shell runtime |
| `theme` | Theme engine |
| `theme-gtk` | GTK theme, icon theme and color-scheme application (gsettings) |
| `theme-firefox` | Firefox theming (pywalfox) |
| `fonts` | Font cache refresh after a font change (fc-cache) |
| `greeter` | VGS greetd greeter, Hyprland or Niri launch, GNOME keyring policy, optional fprint/U2F PAM support |
| `capture` | Screenshots |
| `capture-edit` | Screenshot editor |
| `ocr` | Region OCR |
| `recording` | Screen recording |
| `launcher-zoxide` | Optional recent-directory search mode in launcher/menu |
| `launcher-search` | Launcher text search (ripgrep). Missing means text search fails outright |
| `launcher-search-fast` | Faster launcher file search (fd). Missing only means the built-in directory walk is used |
| `trash` | Trash instead of deleting, keeping restore (gio) |
| `launcher-folder-open` | Launcher "Preferred app" folder opener, which runs `gio open` |
| `network-usage` | Per-interface traffic statistics |
| `gamma` | Night-light color temperature |
| `updates-arch` | Repo updates |
| `updates-aur` | AUR updates |
| `ai-usage` | AI usage widget backend |
| `tailscale` | Tailscale widget |
| `clipboard` | Clipboard history (wl-clipboard) |
| `thumbnails` | File/image thumbnails |
| `brightness` | Display brightness backends |
| `sudo-toggle` | Passwordless sudo toggle widget: status and **revoke**, which need no terminal |
| `sudo-toggle-grant` | **Granting** passwordless sudo, which needs a terminal to prompt in |
| `terminal` | The terminal VGS opens for TUI actions. Any one alternative is enough |
| `default-apps` | XDG default-application layer (`xdg-mime`) |
| `file-manager` | File manager the launcher opens folders with, when the XDG default resolves to none |
| `launcher-folder-open-yazi` | Launcher Yazi folder opener (needs `yazi` *and* `terminal`) |
| `app-scopes` | Launching apps into their own systemd scope (`uwsm`) |
| `cloud-sync` | Cloud file sync (rclone) |
| `cloud-sync-stream` | Cloud sync streaming FUSE mounts |
| `desktop-integration` | Opening files and URLs in their default application (xdg-utils, desktop-file-utils) |
| `system-monitor` | CPU, GPU, memory and process widgets (dgop) |
| `audio-visualizer` | Audio visualizer widget (cava) |
| `calendar` | Calendar events in the dash (khal) |
| `bluetooth-codecs` | Bluetooth audio codec selection (pactl) |
| `launcher-type-out` | Launcher type-out into the focused window (wtype) |
| `fingerprint-auth` | Fingerprint unlock on the lock screen and greeter (fprintd) |
| `theme-qt` | Qt application theming (qt6ct/qt5ct) |
| `polkit` | Privileged actions run from the shell (pkexec) |

## Packaging metadata
The manifest is also what the native packages advertise as optional
dependencies. `packaging/optional-packages.json` maps every manifest command to
a distribution package name (or a `skip` reason when a hard dependency already
covers it), and `scripts/gen-package-metadata.py` joins the two files and
rewrites the generated blocks in the Arch, Debian, Fedora, and Gentoo recipes.

```bash
scripts/gen-package-metadata.py            # verify
scripts/gen-package-metadata.py --write    # regenerate
```

Adding a command to `dependencies.json` without a mapping entry fails the check,
so the packaging cannot silently fall behind the manifest. Details and the
per-channel mechanisms are in `packaging/README.md`.

## Rules
- Missing optional deps must not crash shell.
- Widgets show unavailable/empty state when backend missing.
- VGS ships defaults and bundled plugin code; `~/.config/vshell` holds mutable user state.
- Dotfiles supplies private overlays/wiring, not whole-directory VGS config symlinks.
- No personal command is required for default VGS startup.

## Probing rules

**Rule (enforced).** Shipped code must not probe for a command that exists only
in a private dotfiles repo — one no distribution packages and VGS does not ship.
A private wrapper belongs behind a user setting the shipped code already passes
through (the launcher folder opener uses `launcherFolderOpenCommand`), not behind
a `which()` on its name.

Known exceptions, both of which fall back to `xdg-open` rather than advertising
an action they cannot perform:

| Site | Command |
|------|---------|
| `bin/vshell-capture-screenshot` § `open_folder` | `yazi-scratchpad-open` |
| `bin/vshell-capture-screenrecording` § `open_folder` | `yazi-scratchpad-open` |

**Rule (enforced).** Every distribution-installable command that gates
user-facing behaviour is declared under `features` in `dependencies.json`, so
`vshell deps status` can report it. Commands deliberately left undeclared are
listed with their reason in the `undeclared` map at the top of the file, and
`scripts/check-command-declarations.py` fails on anything in neither place —
and on a stale exclusion for a command nothing probes any more.

One class of entry in that map is a debt rather than a settled decision, and
the map is where it stays visible: `mmsg` and `yazi-scratchpad-open` are probes
for commands VGS neither ships nor supports — `mmsg` is miracle-wm IPC, which
can never succeed on a Hyprland or Niri session. Each falls back rather than
advertising an action it cannot perform, but each should be removed rather than
declared.

## Terminal and file-manager resolution

VGS resolves a terminal in exactly one place: `bin/vshell-helper`, reached from
everywhere else through the `vshell terminal` CLI. QML, plugin JS, bash and the
Go backend all call it; none of them names a terminal binary, and nothing
outside it invokes `xdg-terminal-exec` or `uwsm`.

```bash
vshell terminal resolve [--json] [--prefer TERM]  # what would be used, and why
vshell terminal open [--app-id ID]                # a terminal window
vshell terminal exec [--app-id ID|--tui] [--hold] [--wait] [--prefer TERM] \
                     -- <cmd> [args...]
```

The chain, most preferred first:

| Source | Where it comes from |
|--------|---------------------|
| `--prefer` | a terminal the caller already resolved and must not have discarded (the backend's `upgradeParams.terminal`) |
| `terminalOverride` | Settings -> Launcher terminal picker, stored in `session.json` |
| `$TERMINAL` | the session environment |
| `xdg-terminal-exec` | the full XDG terminal spec, when it happens to be installed |
| `xdg-terminals.list` | the same user choice, parsed directly — Settings -> Default Apps -> Terminal writes this file |
| installed terminals | `TERMINAL_CANDIDATES` in the helper, mirrored by the `terminal` feature group |

`xdg-terminal-exec` is **AUR-only**, so it is an alternative and never a
requirement: a default install with any terminal at all works. It is
deliberately *not* one of the `terminal` feature group's alternatives — it
launches a terminal rather than being one, so counting it would report the
group available on a machine with no terminal installed, which is the VGS-54
defect in a new costume. It sits in the `undeclared` map with that reason. Each terminal's
argv shape (`-e` vs `--`, `--class=` vs `--app-id=` vs `-class`) lives in
`TERMINAL_SPECS`; a terminal with no app-id equivalent has the app-id dropped
rather than passed as an option it would reject. `uwsm app --` is prepended only
when uwsm is present and the session is systemd — it is an enhancement, and
hardcoding it is what made every VGS terminal action fail with
`command not found` on installs without it (VGS-54). Because presence does not
prove the session can use it, usability is settled once per process with a
`uwsm app -- true` probe rather than by watching the payload die — retrying the
payload unscoped would run the user's command twice. `VSHELL_NO_APP_SCOPE=1`
turns it off outright (the capture and screensaver scripts honour the same
variable).

A terminal that exits within the settle window only means the *terminal* failed
when the payload cannot itself exit fast, which is what `--hold`'s wrapper
guarantees. Without `--hold` the status belongs to the user's command, so the
next candidate is **not** tried: retrying would flash a window and re-run that
command once per installed terminal.

Failures reach the user, not just stderr. Every call site launches through
`Quickshell.execDetached`, which discards output and exit status, so
`vshell terminal` reports "no terminal found" through the shell's toast IPC,
falling back to `notify-send`. A button that cannot work has to say so — a
silent no-op is worse than the `command not found` toast VGS-54 was reported
for.

By default `vshell terminal exec` returns as soon as the window is up. A caller
that treats that exit as "the command finished" — the backend's upgrade
supervisor does, and would otherwise permit a second package-manager run on top
of a live one — must pass `--wait`, which blocks for the terminal's whole
lifetime and returns its status.

Granting passwordless sudo needs a terminal to prompt in; reading status and
**revoking** a grant do not. The widget gates on `vshell sudo-toggle status`
rather than on `deps`, so the safety valve works either way — but the two halves
are separate feature groups (`sudo-toggle`, `sudo-toggle-grant`) so that
`vshell deps status` says the same thing the runtime does. Collapsing them would
have the reporting layer tell a terminal-less user they cannot take back a grant
they can always take back (VGS-11).

The file manager follows the same rule: `xdg-mime query default inode/directory`
first — the XDG layer Settings -> Default Apps writes — then the installed
candidates in the `file-manager` group. An entry with `Terminal=true` (yazi,
ranger, lf) is opened through the terminal resolver, so a TUI default is a
legitimate choice rather than a folder that never opens.
