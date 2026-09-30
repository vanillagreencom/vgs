# D076: One-time migrations run once per user, in order, before the shell starts and after a self-update

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: [VGS-683](https://linear.app/vanillagreen/issue/VGS-683)

**Refines**: [D053](D053-runner-holds-the-instance-lock.md), [D069](D069-runner-supervises-the-shell.md)

**Context**: [D075](D075-consumer-features-need-no-developer-setup.md) turned Slack photos into an owner-only extra, off by default. A user who already had photos, the owner among them, would lose them at the next start unless their configuration names the extra. A plugin cannot write the key itself: the `configure` capability writes only keys the manifest's `schema` declares, and an extra has no schema entry. VGS had no way to change a user's files once when a new version needs it. Omarchy has one: `bin/omarchy-migrate` runs each script under `migrations/` once, keeps a marker per script under `~/.local/state/omarchy/migrations/`, and runs from `omarchy-update`; a login notice offers the pending ones.

**Decision**: A core migration runner, `bin/vgsh-migrate`, modelled on Omarchy's.

- **Migrations.** One bash script per migration under `bin/migrations/`, named `<unix time>-<slug>.sh` and run in name order. Each is idempotent, uses no network, asks for no privilege and asks no question. A migration that reads a credential store reads presence alone.
- **Once, in order.** A migration that exits 0 gets a marker under `${XDG_STATE_HOME:-~/.local/state}/vgs/migrations/`. A failure stops the run, gets no marker and runs again first next time, so a later migration never runs over an earlier one that did not finish.
- **Contained.** Each runs with stdin from `/dev/null`, under `setpriv --no-new-privs` and a 20 s `timeout`, below the 30 s `vgsh restart` waits for the new shell, and one run at a time holds the state directory's lock.
- **When.** `vgsh run` runs them once it holds the instance lock and before it starts the shell, with a Hyprland notice on a failure, and starts the shell whatever they answer. `vgsh self update` runs the updated tree's before it restarts the shell. `vgsh migrate` runs them by hand.
- **The first migration** turns the Slack photos extra on for a user whose photo cache or keyring shows a Slack token, unless the user's row already names the extra.

**Rationale**:

- `vgsh run` is the one path every install method reaches: a login, a restart after a package update through the updates pipeline, and a restart after a self-update. Running there needs no hook in a package manager and no systemd unit, which VGS does not ship.
- Running before the shell starts means the shell reads the migrated configuration from its first frame. The shell starts after a failure, because a broken migration must not leave the user without a bar.
- A failed migration keeps its place and the later ones wait, as Omarchy's `set -e` loop does, so the order a later migration assumes always holds.
- The notice tells a user who has no terminal open that something did not finish, and the retry at the next start needs nothing from them ([D061](D061-no-manual-commands.md)).
- `--no-new-privs` makes "asks for no privilege" hold for any setuid program a migration might start; the timeout keeps a stuck migration from holding the shell's start.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| The service treats an unset extra as on when a stored token exists | The configuration would say nothing while the behaviour depended on the keyring. An explicit value in the user's file is clearer and survives a cleared keyring. |
| Let `configure` write an extra's key | A plugin could then turn on its own owner-only feature. The extra is the user's choice, and a migration writes it once. |
| Run migrations only from `vgsh self update`, as Omarchy runs them from `omarchy-update` | A package install never runs `vgsh self update`. Every method reaches `vgsh run`. |
| A login notice that asks the user to run pending migrations, as `omarchy-migrate-notify` does | A migration VGS can run itself needs no click. The notice is kept for a failure. |
| Mark every migration done on a fresh install, as Omarchy's installer does | A migration here is idempotent and checks the state it changes, so on a fresh profile it changes nothing. Marking would need a second path in every installer. |

## Omarchy comparison

Omarchy (basecamp/omarchy `quattro`, `bin/omarchy-migrate` and `bin/omarchy-migrate-notify`, read at 8b4eae6) keeps one script per migration named by its unix time, a marker per script in `~/.local/state/omarchy/migrations/`, runs each with `bash -euo pipefail` and stops on the first failure. VGS takes the layout, the markers and the stop. It differs where VGS is not a distribution: migrations run from `vgsh run` as well as the self-update, since a package manager owns most installs; they run under `--no-new-privs` and a timeout, since they run before the shell starts; and a failure shows a notice while a pending migration needs no click.

**Revisit When**: VGS ships a systemd user unit or a package hook that could run migrations earlier, or a migration needs a privilege or a question.

**Verification**: `scripts/test-vgsh-migrate.sh` pins the order, the markers, the stop and retry, the name pattern, the environment, the lock, the timeout, the notice and both `vgsh` callers, each with a control; `scripts/test-vgsh-self.sh` pins the self-update's run with a control; `scripts/test-migration-slack-photos.sh` pins the first migration with a stub `secret-tool`, each rule with a control.

**References**: [D075](D075-consumer-features-need-no-developer-setup.md), [D053](D053-runner-holds-the-instance-lock.md), [D069](D069-runner-supervises-the-shell.md), [D061](D061-no-manual-commands.md), [migrations.md](../architecture/migrations.md).
