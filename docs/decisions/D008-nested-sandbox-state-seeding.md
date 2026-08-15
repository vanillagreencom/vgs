# D008: The nested smoke sandbox is seeded from the repo alone; no host state

[← Decision Index](INDEX.md)

**Date**: 2026-08-14
**Status**: Active
**Research**: VGS-92
**Applies to**: `scripts/qml-smoke.sh --nested`

## Summary

`scripts/qml-smoke.sh`'s nested sandbox builds its user state **from the repo
and nothing else**: the shipped defaults in `config/vshell/` are seeded into a
throwaway HOME, and nothing is copied out of the operator's
`~/.config/vshell`. Sentinel values then prove at run time that the seed — not
SettingsData's own declared defaults — is what the shell is running on.

## Context

**Both halves already landed**, together, in 6e1673cd (VGS-81, PR #98,
2026-08-09); `main` carries them. What had never been decided is which of them
wins, and that is what this record settles.

The first half answers VGS-92. Between 57d92829 (2026-08-02) and that commit,
the sandbox copied host state with `cp -a`, which preserves symlinks. On the
documented workstation wiring (AGENTS.md § Live workstation wiring)
`~/.config/vshell/settings.json` is a *relative* symlink into `~/dotfiles`, so
it dangled once copied into the sandbox's HOME. The sandboxed shell found no
settings and fell back to SettingsData's defaults — silently, since the shell
starts and the plugins load either way. Every nested run in that window
exercised whatever the fallback produced while the comment above the copy
claimed it exercised "the real theme/settings paths". `cp -aL` dereferences.

The second half seeds `settings.json` and `plugin_settings.json` from
`config/vshell/*.default.json`, so the popout and override phases have a bar
layout they can rely on.

Those pull in opposite directions. The host copy makes the *operator's*
configuration decide what the run exercises; seeding makes the *repo's*
defaults decide. Carrying both with no stated precedence is how the block became
self-contradictory, and it is why the VGS-92 diff adds the sentinels rather than
the `cp -aL` a reader might go looking for here.

Deciding for the repo then killed the host copy outright, in two steps and for
one reason. Copying everything and deleting the recognised parts inherited
whatever it forgot to name — host `theme.json`, `Common/MethodTheme.qml`'s
source of truth for the whole palette, reached every sandbox unnoticed.
Narrowing that to an allowlist of `themes/` + `blueprints/` did not hold
either: a user theme package composes over a built-in file by file and a user
blueprint shadows a built-in by name (`bin/vshell-helper::compose_theme_files`,
`::list_themes`). So whichever theme a sandbox resolved was the operator's to
steer — the moment they overlay a name the run touches, that name composes from
their files, and the log-error scan is then reading a theme the repo never
shipped. Exposure is a property of one machine's config, not of the design:
whether any *particular* run was steered depends on which names that operator
happens to overlay. Applied honestly, "no phase's outcome may differ because of
host state" leaves no host state.

## Decision

1. **Seeded state is authoritative.** `settings.json` and
   `plugin_settings.json` are written from `config/vshell/settings.default.json`
   and `config/vshell/plugin_settings.default.json`.
2. **Nothing is copied out of `~/.config/vshell`.** Not `theme.json`, not
   `themes/`, not `blueprints/`, not `hooks/`, `generated/` or `branding/`.
   There is no allowlist to audit and no `DEGRADED` path, because there is no
   host read. The repo's theme *packages* remain reachable through
   `VSHELL_ROOT`, but no `theme.json` is generated — see § Scope.
3. **No phase's outcome may differ because of host state**, which rule 2 makes
   structurally true rather than a claim to police. The test each candidate
   directory failed is "can any phase's outcome differ because of it?" —
   `theme.json` decides the whole palette (`Common/MethodTheme.qml`); a user
   theme package composes over a built-in file by file and a user blueprint
   shadows a built-in by name (`bin/vshell-helper::compose_theme_files`,
   `::list_themes`), so `themes/` and `blueprints/` both steer what
   `vshell theme current` resolves and therefore what the log-error scan sees;
   `hooks/` is host-authored executables. The sandbox's
   `~/.config/vshell/plugins` is neither copied nor seeded, and `override_check`
   asserts no user package is in it before planting its fixture — the moment
   that property matters, rather than at prep time where nothing could have
   created one.
