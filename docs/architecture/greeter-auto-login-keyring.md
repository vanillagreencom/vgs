# VGS greeter auto-login and GNOME keyring policy

**Status:** implemented. `vshell greeter sync` owns greetd config, greeter
cache, VGS theme sync, auto-login launch, and opt-in empty-password
login-keyring provisioning.

## Policy

- `greeterAutoLoginKeyringMode = "keep"` is the safe default: the login
  keyring is left as-is (it stays locked under auto-login and Secret Service
  consumers prompt once per boot).
- On full-disk-encrypted auto-login systems the user can choose `"empty"` in
  Settings → Greeter and press the explicit conversion button:
  `vshell greeter keyring empty --force` backs up
  `~/.local/share/keyrings/login.keyring`, then provisions an empty-password
  replacement through `gnome-keyring-daemon` so it auto-unlocks at startup
  (what GNOME itself does under autologin).
- `vshell greeter sync` refuses to replace an existing keyring unless
  conversion was already completed or `--force-keyring` is passed.
- Auto-login launches via `vshell greeter launch-session --from-memory` in
  greetd's `[initial_session]`.

## Why (threat model)

PAM keyring unlock needs the password typed at the greeter; auto-login types
none, so `pam_gnome_keyring` can never unlock it — auto-unlock and auto-login
are mutually exclusive by design. On this machine root+home are LUKS, so the
keyring file is already encrypted at rest, and auto-login already removes the
login gate: an encrypted keyring password adds a per-boot prompt with ~zero
real security. Alternatives considered and rejected: capture-once password
auto-login (keeps a password step), disabling auto-login, non-Secret-Service
backends (libsecret consumers expect Secret Service).

## Gotchas (learned the hard way)

- `gnome-keyring-daemon --unlock` without `--replace` alongside the running
  `systemd --user` daemon spawns a split-brain second daemon and a mismatched
  `login.keyring`. Stop/replace the service; never race it.
- `pkill -x gnome-keyring-daemon` misses: `comm` truncates to 15 chars
  (`gnome-keyring-d`). Match the full cmdline.
- Empty-password provisioning must handle both "unlock existing" and "create
  new" states (the per-boot dialog wording tells you which).
- Legacy `pam_gnome_keyring.so` lines in `/etc/pam.d/greetd` are inert under
  auto-login (harmless); the VGS mechanism supersedes them.
