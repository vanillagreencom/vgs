# D008: The nested smoke sandbox seeds from shipped defaults; host state is inert enrichment

[← Decision Index](INDEX.md)

**Date**: 2026-08-14
**Status**: Active
**Research**: —
**Applies to**: `scripts/qml-smoke.sh --nested`

## Summary

`scripts/qml-smoke.sh`'s nested sandbox gets its user state from two sources,
and the split is deliberate: **everything any check asserts on is seeded from
the shipped defaults in `config/vshell/`**, and the operator's own
`~/.config/vshell` is copied in only underneath that, as inert enrichment that
no assertion may depend on. A sentinel value proves at run time that the seed —
not SettingsData's built-in defaults, and not the operator's config — is what
the shell is running on.

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

Those pull in opposite directions. `cp -aL` makes the *host's* configuration
decide what the run exercises; seeding makes the *repo's* defaults decide.
Carrying both with no stated precedence is how the block became
self-contradictory, and it is why the VGS-92 diff adds the sentinel rather than
the `cp -aL` a reader might go looking for here.

## Decision

1. **Seeded state is authoritative.** `settings.json` and
   `plugin_settings.json` are written from `config/vshell/settings.default.json`
   and `config/vshell/plugin_settings.default.json`.
2. **The host contributes only an allowlist, dereferenced (`cp -aL`), and
   optionally.** Exactly `themes/` and `blueprints/` are copied from
   `~/.config/vshell`, by name. They bring real theme and wallpaper content the
   theme paths can chew on. A copy may fail — a genuinely broken symlink in
   someone's config must not fail everyone's smoke — and when it does the run
   says `DEGRADED` and continues without it.
3. **No assertion may depend on host state**, which is enforced by rule 2
   rather than asserted: an allowlist means the host cannot *supply* state
   worth depending on. Everything outside those two names is either seeded
   (`settings.json`, `plugin_settings.json`, `plugins/`) or would silently
   steer the run — `theme.json` is `Common/MethodTheme.qml`'s source of truth
   for the whole palette, `hooks/` is host-authored executables, `generated/`
   is app-target output, `branding/` replaces shipped assets. A copy-everything
   -then-delete shape cannot hold this line, because it must enumerate what to
   remove and silently inherits anything it forgets — which is how `theme.json`
   reached the sandbox unnoticed.
4. **The seed's effect is asserted, not assumed — for every seeded file.** Both
   `settings.json` (`customAnimationDuration=4242`) and `plugin_settings.json`
   (`sysUpdate.aurUpdateCommand`) carry a sentinel equal to neither the shipped
   default nor SettingsData's own default, and `seeded_settings_check` reads
   both back out of the running shell via `qs ipc call settings get`. It is the
   first state-dependent phase and gates the bundled-plugin wait, the popout
   phase and the override phase. The log-error scan is independent of it.

## Rationale

| Concern | Seeded defaults | Host state (`cp -aL` alone) |
|---------|-----------------|------------------------------|
| Reproducible across machines | Yes — the same bytes on every checkout | No — the result depends on whose bar layout it ran on |
| Reproducible across runs | Yes | No — the operator edits their settings between runs |
| Forecloses running in CI | No | Yes — a runner has no `~/.config/vshell` at all. Neither column runs in CI *today*: per AGENTS.md § "What CI covers", only the static half of `qml-smoke.sh` runs there and `--nested` is local-only, needing Hyprland and `quickshell` on PATH |
| Covers what VGS ships | Yes — the shipped defaults are what a new user gets | Only incidentally |
| Catches "my config breaks the shell" | No | Yes, but only for one person's config |

The deciding argument is that a sandbox whose verdict depends on the machine it
ran on is not a sandbox. VGS-92's own symptom demonstrates the cost directly:
the bar layout every nested run exercised had been chosen by an accident of how
one operator stores their dotfiles, and nothing in the run said so.

The host allowlist is nonetheless kept rather than dropped, because the theme
and wallpaper paths benefit from real content and no check asserts on it.
Dropping it would be defensible; it is not free, and it buys nothing rules 2
and 3 do not already guarantee.

Rule 4 exists because rules 1-3 are unobservable without it. Most keys in
`settings.default.json` repeat SettingsData's built-in default — and
`plugin_settings.default.json` is loaded into `builtInPluginSettings` as well
as `pluginSettings`, so the same is true one file over. A check reading any of
them answers identically whether the seed was found or not, and that
non-discriminating shape is precisely what let VGS-92 survive.

## Alternatives Considered

| Alternative | Why rejected |
|-------------|--------------|
| Host state only, fixed with `cp -aL` | Correct but not reproducible: the run's meaning changes when the operator edits their config, and it could never move to CI |
| Drop the host allowlist entirely | Loses real theme/wallpaper/blueprint content for no correctness gain, since no assertion depends on it |
| Keep both with no stated precedence | The status quo ante, and the direct cause of a comment that asserted a property the code did not have |
| Copy everything, then delete what is seeded | The shape that let host `theme.json` — MethodTheme's whole palette — into the sandbox unnoticed. A denylist inherits whatever it forgets to name |
| Assert on a normal seeded key instead of a sentinel | Non-discriminating: its seeded value equals the built-in default, so it passes in both worlds |
| Assert only on `settings.json` | `plugin_settings.json` is seeded on the adjacent line and has its own built-in fallback, so the same defect one file over would pass every phase |

## Verification

```bash
WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 \
  scripts/qml-smoke.sh --nested --require-static --require-nested
```

A passing run prints `seeded settings check passed`. The must-fail control for
that assertion is to suppress a sentinel stamp in
`scripts/qml-smoke.sh::nested_check` and re-run: the check must then fail with
the shipped default's value, not pass.

**This assertion is local-only by construction.** `--nested` needs Hyprland and
`quickshell` on PATH, so CI runs only the static half of `qml-smoke.sh`
(AGENTS.md § "What CI covers, and what it cannot"). Nothing in CI enforces
D008; a green PR is not evidence the sandbox seeded correctly, and the command
above has to be run locally before finishing QML work.

## References

- VGS-92 — the `cp -a` symlink defect and this decision's acceptance criteria
- VGS-81 / PR #98 — introduced the deterministic seeding
- `scripts/qml-smoke.sh` — `nested_check`'s seeding block and `seeded_settings_check`
- AGENTS.md § Live workstation wiring — the dotfiles symlink that started this