4. **The seed's effect is asserted, not assumed — for every seeded file.** Both
   `settings.json` (`customAnimationDuration=4242`) and `plugin_settings.json`
   (`sysUpdate.aurUpdateCommand`) carry a sentinel equal to neither the shipped
   value nor the fallback the shell would use without the file, and
   `seeded_settings_check` reads both back out of the running shell via
   `qs ipc call settings get`. It is the first state-dependent phase and gates
   the popout and override phases; the bundled-plugin wait is NOT gated on it,
   because plugin loading does not depend on settings. Both reads are EXACT —
   the scalar compared literally, the plugin one parsed as JSON and asserted at
   `sysUpdate.aurUpdateCommand` — because a substring test would accept `14242`
   for a `4242` sentinel, or the right pair under the wrong section. From
   teardown on, every diagnostic (the log-error scan included) precedes every
   verdict, so no failure withholds the evidence for itself; of the two
   failures that can end a run earlier, the launch failure prints the log tail
   and "no bundled plugins in the repo" has no log evidence to print.

## Rationale

| Concern | Repo-only seed | Any host state, however narrow |
|---------|----------------|--------------------------------|
| Reproducible across machines | Yes — the same bytes on every checkout | No — the result depends on whose config it ran on |
| Reproducible across runs | Yes | No — the operator edits their config between runs |
| Forecloses running in CI | No | Yes — a runner has no `~/.config/vshell` at all. Neither column runs in CI *today*: per AGENTS.md § "What CI covers", only the static half of `qml-smoke.sh` runs there and `--nested` is local-only, needing Hyprland and `quickshell` on PATH |
| Covers what VGS ships | Yes — the shipped defaults are what a new user gets | Only incidentally |
| Catches "my config breaks the shell" | No | Yes, but only for one person's config, and it is not what this smoke is for |

The deciding argument is that a sandbox whose verdict depends on the machine it
ran on is not a sandbox. VGS-92's own symptom demonstrates the cost directly:
the bar layout every nested run exercised had been chosen by an accident of how
one operator stores their dotfiles, and nothing in the run said so.

Dropping the host read cost less than expected. The enrichment it was kept for —
real theme packages, wallpapers, blueprints — ships in the repo under `themes/`
and is reached through `VSHELL_ROOT`, so the theme paths still run against real
content, and now against the same content everywhere.

Rule 4 exists because rules 1-3 are unobservable without it. Most keys in
`settings.default.json` repeat the default SettingsData declares inline — and
for plugins, `getPluginSetting` falls back through `defaultPluginSettings`,
loaded from the REPO's `config/vshell/plugin_settings.default.json` (`Paths.repoRoot`,
never the sandbox copy), so the same is true one file over. A check reading any
unstamped key answers identically whether the seed was found or not, and that
non-discriminating shape is precisely what let VGS-92 survive.

## Scope: theme state is out

**The sandbox seeds no `theme.json`, so the shell renders on `MethodTheme`'s
hardcoded `fallbackColors`.** A `theme.json` regression, or a theme that fails
to load, passes this smoke unseen. That is a deliberate boundary, not an
oversight, and it is the one place where "the repo's content reaches the run"
has a hole: the theme *packages* under `themes/` are reachable through
`VSHELL_ROOT`, but nothing generates the file the shell actually reads
(`Common/MethodTheme.qml` § `themePath`).

Seeding one was considered and rejected on measurement:

