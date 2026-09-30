# One-time migrations

Covers: bin/vgsh-migrate, bin/migrations/*, scripts/test-vgsh-migrate.sh, scripts/test-migration-slack-photos.sh

A migration is a change VGS makes once to a user's own files when a new version needs it, such as turning on a setting the user relied on before it became opt-in. [D076](../decisions/D076-one-time-migrations.md) records the choice; Omarchy's `bin/omarchy-migrate` is the model.

## Migrations

- One bash script per migration under `bin/migrations/`, named `<unix time, 10 digits>-<slug>.sh`, the slug lower-case letters, digits and single hyphens. The names sort in the order the migrations run, so a new migration takes the time it was written. A name outside the pattern refuses the whole run before any migration runs.
- A migration runs once per user. It is idempotent: it reads the state it would change and changes nothing when there is nothing to change, so it is safe on a fresh profile and after a partial run.
- A migration uses no network and asks for no privilege. It edits the user's own files, never `/etc`, and asks nothing: no prompt, no terminal. It writes a setting through `vgsh-plugin-judge seed-setting`, which keeps a symlinked file a link and leaves a key the user already set.
- A migration that reads a credential store reads presence alone, never a secret, and unlocks nothing, as the plugin's own probe does ([status.md § The Slack token rows](status.md#the-slack-token-rows)).

## The runner

`bin/vgsh-migrate run [--notice]` runs each pending migration, one without a marker under `${XDG_STATE_HOME:-~/.local/state}/vgs/migrations/`, in name order. `bin/vgsh-migrate`'s header states every line it prints and every refusal.

- Each runs as `bash -euo pipefail` with stdin from `/dev/null`, `VGS_ROOT` the tree's root and `VGS_MIGRATION` its name, under `setpriv --no-new-privs`, so no setuid program it starts, such as `sudo`, gains a privilege, and under `timeout` 20 s, so a stuck migration holds the shell's start for 20 s at most, below the 30 s `vgsh restart` waits for the new shell.
- A migration that exits 0 gets its marker, a file of its name holding the time it ran. One that fails or times out gets none and stops the run: no later migration runs, the run exits 1, and the next run tries it again first. With `--notice` a failure also shows a Hyprland warning notice for 10 minutes, which names no command ([D061](../decisions/D061-no-manual-commands.md)).
- One run at a time: a run holds `flock` on the state directory's `.lock`, and a second run refuses at once with exit 75, leaving the migrations to the first.

## When migrations run

- **`vgsh run`**, once it holds the instance lock and before it starts the shell, runs `vgsh-migrate run --notice` and starts the shell whatever it answers. Every install method reaches this: a package update restarts the shell through the updates pipeline, and a login starts `vgsh run` ([runtime.md § Process](runtime.md#process)).
- **`vgsh self update`** runs the updated tree's `vgsh-migrate run` before it restarts the shell, for a checkout and a curl install ([distribution-methods.md](distribution-methods.md)). A failure prints its line and leaves the migration to the next `vgsh run`.
- **`vgsh migrate`** runs them on the command line, and `vgsh migrate --pending` lists the pending names.

## The migrations

| Migration | What it does |
|---|---|
| `1790801764-slack-photos-extra.sh` | Turns on the owner-only Slack photos extra ([D075](../decisions/D075-consumer-features-need-no-developer-setup.md)) for a user who had Slack photos: when the photo cache records an account it served, or libsecret holds an item of service `vgs-notifications`, and the user's `vgs.notifications` row does not name `slackPhotos`, it writes `"slackPhotos": true`. The keyring is asked with `secret-tool search` without `--unlock`, stdout discarded, as `token-status.sh` asks it. No `secret-tool`, a store that refuses the search and no cache record leave the extra off; a search that times out fails the migration, which runs again at the next start. |

## Invariants

1. Each migration runs once, in name order; a failed one stops the later ones, gets no marker and runs again; a run holds the lock alone; a migration runs with no new privileges, no stdin and a bounded time. Enforced by `scripts/test-vgsh-migrate.sh`, each rule with a control.
2. `vgsh run` migrates before it starts the shell and starts it after a failure, with the notice; `vgsh self update` runs the updated tree's migrations. Enforced by `scripts/test-vgsh-migrate.sh` and `scripts/test-vgsh-self.sh`, each with a control.
3. The Slack photos migration reads no token, unlocks nothing and keeps a user's own choice. Enforced by `scripts/test-migration-slack-photos.sh` with a stub `secret-tool`, each rule with a control.
