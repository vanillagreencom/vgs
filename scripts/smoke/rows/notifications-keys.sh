# The notifications inbox shortcut pressed as keys. Super+N typed on the
# nested seat, five times in a row, alternates the inbox open, closed,
# open, closed, open; the same holds after a press on the desktop beside
# the open inbox closed it (SummonLayer's catcher) and after an Escape
# closed it. "Open" is the summon host's panel layer mapped and drawn at
# its size, "closed" no panel layer and no panel instance.
# Controls: with Hyprland's default `input:resolve_binds_by_sym`, false,
# wtype's keys reach no bind and a press leaves the inbox closed, which
# is how the same presses read on a live session with that default, so
# the row's presses are key presses a bind takes and not a dispatch; and
# a copy of the service whose shortcut summons where it should toggle
# leaves the inbox open on the second press.
# A long inbox, forty rows whose newest carries actions, opened by the
# key eight times, shows its first card whole each time: panel_fit
# (rows/notifications.sh) reads its top under the header and inside the
# list's clip. Its control is a Panel.qml copy that reveals the selected
# card only in the refresh, before the list has taken its cards' height,
# which scrolled the first card under the header on all eight opens in
# the sandbox on 2026-10-02, at scale 1 and at scale 2. rows/hidpi.sh
# reads the same opens at scale 2.
# No latency is measured; each reading polls every 200 ms for up to 5 s.
# A press that reaches nothing changes nothing to poll for, so the
# controls read their press once nk_quiet_s has passed.
set -euo pipefail

nk_quiet_s=1.5
nk_hypr_lua="$home/.config/hypr/hyprland.lua"
read -r mon_w mon_h < <(hypr -j monitors | py_reply 'import json,sys; m=json.load(sys.stdin)[0]; print(m["width"], m["height"])')
nk_press() { type_keys -M logo -k n -m logo; }
# The inbox as the user sees it: open, closed, or the readings between.
inbox_shown() {
  local layers window
  layers="$(layer_count vgs:panel)" || return
  window="$(ipc smoke windowDrawn panel vgs.notifications)" || return
  case "$layers $window" in
    "1 drawn") echo open ;;
    "0 absent") echo closed ;;
    *) echo "between layers=$layers window=$window" ;;
  esac
}
# The long inbox's forty rows: thirty-nine tall cards and, newest, one
# with actions, the card a selected inbox opens on. They are low, so their
# toasts leave the screen within NotificationLogic's LOW_LIFETIME, and the
# inbox opens on history alone, as the owner's did: while a toast shows,
# opening the panel settles its clock, and the refresh that follows comes
# after the list has its height and hides a cut (read in the sandbox on
# 2026-10-02: the first three opens with live toasts fit on the refresh-only
# copy, the later ones did not). Prints 0 once no toast shows, polled every
# 200 ms for up to 15 s, else the count still showing.
long_inbox_rows() {
  local n shown=""
  for n in $(seq 1 39); do
    notify smoke-app 0 "Long $n" "A body long enough to wrap onto a second line of the card, so the card is tall" '[]' '{"urgency": <byte 0>}' 0 >/dev/null
  done
  notify smoke-app 0 "Long newest" "Waiting for your input" '["default", "Show"]' '{"urgency": <byte 0>}' 0 >/dev/null
  for _ in $(seq 1 75); do
    shown="$(note_status onScreen)" || return
    [[ $shown == 0 ]] && break
    sleep 0.2
  done
  echo "$shown"
}
# long_inbox_cut TOGGLE...: eight opens of the long inbox by the command
# TOGGLE, which also closes it. Each open is read once the panel lists the
# newest row and has drawn: `fits` when every open's panel_fit read fits
# within long_inbox_settle_s, else `cut`; the readings that did not fit go
# to $sandbox/long-inbox.txt. A first card scrolled under the header stays
# there, so a reading that stays off fits for the settle is the cut.
long_inbox_settle_s=1
long_inbox_cut() {
  local n reading cuts="" polls
  polls="$(python3 -c 'import sys; print(max(1, int(float(sys.argv[1]) / 0.2)))' "$long_inbox_settle_s")" || return
  for n in 1 2 3 4 5 6 7 8; do
    "$@" >/dev/null || { echo "open=$n toggle-failed"; return; }
    for _ in $(seq 1 25); do [[ $(has_row panel "Long newest") == True ]] && break; sleep 0.2; done
    summon_drawn panel vgs.notifications || { echo "open=$n not-drawn"; return; }
    reading=""
    for _ in $(seq 1 "$polls"); do
      reading="$(panel_fit)" || reading="unread"
      [[ $reading == fits ]] && break
      sleep 0.2
    done
    [[ $reading == fits ]] || cuts+="open=$n $reading; "
    "$@" >/dev/null || { echo "close=$n toggle-failed"; return; }
    for _ in $(seq 1 25); do [[ $(layer_count vgs:panel) == 0 ]] && break; sleep 0.2; done
  done
  printf '%s\n' "${cuts:-none}" >"$sandbox/long-inbox.txt"
  if [[ -z $cuts ]]; then echo fits; else echo cut; fi
}
# PRESSES LABEL: five presses from a closed inbox, each read before the next.
nk_presses() {
  local want=open n
  for n in 1 2 3 4 5; do
    nk_press || fail "$1: press $n failed"
    expect_poll "$1: press $n leaves the inbox $want" "$want" inbox_shown
    if [[ $want == open ]]; then want=closed; else want=open; fi
  done
}

