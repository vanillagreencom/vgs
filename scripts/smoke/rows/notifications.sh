# The notifications, vgs.notifications: a first-party service drawing its
# toasts through the `layers` capability. The harness starts it disabled;
# this row enables it and drives it with synthetic notifications on the
# sandbox's own session bus, never the user's, and reads back what it holds
# through the probe, its state file, the compositor and the lending record.
# No owner data reaches it: every notification here is made up. The row ends
# with the plugin disabled and every registration released.
set -euo pipefail
note_state="$home/.local/state/vgs/notifications/state.json"
note_images="$home/.local/state/vgs/notifications/images"
notes() { ipc vgs.notifications invoke "$1" "${2:-}"; }
note_status() { notes status | python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[k]
print(json.dumps(v))' "$1"; }
read_notes() { ipc smoke readInstance service vgs.notifications "$1"; }
# The rows the service holds, as [summary, origin, leaving] triples, newest first.
note_rows() { ipc smoke modelRows vgs.notifications rows summary,origin,leaving | python3 -c 'import json,sys; print(json.dumps([r for r in json.load(sys.stdin) if r[2] == ""]))'; }
row_summaries() { note_rows | python3 -c 'import json,sys; print(json.dumps([r[0] for r in json.load(sys.stdin) if r[1] == sys.argv[1]]))' "$1"; }
state_at() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v=v[int(k)] if isinstance(v, list) else v[k]
print(json.dumps(v))' "$note_state" "$1"; }
history_summaries() { python3 -c 'import json,sys; print(json.dumps([e["summary"] for e in json.load(open(sys.argv[1]))["history"]]))' "$note_state"; }
history_count() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["history"]))' "$note_state"; }
live_summaries() { python3 -c 'import json,sys; print(json.dumps([e["summary"] for e in json.load(open(sys.argv[1]))["live"]]))' "$note_state"; }
# One notification on the sandbox bus: APP REPLACES SUMMARY BODY ACTIONS HINTS
# TIMEOUT, the last three in gdbus's GVariant text; prints its id.
notify() {
  "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify "$1" "$2" "" "$3" "$4" "$5" "$6" "$7" | python3 -c 'import re,sys; print(re.search(r"uint32 (\d+)", sys.stdin.read()).group(1))'
}
close_note() { "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.CloseNotification "$1" >/dev/null; }
lent_notes() { ipc shell lent | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([[s for s in d["shortcuts"] if s.startswith("vgs.notifications")], [t for t in d["ipcTargets"] if t == "vgs.notifications"], [s for s in d["subscribers"] if s == "vgs.notifications"], [l["plugin"] for l in d["layers"] if l["plugin"] == "vgs.notifications"]]))'; }
note_shortcuts() { hypr globalshortcuts | python3 -c 'import sys; print(sum(1 for line in sys.stdin if "vgs.notifications:inbox" in line))'; }

expect "the notifications start disabled in the sandbox" False plugin_enabled vgs.notifications
# A synthetic Slack under the sandbox's configuration, in place before the
# service starts and reads its workspace list.
mkdir -p -- "$home/.config/Slack"
cp -R -- "$repo/scripts/smoke/fixtures/slack/." "$home/.config/Slack/"
expect "enabling the notifications is allowed" ok ipc shell setPluginEnabled vgs.notifications true
expect_poll "the notification service is built" True record_exists vgs.notifications
expect_poll "the service registered its shortcut, IPC target and subscriber and holds no layer" '[["vgs.notifications:inbox"], ["vgs.notifications"], ["vgs.notifications"], []]' lent_notes
expect_poll "the compositor lists the inbox shortcut" 1 note_shortcuts
expect "the notification server exists" true lent notificationServer
expect "a first start finds no state file" '"absent"' note_status store.state
expect "no layer surface shows with nothing to show" 0 layer_count vgs:layer

# A notification shows as a toast on every screen, under the bar.
first_id="$(notify smoke-app 0 "First toast" "A body with <b>markup</b> and <img src=\"http://127.0.0.1:9/beacon.png\"> no image" '[]' '{}' 0)"
expect_poll "a notification becomes a live toast" '["First toast"]' row_summaries live
expect_poll "its layer surface shows on every screen" "$monitors" layer_count vgs:layer
expect_poll "the toast is in the state file as on screen" '["First toast"]' live_summaries
# The edge light loads its shader from the plugin's published revision, and
# the shader compiled. Qt compiles a shader once per process and marks only
# the effect that compiled it, so the row reads the first toast's, the first
# edge light this shell draws (read in the sandbox on 2026-09-28: a later
# card's effect stayed Uncompiled while it drew).
edge_shaders_ok() { ipc smoke layerShaders vgs.notifications | python3 -c 'import json,re,sys
edges = [(u, ok) for _, u, ok in json.load(sys.stdin) if u.endswith("/edgelight.frag.qsb")]
print(len(edges) >= 1 and all(re.search(r"/vgsh-sources-[0-9]+/[0-9a-f]+/shaders/edgelight\.frag\.qsb$", u) for u, _ in edges) and any(ok for _, ok in edges))'; }
render expect_poll "the edge light's shader compiled from the published revision" True edge_shaders_ok
key_of() { ipc smoke modelRows vgs.notifications rows key,summary | python3 -c 'import json,sys; print(next((k for k, s in json.load(sys.stdin) if s == sys.argv[1]), "none"))' "$1"; }
clock_of() { read_notes clocks | python3 -c 'import json,sys; c=json.load(sys.stdin).get(sys.argv[1]); print("none" if c is None else ("running" if c["since"] is not None else "paused") + " " + str(c["remaining"]))' "$1"; }
# A card's centre on the screen: its rectangle in its window plus the
# window's origin from the compositor.
card_centre() { ipc smoke layerItems vgs.notifications NotificationCard summary | python3 -c 'import json,sys; y0=int(sys.argv[2])
for screen, (x, y, w, h), v in json.load(sys.stdin):
    if v["summary"] == sys.argv[1]: print(x + w // 2, y0 + y + h // 2); break' "$1" "$bar_reserved"; }
card_left() { ipc smoke layerItems vgs.notifications NotificationCard summary | python3 -c 'import json,sys; y0=int(sys.argv[2])
for screen, (x, y, w, h), v in json.load(sys.stdin):
    if v["summary"] == sys.argv[1]: print(x + 30, y0 + y + h // 2); break' "$1" "$bar_reserved"; }
pill_centre() { ipc smoke layerItems vgs.notifications PillButton text,visible | python3 -c 'import json,sys; y0=int(sys.argv[2])
for screen, (x, y, w, h), v in json.load(sys.stdin):
    if v["text"] == sys.argv[1]: print(x + w // 2, y0 + y + h // 2); break' "$1" "$bar_reserved"; }
shown_pills() { ipc smoke layerItems vgs.notifications CardSlot summary,actions | python3 -c 'import json,sys; print(json.dumps(next(([a["label"] for a in v["actions"]] for s, r, v in json.load(sys.stdin) if v["summary"] == sys.argv[1]), None)))' "$1"; }
has_row() { row_summaries "$1" | python3 -c 'import json,sys; print(sys.argv[1] in json.load(sys.stdin))' "$2"; }
in_history() { history_summaries | python3 -c 'import json,sys; print(sys.argv[1] in json.load(sys.stdin))' "$1"; }
panel_count() { row_summaries panel | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
clock_state() { clock_of "$(key_of "$1")" | cut -d' ' -f1; }
test_file() { if [[ -f $1 ]]; then echo True; else echo False; fi; }
# wait_for LABEL WANT SECONDS CMD...: expect_poll with its own bound, for a
# toast's lifetime, which runs for seconds.
wait_for() {
  local label="$1" want="$2" seconds="$3" got=""
  shift 3
  for _ in $(seq 1 $((seconds * 5))); do
    if got="$("$@")" && [[ $got == "$want" ]]; then ok "$label"; return; fi
    sleep 0.2
  done
  fail "$label: got $got want $want"
}
toast_centred() { ipc smoke layerItems vgs.notifications NotificationCard summary | python3 -c 'import json,sys; x,y,w,h=json.load(sys.stdin)[0][1]; print(abs(x + w / 2 - int(sys.argv[1]) / 2) <= 1 and 0 < y < 40)' "$mon_w"; }
geometry expect_poll "the toast is centred at the top of the screen under the bar" True toast_centred
geometry expect_poll "the layer covers the screen below the bar" "[[0, $bar_reserved, $mon_w, $((mon_h - bar_reserved))]]" layers_of vgs:layer

# A sender's timeout is milliseconds, held to the urgency's floor and ceiling.
notify smoke-app 0 "Timed" "" '[]' '{}' 12000 >/dev/null
expect_poll "a timed toast shows" True has_row live "Timed"
timed_clock() { clock_of "$(key_of Timed)" | python3 -c 'import sys; state, left = sys.stdin.read().split(); print(state == "running" and 12000 <= float(left) <= 13500)'; }
expect "its clock holds the sender's twelve seconds" True timed_clock

# Replacement keeps the toast and its identity; the sender's close ends it.
first_key="$(key_of "First toast")"
notify smoke-app "$first_id" "First toast, updated" "New body" '[]' '{}' 0 >/dev/null
expect_poll "a replacement updates the toast in place" "$first_key" key_of "First toast, updated"
expect "the replaced toast leaves no second row" none key_of "First toast"
expect_poll "the state file holds the update" '["Timed", "First toast, updated"]' live_summaries
close_note "$first_id"
expect_poll "the sender's close ends the toast" none key_of "First toast, updated"
expect_poll "the closed toast is in the history" True in_history "First toast, updated"

# A toast expires on its own; the pointer on it pauses its clock.
notify smoke-app 0 "Brief" "" '[]' '{"urgency": <byte 0>}' 0 >/dev/null
expect_poll "a low-urgency toast shows" True has_row live "Brief"
wait_for "the low-urgency toast expires after its five seconds" none 9 key_of Brief
notify smoke-app 0 "Held" "" '[]' '{"urgency": <byte 0>}' 0 >/dev/null
expect_poll "a second low-urgency toast shows" True has_row live "Held"
sleep 1
read -r hx hy < <(card_centre Held) || fail "the held toast has no card"
hover "$hx" "$hy" || fail "the hover over the held toast failed"
held_key="$(key_of Held)"
expect_poll "the pointer on a toast pauses its clock" paused clock_state Held
stored_clock() { python3 -c 'import json,sys; e=next((e for e in json.load(open(sys.argv[1]))["live"] if e["key"] == sys.argv[2]), {}); print(" ".join(k for k in ("deadline", "remaining") if k in e) or "none")' "$note_state" "$1"; }
expect_poll "the state file keeps the paused toast's time left" remaining stored_clock "$held_key"
sleep 6
expect "a paused toast outlives its lifetime" "$held_key" key_of Held
hover "$((mon_w - 5))" "$((mon_h - 5))" || fail "moving the pointer off the toast failed"
expect_poll "the state file keeps the running toast's deadline" deadline stored_clock "$held_key"
wait_for "the toast expires once the pointer leaves" none 9 key_of Held

# A critical notification stays until closed and lights its edge.
alarm_id="$(notify smoke-app 0 "Alarm" "" '[]' '{"urgency": <byte 2>}' 0)"
expect_poll "a critical toast shows" True has_row live "Alarm"
expect "a critical toast has no clock" none clock_of "$(key_of Alarm)"
edge_active() { ipc smoke layerItems vgs.notifications EdgeLight active,lit | python3 -c 'import json,sys; print(sorted(set(v["active"] for s, r, v in json.load(sys.stdin))))'; }
notify smoke-app 0 "Calm" "" '[]' '{}' 0 >/dev/null
expect_poll "a normal toast shows beside it" True has_row live Calm
expect_poll "only the critical toast's edge light is active" '[False, True]' edge_active

# Hover actions: the sender's own, then Dismiss; one runs on a click.
signals="$sandbox/notification-signals.log"
spawn "$signals" "${shell_env[@]}" stdbuf -oL gdbus monitor --session --dest org.freedesktop.Notifications
sleep 0.5
notify smoke-chat 0 "Actioned" "Pick one" '["default", "Open", "reply", "Reply"]' '{}' 0 >/dev/null
expect_poll "an actionable toast shows" True has_row live "Actioned"
sleep 1
read -r ax ay < <(card_centre Actioned) || fail "the actionable toast has no card"
hover "$ax" "$ay" || fail "the hover over the actionable toast failed"
expect_poll "the hover reveals the sender's actions and Dismiss" '["Open", "Reply", "Dismiss"]' shown_pills Actioned
sleep 0.5
# The hover actions draw nothing past the capsule's rounded ends: the card
# grabbed alone, without the glass under it, is clear everywhere more than
# 1.5 px outside either end's curve, and drawn where the fade runs under
# no pill. The PNG is read with the standard library.
capsule_clear() { ipc smoke layerItems vgs.notifications NotificationCard summary | python3 -c '
import json, math, struct, sys, zlib
path, summary = sys.argv[1], sys.argv[2]
w, h = next((r[2], r[3]) for s, r, v in json.load(sys.stdin) if v["summary"] == summary)
data = open(path, "rb").read()
pos, idat, head = 8, b"", None
while pos < len(data):
    n, kind = struct.unpack(">I4s", data[pos:pos + 8])
    if kind == b"IHDR": head = struct.unpack(">IIBBBBB", data[pos + 8:pos + 8 + n])
    elif kind == b"IDAT": idat += data[pos + 8:pos + 8 + n]
    pos += 12 + n
iw, ih, depth, ctype, _, _, interlace = head
if (depth, ctype, interlace) != (8, 6, 0): print("png=%d/%d/%d" % (depth, ctype, interlace)); sys.exit()
raw, stride, prev, alpha = zlib.decompress(idat), iw * 4, bytearray(iw * 4), []
for y in range(ih):
    f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for i in range(stride):
        a, b, c = (line[i - 4] if i >= 4 else 0), prev[i], (prev[i - 4] if i >= 4 else 0)
        if f == 1: line[i] = (line[i] + a) & 255
        elif f == 2: line[i] = (line[i] + b) & 255
        elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c
            line[i] = (line[i] + (a if abs(p - a) <= abs(p - b) and abs(p - a) <= abs(p - c) else b if abs(p - b) <= abs(p - c) else c)) & 255
    alpha.append(line[3::4]); prev = line
s, r = iw / w, min(w, h) / 2
at = lambda x, y: alpha[min(ih - 1, int(y * s))][min(iw - 1, int(x * s))]
outside = 0
for py in range(ih):
    for px in range(iw):
        x, y = (px + 0.5) / s, (py + 0.5) / s
        cx = r if x < r else w - r if x > w - r else None
        if cx is not None and math.hypot(x - cx, y - min(max(y, r), h - r)) > r + 1.5: outside = max(outside, alpha[py][px])
inside = min(at(w - r, 3), at(w - r, h - 4))
print("clear" if outside <= 8 and inside >= 128 else "outside=%d inside=%d" % (outside, inside))' "$1" "$2"; }
card_grab="$sandbox/actioned-card.png"
render expect "the hovered actionable card is grabbed" grabbing ipc smoke grabLayerItem vgs.notifications NotificationCard summary Actioned "$card_grab"
render expect_poll "the grab of the hovered card is saved" "saved $card_grab" ipc smoke grabbed
render expect "the hover actions draw nothing past the capsule's rounded ends" clear capsule_clear "$card_grab" Actioned
read -r px py < <(pill_centre Reply) || fail "the Reply pill is not drawn"
click "$px" "$py" || fail "the click on Reply failed"
invoked() { grep -c "ActionInvoked (uint32 [0-9]*, '$1')" -- "$signals" || true; }
expect_poll "the click runs the sender's action" 1 invoked reply
expect_poll "the acted-on toast leaves" none key_of Actioned
notify smoke-chat 0 "Clicked" "Open me" '["default", "Open"]' '{}' 0 >/dev/null
expect_poll "a toast with a default action shows" True has_row live "Clicked"
sleep 1
read -r cx cy < <(card_left Clicked) || fail "the clicked toast has no card"
hover "$cx" "$cy" || fail "the hover before the card click failed"
click "$cx" "$cy" || fail "the click on the card failed"
expect_poll "a click on the card runs its default action" 1 invoked default
expect_poll "the clicked toast leaves" none key_of Clicked

# Images: a sender's file is copied for the stored entry; a missing one is
# skipped and the card draws no image.
python3 -c 'import base64,sys; open(sys.argv[1], "wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))' "$home/avatar.png"
notify smoke-chat 0 "Pictured" "" '[]' "{\"image-path\": <\"$home/avatar.png\">}" 0 >/dev/null
expect_poll "a toast with an image shows" True has_row live "Pictured"
pictured_key="$(key_of Pictured)"
expect_poll "the sender's image was copied for the stored entry" True test_file "$note_images/$pictured_key-image"
stored_image() { python3 -c 'import json,sys; print(json.dumps(next((e["image"] for e in json.load(open(sys.argv[1]))["live"] if e["key"] == sys.argv[2]), None)))' "$note_state" "$1"; }
expect_poll "the stored entry points at its copy" "\"file://$note_images/$pictured_key-image\"" stored_image "$pictured_key"
expected_errors+=('NotificationCard\.qml.*Cannot open: file://.*/missing\.png')
notify smoke-chat 0 "Unpictured" "" '[]' "{\"image-path\": <\"$home/missing.png\">}" 0 >/dev/null
expect_poll "a toast whose image file is missing shows" True has_row live "Unpictured"
shows_icon() { ipc smoke layerItems vgs.notifications NotificationCard summary,showsIcon | python3 -c 'import json,sys; print(next((v["showsIcon"] for s, r, v in json.load(sys.stdin) if v["summary"] == sys.argv[1]), None))' "$1"; }
expect_poll "the card with a missing image draws no image" False shows_icon Unpictured
expect_poll "the card with its image draws it" True shows_icon Pictured
unpictured_key="$(key_of Unpictured)"
expect "no copy exists for the missing image" False test_file "$note_images/$unpictured_key-image"
expect_poll "the stored entry with a missing image keeps no image" '""' stored_image "$unpictured_key"

# A sender a NotificationLogic rule reads: Slack's titles, over the
# synthetic Slack. Its workspace list names acme, whose icon its cache
# holds, and globex, whose icon it does not.
card_value() { ipc smoke layerItems vgs.notifications NotificationCard "summary,$2" | python3 -c 'import json,sys; print(next((json.dumps(v[sys.argv[2]]) for s, r, v in json.load(sys.stdin) if v["summary"] == sys.argv[1]), "none"))' "$1" "$2"; }
slack_icon="$home/.cache/vgs/notifications/workspaces/slack/T0ACME-0"
notify Slack 0 "[acme] from Ada Lovelace" "Did you see the notes?" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
expect_poll "a Slack direct message draws its workspace's icon" true card_value "[acme] from Ada Lovelace" showsBadge
expect "the icon is the copy out of Slack's cache" "\"file://$slack_icon\"" card_value "[acme] from Ada Lovelace" workspaceIcon
expect "the copy is the cached image's body" "370 89504e470d0a1a0a" bash -c 'printf "%s %s\n" "$(stat -c %s -- "$1")" "$(od -An -tx1 -N8 -- "$1" | tr -d " ")"' _ "$slack_icon"
expect "the workspace's name gives way to its icon" '"from Ada Lovelace"' card_value "[acme] from Ada Lovelace" title
expect "a direct message shows its sender's face" '{"rule": "slack", "workspace": "acme", "title": "from Ada Lovelace", "faces": ["Ada Lovelace"], "more": 0}' card_value "[acme] from Ada Lovelace" enrichment
notify Slack 0 "[acme] in ada, grace, alan, edsger, barbara" "alan: lunch at noon?" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
expect_poll "a group message shows three faces, its sender first, and the rest as more" '{"rule": "slack", "workspace": "acme", "title": "in ada, grace, alan, edsger, barbara", "faces": ["alan", "ada", "grace"], "more": 2}' card_value "[acme] in ada, grace, alan, edsger, barbara" enrichment
expect "the group message's card draws its faces" true card_value "[acme] in ada, grace, alan, edsger, barbara" showsFaces
notify Slack 0 "[globex] in eng" "Grace: shipped" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
expect_poll "a workspace with no cached icon keeps its name" '"[globex] in eng"' card_value "[globex] in eng" title
expect "and draws no icon" false card_value "[globex] in eng" showsBadge

# A full stack lets the oldest non-critical toast go for a new one.
on_screen() { note_status onScreen; }
expect "clearing the screen before the flood is allowed" ok notes dismiss-all
expect_poll "the screen is clear before the flood" 0 on_screen
notify smoke-app 0 "Siren" "" '[]' '{"urgency": <byte 2>}' 0 >/dev/null
expect_poll "a critical toast leads the flood" True has_row live Siren
for i in $(seq 1 20); do notify smoke-flood 0 "Flood $i" "" '[]' '{}' 0 >/dev/null; done
expect_poll "the newest flood toast shows" True has_row live "Flood 20"
expect_poll "at most twenty toasts show at once" 20 on_screen
expect "the critical toast stayed through the flood" True has_row live Siren
expect_poll "the oldest non-critical toast was let go into the history" True in_history "Flood 1"
expect "the toast let go is off the screen" False has_row live "Flood 1"
expect "dismissing every toast is allowed" ok notes dismiss-all
expect_poll "every toast left the screen" 0 on_screen
expect_poll "the layer goes with the last toast" 0 layer_count vgs:layer

# The Inbox: what arrived since the last Mark read, over the stack, with
# the toasts held while it is open.
kept="$(note_status history)"
expect "the inbox opens over IPC" ok notes inbox
expect_poll "the panel is the inbox" '"inbox"' read_notes panelMode
expect_poll "the inbox lists the kept notifications, forty at most" "$(( kept < 40 ? kept : 40 ))" panel_count
input_all() { ipc smoke layerItems vgs.notifications Stack inputAll | python3 -c 'import json,sys; print(sorted(set(v["inputAll"] for s, r, v in json.load(sys.stdin))))'; }
expect_poll "the stack takes the whole screen's presses while a panel is open" '[True]' input_all
notify smoke-app 0 "While open" "" '[]' '{"urgency": <byte 0>}' 0 >/dev/null
expect_poll "a toast arriving with the panel open shows" True has_row live "While open"
expect_poll "its clock does not run while the panel is open" paused clock_state "While open"
sleep 1
read -r mx my < <(pill_centre "Mark read") || fail "the Mark read pill is not drawn"
click "$mx" "$my" || fail "the click on Mark read failed"
expect_poll "Mark read closes the panel" '""' read_notes panelMode
read_before_set() { state_at readBefore | python3 -c 'import sys; print(float(sys.stdin.read()) > 0)'; }
expect_poll "Mark read persists its cutoff" True read_before_set
expect_poll "the live toast stayed through the panel" True has_row live "While open"
expect_poll "the panel's rows went with it" '[]' row_summaries panel
expect_poll "the stack lets presses through again once the panel is closed" '[False]' input_all
expect "dismissing the toast held through the panel is allowed" ok notes dismiss-all
expect_poll "no toast is left before the inbox opens again" 0 on_screen
all_rows() { ipc smoke modelRows vgs.notifications rows key | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
expect_poll "every exit has played before the inbox opens again" 0 all_rows
expect "the inbox opens again" ok notes inbox
expect_poll "an inbox after Mark read is caught up" '"All caught up"' read_notes panelSubtitle
expect "the history panel opens" ok notes history
kept="$(note_status history)"
expect_poll "the history lists what is kept" "$(( kept < 40 ? kept : 40 ))" panel_count
sleep 1
read -r qx qy < <(pill_centre "Clear history") || fail "the Clear history pill is not drawn"
click "$qx" "$qy" || fail "the click on Clear history failed"
expect_poll "Clear history empties the stored history" 0 history_count
expect_poll "its rows fade out" '[]' row_summaries panel
expect "the panel stays open after Clear history" '"history"' read_notes panelMode
click 5 "$((mon_h - 5))" || fail "the click outside the panel failed"
expect_poll "a press outside the stack closes the panel" '""' read_notes panelMode
expect "the inbox shortcut toggles the panel" ok hypr dispatch 'hl.dsp.global("vgs.notifications:inbox")'
expect_poll "the shortcut opened the inbox" '"inbox"' read_notes panelMode
expect "the shortcut closes it again" ok hypr dispatch 'hl.dsp.global("vgs.notifications:inbox")'
expect_poll "the shortcut closed the inbox" '""' read_notes panelMode
expect_poll "the screen is clear" 0 on_screen

# Silence: a notification goes into the history instead of the screen, bar
# a critical one from the bare command line; one from the bare command line
# that is not critical is not kept at all.
expect "Silence turns on over IPC" on notes silence on
expect_poll "Silence is stored" true state_at dnd
notify smoke-app 0 "Quiet" "" '[]' '{}' 0 >/dev/null
expect_poll "a silenced notification goes into the history" '"Quiet"' state_at history.0.summary
expect "a silenced notification shows no toast" none key_of Quiet
expect "the inbox opens under Silence" ok notes inbox
notify smoke-app 0 "Quiet while open" "" '[]' '{}' 0 >/dev/null
expect_poll "a silenced notification joins the open inbox" True has_row panel "Quiet while open"
notify smoke-chat 0 "Quiet pictured" "" '[]' "{\"image-path\": <\"$home/avatar.png\">}" 0 >/dev/null
expect_poll "a silenced notification with an image joins the open inbox" True has_row panel "Quiet pictured"
expect_poll "its row draws the copy, made before the row showed" True shows_icon "Quiet pictured"
# Clearing fades the panel's rows and removes them a moment later; one that
# arrives in that moment stays.
expect "clearing the history with the inbox open is allowed" ok notes clear-history
notify smoke-app 0 "After clear" "" '[]' '{}' 0 >/dev/null
expect_poll "the cleared rows go" '["After clear"]' row_summaries panel
sleep 1
expect "a notification that arrived while the panel cleared stays in it" '["After clear"]' row_summaries panel
expect "the inbox closes under Silence" ok notes close
expect_poll "the inbox under Silence closed" '""' read_notes panelMode
notify notify-send 0 "Urgent CLI" "" '[]' '{"urgency": <byte 2>}' 0 >/dev/null
expect_poll "a critical notification from the command line shows through Silence" True has_row live "Urgent CLI"
notify notify-send 0 "Noise" "" '[]' '{}' 0 >/dev/null
notify smoke-app 0 "After noise" "" '[]' '{}' 0 >/dev/null
expect_poll "the next silenced notification is kept" '"After noise"' state_at history.0.summary
expect "a plain command-line notification under Silence is not kept" False in_history Noise
expect "a malformed Silence argument is refused" 'refused: silence="loud" want=on|off|toggle' notes silence loud

# The history keeps a hundred; the panel shows forty.
for i in $(seq 1 105); do notify smoke-bulk 0 "Bulk $i" "" '[]' '{}' 0 >/dev/null; done
expect_poll "the history keeps the newest hundred" 100 history_count
expect "the newest is first" '"Bulk 105"' state_at history.0.summary
expect "the oldest went" False in_history "Bulk 5"
expect "the history panel opens on the full history" ok notes history
expect_poll "the full history panel shows forty rows" 40 panel_count
expect "the panel closes over IPC" ok notes close
expect_poll "the panel closed" '""' read_notes panelMode

# A rebuild restores the toasts on screen from the state file, without live
# actions, and keeps Silence; the restored toast answers only Dismiss.
notes silence off >/dev/null
notify smoke-chat 0 "Survivor" "" '["default", "Open"]' '{}' 0 >/dev/null
expect_poll "a toast to survive the rebuild shows" True has_row live "Survivor"
notes silence on >/dev/null
printf '\n' >>"$repo/shell/plugins/vgs.notifications/README.md"
expect "a rescan after editing the plugin answers ok" ok ipc shell rescanPlugins
restored_sorted() { row_summaries restored | python3 -c 'import json,sys; print(json.dumps(sorted(json.load(sys.stdin))))'; }
expect_poll "the rebuilt service restored the toasts on screen" '["Survivor", "Urgent CLI"]' restored_sorted
expect "a rebuild keeps Silence" true note_status silence
sleep 1
read -r sx sy < <(card_centre Survivor) || fail "the restored toast has no card"
hover "$sx" "$sy" || fail "the hover over the restored toast failed"
expect_poll "a restored toast offers no live action" '["Dismiss"]' shown_pills Survivor
hover "$((mon_w - 5))" "$((mon_h - 5))" || fail "moving the pointer off the restored toast failed"

# A stored toast whose time ran out while the service was down goes into
# the history, not onto the screen. The history is emptied first, so the
# stale entry is not cut as its oldest.
expect "clearing the history before the stale entry is allowed" ok notes clear-history
expect_poll "the history is empty before the stale entry" 0 history_count
expect "disabling the notifications is allowed" ok ipc shell setPluginEnabled vgs.notifications false
expect_poll "the service is gone" False record_exists vgs.notifications
python3 - "$note_state" <<'PY'
import json, os, sys, time
p = sys.argv[1]
d = json.load(open(p))
ts = int(time.time() * 1000) - 60000
d["live"].append({"key": "%d-900" % ts, "originalId": 900, "app": "smoke-app", "appIcon": "", "summary": "Stale", "body": "", "image": "", "desktopEntry": "", "urgency": 1, "expireTimeout": 0, "timestamp": ts})
json.dump(d, open(p + ".tmp", "w"))
os.replace(p + ".tmp", p)
PY
expect "re-enabling the notifications is allowed" ok ipc shell setPluginEnabled vgs.notifications true
expect_poll "the re-enabled service is built" True record_exists vgs.notifications
expect_poll "the re-enabled service restored the live toasts" True has_row restored Survivor
expect "a toast whose time ran out is not shown again" none key_of Stale
expect_poll "it went into the history instead" True in_history Stale

# A state file the judge refuses is reported and left as it is; clearing
# the history starts it over.
expect "disabling the notifications before the corrupt file is allowed" ok ipc shell setPluginEnabled vgs.notifications false
expect_poll "the service is gone before the corrupt file" False record_exists vgs.notifications
printf '{ nope\n' >"$note_state"
expected_errors+=('notifications: state refused: file=.*state\.json reason=not-json' 'notifications: state held in memory: file=.*state\.json state=corrupt' 'notifications: state reset by the user: file=.*state\.json was corrupt')
expect "re-enabling over a corrupt file is allowed" ok ipc shell setPluginEnabled vgs.notifications true
expect_poll "the service reports the corrupt file" '"corrupt"' note_status store.state
expect_log "the refusal is logged with its reason" 1 'notifications: state refused: file=.*state\.json reason=not-json'
notify smoke-app 0 "Over corruption" "" '[]' '{}' 0 >/dev/null
expect_poll "a toast still shows over a corrupt file" True has_row live "Over corruption"
sleep 0.5
expect "the corrupt file is not overwritten" '{ nope' cat "$note_state"
expect "clearing the history is allowed" ok notes clear-history
expect_poll "clearing the history starts the file over" '"loaded"' note_status store.state
expect_poll "the new file holds the toast on screen" '["Over corruption"]' live_summaries
expect "dismissing the toast over the new file is allowed" ok notes dismiss-all
expect_poll "no toast is left" 0 on_screen

# A monitor that comes gains the stack; one that goes takes it along.
notify smoke-app 0 "Everywhere" "" '[]' '{}' 0 >/dev/null
expect_poll "a toast for the monitor rows shows" "$monitors" layer_count vgs:layer
note_output=SMOKE-NOTES
expect "the nested compositor adds a monitor for the notification rows" ok hypr output create headless "$note_output"
expect_poll "the new monitor gets the stack" "$((monitors + 1))" layer_count vgs:layer
everywhere() { ipc smoke layerItems vgs.notifications NotificationCard summary | python3 -c 'import json,sys; print(sum(1 for s, r, v in json.load(sys.stdin) if v["summary"] == "Everywhere"))'; }
expect_poll "the new screen's stack draws the toast" "$((monitors + 1))" everywhere
expect "the nested compositor removes that monitor" ok hypr output remove "$note_output"
expect_poll "the removed monitor's stack is gone" "$monitors" layer_count vgs:layer
expect "the toast outlived the removed monitor" True has_row live "Everywhere"

# The look: the theme reaches it through its mode, accent and motion scale
# alone.
theme="$home/.config/vgs/theme.json"
write_theme() { printf '%s\n' "$1" >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"; }
look_at() { read_notes look | python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[k]
print(json.dumps(v))' "$1"; }
edge_values() { ipc smoke layerItems vgs.notifications EdgeLight "$1" | python3 -c 'import json,sys; print(json.dumps(sorted(set(json.dumps(v[sys.argv[1]]) for s, r, v in json.load(sys.stdin)))))' "$1"; }
expect_poll "the look resolved" '"#cc101010"' look_at glass.fill
write_theme '{ "schemaVersion": 1, "name": "unrelated", "tokens": { "palette": { "foreground": "#ff00ff", "background": "#00ff00" }, "font": { "size": 22 }, "space": { "unit": 7 }, "radius": { "md": 9 }, "text": { "body": { "size": 30 } }, "color": { "surface": "#ff0000" } } }'
expect_poll "the unrelated theme is accepted" unrelated ipc smoke themeName
expect "an unrelated theme leaves the glass" '"#cc101010"' look_at glass.fill
expect "an unrelated theme leaves the text" '"#ffe8e8e8"' look_at text.foreground
expect "an unrelated theme leaves the type" '"Liberation Sans"' look_at font.family
expect "an unrelated theme leaves the card width" 420 look_at card.width
write_theme '{ "schemaVersion": 1, "name": "accent", "tokens": { "palette": { "accent": "#7aa2f7" } } }'
expect_poll "the accent reaches the notifications" '"#ff7aa2f7"' look_at palette.accent
expect "the accent reaches the edge light" '["\"#7aa2f7\""]' edge_values accent
expect "the accent leaves the glass" '"#cc101010"' look_at glass.fill
write_theme '{ "schemaVersion": 1, "name": "bright", "tokens": { "scheme": { "mode": "light" }, "palette": { "accent": "#a8330a" } } }'
expect_poll "light mode applies the light glass" '"#d9f2f2f2"' look_at glass.fill
expect "light mode applies the light text" '"#ff2a2a2a"' look_at text.foreground
expect "light mode applies the light edge neutral" '"#ff2d2d2d"' look_at edge.neutral
expect "light mode keeps the theme's accent" '"#ffa8330a"' look_at palette.accent
write_theme '{ "schemaVersion": 1, "name": "still", "tokens": { "motion": { "scale": 0 } } }'
expect_poll "reduced motion stills the durations" 0 look_at motion.duration.medium4
expect_poll "reduced motion stills the orbiting lights" '["false"]' edge_values running
write_theme '{ "schemaVersion": 1, "name": "vgs", "tokens": {} }'
expect_poll "the defaults return" vgs ipc smoke themeName
expect "dismissing the last toast is allowed" ok notes dismiss-all
expect_poll "the last toast's exit has played" 0 layer_count vgs:layer

# Disabling and enabling again, three times over, leaves nothing behind.
for round in 1 2 3; do
  expect "disable round $round is allowed" ok ipc shell setPluginEnabled vgs.notifications false
  expect_poll "disable round $round destroyed the service" False record_exists vgs.notifications
  expect_poll "disable round $round released the shortcut, IPC target, subscriber and layer" '[[], [], [], []]' lent_notes
  expect "disable round $round left no layer surface" 0 layer_count vgs:layer
  expect_poll "disable round $round left no shortcut in the compositor" 0 note_shortcuts
  if [[ $round -lt 3 ]]; then
    expect "enable round $round is allowed" ok ipc shell setPluginEnabled vgs.notifications true
    expect_poll "enable round $round built the service" True record_exists vgs.notifications
    expect_poll "enable round $round registered again" '[["vgs.notifications:inbox"], ["vgs.notifications"], ["vgs.notifications"], []]' lent_notes
  fi
done
expect "the disabled plugin holds no layers capability" null lent holders.layers
notification_holder() { lent holders.notifications | python3 -c 'import json,sys; print("vgs.notifications" in (json.load(sys.stdin) or []))'; }
expect "the disabled plugin holds no notifications capability" False notification_holder
orphans() {
  python3 -c 'import json,os,sys
d = json.load(open(sys.argv[1]))
owned = {os.path.basename(e[r][7:]) for e in d["live"] + d["history"] for r in ("image", "appIcon") if e[r].startswith("file://")}
print(sorted(set(os.listdir(sys.argv[2])) - owned))' "$note_state" "$note_images"
}
expect "the images directory holds only what the stored entries own" '[]' orphans