| Route | Why not |
|-------|---------|
| Copy a repo file | None exists. A package's `theme.json` is a manifest (`name`, `mode`, `pair`, `source`, `wallpaper`); the runtime file additionally needs a `colors` map |
| Compose it in the smoke from `colors.toml` | Would reimplement the helper's `colors.toml` → role mapping, a second source of truth that drifts — the defect class this record exists to remove |
| Generate it with `vshell theme apply` | Measured in an isolated HOME: renders a dozen app-target configs (kitty, alacritty, btop, qt6ct, …) and runs hooks that reach the **live tmux socket** and attempt a shell reload. A validation script must not do that |

**Revisit when** the helper grows a hook-free, single-target way to write only
`theme.json` — `_apply_theme_obj_unlocked` already supports
`only_target=`/`run_hooks=False`, but only reachable through
`theme adjust --preview` on the already-current theme. Exposing that as a
seeding entry point would make theme state assertable here the way the two
seeded files already are.

## Alternatives Considered

| Alternative | Why rejected |
|-------------|--------------|
| Host state only, fixed with `cp -aL` | Correct but not reproducible: the run's meaning changes when the operator edits their config, and it could never move to CI |
| Keep both with no stated precedence | The status quo ante, and the direct cause of a comment that asserted a property the code did not have |
| Copy everything, then delete what is seeded | Let host `theme.json` — MethodTheme's whole palette — into the sandbox unnoticed. A denylist inherits whatever it forgets to name |
| Copy an allowlist of `themes/` + `blueprints/` | The same defect one level down: user theme packages compose over built-ins file by file and user blueprints shadow built-ins by name, so any name the operator overlays is theirs to steer. Whether a given machine's config actually overlays the name a run resolves is luck, and a guarantee that holds by luck is not one |
| Seed the current theme from a repo-only source and keep the allowlist | Machinery to buy back an inheritance nothing needed; the repo's own `themes/` already reaches the sandbox through `VSHELL_ROOT` |
| Assert on a normal seeded key instead of a sentinel | Non-discriminating: its seeded value equals the fallback, so it passes in both worlds |
| Assert only on `settings.json` | `plugin_settings.json` is seeded on the adjacent line and has its own repo-file fallback, so the same defect one file over would pass every phase |

## Verification

```bash
scripts/qml-smoke.sh --nested --require-static --require-nested
```

Run it with `WAYLAND_DISPLAY` exported to the value a session shell reports and
`XDG_RUNTIME_DIR` to `/run/user/$(id -u)`. The socket basename is
session-dependent, so this cannot name it; VGS-70 will have `--nested` discover
it.

A passing run prints `seeded settings check passed`. Two must-fail controls,
both exercised on this branch:

- Suppress either sentinel stamp in `scripts/qml-smoke.sh::nested_check` and
  re-run: the check must fail with the unstamped value, not pass.
- Stamp `14242` instead of `4242`, or write the plugin pair under `aiUsage`
  instead of `sysUpdate`: both must fail. A substring match passes both.
- Set a sentinel equal to the value already in the shipped default: the stamp
  step must refuse it rather than seeding a witness that cannot discriminate.
- Plant a runtime QML error *and* suppress a stamp: the run must still print
  the log-scan findings, because rule 4's log scan runs regardless of the phase
  verdicts.

**This assertion is local-only by construction.** `--nested` needs Hyprland and
`quickshell` on PATH, so CI runs only the static half of `qml-smoke.sh`
(AGENTS.md § "What CI covers, and what it cannot"). Nothing in CI enforces
D008; a green PR is not evidence the sandbox seeded correctly, and the command
above has to be run locally before finishing QML work.

## References

- VGS-92 — the `cp -a` symlink defect and this decision's acceptance criteria
- VGS-81 / PR #98 — introduced the deterministic seeding
- `scripts/qml-smoke.sh` — `nested_check`'s seeding block, `await_sentinel` and `seeded_settings_check`
- `bin/vshell-helper` — `compose_theme_files` and `list_themes`, the user-over-builtin precedence that ruled out a `themes/` allowlist
- AGENTS.md § Live workstation wiring — the dotfiles symlink that started this
