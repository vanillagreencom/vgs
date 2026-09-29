# The sudo grant

Covers: bin/vgsh-sudo-grant, bin/lib/tmpfiles.d/**, scripts/test-vgsh-sudo-grant.sh

`vgsh sudo` is the core's time-boxed passwordless sudo grant: [D036](../decisions/D036-time-boxed-passwordless-sudo-grant.md). `bin/vgsh-sudo-grant` holds both halves, and its header states each verb, output line, refusal key and exit code.

- The core TUI `core/sudo-grant` runs `vgsh sudo grant` with no argument: a 15-minute grant, or a revoke while a grant is active.
- No grant is possible until the owner runs `vgsh sudo install`. It places `bin/lib/tmpfiles.d/vgs-sudo-grant.conf` as `/etc/tmpfiles.d/vgs-sudo-grant.conf`, then the root half at `/usr/local/bin/vgs-sudo-grant`. `grant` refuses a root half that differs from the checkout's file, and `vgsh sudo install` replaces it.
- A grant is one file, `/etc/sudoers.d/99-vgs-nopasswd-<uid>`. sudo refuses it after its `NOTAFTER` deadline, the timer `vgs-sudo-grant-expire-<uid>` removes it at the deadline, and the tmpfiles line removes it at boot.
- Both halves resolve commands in the system directories alone: `/usr/local/sbin`, `/usr/local/bin`, `/usr/sbin`, `/usr/bin`, `/sbin`, `/bin` and `/run/current-system/sw/bin`. `grant` needs `sudo` with `-N`, `gum`, `visudo`, `systemd-run`, `systemctl`, `getent` and `flock` there.
- `uninstall` runs the boot cleanup's line through `systemd-tmpfiles --remove --boot` before it removes anything, so no account's grant outlives the file that ends it at boot.
- `status`, `grant` and `revoke` drop the sudo credential first and when they end, and run each root action through `sudo -N`, so each asks for the password unless a grant is active.
- On NixOS, detected by the package-manager table's `nix` row, every sudo verb writes nothing and runs no sudo. `status`, `revoke`, `install` and `uninstall` report `skipped=nixos-config`. `grant` prints the `security.sudo.extraRules` snippet with the same account rule and `NOTAFTER` deadline, then tells the user to run `nixos-rebuild switch`.

## Invariants

1. A grant is a rule `visudo` accepted, for 1 to 1440 minutes, for the caller's own account, published by rename after its expiry is armed, only while the boot cleanup is in place and only after one question that `VGS_TUI_UNATTENDED` never answers; a grant sudo does not honour is revoked, a second `grant` revokes, and `uninstall` removes every account's grant before the root half and the boot cleanup. On NixOS, the same verb path writes nothing, runs no sudo and prints the configuration snippet. Enforced by `scripts/test-vgsh-sudo-grant.sh` under a temporary prefix with stand-in `sudo`, `visudo`, `systemd-run`, `systemctl`, `getent` and `gum`, with NixOS fixture rows and the `nixos-write` and `nixos-blind` controls beside the other copies that skip each check.
2. The root half runs only under `bash -p`, with an environment of `PATH`, `LC_ALL` and `SUDO_UID` alone, and takes `__status`, `__enable` and `__disable` for `SUDO_UID`'s uid and nothing else. Enforced by `scripts/test-vgsh-sudo-grant.sh`, which runs it under `unshare -r`, with copies that skip the startup, environment and caller checks as its controls.

## Omarchy

`vgsh sudo grant` follows `omarchy-sudo-passwordless` and differs where [D036](../decisions/D036-time-boxed-passwordless-sudo-grant.md) states.
