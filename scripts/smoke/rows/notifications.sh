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
note_status() { notes status | py_reply 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[k]
print(json.dumps(v))' "$1"; }
read_notes() { ipc smoke readInstance service vgs.notifications "$1"; }
# The rows the service holds, as [summary, origin, leaving] triples, newest first.
note_rows() { ipc smoke modelRows vgs.notifications rows summary,origin,leaving | py_reply 'import json,sys; print(json.dumps([r for r in json.load(sys.stdin) if r[2] == ""]))'; }
row_summaries() { note_rows | py_reply 'import json,sys; print(json.dumps([r[0] for r in json.load(sys.stdin) if r[1] == sys.argv[1]]))' "$1"; }
# The store writes its state file whole through FileView's atomicWrites, a
# temporary file renamed over it, so a file that exists is complete.
# note_state_py PROGRAM [ARG...]: python3 -c PROGRAM with the file's path
# as sys.argv[1], then ARG...; `absent` before the store's first save.
note_state_py() { # PROGRAM [ARG...]
  if [[ -e $note_state ]]; then python3 -c "$1" "$note_state" "${@:2}"; else echo absent; fi
}
# The stored value at a dotted path such as history.0.summary; `missing`
# when a key or an index on the path is not there, as in an emptied
# history.
state_at() { note_state_py 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    if isinstance(v, list):
        if not -len(v) <= int(k) < len(v): print("missing"); sys.exit()
        v = v[int(k)]
    else:
        if k not in v: print("missing"); sys.exit()
        v = v[k]
print(json.dumps(v))' "$1"; }
history_summaries() { note_state_py 'import json,sys; print(json.dumps([e["summary"] for e in json.load(open(sys.argv[1]))["history"]]))'; }
history_count() { note_state_py 'import json,sys; print(len(json.load(open(sys.argv[1]))["history"]))'; }
live_summaries() { note_state_py 'import json,sys; print(json.dumps([e["summary"] for e in json.load(open(sys.argv[1]))["live"]]))'; }
# Which of deadline and remaining the stored live entry KEY holds, or none.
stored_clock() { note_state_py 'import json,sys; e=next((e for e in json.load(open(sys.argv[1]))["live"] if e["key"] == sys.argv[2]), {}); print(" ".join(k for k in ("deadline", "remaining") if k in e) or "none")' "$1"; }
# The image the stored live entry KEY points at, as JSON, or null.
stored_image() { note_state_py 'import json,sys; print(json.dumps(next((e["image"] for e in json.load(open(sys.argv[1]))["live"] if e["key"] == sys.argv[2]), None)))' "$1"; }
# One notification on the sandbox bus: APP REPLACES SUMMARY BODY ACTIONS HINTS
# TIMEOUT, the last three in gdbus's GVariant text; prints its id.
notify() {
  "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify "$1" "$2" "" "$3" "$4" "$5" "$6" "$7" | python3 -c 'import re,sys; print(re.search(r"uint32 (\d+)", sys.stdin.read()).group(1))'
}
close_note() { "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.CloseNotification "$1" >/dev/null; }
lent_notes() { ipc shell lent | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([[s for s in d["shortcuts"] if s.startswith("vgs.notifications")], [t for t in d["ipcTargets"] if t == "vgs.notifications"], [s for s in d["subscribers"] if s == "vgs.notifications"], [l["plugin"] for l in d["layers"] if l["plugin"] == "vgs.notifications"]]))'; }
note_shortcuts() { hypr globalshortcuts | python3 -c 'import sys; print(sum(1 for line in sys.stdin if "vgs.notifications:inbox" in line))'; }

# Controls for the state readers, pointed at planted files: with no file,
# as before the store's first save, each answers absent; a path past the
# end of a list, as in an emptied history, or through a key the file
# lacks answers missing.
with_state() { # FILE CMD...: CMD with the state readers reading FILE
  local note_state="$1"
  shift
  "$@"
}
state_readers=("live_summaries" "history_summaries" "history_count" "state_at dnd" "stored_clock k" "stored_image k")
for reader in "${state_readers[@]}"; do
  read -r -a reader_words <<<"$reader"
  expect "with no state file $reader answers absent" absent with_state "$sandbox/no-notifications-state.json" "${reader_words[@]}"
done
printf '%s\n' '{"dnd": false, "live": [], "history": []}' >"$sandbox/empty-notifications-state.json"
expect "state_at past the end of an empty history answers missing" missing with_state "$sandbox/empty-notifications-state.json" state_at history.0.summary
expect "state_at through a key the file lacks answers missing" missing with_state "$sandbox/empty-notifications-state.json" state_at readBefore
expect "state_at reads a value the file holds" false with_state "$sandbox/empty-notifications-state.json" state_at dnd

expect "the notifications start disabled in the sandbox" False plugin_enabled vgs.notifications
# A synthetic Slack under the sandbox's configuration, in place before the
# service starts and reads its workspace list.
mkdir -p -- "$home/.config/Slack"
cp -R -- "$repo/scripts/smoke/fixtures/slack/." "$home/.config/Slack/"
# The row runs after the shell process starts, so it cannot add the
# helper's test API environment to that process without changing core. The
# helper's own suite covers the HTTP refresh. seed_slack_photos writes the
# helper's per-team cache, fresh, so the helper serves it without a call:
# acme from its own workspace's token, and globex from the single-workspace
# token, whose team accounts.json records. The row seeds it before the
# service starts, and again after the token rows, whose last states hold no
# token and so leave no cache, so no run of the helper is due a network call.
slack_photos="$home/.cache/vgs/notifications/slack-photos"
seed_slack_photos() {
  mkdir -p -- "$slack_photos"
  python3 - "$slack_photos" <<'PY'
import hashlib, json, pathlib, struct, sys, time, zlib

root = pathlib.Path(sys.argv[1])
now = int(time.time() * 1000)

def crc32(data):
    import binascii
    return binascii.crc32(data) & 0xffffffff

def chunk(kind, data):
    name = kind.encode()
    return struct.pack(">I", len(data)) + name + data + struct.pack(">I", crc32(name + data))

def png(r, g, b):
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes([0, r, g, b, 255]))
    return b"\x89PNG\r\n\x1a\n" + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", b"")

def file_url(file):
    return "file://" + str(file) + "?v=" + hashlib.sha256(file.read_bytes()).hexdigest()[:16]

def team(id, names, account, colour, users):
    folder = root / id
    (folder / "users").mkdir(parents=True, exist_ok=True)
    (folder / "workspace.png").write_bytes(png(*colour))
    listed = []
    for uid, user_names, rgb in users:
        photo = folder / "users" / (uid + ".png")
        photo.write_bytes(png(*rgb))
        listed.append({"id": uid, "names": user_names, "photo": file_url(photo)})
    (folder / "team.json").write_text(json.dumps({"id": id, "names": names, "icon": file_url(folder / "workspace.png"), "account": account, "generatedAt": now, "downloadFailed": 0}) + "\n")
    (folder / "users.json").write_text(json.dumps({"users": listed}) + "\n")

team("T0ACME", ["acme", "Acme Corp"], "slack:T0ACME", (20, 80, 180), [
    ("UALAN", ["alan"], (180, 40, 40)),
    ("UADA", ["ada", "Ada Lovelace"], (40, 160, 80)),
    ("UGRACE", ["grace", "Grace Hopper"], (150, 70, 180)),
])
team("T0GLOBEX", ["globex", "Globex"], "slack", (200, 120, 20), [
    ("UEDSGER", ["edsger"], (60, 60, 200)),
])
(root / "accounts.json").write_text(json.dumps({"slack:T0ACME": {}, "slack": {"team": "T0GLOBEX", "resolvedAt": now}}) + "\n")
# A fresh emoji.list answer for each team, so the custom emoji come from the
# synthetic disk cache alone and no run asks Slack for the list.
for id in ("T0ACME", "T0GLOBEX"):
    (root / id / "emoji.json").write_text(json.dumps({"team": id, "map": {}, "sources": {}, "list": {"at": now, "failedAt": 0, "error": "", "names": {}}}) + "\n")
PY
}
seed_slack_photos
secret_tool_stand_in "slack:T0ACME present;slack:T0GLOBEX absent;slack present"
cat >"$shim/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'notifications-smoke: real Slack API refused' >&2
exit 19
SH
chmod 755 "$shim/curl"
shell_secret_tool() { PATH="$shim:$(dirname -- "$node_bin"):$PATH" command -v secret-tool || true; }
expect "the Slack photo helper resolves the stub secret-tool first" "$shim/secret-tool" shell_secret_tool
file_url_json() { python3 -c 'import hashlib,json,pathlib,sys; p=pathlib.Path(sys.argv[1]); print(json.dumps("file://" + str(p) + "?v=" + hashlib.sha256(p.read_bytes()).hexdigest()[:16]))' "$1"; }
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
key_of() { ipc smoke modelRows vgs.notifications rows key,summary | py_reply 'import json,sys; print(next((k for k, s in json.load(sys.stdin) if s == sys.argv[1]), "none"))' "$1"; }
clock_of() { read_notes clocks | py_reply 'import json,sys; c=json.load(sys.stdin).get(sys.argv[1]); print("none" if c is None else ("running" if c["since"] is not None else "paused") + " " + str(c["remaining"]))' "$1"; }
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
has_row() { row_summaries "$1" | py_reply 'import json,sys; print(sys.argv[1] in json.load(sys.stdin))' "$2"; }
in_history() { history_summaries | python3 -c 'import json,sys; print(sys.argv[1] in json.load(sys.stdin))' "$1"; }
panel_count() { row_summaries panel | py_reply 'import json,sys; print(len(json.load(sys.stdin)))'; }
clock_state() { clock_of "$(key_of "$1")" | cut -d' ' -f1; }
test_file() { if [[ -f $1 ]]; then echo True; else echo False; fi; }
# wait_for LABEL WANT SECONDS CMD...: expect_poll with its own bound, for a
# toast's lifetime, which runs for seconds; a traceback fails at once, as
# harness.sh's reader_stderr says.
wait_for() {
  local label="$1" want="$2" seconds="$3" got="" matched err="$sandbox/reader-$BASHPID.stderr"
  shift 3
  for _ in $(seq 1 $((seconds * 5))); do
    matched=false
    if got="$("$@" 2>"$err")" && [[ $got == "$want" ]]; then matched=true; fi
    reader_stderr "$label" "$err" || return 0
    if [[ $matched == true ]]; then ok "$label"; return; fi
    sleep 0.2
  done
  fail "$label: got $got want $want"
}
# Whether the first card is centred at the top; `no-card` before it is laid out.
toast_centred() { ipc smoke layerItems vgs.notifications NotificationCard summary | python3 -c 'import json,sys; c=json.load(sys.stdin)
if not c: print("no-card"); sys.exit()
x,y,w,h=c[0][1]; print(abs(x + w / 2 - int(sys.argv[1]) / 2) <= 1 and 0 < y < 40)' "$mon_w"; }
geometry expect_poll "the toast is centred at the top of the screen under the bar" True toast_centred
geometry expect_poll "the layer covers the screen below the bar" "[[0, $bar_reserved, $mon_w, $((mon_h - bar_reserved))]]" layers_of vgs:layer

# A sender's timeout is milliseconds, held to the urgency's floor and ceiling.
notify smoke-app 0 "Timed" "" '[]' '{}' 12000 >/dev/null
expect_poll "a timed toast shows" True has_row live "Timed"
timed_clock() { clock_of "$(key_of Timed)" | py_reply 'import sys; state, left = sys.stdin.read().split(); print(state == "running" and 12000 <= float(left) <= 13500)'; }
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
notify smoke-chat 0 "Pictured" "" '[]' "{\"image-path\": <\"$home/avatar.png\">}" 30000 >/dev/null
expect_poll "a toast with an image shows" True has_row live "Pictured"
pictured_key="$(key_of Pictured)"
expect_poll "the sender's image was copied for the stored entry" True test_file "$note_images/$pictured_key-image"
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
notify Slack 0 "[acme] from Ada Lovelace" "Did you see the notes?" '[]' '{"desktop-entry": <"slack">}' 30000 >/dev/null
expect_poll "a Slack direct message draws its workspace's icon" true card_value "[acme] from Ada Lovelace" showsBadge
expect "the icon is the copy out of Slack's cache" "$(file_url_json "$slack_icon")" card_value "[acme] from Ada Lovelace" workspaceIcon
expect "the copy is the cached image's body" "370 89504e470d0a1a0a" bash -c 'printf "%s %s\n" "$(stat -c %s -- "$1")" "$(od -An -tx1 -N8 -- "$1" | tr -d " ")"' _ "$slack_icon"
expect "the workspace's name gives way to its icon" '"from Ada Lovelace"' card_value "[acme] from Ada Lovelace" title
expect "a direct message shows its sender's face" '{"rule": "slack", "source": "desktop", "workspace": "acme", "title": "from Ada Lovelace", "faces": ["Ada Lovelace"], "more": 0}' card_value "[acme] from Ada Lovelace" enrichment
notify Slack 0 "[acme] in ada, grace, alan, edsger, barbara" "alan: lunch at noon?" '[]' '{"desktop-entry": <"slack">}' 30000 >/dev/null
expect_poll "a group message shows three faces, its sender first, and the rest as more" '{"rule": "slack", "source": "desktop", "workspace": "acme", "title": "in ada, grace, alan, edsger, barbara", "faces": ["alan", "ada", "grace"], "more": 2}' card_value "[acme] in ada, grace, alan, edsger, barbara" enrichment
expect "the group message's card draws its faces" true card_value "[acme] in ada, grace, alan, edsger, barbara" showsFaces
token_faces_loaded() { ipc smoke layerItems vgs.notifications Faces names,images | python3 -c 'import json,sys
for _screen, _rect, value in json.load(sys.stdin):
    if value["names"] == ["alan", "ada", "grace"]:
        images = value["images"]
        print(len(images) == 3 and all(str(i).startswith("file://") and "?v=" in str(i) for i in images) and len(set(images)) == 3)
        break
else:
    print(False)' ; }
expect_poll "the token cache supplies distinct Slack group photos" True token_faces_loaded
notify Slack 0 "[globex] in eng" "Grace: shipped" '[]' '{"desktop-entry": <"slack">}' 30000 >/dev/null
expect_poll "a workspace with no disk-cache icon uses the token-cache icon" true card_value "[globex] in eng" showsBadge
expect "the token-cache workspace icon replaces that workspace name" '"in eng"' card_value "[globex] in eng" title
expect "the fallback icon came from the Slack photo cache" "$(file_url_json "$slack_photos/T0GLOBEX/workspace.png")" card_value "[globex] in eng" workspaceIcon

# Slack in a browser: Chromium names no application and opens the body
# with the site's address and a blank line. The card reads it with the
# Slack rule; the one photo team whose users hold its sender, acme, is its
# workspace.
notify "" 0 "New message in standup" $'app.slack.com\n\nalan: standup at ten?' '[]' '{}' 0 >/dev/null
expect_poll "a browser Slack message is read by the Slack rule" '{"rule": "slack", "source": "browser", "workspace": "", "title": "in standup", "faces": ["alan"], "more": 0}' card_value "New message in standup" enrichment
expect_poll "its workspace is the one team that knows its sender" '"acme"' card_value "New message in standup" workspace
expect_poll "it draws that workspace's icon" true card_value "New message in standup" showsBadge
expect "it draws the Slack title" '"in standup"' card_value "New message in standup" title
expect "its body loses the site's address" '"alan: standup at ten?"' card_value "New message in standup" sanitizedBody
sender_photo() { card_value "$1" faceImages | python3 -c 'import json,sys; v=json.load(sys.stdin); print(isinstance(v, list) and len(v) == 1 and str(v[0]).startswith("file://" + sys.argv[1] + "/"))' "$2"; }
expect_poll "its sender shows the photo of that workspace" True sender_photo "New message in standup" "$slack_photos/T0ACME/users"

# One message from both clients: the desktop copy stays. A browser copy
# after the desktop's never shows; a desktop copy after a browser card on
# screen replaces it, and the browser card leaves no history entry.
duplicate_count() { log_lines 'notifications: slack duplicate: kept=desktop dropped=browser'; }
notify Slack 0 "[acme] in eng-core" "Grace Hopper: the build is green" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
expect_poll "the desktop copy shows" True has_row live "[acme] in eng-core"
notify "" 0 "New message in eng-core" $'app.slack.com\n\nGrace Hopper: the build is green' '[]' '{}' 0 >/dev/null
expect_poll "the browser copy after it is dropped, and the log says which stayed" 1 duplicate_count
expect "the browser copy never shows" False has_row live "New message in eng-core"
notify "" 0 "New message in design" $'app.slack.com\n\nada: mockups are ready' '[]' '{}' 0 >/dev/null
expect_poll "a browser copy alone shows" True has_row live "New message in design"
notify Slack 0 "[acme] in design" "ada: mockups are ready" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
expect_poll "the desktop copy after it shows" True has_row live "[acme] in design"
expect_poll "the browser card gives way to it" False has_row live "New message in design"
expect "the browser card left no history entry" False in_history "New message in design"
expect "the log says the desktop copy stayed twice" 2 duplicate_count
expect "the status counts the copies kept" '{"keptDesktop": 2, "keptBrowser": 0}' note_status duplicates

# The space around a card's text, from the card's rectangle and its visible
# title and body items, as `top=<px> bottom=<px> left=<px> right=<px>
# height=<px> slot=<px> pad=<px>` for the card whose summary is SUMMARY on
# the first screen; `absent` before the card exists and `no-text` while
# none of its text lines is visible. The predicate below is the contract
# and its control.
text_space() {
  local cards texts
  cards="$(ipc smoke layerItems vgs.notifications NotificationCard summary,slotLeft,pad)" || return
  texts="$(ipc smoke layerItems vgs.notifications QQuickText text,visible,objectName)" || return
  bodies="$(ipc smoke layerItems vgs.notifications ImageText lineCount,visible,objectName)" || return
  python3 -c 'import json,sys
cards, texts, bodies = json.loads(sys.argv[2]), json.loads(sys.argv[3]), json.loads(sys.argv[4])
card = next(((s, r, v) for s, r, v in cards if v["summary"] == sys.argv[1]), None)
if card is None: print("absent"); sys.exit()
screen, (x, y, w, h), values = card
inside = lambda s, r: s == screen and x <= r[0] < x + w and y <= r[1] < y + h
# The body is an ImageText, whose box is its drawn text'"'"'s.
lines = [r for s, r, v in texts if inside(s, r) and v["visible"] and v["text"] and v["objectName"] == "notificationTitleText"]
lines += [r for s, r, v in bodies if inside(s, r) and v["visible"] and v["lineCount"] > 0 and v["objectName"] == "notificationBodyText"]
if not lines: print("no-text"); sys.exit()
top, bottom = min(r[1] for r in lines), max(r[1] + r[3] for r in lines)
left, right = min(r[0] for r in lines), max(r[0] + r[2] for r in lines)
print("top=%d bottom=%d left=%d right=%d height=%d slot=%d pad=%d" % (top - y, y + h - bottom, left - x, x + w - right, h, round(values["slotLeft"]), round(values["pad"])))' "$1" "$cards" "$texts" "$bodies"
}
# Rectangular text clears the rounded end by one spacing step on both sides.
# A round slot stays at the pad.
inset_contract_value() { # KIND CLAMPED MEASUREMENT
  python3 -c 'import math,re,sys
t = sys.stdin.read().strip()
m = re.fullmatch(r"top=(\d+) bottom=(\d+) left=(\d+) right=(\d+) height=(\d+) slot=(-?\d+) pad=(\d+)", t)
if not m: print(t); sys.exit()
top, bottom, left, right, height, slot, pad = map(int, m.groups())
need = math.ceil(height / 2) + 4
problems = []
if abs(top - bottom) > 1: problems.append("vertical")
if left < need: problems.append("left")
if right < need: problems.append("right")
if sys.argv[1] == "avatarless" and abs(left - right) > 1: problems.append("sides")
if sys.argv[1] == "slot":
    if abs(slot - pad) > 1: problems.append("slot")
    if right > need + 1: problems.append("right-clear")
if sys.argv[2] == "clamped" and not (80 <= height <= 94): problems.append("clamped")
print("ok" if not problems else "violation " + ",".join(problems))' "$1" "$2" <<<"$3"
}
checked_space() { # SUMMARY KIND [clamped]
  local t
  t="$(text_space "$1")" || return
  inset_contract_value "$2" "${3:-}" "$t"
}
note_card_reading() { # LABEL SUMMARY
  local t
  t="$(text_space "$2")" || { fail "$1: no card reading"; return; }
  ok "$1: $t"
}
header_space() {
  local headers texts pills
  headers="$(ipc smoke layerItems vgs.notifications InboxHeader titleInset)" || return
  texts="$(ipc smoke layerItems vgs.notifications QQuickText text,visible,objectName)" || return
  pills="$(ipc smoke layerItems vgs.notifications PillButton text,visible)" || return
  python3 -c 'import json,sys
headers, texts, pills = json.loads(sys.argv[1]), json.loads(sys.argv[2]), json.loads(sys.argv[3])
header = next(((s, r, v) for s, r, v in headers if r[3] > 0), None)
if header is None: print("absent"); sys.exit()
screen, (x, y, w, h), values = header
lines = [r for s, r, v in texts if s == screen and v["visible"] and v["objectName"] in ("notificationHeaderTitleText", "notificationHeaderSubtitleText") and x <= r[0] < x + w and y <= r[1] < y + h]
buttons = [(r, v["text"]) for s, r, v in pills if s == screen and v["visible"] and v["text"] in ("Mark read", "History", "Clear history", "Unread") and x <= r[0] < x + w and y <= r[1] < y + h]
if not lines or not buttons: print("incomplete"); sys.exit()
left = min(r[0] for r in lines) - x
right_button = max(buttons, key=lambda item: item[0][0] + item[0][2])[0]
control = x + w - (right_button[0] + right_button[2])
centre = control + right_button[3] / 2
print("left=%d height=%d control=%d centre=%.1f" % (left, h, control, centre))' "$headers" "$texts" "$pills"
}
header_contract_value() {
  python3 -c 'import math,re,sys
t = sys.stdin.read().strip()
m = re.fullmatch(r"left=(\d+) height=(\d+) control=(\d+) centre=([0-9.]+)", t)
if not m: print(t); sys.exit()
left, height, control, centre = int(m.group(1)), int(m.group(2)), int(m.group(3)), float(m.group(4))
need = math.ceil(height / 2) + 4
problems = []
if left < need: problems.append("left")
if abs(centre - height / 2) > 1: problems.append("control")
print("ok" if not problems else "violation " + ",".join(problems))'
}
checked_header() {
  local t
  t="$(header_space)" || return
  header_contract_value <<<"$t"
}
note_header_reading() {
  local t
  t="$(header_space)" || { fail "header: no reading"; return; }
  ok "header geometry measured: $t"
}
notify smoke-app 0 "Even one" "" '[]' '{}' 0 >/dev/null
notify smoke-app 0 "Even two" "One line of body text" '[]' '{}' 0 >/dev/null
notify smoke-app 0 "Even multi" $'The first line of the body\nthe second line\nand the third' '[]' '{}' 0 >/dev/null
notify "Google Chrome" 0 "Weekly eStaff" $'calendar.google.com\n\n10:30am – 11:30am' '[]' '{}' 0 >/dev/null
notify "" 0 "New message in master-operator" $'app.slack.com\n\nada: the deployment note is in the channel.' '[]' '{}' 0 >/dev/null
notify smoke-app 0 "Even max" "$(printf 'A body long enough to run past every line the card may show. %.0s' $(seq 1 12))" '[]' '{}' 0 >/dev/null
notify smoke-chat 0 "Hover geometry" "Pick one" '["default", "Open", "reply", "Reply"]' '{}' 30000 >/dev/null
expect_poll "the hover geometry card shows" True has_row live "Hover geometry"
read -r gx gy < <(card_centre "Hover geometry") || fail "the hover geometry toast has no card"
hover "$gx" "$gy" || fail "the hover over the geometry toast failed"
expect_poll "the hover geometry card shows actions" '["Open", "Reply", "Dismiss"]' shown_pills "Hover geometry"
expect "the inset predicate rejects text under the rounded end" "violation left,right" inset_contract_value avatarless "" "top=14 bottom=14 left=14 right=14 height=45 slot=-1 pad=14"
expect "the header predicate rejects a title under the rounded end" "violation left" header_contract_value <<<"left=20 height=48 control=10 centre=24.0"
expect_poll "a one-line card clears the rounded end on both sides" ok checked_space "Even one" avatarless
expect_poll "a two-line card clears the rounded end on both sides" ok checked_space "Even two" avatarless
expect_poll "a multiline card clears the rounded end on both sides" ok checked_space "Even multi" avatarless
expect_poll "a browser calendar card clears the rounded end on both sides" ok checked_space "Weekly eStaff" avatarless
expect_poll "a browser Slack card keeps its round slot at the pad and clears the text" ok checked_space "New message in master-operator" slot
expect_poll "a card past its most lines stops at its maximum height and clears both sides" ok checked_space "Even max" avatarless clamped
expect_poll "a hovered action card clears the rounded end while the pills show" ok checked_space "Hover geometry" avatarless
expect_poll "a card with an image keeps its round slot at the pad and clears the text" ok checked_space Pictured slot
expect_poll "a Slack faces card keeps its round slot at the pad and clears the text" ok checked_space "[acme] in ada, grace, alan, edsger, barbara" slot
expect "the inbox opens for header geometry" ok notes inbox
expect_poll "the inbox header title clears the rounded end" ok checked_header
note_card_reading "one-line card geometry measured" "Even one"
note_card_reading "two-line card geometry measured" "Even two"
note_card_reading "multiline card geometry measured" "Even multi"
note_card_reading "browser calendar card geometry measured" "Weekly eStaff"
note_card_reading "browser message card geometry measured" "New message in master-operator"
note_card_reading "clamped card geometry measured" "Even max"
note_card_reading "hover action card geometry measured" "Hover geometry"
note_card_reading "image avatar card geometry measured" Pictured
note_card_reading "Slack faces card geometry measured" "[acme] in ada, grace, alan, edsger, barbara"
note_header_reading
expect "the inbox closes after header geometry" ok notes close

# Custom emoji. The synthetic cache holds acme's :smoke-party:, which the
# helper made into a normalized image at start. A card in acme draws it
# inline, in the body's text at the body's height and at full strength;
# a shortcode acme lacks, and a card in globex, keep the text. The cards
# read the emoji from memory and start no helper run; a copy of the
# service that asks for a run from each card's lookup makes the same
# notifications count runs, so the count reads the rule, not a quiet
# helper.
emoji_count() { note_status slack.emoji.teams | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], 0))' "$1"; }
expect_poll "the helper made acme's custom emoji at start" 1 emoji_count T0ACME
party_url() { python3 -c 'import json,sys; h=json.load(open(sys.argv[1] + "/T0ACME/emoji.json"))["map"]["smoke-party"]; print("file://%s/T0ACME/emoji/%s.png?v=%s" % (sys.argv[1], h, h))' "$slack_photos"; }
party="$(party_url)"
expect "the emoji image is a 48 px PNG" "PNG 48 48" python3 -c 'import struct,sys; b=open(sys.argv[1].split("?")[0][7:], "rb").read(24); print(b[1:4].decode(), *struct.unpack(">II", b[16:24]))' "$party"
# The drawn body texts that name an image, and the ImageText items' fade.
drawn_images() { ipc smoke layerItems vgs.notifications QQuickText text,visible | python3 -c 'import json,sys; print(sum(1 for s, r, v in json.load(sys.stdin) if v["visible"] and ("<img src=\"" + sys.argv[1] + "\"") in v["text"]))' "$1"; }
body_fade() { ipc smoke layerItems vgs.notifications ImageText opacity,color | python3 -c 'import json,sys; print(json.dumps(sorted(set((v["opacity"], str(v["color"])) for s, r, v in json.load(sys.stdin)))))'; }
expect "dismissing the Slack cards before the emoji is allowed" ok notes dismiss-all
expect_poll "no card is left before the emoji" 0 note_status onScreen
expect_poll "the helper is idle before the emoji cards" true note_status slack.idle
runs_before="$(note_status slack.runs)"
notify Slack 0 "[acme] in launch" "ada: ship it :smoke-party: and :no-such-emoji:" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
expect_poll "a known custom emoji draws as an image in its body" "$monitors" drawn_images "$party"
expect "its segments hold the image and keep the unknown shortcode as text" "[{\"markup\": \"ada: ship it \"}, {\"image\": \"$party\", \"alt\": \":smoke-party:\"}, {\"markup\": \" and :no-such-emoji:\"}]" card_value "[acme] in launch" bodySegments
expect "the body fades by its colour, so the emoji draws at full strength" '[[1, "#80e8e8e8"]]' body_fade
notify Slack 0 "[globex] in launch" "edsger: ship it :smoke-party:" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
expect_poll "another workspace's card keeps the shortcode as text" '[{"markup": "edsger: ship it :smoke-party:"}]' card_value "[globex] in launch" bodySegments
for i in 1 2 3; do notify Slack 0 "[acme] in party $i" ":smoke-party: $i :smoke-party:" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null; done
expect_poll "every emoji card draws its images" "$((monitors * 4))" drawn_images "$party"
expect "cards with custom emoji start no helper run" "$runs_before" note_status slack.runs
expect "dismissing the emoji cards is allowed" ok notes dismiss-all
expect_poll "no card is left before the emoji latencies" 0 note_status onScreen
# The latencies with custom emoji, each read once: from the notify call to
# the card's body naming its images on every screen, and from the history
# call to forty such rows naming theirs, each polled back to back through
# the probe, one reading per IPC round trip. The budgets and their runs are
# in scripts/qml-smoke.sh's header.
emoji_body="ada: :smoke-party: ship :smoke-party: it :smoke-party: now :smoke-party: team, and a tail long enough to run onto a second line :smoke-party: here"
emoji_texts() { ipc smoke layerItems vgs.notifications QQuickText text,visible | python3 -c 'import json,sys; print(sum(1 for s, r, v in json.load(sys.stdin) if v["visible"] and "<img src=" in v["text"]))'; }
# latency_since START WANT CMD...: the milliseconds from START until CMD
# prints WANT or more, or -1 after 5 s.
latency_since() {
  local start="$1" want="$2" got
  shift 2
  while (( $(date +%s%3N) - start < 5000 )); do
    got="$("$@")" || got=0
    if (( got >= want )); then echo $(( $(date +%s%3N) - start )); return; fi
  done
  echo -1
}
notify_now() { "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.Notify Slack 0 "" "$1" "$emoji_body" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null; }
within_budget() { python3 -c 'import sys; print(0 <= int(sys.argv[1]) <= int(sys.argv[2]))' "$1" "$2"; }
start="$(date +%s%3N)"
notify_now "[acme] in latency"
emoji_toast_ms="$(latency_since "$start" "$monitors" emoji_texts)"
printf '        latency_emoji_toast_ms=%s budget_ms=%s\n' "$emoji_toast_ms" "$emoji_toast_budget_ms"
expect "a toast with custom emoji names its images within its budget" True within_budget "$emoji_toast_ms" "$emoji_toast_budget_ms"
expect "dismissing the latency toast is allowed" ok notes dismiss-all
expect "Silence turns on for the inbox latency" on notes silence on
expect "clearing the history before the inbox latency is allowed" ok notes clear-history
for i in $(seq 1 40); do notify_now "[acme] in inbox $i"; done
expect_poll "the forty emoji notifications are in the history" 40 note_status history
start="$(date +%s%3N)"
notes history >/dev/null
emoji_inbox_ms="$(latency_since "$start" "$((40 * monitors))" emoji_texts)"
printf '        latency_emoji_inbox_ms=%s budget_ms=%s\n' "$emoji_inbox_ms" "$emoji_inbox_budget_ms"
expect "an inbox of forty cards with custom emoji names their images within its budget" True within_budget "$emoji_inbox_ms" "$emoji_inbox_budget_ms"
expect "the emoji inbox closes" ok notes close
expect_poll "the emoji inbox closed" '""' read_notes panelMode
expect "clearing the emoji history is allowed" ok notes clear-history
expect "Silence turns off after the inbox latency" off notes silence off
expect_poll "no card is left before the run-per-card copy" 0 note_status onScreen
# The control: a copy of the service whose card lookup runs the helper.
service_qml="$repo/shell/plugins/vgs.notifications/Service.qml"
cp -- "$service_qml" "$sandbox/Service.qml.kept"
python3 - "$service_qml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = "return Logic.slackEmojiFor(slackPhotos.emoji,"
assert text.count(needle) == 1, "the lookup to plant a run in occurs once"
open(path, "w").write(text.replace(needle, "Qt.callLater(slackPhotos.load); " + needle))
PY
expect "a rescan builds the run-per-card copy" ok ipc shell rescanPlugins
expect_poll "the run-per-card copy is built" True record_exists vgs.notifications
expect_poll "the run-per-card copy made acme's emoji" 1 emoji_count T0ACME
expect_poll "the run-per-card copy's helper is idle" true note_status slack.idle
copy_runs="$(note_status slack.runs)"
notify Slack 0 "[acme] in control" ":smoke-party:" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
more_runs() { python3 -c 'import sys; print(int(sys.argv[1]) > int(sys.argv[2]))' "$(note_status slack.runs)" "$copy_runs"; }
expect_poll "the run count sees the copy run the helper for a card" True more_runs
cp -- "$sandbox/Service.qml.kept" "$service_qml"
expect "a rescan restores the service" ok ipc shell rescanPlugins
expect_poll "the restored service is built" True record_exists vgs.notifications
expect_poll "the restored service made acme's emoji" 1 emoji_count T0ACME

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
all_rows() { ipc smoke modelRows vgs.notifications rows key | py_reply 'import json,sys; print(len(json.load(sys.stdin)))'; }
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
restored_sorted() { row_summaries restored | py_reply 'import json,sys; print(json.dumps(sorted(json.load(sys.stdin))))'; }
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
look_at() { read_notes look | py_reply 'import json,sys; v=json.load(sys.stdin)
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

# The Slack token rows: the service publishes whether the stub libsecret
# holds each listed workspace's token and the single-workspace one, never a
# token, and the Settings page draws a line per account with the command
# that stores it. The probe runs when the service starts, so each set of
# states is read after a disable and an enable. No state here makes the
# photo helper call Slack.
token_hint="One Slack app user token (xoxp-) per workspace with users:read and team:read, emoji:read optional for custom emoji. Create it at api.slack.com/apps, OAuth & Permissions, User Token Scopes."
token_row() { ipc smoke readInstance window vgs.settings plugins | py_reply 'import json,sys; r=[p for p in json.load(sys.stdin) if p["id"] == "vgs.notifications"][0]["status"]; print(json.dumps([[s["label"], s["report"], s["tone"], s["command"], s["value"]] for s in r]))'; }
drawn_token_row() { ipc smoke itemTexts window vgs.settings StatusRow | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }
# want_rows rows|drawn ITEMS: the manager row, or the texts the page draws,
# for ITEMS, `;`-separated `<account>,<state>[,served]` items, `served`
# naming a workspace the single-workspace token serves.
want_rows() {
  python3 - "$1" "$2" "$token_hint" <<'PY'
import json, sys
what, items, hint = sys.argv[1], sys.argv[2], sys.argv[3]
# A name equal to its domain, case folded, is drawn once.
labels = {"slack:T0ACME": "Acme Corp (acme)", "slack:T0GLOBEX": "Globex", "slack": "Single-workspace token"}
tones = {"present": "success", "absent": "warning", "locked": "info"}
words = {"present": "Present", "absent": "Absent", "locked": "Locked"}
def command(account):
    if account == "slack":
        return "secret-tool store --label='VGS notifications Slack token' service vgs-notifications account slack"
    team = account.split(":")[1]
    return "secret-tool store --label='VGS notifications Slack token %s' service vgs-notifications account %s" % (team, account)
rows, drawn = [], ["Slack tokens", hint]
for item in items.split(";"):
    account, state, *served = item.split(",")
    served_hint = "Served by the single-workspace token" if served else ""
    rows.append({"label": labels[account], "value": state, "hint": served_hint, "command": command(account), "tone": tones[state]})
    drawn += [labels[account], words[state]] + ([served_hint] if served else []) + [command(account)]
print(json.dumps([["Slack tokens", "reported", "", "", rows]]) if what == "rows" else json.dumps([drawn]))
PY
}
restart_notes() {
  expect "the notifications are disabled to read the tokens $1" ok ipc shell setPluginEnabled vgs.notifications false
  expect_poll "the service is gone before the tokens $1 are read" False record_exists vgs.notifications
  expect "the notifications are enabled to read the tokens $1" ok ipc shell setPluginEnabled vgs.notifications true
  expect_poll "the service is built to read the tokens $1" True record_exists vgs.notifications
}
expect "enabling the Settings plugin for the token rows is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect_poll "the Settings service is built for the token rows" True record_exists vgs.settings
expect "the notifications' Settings page opens" ok ipc shell summon window vgs.settings '{"plugin":"vgs.notifications"}'
first_items="slack:T0ACME,present;slack:T0GLOBEX,present,served;slack,present"
expect_poll "the page reads each workspace's token, globex served by the single-workspace one" "$(want_rows rows "$first_items")" token_row
expect_poll "the page draws a line per account with the command that stores it" "$(want_rows drawn "$first_items")" drawn_token_row
# Flips: label | the stub's states | the items the page reads.
flips=(
  "locked|slack:T0ACME locked;slack:T0GLOBEX locked;slack present|slack:T0ACME,locked;slack:T0GLOBEX,locked;slack,present"
  "absent-served|slack:T0ACME absent;slack:T0GLOBEX absent;slack present|slack:T0ACME,absent;slack:T0GLOBEX,present,served;slack,present"
  "all-absent|slack:T0ACME absent;slack:T0GLOBEX absent;slack absent|slack:T0ACME,absent;slack:T0GLOBEX,absent"
)
for flip in "${flips[@]}"; do
  IFS='|' read -r label states items <<<"$flip"
  slack_states "$states"
  restart_notes "$label"
  expect_poll "the page reads the tokens $label" "$(want_rows rows "$items")" token_row
  expect_poll "the page draws the tokens $label with the commands that store them" "$(want_rows drawn "$items")" drawn_token_row
done
# The lending record and the manager rows, read whole, hold the plugin's
# record and row and nowhere a token.
leaks() {
  local text count status=0
  text="$(ipc shell lent)" && text+="$(ipc smoke readInstance window vgs.settings plugins)" || return
  [[ $text == *'"vgs.notifications"'* && $text == *slackTokens* ]] || { echo "unread"; return; }
  count="$(grep -c -F -- 'xoxp-smoke' <<<"$text")" || status=$?
  [[ $status -le 1 ]] || return 1
  printf '%s\n' "$count"
}
expect "no status record and no manager row holds a token" 0 leaks
probe_failures() { log_lines 'notifications-token-status: probe=failed'; }
expect "the probe answered every state with the stub" 0 probe_failures
token_in_log() { log_lines 'xoxp-smoke'; }
expect "the shell's log holds no token" 0 token_in_log
expect "the Settings window closes after the token rows" ok ipc shell hide window vgs.settings
expect "disabling the Settings plugin after the token rows is allowed" ok ipc shell setPluginEnabled vgs.settings false
expect_poll "the Settings service is gone after the token rows" False record_exists vgs.settings
seed_slack_photos
slack_states "slack:T0ACME present;slack:T0GLOBEX absent;slack present"

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
