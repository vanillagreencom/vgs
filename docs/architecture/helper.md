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
- Hyprland display previews retain the previous generated fragment under a transaction lock. A separate helper restores it if confirmation does not arrive. Startup reads and new applies recover expired previews or previews from another compositor session under that same lock; internal snapshot reads never acquire it recursively. `test_display_output_controls` in `scripts/check-vshell-helper.py` checks recovery, rejection and confirmation.
- Live display validation excludes saved offline outputs. Preserve-only names retain the helper's exact generated rules until the user forgets them. `test_display_output_controls` checks offline ICC retention and removal; `scripts/check-display-config-fixtures.js` checks live and saved-setup payloads.
- The remote-desktop unit starts only after its capture output is verified. Cleanup requires VGS ownership tied to the compositor instance. The remote-desktop lifecycle tests in `scripts/check-vshell-helper.py` enforce this contract.
- Unknown remote-desktop state must not clear a known streaming indicator. `scripts/test-remote-desktop-state.js` checks state handling; helper journal tests cover the bounded session read.
- Catalog stubs replace only VGS-owned files and must not hide an existing external command. This covers every group in `config/vshell/dev-tools.json`, agents, apps and tools alike. See the stub installation code in `bin/vshell-helper`.
- Removing a distribution package to resolve a duplicate command is a separate action the owner asks for, never a step inside an install. `entry_replace` refuses unless a package manager names an owner for the path, and stops without installing when the removal fails, so a machine is never left with neither copy. `test_row_actions_run_and_refuse` in `scripts/check-dev-tools.py` checks both refusals and the failed removal.
- System font families use fontconfig aliases and GTK/GSettings preferences. Hyprland text uses its existing generated layout fragment. `test_system_font_family_targets` and `test_apply_system_fonts_temp_home` in `scripts/check-vshell-helper.py` check these targets and reset ownership.
- User font-size edits preserve Default families. The generated font file retains size-only ownership and prior GSettings descriptions for reset; ordinary startup does not claim a size override. `test_system_font_size_targets` checks these paths.
- A shell running against a throwaway `HOME` must not write `/etc/chromium/policies/managed` nor reach the login session's tmux, nvim, kitty, btop, ghostty, compositor or shell IPC. `_sandboxed_home` decides this by comparing `$HOME` against `login_home`, the passwd home of the user the process acts for, and every refusal carries `SANDBOX_REFUSAL` so a guard is not read as a machine with no kitty or no root. `test_chromium_policy_refuses_a_sandbox_home` and `test_theme_hooks_stay_out_of_the_login_session` in `scripts/check-vshell-helper.py` check both, including a sandbox home directly under the login home, which a containment test cannot tell apart from the user's own session.
- Wallpaper upscaling runs as a one-shot process. See `bin/vshell-upscale` and its helper invocation.
- AI-usage credentials are read from stdin, never argv, and the store is written 0600 under the state directory with its mode narrowed on the descriptor before the key goes through it. Nothing prints a key back; `sources` reports only which source a key came from. `scripts/test-ai-usage-sources.js` checks each of these against the real helper.
- Which config directories an AI-usage provider reads has one owner, `bin/vshell-ai-usage`, and its `--dirs` mode is what the widget's setup page lists. A separate reader could report directories the fetch ignores.

## Decisions

[D006](../decisions/D006-scratchpad-window-identity.md), [D011](../decisions/D011-mise-owns-agent-harnesses.md).
