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

The two approaches arrived independently and conflicted in the same block of
code.

VGS-92 found that `cp -a -- "$HOME/.config/vshell" ...` preserved symlinks. On
the documented workstation wiring (AGENTS.md § Live workstation wiring)
`~/.config/vshell/settings.json` is a *relative* symlink into `~/dotfiles`,
which dangles once copied into the sandbox's HOME. The sandboxed shell found no
settings and fell back to SettingsData's defaults — silently, since the shell
starts and the plugins load either way. Every nested run had been exercising
whatever the fallback produced while the comment above the copy claimed it
exercised "the real theme/settings paths". The narrow fix is `cp -aL`.

VGS-81 (PR #98) had meanwhile started seeding `settings.json` and
`plugin_settings.json` from `config/vshell/*.default.json` so the popout and
override phases had a bar layout they could rely on.

Those pull in opposite directions. `cp -aL` makes the *host's* configuration
decide what the run exercises; seeding makes the *repo's* defaults decide.
Keeping both without saying which one wins is how the block became
self-contradictory in the first place.

## Decision

1. **Seeded state is authoritative.** `settings.json` and
   `plugin_settings.json` are removed after the host copy and written fresh
   from `config/vshell/settings.default.json` and
   `config/vshell/plugin_settings.default.json`. The copied user `plugins/`
   directory is removed outright, and its removal is verified rather than
   assumed.
2. **The host copy stays, dereferenced (`cp -aL`), and is optional.** It brings
   real themes, wallpapers and blueprints into the sandbox, which makes the
   theme paths exercise something plausible. It may fail — a genuinely broken
   symlink in someone's config must not fail everyone's smoke — and when it
   does the run says `DEGRADED` and continues on shipped defaults alone.
3. **No assertion may depend on host state.** Anything a check reads must be
   seeded. That is what makes the copy safe to be optional.
4. **The seed's effect is asserted, not assumed.** The seeding step stamps a
   sentinel (`customAnimationDuration=4242`) that equals neither the shipped
   default nor SettingsData's own default, and `seeded_settings_check` reads it
   back out of the running shell via `qs ipc call settings get`. It runs first
   and gates the popout and override phases.

## Rationale

| Concern | Seeded defaults | Host state (`cp -aL` alone) |
|---------|-----------------|------------------------------|
| Reproducible across machines | Yes — the same bytes on every checkout | No — the result depends on whose bar layout it ran on |
| Reproducible across runs | Yes | No — the operator edits their settings between runs |
| Runnable in CI | Yes | No — a runner has no `~/.config/vshell` at all |
| Covers what VGS ships | Yes — the shipped defaults are what a new user gets | Only incidentally |
| Catches "my config breaks the shell" | No | Yes, but only for one person's config |

The deciding argument is that a sandbox whose verdict depends on the machine it
ran on is not a sandbox. VGS-92's own symptom demonstrates the cost directly:
the bar layout every nested run exercised had been chosen by an accident of how
one operator stores their dotfiles, and nothing in the run said so.

The host copy is nonetheless kept rather than deleted, because the theme and
wallpaper paths benefit from real content and no check asserts on it. Deleting
it would be defensible; it is not free, and it buys nothing that rule 3 does
not already guarantee.

Rule 4 exists because rules 1-3 are unobservable without it. Most keys in
`settings.default.json` repeat SettingsData's built-in default, so a check
reading any of them answers identically whether the seed was found or not —
that non-discriminating check is precisely the shape that let VGS-92 survive.

## Alternatives Considered

| Alternative | Why rejected |
|-------------|--------------|
| Host state only, fixed with `cp -aL` | Correct but not reproducible: unrunnable in CI, and the run's meaning changes when the operator edits their config |
| Drop the host copy entirely | Loses real theme/wallpaper/blueprint content for no correctness gain, since no assertion depends on it |
| Keep both with no stated precedence | The status quo ante, and the direct cause of a comment that asserted a property the code did not have |
| Assert on a normal seeded key instead of a sentinel | Non-discriminating: its seeded value equals the QML default, so it passes in both worlds |

## Verification

```bash
WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 \
  scripts/qml-smoke.sh --nested --require-static --require-nested
```

A passing run prints `seeded settings check passed`. The must-fail control for
that assertion is to remove the sentinel-stamping step in
`scripts/qml-smoke.sh::nested_check` and re-run: the check must then fail with
the shipped default's value, not pass.

## References

- VGS-92 — the `cp -a` symlink defect and this decision's acceptance criteria
- VGS-81 / PR #98 — introduced the deterministic seeding
- `scripts/qml-smoke.sh` — `nested_check`'s seeding block and `seeded_settings_check`
- AGENTS.md § Live workstation wiring — the dotfiles symlink that started this
