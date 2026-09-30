#!/usr/bin/env bash
# Keeps Slack photos for a user who had them before they became the
# owner-only Slack photos extra (docs/decisions/D075-consumer-features-need-no-developer-setup.md):
# when a Slack token was in use and the user's vgs.notifications row does
# not name `slackPhotos`, the row gets `"slackPhotos": true`. A row that
# names it, true or false, is the user's own choice and stays.
#
# A token was in use when the photo helper's cache records an account it
# served, accounts.json under $XDG_CACHE_HOME/vgs/notifications/slack-photos,
# or else when libsecret holds an item of service vgs-notifications. The
# keyring is asked with `secret-tool search` without --unlock, as
# shell/plugins/vgs.notifications/token-status.sh asks it: its stdout, where
# a found item's secret prints, goes to /dev/null, and only the item's
# attributes on stderr are read, so no token is read, no collection is
# unlocked and no prompt shows. With no secret-tool, or a store that
# refuses the search, and no cache record, no token VGS could read was
# stored, and the extra stays off. A search that times out fails the
# migration, `slack-photos: keyring=timeout` on stderr and exit 1, so the
# runner runs it again at the next start.
#
# Prints one line, `slack-photos: extra=<written|unchanged|off>
# evidence=<cache|keyring|none>[ keyring=<no-secret-tool|failed status=N>]`.
#
# VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR, which tests alone set, as
# for token-status.sh: the secret-tool on PATH must resolve inside that
# directory, or the migration refuses with
# `slack-photos: secret-tool=test-stub-required` and exits 5 before it runs
# any secret-tool.
set -euo pipefail

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
accounts="${XDG_CACHE_HOME:-$HOME/.cache}/vgs/notifications/slack-photos/accounts.json"
# A search that hangs on the bus is abandoned; a store answers in well
# under a second.
limit=10

# Whether the photo helper's cache records an account it served: a JSON
# object with at least one key.
cache_served() {
  [[ -f $accounts ]] || return 1
  node -e 'let d; try { d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); } catch (e) { process.exit(1); }
process.exit(d !== null && typeof d === "object" && !Array.isArray(d) && Object.keys(d).length > 0 ? 0 : 1);' "$accounts"
}

evidence=none
keyring=""
if cache_served; then
  evidence=cache
elif tool="$(command -v secret-tool)"; then
  if [[ -n ${VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR:-} ]]; then
    stub_dir="$(readlink -f -- "$VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR")" || stub_dir=""
    real_tool="$(readlink -f -- "$tool")" || real_tool=""
    if [[ -z $stub_dir || -z $real_tool || $real_tool != "$stub_dir"/* ]]; then
      echo "slack-photos: secret-tool=test-stub-required" >&2
      exit 5
    fi
  fi
  status=0
  err="$(timeout "$limit" secret-tool search service vgs-notifications 2>&1 >/dev/null)" || status=$?
  if [[ $status -eq 124 ]]; then
    # A store that hangs may answer at the next start; the runner keeps
    # no marker and runs this again then.
    echo "slack-photos: keyring=timeout" >&2
    exit 1
  elif [[ $status -ne 0 ]]; then
    keyring=" keyring=failed status=$status"
  elif grep -q '^attribute\.' <<<"$err"; then
    evidence=keyring
  fi
else
  keyring=" keyring=no-secret-tool"
fi

if [[ $evidence == none ]]; then
  printf 'slack-photos: extra=off evidence=none%s\n' "$keyring"
  exit 0
fi
result="$(node "$VGS_ROOT/bin/vgsh-plugin-judge" seed-setting "$VGS_ROOT/config/shell.json" "$config_home/vgs/shell.json" \
  "$VGS_ROOT/shell/plugins/vgs.notifications" slackPhotos true)"
printf 'slack-photos: extra=%s evidence=%s\n' "$result" "$evidence"
