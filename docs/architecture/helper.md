# Helper CLI

Covers: bin/

The helper owns parsing, generation and privileged operations. `bin/vshell` dispatches to `bin/vshell-helper`; the importable Python modules provide its Niri and colour support.

## Boundaries

- Keep new helper behaviour behind the dispatcher. A helper module split is separate work, not a requirement of unrelated fixes.
- Hyprland receives VGS-owned configuration fragments. Niri also permits an include update with a backup; see `bin/vshell_niri.py`.
- External commands use argv arrays and must not log secrets or raw payloads. Review each changed call; `scripts/check-vshell-helper.py` tests named operations, not the absence of every unsafe call.

## Invariants

- The passwordless-sudo drop-in is validated before installation. Its user-readable mirror refuses symlink traversal. See `sudo_toggle_apply` and `sudo_toggle_write_flag`, tested by `scripts/check-vshell-helper.py`.
- `sudo-toggle` requires an explicit requested state and refuses a stale direction. Grants require terminal confirmation; revocation can work without a terminal. See `sudo_toggle_set`, the helper tests and `scripts/test-sudo-toggle-confirm.js`.
- Terminal selection belongs to `terminal_candidates` and `terminal_argv`. An unwrapped command must not be retried after a terminal exits. The terminal tests in `scripts/check-vshell-helper.py` cover these contracts.
- Scratchpad removal releases the window instead of closing the application. Niri pads use persistent named workspaces; the toggle moves the window and restores focus. See `cmd_scratchpad`, `SCRATCHPAD_NIRI_ANCHORS` and the helper scratchpad tests.
- A rejected scratchpad must not be launched or emitted into compositor configuration. See the validation paths in `bin/vshell-helper` and `scripts/check-vshell-niri.py`.
- Brightness scans must not publish stale results. Repeated failures quarantine scans; potentially blocking probes run in separate processes. See `scripts/check-brightness.py` and `scripts/test-brightness-scan-ordering.js`.
- The remote-desktop unit starts only after its capture output is verified. Cleanup requires VGS ownership tied to the compositor instance. The remote-desktop lifecycle tests in `scripts/check-vshell-helper.py` enforce this contract.
- Unknown remote-desktop state must not clear a known streaming indicator. `scripts/test-remote-desktop-state.js` checks state handling; helper journal tests cover the bounded session read.
- Coding-agent stubs replace only VGS-owned files and must not hide an existing external command. See the stub installation code in `bin/vshell-helper`.
- Wallpaper upscaling runs as a one-shot process. See `bin/vshell-upscale` and its helper invocation.

## Decisions

[D006](../decisions/D006-scratchpad-window-identity.md), [D011](../decisions/D011-mise-owns-agent-harnesses.md).
