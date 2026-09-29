#!/usr/bin/env bash
# Whether the Slack token vgs.notifications reads is stored in libsecret
# (service vgs-notifications, account slack), without reading it. Prints one
# line on stdout, which SlackPhotos.qml parses through
# NotificationLogic.slackTokenState:
#   slack-token: present
#   slack-token: absent
#   slack-token: locked
#   slack-token: unavailable reason=<secret-tool-missing|search-failed status=N|timeout|unrecognised>
# and exits 0. `locked` is an item stored in a locked collection: the probe
# never asks to unlock it, so a background check raises no prompt.
# `unavailable` is a store the probe cannot ask.
#
# The token never reaches this script. `secret-tool search` without
# `--unlock` prints each item it finds on stdout, an unlocked item's secret
# included, and the item's attributes and any error on stderr (libsecret
# tool/secret-tool.c, on_retrieve_secret, since 0.20.4). Its stdout goes to
# /dev/null before this script reads a byte; only stderr is read. An item it
# found prints its `attribute.` lines; an item whose secret it could not
# read because its collection is locked adds a `secret-tool: ` line naming
# the lock, gnome-keyring's `Cannot get secret of a locked object`.
#
# VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR, which tests alone set, as
# for slack-photos.js: the secret-tool on PATH must resolve inside that
# directory, a stub, or the probe refuses on stderr with
# `notifications-token-status: secret-tool=test-stub-required` and exits 5
# before it runs any secret-tool.
set -euo pipefail

attrs=(service vgs-notifications account slack)
# A search that hangs on the bus is abandoned; a store answers in well
# under a second.
limit=10

if ! tool="$(command -v secret-tool)"; then
  echo "slack-token: unavailable reason=secret-tool-missing"
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
status=0
err="$(timeout "$limit" secret-tool search "${attrs[@]}" 2>&1 >/dev/null)" || status=$?
if [[ $status -eq 124 ]]; then
  echo "slack-token: unavailable reason=timeout"
  exit 0
fi
if [[ $status -ne 0 ]]; then
  echo "slack-token: unavailable reason=search-failed status=$status"
  exit 0
fi
found=false
failure=""
while IFS= read -r line; do
  case "$line" in
    attribute.*) found=true ;;
    "secret-tool: "*) failure="$line" ;;
  esac
done <<<"$err"
if [[ $found == false && -z $failure ]]; then
  echo "slack-token: absent"
elif [[ $found == true && -z $failure ]]; then
  echo "slack-token: present"
elif [[ $found == true && ${failure,,} == *locked* ]]; then
  echo "slack-token: locked"
else
  echo "slack-token: unavailable reason=unrecognised"
fi
exit 0