hypr_lua_save notifications-keys
expect "enabling the notifications for the key rows is allowed" ok ipc shell setPluginEnabled vgs.notifications true
expect_poll "the notification service for the key rows is built" True record_exists vgs.notifications
expect_poll "the compositor lists the inbox shortcut for the key rows" 1 note_shortcuts
notify smoke-app 0 "Key rows" "" '[]' '{"urgency": <byte 0>}' 0 >/dev/null
expect_poll "the key rows' notification is live" True has_row live "Key rows"
expect "the inbox starts closed" closed inbox_shown

# Control: Hyprland's default bind resolution, the live session's.
nk_press || fail "control default resolution: the press failed"
sleep "$nk_quiet_s"
expect "control: with the default bind resolution a typed Super+N leaves the inbox closed" closed inbox_shown

printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = true } })' >>"$nk_hypr_lua"
expect "the nested instance reloads with binds resolved by symbol" ok hypr reload config-only

nk_presses "from closed"
if summon_drawn panel vgs.notifications; then
  click 40 "$((mon_h - 40))" || fail "the press on the desktop beside the inbox failed"
else
  fail "the inbox before the desktop press never drew"
fi
expect_poll "a press on the desktop closes the inbox" closed inbox_shown
nk_presses "after a desktop press"
type_keys -k Escape || fail "sending Escape to the inbox failed"
expect_poll "Escape closes the inbox" closed inbox_shown
nk_presses "after Escape"
type_keys -k Escape || fail "sending the last Escape to the inbox failed"
expect_poll "the last Escape closes the inbox" closed inbox_shown

expect "the long inbox's toasts leave the screen" 0 long_inbox_rows
geometry expect "a long inbox opened by the key eight times shows its first card whole each time" fits long_inbox_cut nk_press
ok "long inbox cuts: $(cat -- "$sandbox/long-inbox.txt")"
expect "disabling the notifications before the panel copy is allowed" ok ipc shell setPluginEnabled vgs.notifications false
expect_poll "the compositor lists no inbox shortcut before the panel copy" 0 note_shortcuts
nk_panel="$repo/shell/plugins/vgs.notifications/Panel.qml"
cp -- "$nk_panel" "$sandbox/Panel.qml.keys-kept"
python3 - "$nk_panel" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = "onViewHeightChanged: reveal(root.currentIndex)"
assert text.count(needle) == 1, "the reveal at the list's height occurs once"
open(path, "w").write(text.replace(needle, "onViewHeightChanged: {}"))
PY
expect "a rescan reads the refresh-only reveal panel copy" ok ipc shell rescanPlugins
expect "enabling the notifications beside the panel copy is allowed" ok ipc shell setPluginEnabled vgs.notifications true
expect_poll "the service is built beside the panel copy" True record_exists vgs.notifications
expect_poll "the inbox shortcut is listed beside the panel copy" 1 note_shortcuts
geometry expect "control: a panel that reveals only in the refresh scrolls the long inbox's first card under the header" cut long_inbox_cut nk_press
ok "control long inbox cuts: $(cat -- "$sandbox/long-inbox.txt")"
cp -- "$sandbox/Panel.qml.keys-kept" "$nk_panel"
expect "a rescan restores the panel" ok ipc shell rescanPlugins
expect_poll "the service is built beside the restored panel" True record_exists vgs.notifications
notes dismiss-all >/dev/null # `none` once every toast's clock ran out
expect "clearing the long inbox's history is allowed" ok notes clear-history

# Control: a service whose shortcut summons the open inbox again. The
# plugin goes off before the copy is planted and on after, so the shortcut
# the compositor lists is the copy's and no press lands between the two.
expect "disabling the notifications before the summon-only copy is allowed" ok ipc shell setPluginEnabled vgs.notifications false
expect_poll "the compositor lists no inbox shortcut before the copy" 0 note_shortcuts
nk_service="$repo/shell/plugins/vgs.notifications/Service.qml"
cp -- "$nk_service" "$sandbox/Service.qml.keys-kept"
python3 - "$nk_service" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = "if (panelOpen) return closePanel();"
assert text.count(needle) == 1, "the shortcut's close branch occurs once"
open(path, "w").write(text.replace(needle, "if (false) return closePanel();"))
PY
expect "a rescan reads the summon-only service copy" ok ipc shell rescanPlugins
expect "enabling the summon-only service copy is allowed" ok ipc shell setPluginEnabled vgs.notifications true
expect_poll "the summon-only service copy is built" True record_exists vgs.notifications
expect_poll "the summon-only copy's shortcut is listed" 1 note_shortcuts
nk_press || fail "control summon-only: the first press failed"
expect_poll "control summon-only: the first press opens the inbox" open inbox_shown
nk_press || fail "control summon-only: the second press failed"
sleep "$nk_quiet_s"
expect_poll "control: the summon-only copy leaves the inbox open on the second press" open inbox_shown
type_keys -k Escape || fail "control summon-only: Escape failed"
expect_poll "control summon-only: Escape closes the inbox" closed inbox_shown
expect "disabling the summon-only service copy is allowed" ok ipc shell setPluginEnabled vgs.notifications false
expect_poll "the summon-only service copy is gone" False record_exists vgs.notifications
cp -- "$sandbox/Service.qml.keys-kept" "$nk_service"
expect "a rescan restores the service" ok ipc shell rescanPlugins
hypr_lua_restore notifications-keys || fail "the key rows put the harness hyprland.lua back"
expect "the nested instance reloads the harness hyprland.lua after the key rows" ok hypr reload config-only
