#!/usr/bin/env bash
# Whether the Slack tokens vgs.notifications reads are stored in libsecret,
# without reading them. Usage: token-status.sh [TEAM_ID...]. Each TEAM_ID is
# a Slack workspace's team id, as Slack's workspace list names it, at most 16
# of them; the probe asks for account slack:<TEAM_ID> of service
# vgs-notifications for each, in the order given, then for the
# single-workspace account `slack`. It prints one line per account on
# stdout, which SlackPhotos.qml parses through
# NotificationLogic.slackTokenStates:
#   slack-token: account=<account> present
#   slack-token: account=<account> absent
#   slack-token: account=<account> locked
#   slack-token: account=<account> unavailable reason=<secret-tool-missing|search-failed status=N|timeout|unrecognised>
# and exits 0. `locked` is an item stored in a locked collection: the probe
# never asks to unlock it, so a background check raises no prompt.
# `unavailable` is a store the probe cannot ask. A TEAM_ID that is not 1 to
# 32 letters and digits, or more than 16 of them, is refused on stderr with
# `notifications-token-status: refused: team-id` or `refused: teams` and
# exit 2, before any search.
#
# No token reaches this script. `secret-tool search` without `--unlock`
# prints each item it finds on stdout, an unlocked item's secret included,
# and the item's attributes and any error on stderr (libsecret
# tool/secret-tool.c, on_retrieve_secret, since 0.20.4). Its stdout goes to
# /dev/null before this script reads a byte; only stderr is read. An item it
# found prints its `attribute.` lines; an item whose secret it could not
# read because its collection is locked adds a `secret-tool: ` line naming
# the lock, gnome-keyring's `Cannot get secret of a locked object`. The
# search matches each attribute exactly, so account `slack` never finds an
# item stored under `slack:<TEAM_ID>`.
#
# VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR, which tests alone set, as
# for slack-photos.js: the secret-tool on PATH must resolve inside that
# directory, a stub, or the probe refuses on stderr with
# `notifications-token-status: secret-tool=test-stub-required` and exits 5
# before it runs any secret-tool.
set -euo pipefail

# The most workspaces NotificationLogic.slackWorkspaces reads from Slack's
# list, its WORKSPACES_MAX.
teams_max=16
if [[ $# -gt $teams_max ]]; then
  echo "notifications-token-status: refused: teams count=$# want<=$teams_max" >&2
  exit 2
fi
accounts=()
for team in "$@"; do
  if [[ ! $team =~ ^[A-Za-z0-9]{1,32}$ ]]; then
    echo "notifications-token-status: refused: team-id want=[A-Za-z0-9]{1,32}" >&2
    exit 2
  fi
  accounts+=("slack:$team")
done
accounts+=(slack)
# A search that hangs on the bus is abandoned; a store answers in well
# under a second.
limit=10

if ! tool="$(command -v secret-tool)"; then
  for account in "${accounts[@]}"; do echo "slack-token: account=$account unavailable reason=secret-tool-missing"; done
  exit 0
fi
if [[ -n ${VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR:-} ]]; then
  stub_dir="$(readlink -f -- "$VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR")" || stub_dir=""
  real_tool="$(readlink -f -- "$tool")" || real_tool=""
  if [[ -z $stub_dir || -z $real_tool || $real_tool != "$stub_dir"/* ]]; then
    echo "notifications-token-status: secret-tool=test-stub-required" >&2
    exit 5
  fi
fi

# probe ACCOUNT: the state of one account, as the rest of its line.
probe() {
  local status=0 err found=false failure="" line
  err="$(timeout "$limit" secret-tool search service vgs-notifications account "$1" 2>&1 >/dev/null)" || status=$?
  if [[ $status -eq 124 ]]; then
    echo "unavailable reason=timeout"
    return
  fi
  if [[ $status -ne 0 ]]; then
    echo "unavailable reason=search-failed status=$status"
    return
  fi
  while IFS= read -r line; do
    case "$line" in
      attribute.*) found=true ;;
      "secret-tool: "*) failure="$line" ;;
    esac
  done <<<"$err"
  if [[ $found == false && -z $failure ]]; then
    echo "absent"
  elif [[ $found == true && -z $failure ]]; then
    echo "present"
  elif [[ $found == true && ${failure,,} == *locked* ]]; then
    echo "locked"
  else
    echo "unavailable reason=unrecognised"
  fi
}

for account in "${accounts[@]}"; do
  state="$(probe "$account")"
  echo "slack-token: account=$account $state"
done
exit 0
