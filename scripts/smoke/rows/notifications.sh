# The notifications, vgs.notifications: a first-party service drawing its
# toasts through the `layers` capability. The harness starts it disabled;
# this row enables it and drives it with synthetic notifications on the
# sandbox's own session bus, never the user's, and reads back what it holds
# through the probe, its state file, the compositor and the lending record.
# No owner data reaches it: every notification here is made up. The row ends
# with the plugin disabled and every registration released.
set -euo pipefail
expected_errors+=('notifications: refused: status=slackTokens reason=retired')
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
lent_notes() { ipc shell lent | py_reply 'import json,sys; d=json.load(sys.stdin); print(json.dumps([[s for s in d["shortcuts"] if s.startswith("vgs.notifications")], [t for t in d["ipcTargets"] if t == "vgs.notifications"], [s for s in d["subscribers"] if s == "vgs.notifications"], [l["plugin"] for l in d["layers"] if l["plugin"] == "vgs.notifications"]]))'; }
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
edge_shaders_ok() { ipc smoke layerShaders vgs.notifications | py_reply 'import json,re,sys
edges = [(u, ok) for _, u, ok in json.load(sys.stdin) if u.endswith("/edgelight.frag.qsb")]
print(len(edges) >= 1 and all(re.search(r"/vgsh-sources-[0-9]+/[0-9a-f]+/shaders/edgelight\.frag\.qsb$", u) for u, _ in edges) and any(ok for _, ok in edges))'; }
render expect_poll "the edge light's shader compiled from the published revision" True edge_shaders_ok
key_of() { ipc smoke modelRows vgs.notifications rows key,summary | py_reply 'import json,sys; print(next((k for k, s in json.load(sys.stdin) if s == sys.argv[1]), "none"))' "$1"; }
clock_of() { read_notes clocks | py_reply 'import json,sys; c=json.load(sys.stdin).get(sys.argv[1]); print("none" if c is None else ("running" if c["since"] is not None else "paused") + " " + str(c["remaining"]))' "$1"; }
# rest_on_card SUMMARY: the pointer left on the centre of the card
# SUMMARY once the card reports it, through point_item.
rest_on_card() { point_item vgs:layer vgs.notifications NotificationCard summary "$1" >/dev/null; }
# click_pill TEXT: one click_item on the shown pill TEXT in the layer.
click_pill() { click_item vgs:layer vgs.notifications PillButton text "$1"; }
shown_pills() { ipc smoke layerItems vgs.notifications CardSlot summary,actions | py_reply 'import json,sys; print(json.dumps(next(([a["label"] for a in v["actions"]] for s, r, v in json.load(sys.stdin) if v["summary"] == sys.argv[1]), None)))' "$1"; }
has_row() { row_summaries "$1" | py_reply 'import json,sys; print(sys.argv[1] in json.load(sys.stdin))' "$2"; }
in_history() { history_summaries | py_reply 'import json,sys; print(sys.argv[1] in json.load(sys.stdin))' "$1"; }
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
toast_centred() { ipc smoke layerItems vgs.notifications NotificationCard summary | py_reply 'import json,sys; c=json.load(sys.stdin)
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

# The VGS hints (docs/architecture/notification-hints.md): a card keeps the
# hints the judge accepts, draws the hinted Lucide icon, and a click on an
# `open` card hands the open TUI the file through the stand-in terminal,
# whose presenter runs the plugin's script; with no EDITOR in the shell's
# environment the script hands the file to xdg-open, here a stand-in that
# records its argv, so no opener runs. A `none` card is only dismissed.
# While $hint_gate exists the stand-in holds the open run live, so a second
# card's open finds the one open TUI busy: that card stays and a core toast
# says why, and once the first run ends its click opens its own file.
terminal_stand_in
hint_file="$sandbox/hint-transcript.log"
hint_other="$sandbox/hint-other.log"
printf 'transcript\n' >"$hint_file"
printf 'other\n' >"$hint_other"
hint_opened="$sandbox/xdg-open-argv"
hint_gate="$sandbox/xdg-open-gate"
# The wait ends after 1200 polls, 60 s, whatever the gate does: a ceiling
# past the rows that hold it, so an interrupted run leaves no opener behind.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >%q\nn=0; while [[ -e %q && $n -lt 1200 ]]; do sleep 0.05; n=$((n + 1)); done\n' "$hint_opened" "$hint_gate" >"$shim/xdg-open"
chmod 755 "$shim/xdg-open"
hint_roles() { ipc smoke modelRows vgs.notifications rows summary,hintIcon,hintTone,hintOpen,hintClick | py_reply 'import json,sys; print(json.dumps(next((r[1:] for r in json.load(sys.stdin) if r[0] == sys.argv[1]), None)))' "$1"; }
hint_drawn() { ipc smoke layerItems vgs.notifications NotificationCard summary,mediaKind,showsSlot | py_reply 'import json,sys; print(json.dumps(next(([v["mediaKind"], v["showsSlot"]] for s, r, v in json.load(sys.stdin) if v["summary"] == sys.argv[1]), None)))' "$1"; }
opened_file() { if [[ -f $hint_opened ]]; then cat -- "$hint_opened"; else echo absent; fi; }
forget_record
notify smoke-app 0 "Hinted error" "Exit code 3" '[]' "{\"x-vgs-icon\": <\"circle-x\">, \"x-vgs-tone\": <\"danger\">, \"x-vgs-open\": <\"$hint_file\">, \"x-vgs-click\": <\"open\">}" 0 >/dev/null
expect_poll "a hinted notification keeps its hints" "[\"circle-x\", \"danger\", \"$hint_file\", \"open\"]" hint_roles "Hinted error"
expect_poll "its card's media slot draws the hinted icon in place of the application icon" '["glyph", true]' hint_drawn "Hinted error"
: >"$hint_gate"
expect "a click on the newest card is allowed" ok notes invoke-latest
expect_poll "the click hands the open TUI the hinted file" "$(words vgs.notifications/open tui/open.sh "$hint_file")" recorded_tail
expect_poll "the open TUI hands the file to xdg-open without an EDITOR" "$hint_file" opened_file
expect_poll "the clicked card leaves" none key_of "Hinted error"
open_toasts() { ipc shell lent | py_reply 'import json,sys; print(json.dumps([[t["title"], t["tone"]] for t in json.load(sys.stdin)["toasts"]["visible"] if t["plugin"] == "vgs.notifications"]))'; }
forget_record
notify smoke-app 0 "Hinted other" "Exit code 4" '[]' "{\"x-vgs-icon\": <\"circle-x\">, \"x-vgs-tone\": <\"danger\">, \"x-vgs-open\": <\"$hint_other\">, \"x-vgs-click\": <\"open\">}" 0 >/dev/null
expect_poll "a second hinted card shows while the first file is open" True has_row live "Hinted other"
expect "a click on it while the open TUI is busy is allowed" ok notes invoke-latest
expect_poll "the busy open shows why as a core toast" '[["Another file is open", "warning"]]' open_toasts
expect_log "the busy open is logged" 1 'notifications: open refused: tui=open reason=busy'
expected_errors+=('notifications: open refused: tui=open reason=busy')
expect "the busy open keeps its card" True has_row live "Hinted other"
expect "the busy open reaches no terminal" absent recorded
rm -f -- "$hint_gate"
expect_poll "the first open run ends" idle key_idle vgs.notifications/open
expect "a click on the kept card is allowed" ok notes invoke-latest
expect_poll "the kept card's click hands the open TUI its own file" "$(words vgs.notifications/open tui/open.sh "$hint_other")" recorded_tail
expect_poll "the kept card leaves once its file opens" none key_of "Hinted other"
wait_for "the open notice leaves after its five seconds" '[]' 9 open_toasts
forget_record
notify smoke-app 0 "Hinted start" "" '[]' '{"x-vgs-icon": <"play">, "x-vgs-tone": <"warning">, "x-vgs-click": <"none">}' 0 >/dev/null
expect_poll "a none card shows" '["play", "warning", "", "none"]' hint_roles "Hinted start"
expect "a click on the none card is allowed" ok notes invoke-latest
expect_poll "the none card is dismissed" none key_of "Hinted start"
sleep 1
expect "a click on a none card opens nothing" absent recorded
notify smoke-app 0 "Bad hints" "" '[]' '{"x-vgs-tone": <"red">, "x-vgs-click": <"open">}' 0 >/dev/null
expect_poll "refused hints leave no role" '["", "", "", ""]' hint_roles "Bad hints"
expected_errors+=('notifications: hints refused: app="smoke-app" names=x-vgs-tone,x-vgs-click')
# The stand-in stays, answering 1, so no later row reaches the host's opener.
printf '#!/usr/bin/env bash\nexit 1\n' >"$shim/xdg-open"

# A toast expires on its own; the pointer on it pauses its clock.
notify smoke-app 0 "Brief" "" '[]' '{"urgency": <byte 0>}' 0 >/dev/null
expect_poll "a low-urgency toast shows" True has_row live "Brief"
wait_for "the low-urgency toast expires after its five seconds" none 9 key_of Brief
notify smoke-app 0 "Held" "" '[]' '{"urgency": <byte 0>}' 0 >/dev/null
expect_poll "a second low-urgency toast shows" True has_row live "Held"
rest_on_card Held || fail "the pointer never rested on the held toast"
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
edge_active() { ipc smoke layerItems vgs.notifications EdgeLight active,lit | py_reply 'import json,sys; print(sorted(set(v["active"] for s, r, v in json.load(sys.stdin))))'; }
notify smoke-app 0 "Calm" "" '[]' '{}' 0 >/dev/null
expect_poll "a normal toast shows beside it" True has_row live Calm
expect_poll "only the critical toast's edge light is active" '[False, True]' edge_active

# Hover actions: the sender's own, then Dismiss; one runs on a click.
signals="$sandbox/notification-signals.log"
spawn "$signals" "${shell_env[@]}" stdbuf -oL gdbus monitor --session --dest org.freedesktop.Notifications
sleep 0.5
notify smoke-chat 0 "Actioned" "Pick one" '["default", "Open", "reply", "Reply"]' '{}' 0 >/dev/null
expect_poll "an actionable toast shows" True has_row live "Actioned"
rest_on_card Actioned || fail "the pointer never rested on the actionable toast"
expect_poll "the hover reveals the sender's actions and Dismiss" '["Open", "Reply", "Dismiss"]' shown_pills Actioned
sleep 0.5
# png_rgba(PATH), the one PNG reader of this row, for Python programs that
# start with it: (width, height, rows of RGBA bytes) for the 8-bit,
# non-interlaced RGBA files grabToImage saves, or a `png=<depth>/<type>/
# <interlace>` word for any other file. Standard library only.
png_rgba_py='import json, math, struct, sys, zlib
def png_rgba(path):
    data = open(path, "rb").read()
    pos, idat, head = 8, b"", None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if kind == b"IHDR": head = struct.unpack(">IIBBBBB", data[pos + 8:pos + 8 + n])
        elif kind == b"IDAT": idat += data[pos + 8:pos + 8 + n]
        pos += 12 + n
    iw, ih, depth, ctype, _, _, interlace = head
    if (depth, ctype, interlace) != (8, 6, 0): return "png=%d/%d/%d" % (depth, ctype, interlace)
    raw, stride, prev, rows = zlib.decompress(idat), iw * 4, bytearray(iw * 4), []
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
        rows.append(line); prev = line
    return iw, ih, rows
'
# The hover actions draw nothing past the capsule's rounded ends: the card
# grabbed alone, without the glass under it, is clear everywhere more than
# 1.5 px outside either end's curve, and drawn where the fade runs under
# no pill.
capsule_clear() { ipc smoke layerItems vgs.notifications NotificationCard summary | py_reply "$png_rgba_py"'
path, summary = sys.argv[1], sys.argv[2]
w, h = next((r[2], r[3]) for s, r, v in json.load(sys.stdin) if v["summary"] == summary)
image = png_rgba(path)
if isinstance(image, str): print(image); sys.exit()
iw, ih, rows = image
alpha = [line[3::4] for line in rows]
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
click_pill Reply || fail "the click on Reply failed"
invoked() { grep -c "ActionInvoked (uint32 [0-9]*, '$1')" -- "$signals" || true; }
expect_poll "the click runs the sender's action" 1 invoked reply
expect_poll "the acted-on toast leaves" none key_of Actioned
notify smoke-chat 0 "Clicked" "Open me" '["default", "Open"]' '{}' 0 >/dev/null
expect_poll "a toast with a default action shows" True has_row live "Clicked"
# The click lands left on the card, clear of the actions its hover shows.
click_item vgs:layer vgs.notifications NotificationCard summary Clicked 30 - || fail "the click on the card failed"
expect_poll "a click on the card runs its default action" 1 invoked default
expect_poll "the clicked toast leaves" none key_of Clicked

# Every action on a notification delivers the sender's action and brings
# the sender's window into view, through the compositor's reveal: a click
# on a toast, the default action's pill, another action's pill and the
# inbox row of a toast that expired, whose notification the service still
# holds. The sender is a toplevel helper of class smoke.sender and the
# notifications this row sends in its name; the signals log above records
# what reaches it. Quickshell 0.3.1 sends no ActivationToken, so the count
# of those stays 0. Another window takes the focus before each click, so
# no raise reading passes on a focus that was already there, and the
# Dismiss pill, which raises nothing, must leave it there. The controls:
# the inbox rows of a notification its sender closed and of one whose
# toast was dismissed deliver nothing, and still raise. Where the window
# is on the screen is the reveal row's (rows/compositor-reveal.sh).
sender_class=smoke.sender
sender_focused="[\"$sender_class\", \"Sender window\"]"
other_focused='["smoke.other", "Other window"]'
# sender_note SUMMARY URGENCY: a notification in the sender's name with a
# default action and a Reply, URGENCY a byte; prints its id.
sender_note() { notify "$sender_class" 0 "$1" "" '["default", "Open", "reply", "Reply"]' "{\"desktop-entry\": <\"$sender_class\">, \"urgency\": <byte $2>}" 0; }
# delivered ID ACTION: how many times ACTION reached notification ID.
delivered() { grep -c "ActionInvoked (uint32 $1, '$2')" -- "$signals" || true; }
closed_on_server() { grep -c "NotificationClosed (uint32 $1, " -- "$signals" || true; }
activation_tokens() { grep -c "ActivationToken" -- "$signals" || true; }
focus_other() {
  expect "a focus dispatch gives the other window the focus" ok hypr dispatch "hl.dsp.focus({ window = \"address:$other_window\" })"
  expect_poll "the other window has the focus before the click" "$other_focused" active_window
}
# open_card LABEL SUMMARY: the pointer resting on the card SUMMARY, left
# of its centre and clear of the actions its hover shows, through
# point_item; a check that the other window kept the focus under it; then
# a click there. act_on LABEL SUMMARY PILL: the same on the card's pill
# PILL, once the hover shows the sender's actions.
open_card() { # LABEL SUMMARY
  local at x y
  at="$(point_item vgs:layer vgs.notifications NotificationCard summary "$2" 30 -)" || { fail "$1: the pointer never rested on the card $2"; return; }
  read -r x y <<<"$at"
  expect "$1: the pointer on the card leaves the focus where it was" "$other_focused" active_window
  click "$x" "$y" || fail "$1: the click failed"
}
act_on() { # LABEL SUMMARY PILL
  local at x y
  rest_on_card "$2" || { fail "$1: the pointer never rested on the card $2"; return; }
  expect_poll "$1: the hover reveals the sender's actions" '["Open", "Reply", "Dismiss"]' shown_pills "$2"
  at="$(point_item vgs:layer vgs.notifications PillButton text "$3")" || { fail "$1: the pointer never rested on the $3 pill"; return; }
  read -r x y <<<"$at"
  expect "$1: the pointer on the card leaves the focus where it was" "$other_focused" active_window
  click "$x" "$y" || fail "$1: the click failed"
}
sender_pid=""
if open_toplevel "$sandbox/toplevel-sender.log" "$sender_class" "Sender window" && sender_pid="$toplevel_pid" && open_other "$sandbox/toplevel-notifications.log"; then
  other_window="$(other_address)"
  # Low urgency: these two expire while the toasts below are clicked.
  held_id="$(sender_note "Held for the inbox" 0)"
  gone_id="$(sender_note "Closed by its sender" 0)"
  focus_other
  toast_id="$(sender_note "Opened from its toast" 1)"
  expect_poll "the sender's toast shows" True has_row live "Opened from its toast"
  open_card "the toast" "Opened from its toast"
  expect_poll "a click on the toast delivers the default action once" 1 delivered "$toast_id" default
  expect_poll "a click on the toast raises the sender's window" "$sender_focused" active_window
  expect_poll "the opened toast leaves" none key_of "Opened from its toast"

  focus_other
  reply_id="$(sender_note "Answered with Reply" 1)"
  expect_poll "the toast to answer shows" True has_row live "Answered with Reply"
  act_on "the Reply pill" "Answered with Reply" Reply
  expect_poll "the Reply pill delivers the reply action" 1 delivered "$reply_id" reply
  expect_poll "the Reply pill raises the sender's window too" "$sender_focused" active_window
  expect "a Reply delivers no default action" 0 delivered "$reply_id" default
  expect_poll "the answered toast leaves" none key_of "Answered with Reply"

  # The Dismiss pill asks the core for no reveal: the service logs each
  # choice that asks for one, and the count stays.
  focus_other
  chose_before="$(log_lines "notifications: chose ")"
  dismissed_pill_id="$(sender_note "Dismissed by its pill" 1)"
  expect_poll "the toast to dismiss by its pill shows" True has_row live "Dismissed by its pill"
  act_on "the Dismiss pill" "Dismissed by its pill" Dismiss
  expect_poll "the Dismiss pill closes the notification on the server" 1 closed_on_server "$dismissed_pill_id"
  expect "the Dismiss pill asks for no reveal" "$chose_before" log_lines "notifications: chose "
  expect "the Dismiss pill leaves the focus on the other window" "$other_focused" active_window
  expect "the Dismiss pill delivers no action" 0 delivered "$dismissed_pill_id" default

  focus_other
  pill_id="$(sender_note "Opened from its pill" 1)"
  expect_poll "the toast to open by its pill shows" True has_row live "Opened from its pill"
  act_on "the Open pill" "Opened from its pill" Open
  expect_poll "the Open pill delivers the default action once" 1 delivered "$pill_id" default
  expect_poll "the Open pill raises the sender's window" "$sender_focused" active_window
  expect_poll "the toast opened by its pill leaves" none key_of "Opened from its pill"

  dismissed_id="$(sender_note "Dismissed from its toast" 1)"
  expect_poll "the toast to dismiss shows" True has_row live "Dismissed from its toast"
  expect "dismissing the newest toast is allowed" ok notes dismiss-latest
  expect_poll "a dismissal closes the notification on the server" 1 closed_on_server "$dismissed_id"

  # The pointer off the stack, so no card that moved under it keeps its
  # clock paused.
  hover "$((mon_w - 5))" "$((mon_h - 5))" || fail "moving the pointer off the toasts failed"
  wait_for "the toast held for the inbox expires" none 9 key_of "Held for the inbox"
  wait_for "the toast its sender closes expires" none 9 key_of "Closed by its sender"
  expect "an expiry closes nothing on the server" 0 closed_on_server "$held_id"
  close_note "$gone_id"
  expect_poll "the sender closed the other expired one" 1 closed_on_server "$gone_id"
  expect "the inbox opens on the expired toasts" ok notes inbox
  expect_poll "the expired toast is an inbox row" True has_row panel "Held for the inbox"

  focus_other
  open_card "the held inbox row" "Held for the inbox"
  expect_poll "a click on the inbox row of an expired toast delivers its default action once" 1 delivered "$held_id" default
  expect_poll "a click on that inbox row raises the sender's window" "$sender_focused" active_window
  expect_poll "the opened inbox row leaves" none key_of "Held for the inbox"

  focus_other
  open_card "the closed inbox row" "Closed by its sender"
  expect_poll "the inbox row of a notification its sender closed still raises the sender's window" "$sender_focused" active_window
  expect "that row delivers no action" 0 delivered "$gone_id" default
  expect_poll "the closed inbox row leaves" none key_of "Closed by its sender"

  focus_other
  open_card "the dismissed inbox row" "Dismissed from its toast"
  expect_poll "the inbox row of a dismissed toast still raises the sender's window" "$sender_focused" active_window
  expect "that row delivers no action" 0 delivered "$dismissed_id" default

  expect "the server sent the sender no activation token" 0 activation_tokens
  expect "the inbox closes after the open rows" ok notes close
  expect_poll "the inbox closed after the open rows" '""' read_notes panelMode
  close_other "the other window's helper exits 0 on SIGTERM"
  close_toplevel "$sender_pid" "the sender window's helper exits 0 on SIGTERM"
else
  fail "the sender's window and another window map for the open rows"
fi

# Images: a sender's file is copied for the stored entry; a missing one is
# skipped and the card draws no image.
python3 -c 'import base64,sys; open(sys.argv[1], "wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))' "$home/avatar.png"
notify smoke-chat 0 "Pictured" "" '[]' "{\"image-path\": <\"$home/avatar.png\">}" 30000 >/dev/null
expect_poll "a toast with an image shows" True has_row live "Pictured"
pictured_key="$(key_of Pictured)"
expect_poll "the sender's image was copied for the stored entry" True test_file "$note_images/$pictured_key-image"
expect_poll "the stored entry points at its copy" "\"file://$note_images/$pictured_key-image\"" stored_image "$pictured_key"
expected_errors+=('MediaSlot\.qml.*Cannot open: file://.*/missing\.png')
notify smoke-chat 0 "Unpictured" "" '[]' "{\"image-path\": <\"$home/missing.png\">}" 0 >/dev/null
expect_poll "a toast whose image file is missing shows" True has_row live "Unpictured"
shows_slot() { ipc smoke layerItems vgs.notifications NotificationCard summary,showsSlot | py_reply 'import json,sys; print(next((v["showsSlot"] for s, r, v in json.load(sys.stdin) if v["summary"] == sys.argv[1]), None))' "$1"; }
expect_poll "the card with a missing image draws no image" False shows_slot Unpictured
expect_poll "the card with its image draws it" True shows_slot Pictured
unpictured_key="$(key_of Unpictured)"
expect "no copy exists for the missing image" False test_file "$note_images/$unpictured_key-image"
expect_poll "the stored entry with a missing image keeps no image" '""' stored_image "$unpictured_key"

# A sender a NotificationLogic rule reads: Slack's titles, over the
# synthetic Slack. Its workspace list names acme, whose icon its cache
# holds, and globex, whose icon it does not.
card_value() { ipc smoke layerItems vgs.notifications NotificationCard "summary,$2" | py_reply 'import json,sys; print(next((json.dumps(v[sys.argv[2]]) for s, r, v in json.load(sys.stdin) if v["summary"] == sys.argv[1]), "none"))' "$1" "$2"; }
slack_icon="$home/.cache/vgs/notifications/workspaces/slack/T0ACME-0"
notify Slack 0 "[acme] from Ada Lovelace" "Did you see the notes?" '[]' '{"desktop-entry": <"slack">}' 30000 >/dev/null
expect_poll "a Slack direct message draws its workspace's icon" true card_value "[acme] from Ada Lovelace" showsBadge
expect "the icon is the copy out of Slack's cache" "$(file_url_json "$slack_icon")" card_value "[acme] from Ada Lovelace" workspaceIcon
expect "the copy is the cached image's body" "370 89504e470d0a1a0a" bash -c 'printf "%s %s\n" "$(stat -c %s -- "$1")" "$(od -An -tx1 -N8 -- "$1" | tr -d " ")"' _ "$slack_icon"
expect "the workspace's name gives way to its icon" '"from Ada Lovelace"' card_value "[acme] from Ada Lovelace" title
expect "a direct message shows its sender's face" '{"rule": "slack", "source": "desktop", "workspace": "acme", "title": "from Ada Lovelace", "faces": ["Ada Lovelace"], "more": 0}' card_value "[acme] from Ada Lovelace" enrichment
notify Slack 0 "[acme] in ada, grace, alan, edsger, barbara" "alan: lunch at noon?" '[]' '{"desktop-entry": <"slack">}' 30000 >/dev/null
expect_poll "a group message reads four people, its sender first, and the rest as more" '{"rule": "slack", "source": "desktop", "workspace": "acme", "title": "in ada, grace, alan, edsger, barbara", "faces": ["alan", "ada", "grace", "edsger"], "more": 1}' card_value "[acme] in ada, grace, alan, edsger, barbara" enrichment
expect "the group message's card draws its faces" true card_value "[acme] in ada, grace, alan, edsger, barbara" showsFaces
# The group draws three faces and a chip past four people: alan, ada and
# grace, whose photos acme's cache holds.
token_faces_loaded() { card_value "[acme] in ada, grace, alan, edsger, barbara" faceImages | py_reply 'import json,sys
t = sys.stdin.read()
images = json.loads(t)[:3] if t.startswith("[") else []
print(len(images) == 3 and all(str(i).startswith("file://") and "?v=" in str(i) for i in images) and len(set(images)) == 3)'; }
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
sender_photo() { card_value "$1" faceImages | py_reply 'import json,sys; v=json.load(sys.stdin); print(isinstance(v, list) and len(v) == 1 and str(v[0]).startswith("file://" + sys.argv[1] + "/"))' "$2"; }
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
# height=<px> slot=<px> pad=<px> column=<px>` for the card whose summary is
# SUMMARY on the first screen, `column` being the stack's text column the
# card reads; `absent` before the card exists and `no-text` while none of
# its text lines is visible. The predicate below is the contract and its
# controls.
text_space() {
  local cards texts bodies
  cards="$(ipc smoke layerItems vgs.notifications NotificationCard summary,slotLeft,pad,textColumn)" || return
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
print("top=%d bottom=%d left=%d right=%d height=%d slot=%d pad=%d column=%d" % (top - y, y + h - bottom, left - x, x + w - right, h, round(values["slotLeft"]), round(values["pad"]), round(values["textColumn"])))' "$1" "$cards" "$texts" "$bodies"
}
# Whether a text block's corner, SIDE in from a rounded end and EDGE in
# from the top or bottom of a container HEIGHT tall, keeps the clearance
# step, 4 (radius.clearance), inside the end's curve, less 1 px for the
# whole-pixel readings. The card and the header are far wider than tall,
# so each end is a half circle of radius HEIGHT / 2. Python source for the
# predicates below.
corner_clears_py='import math
def corner_clears(side, edge, height):
    c = height / 2
    return c - math.hypot(max(0, c - side), max(0, c - edge)) >= 4 - 1
'
# A card's text starts on the stack's text column, the same at both ends
# for text alone, and its corners keep the step inside the rounded end. A
# round slot stays at the pad, and the text's far end is on the column.
inset_contract_value() { # KIND CLAMPED MEASUREMENT
  python3 -c "$corner_clears_py"'
import re, sys
t = sys.stdin.read().strip()
m = re.fullmatch(r"top=(\d+) bottom=(\d+) left=(\d+) right=(\d+) height=(\d+) slot=(-?\d+) pad=(\d+) column=(\d+)", t)
if not m: print(t); sys.exit()
top, bottom, left, right, height, slot, pad, column = map(int, m.groups())
edge = min(top, bottom)
problems = []
if abs(top - bottom) > 1: problems.append("vertical")
if sys.argv[1] == "avatarless":
    if abs(left - column) > 1: problems.append("left")
    if abs(right - column) > 1: problems.append("right")
    if not corner_clears(min(left, right), edge, height): problems.append("curve")
if sys.argv[1] == "slot":
    if abs(slot - pad) > 1: problems.append("slot")
    if abs(right - column) > 1: problems.append("right")
    if not corner_clears(right, edge, height): problems.append("curve")
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
# The header's title and subtitle and its rightmost pill, as `left=<px>
# top=<px> height=<px> control=<px> centre=<px>`: the titles' inset and top
# in the header, and the pill's inset from the right end and its centre.
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
top = min(r[1] for r in lines) - y
right_button = max(buttons, key=lambda item: item[0][0] + item[0][2])[0]
control = x + w - (right_button[0] + right_button[2])
centre = control + right_button[3] / 2
print("left=%d top=%d height=%d control=%d centre=%.1f" % (left, top, h, control, centre))' "$headers" "$texts" "$pills"
}
# The header's title starts where a card's text alone does, its corner
# keeps the step inside the header's own rounded end, and its pills sit
# centred on that end. CARD is text_space's reading of a card without a
# slot, measured in the same run.
header_contract_value() { # CARD
  python3 -c "$corner_clears_py"'
import re, sys
t = sys.stdin.read().strip()
m = re.fullmatch(r"left=(\d+) top=(\d+) height=(\d+) control=(\d+) centre=([0-9.]+)", t)
if not m: print(t); sys.exit()
card = re.search(r"\bleft=(\d+) ", sys.argv[1])
if not card: print("card " + sys.argv[1]); sys.exit()
left, top, height, control, centre = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)), float(m.group(5))
problems = []
if abs(left - int(card.group(1))) > 1: problems.append("align")
if not corner_clears(left, top, height): problems.append("curve")
if abs(centre - height / 2) > 1: problems.append("control")
print("ok" if not problems else "violation " + ",".join(problems))' "$1"
}
checked_header() { # CARD_SUMMARY
  local card t
  card="$(text_space "$1")" || return
  t="$(header_space)" || return
  header_contract_value "$card" <<<"$t"
}
note_header_reading() {
  local t
  t="$(header_space)" || { fail "header: no reading"; return; }
  ok "header geometry measured: $t"
}
# Nothing of a card's glass, shadow or light draws outside its capsule:
# every pixel of the grabbed slot more than 1.5 px outside the capsule is
# no lighter than the black drop shadow, its colour times its alpha at most
# 3 of 255 in every channel, and the fill is drawn inside. SLOT and CARD
# are `x y w h` rectangles on one screen, the grab is the slot's. A sheen
# shorter than the card, rounded to its own smaller corner, read 9 and 10
# outside the two-line and the clamped card, and the shared shape reads 0:
# this row under scripts/qml-smoke.sh, and the same grabs of a sandbox
# shell at QT_SCALE_FACTOR=2, on host cachy on 2026-09-29.
glass_clear_value() { # PNG SLOT CARD
  python3 -c "$png_rgba_py"'
image = png_rgba(sys.argv[1])
if isinstance(image, str): print(image); sys.exit()
iw, ih, rows = image
sx, sy, sw, sh = map(float, sys.argv[2].split())
cx, cy, w, h = map(float, sys.argv[3].split())
s, r = iw / sw, min(w, h) / 2
def outside(x, y):
    qx, qy = abs(x - w / 2) - (w / 2 - r), abs(y - h / 2) - (h / 2 - r)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
light, at = 0, None
for py in range(ih):
    line = rows[py]
    for px in range(iw):
        x, y = (px + 0.5) / s + sx - cx, (py + 0.5) / s + sy - cy
        if outside(x, y) > 1.5:
            k = 4 * px
            v = max(line[k], line[k + 1], line[k + 2]) * line[k + 3] // 255
            if v > light: light, at = v, (round(x), round(y))
def alpha(x, y): return rows[min(ih - 1, int((y + cy - sy) * s))][4 * min(iw - 1, int((x + cx - sx) * s)) + 3]
inside = min(alpha(w / 2, 4), alpha(w / 2, h - 5))
print("clear" if light <= 3 and inside >= 128 else "violation light=%d at=%s inside=%d" % (light, at, inside))' "$1" "$2" "$3"
}
# The slot's and the card's rectangles, `x y w h` each, for the card whose
# summary is SUMMARY on the first screen, the one grabLayerItem grabs.
glass_rects() { # SUMMARY
  local slots cards
  slots="$(ipc smoke layerItems vgs.notifications CardSlot summary)" || return
  cards="$(ipc smoke layerItems vgs.notifications NotificationCard summary)" || return
  python3 -c 'import json,sys
pick = lambda items: next((r for s, r, v in json.loads(items) if v["summary"] == sys.argv[1]), None)
slot, card = pick(sys.argv[2]), pick(sys.argv[3])
print("absent" if slot is None or card is None else "%d %d %d %d|%d %d %d %d" % (*slot, *card))' "$1" "$slots" "$cards"
}
glass_clear() { # PNG SUMMARY
  local rects
  rects="$(glass_rects "$2")" || return
  [[ $rects == *"|"* ]] || { echo "$rects"; return; }
  glass_clear_value "$1" "${rects%%|*}" "${rects#*|}"
}
# The control: the same grab read against a capsule 6 px smaller all
# round, so the drawn glass lies outside it.
glass_clear_shrunk() { # PNG SUMMARY
  local rects card
  rects="$(glass_rects "$2")" || return
  [[ $rects == *"|"* ]] || { echo "$rects"; return; }
  read -r -a card <<<"${rects#*|}"
  glass_clear_value "$1" "${rects%%|*}" "$((card[0] + 6)) $((card[1] + 6)) $((card[2] - 12)) $((card[3] - 12))" | cut -d' ' -f1
}
grab_glass() { # LABEL SUMMARY PNG
  render expect "the $1 card's slot is grabbed" grabbing ipc smoke grabLayerItem vgs.notifications CardSlot summary "$2" "$3"
  render expect_poll "the grab of the $1 card's slot is saved" "saved $3" ipc smoke grabbed
}
notify smoke-app 0 "Even one" "" '[]' '{}' 0 >/dev/null
notify smoke-app 0 "Even two" "One line of body text" '[]' '{}' 0 >/dev/null
notify smoke-app 0 "Even multi" $'The first line of the body\nthe second line\nand the third' '[]' '{}' 0 >/dev/null
notify "Google Chrome" 0 "Weekly eStaff" $'calendar.google.com\n\n10:30am – 11:30am' '[]' '{}' 0 >/dev/null
notify "" 0 "New message in master-operator" $'app.slack.com\n\nada: the deployment note is in the channel.' '[]' '{}' 0 >/dev/null
notify smoke-app 0 "Even max" "$(printf 'A body long enough to run past every line the card may show. %.0s' $(seq 1 12))" '[]' '{}' 0 >/dev/null
notify smoke-chat 0 "Hover geometry" "Pick one" '["default", "Open", "reply", "Reply"]' '{}' 30000 >/dev/null
expect_poll "the hover geometry card shows" True has_row live "Hover geometry"
rest_on_card "Hover geometry" || fail "the pointer never rested on the hover geometry toast"
expect_poll "the hover geometry card shows actions" '["Open", "Reply", "Dismiss"]' shown_pills "Hover geometry"
expect "the inset predicate rejects text off the stack's column" "violation left,right" inset_contract_value avatarless "" "top=14 bottom=14 left=34 right=34 height=59 slot=-1 pad=14 column=20"
expect "the inset predicate rejects text under the rounded end" "violation curve" inset_contract_value avatarless "" "top=14 bottom=14 left=14 right=14 height=94 slot=-1 pad=14 column=14"
expect "the inset predicate rejects a round slot off the pad" "violation slot" inset_contract_value slot "" "top=14 bottom=14 left=66 right=20 height=68 slot=20 pad=14 column=20"
expect "the header predicate rejects a title off the cards' column" "violation align" header_contract_value "top=21 bottom=21 left=20 right=20 height=59 slot=-1 pad=14 column=20" <<<"left=12 top=8 height=48 control=10 centre=24.0"
expect "the header predicate rejects a title under its rounded end" "violation curve" header_contract_value "top=21 bottom=21 left=8 right=8 height=59 slot=-1 pad=14 column=8" <<<"left=8 top=8 height=48 control=10 centre=24.0"
expect_poll "a one-line card's text is on the stack's column and clears the rounded ends" ok checked_space "Even one" avatarless
expect_poll "a two-line card's text is on the stack's column and clears the rounded ends" ok checked_space "Even two" avatarless
expect_poll "a multiline card's text is on the stack's column and clears the rounded ends" ok checked_space "Even multi" avatarless
expect_poll "a browser calendar card's text is on the stack's column and clears the rounded ends" ok checked_space "Weekly eStaff" avatarless
expect_poll "a browser Slack card keeps its round slot at the pad and ends its text on the column" ok checked_space "New message in master-operator" slot
expect_poll "a card past its most lines stops at its maximum height with its text on the column" ok checked_space "Even max" avatarless clamped
expect_poll "a hovered action card keeps its text on the column while the pills show" ok checked_space "Hover geometry" avatarless
expect_poll "a card with an image keeps its round slot at the pad and ends its text on the column" ok checked_space Pictured slot
expect_poll "a Slack faces card keeps its round slot at the pad and ends its text on the column" ok checked_space "[acme] in ada, grace, alan, edsger, barbara" slot
for glass_card in "one-line:Even one" "two-line:Even two" "clamped:Even max"; do
  glass_png="$sandbox/glass-${glass_card%%:*}.png"
  grab_glass "${glass_card%%:*}" "${glass_card#*:}" "$glass_png"
  render expect "the ${glass_card%%:*} card's glass draws nothing outside its capsule" clear glass_clear "$glass_png" "${glass_card#*:}"
done
render expect "the glass predicate rejects glass drawn outside the capsule" violation glass_clear_shrunk "$sandbox/glass-clamped.png" "Even max"
expect "the inbox opens for header geometry" ok notes inbox
expect_poll "the inbox header title starts on a card's text column and clears its rounded end" ok checked_header "Even two"
# The Silence toggle takes a press over the pills' height, a strip above
# and below its 20 px track: a click 2 px above the track turns Silence on,
# and a click past the strip, 2 px above its top, changes nothing, so the
# strip is the look's `toggle.hitHeight` and no taller.
toggle_press() { # CHECKED DY: one click DY px above the shown toggle's top
  local rect x y
  rect="$(control_box vgs:layer vgs.notifications Toggle checked "$1")" && [[ $rect == \[* ]] || return 1
  read -r x y < <(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); print(int(r[0] + r[2] / 2), int(r[1]) - int(sys.argv[2]))' "$rect" "$2") || return 1
  hover "$((x - 1))" "$y" && click "$x" "$y"
}
# (toggle.hitHeight 28 - toggle.height 20) / 2 in vgs.notifications/Appearance.js.
toggle_strip=4
toggle_press false 2 || fail "the click in the Silence toggle's strip failed"
expect_poll "a click in the toggle's strip above its track turns Silence on" true read_notes silenced
expect "Silence turns off before the strip's edge" off notes silence off
toggle_press false "$((toggle_strip + 2))" || fail "the click past the Silence toggle's strip failed"
sleep 0.3
expect "a click past the strip leaves Silence off" false read_notes silenced
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

# Media tiers: a card of one line takes the compact media slot and every
# other card the regular one, and every card of a tier starts its text at
# the same x, whatever its media: an image, one person or a group. The
# people fit the slot, two to four as a cluster and seven as three faces
# and a chip. The fixture set runs on a clear screen. Summary-only cards
# reach the title measure the tier is judged from: a title that fits the
# compact text width stays compact, and one that wraps there or holds a
# line break is regular.
tier_image="$repo/themes/catalog/thumbnails/akane.jpg"
tier_fits_person="[acme] from Edsger Dijkstra"
tier_wraps_image="Tier wrapping title: a screenshot saved to the clipboard and to the pictures folder"
tier_wraps_person="[acme] from Barbara Liskov, Frances Allen and Margaret Hamilton at the design review"
tier_break_image=$'Tier break\nsecond line'
expect "clearing the screen before the media tiers is allowed" ok notes dismiss-all
expect_poll "the screen is clear before the media tiers" 0 note_status onScreen
tier_compact=("Tier image" "[acme] from Grace Hopper" "[acme] in edsger, barbara" "$tier_fits_person")
tier_regular=("$tier_wraps_image" "$tier_wraps_person" "$tier_break_image" "Tier image saved" "[acme] from Alan Turing" "[acme] in ada, grace" "[acme] in ada, grace, alan" "[acme] in ada, grace, alan, edsger" "[acme] in ada, grace, alan, edsger, barbara, ken, linus" "New message in tier-room")
notify smoke-shot 0 "Tier image" "" '[]' "{\"image-path\": <\"$tier_image\">}" 0 >/dev/null
notify Slack 0 "[acme] from Grace Hopper" "" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
notify Slack 0 "[acme] in edsger, barbara" "" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
notify smoke-shot 0 "Tier image saved" "Saved: screenshot.png" '[]' "{\"image-path\": <\"$tier_image\">}" 0 >/dev/null
notify Slack 0 "[acme] from Alan Turing" "lunch at noon?" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
for tier_group in "ada, grace" "ada, grace, alan" "ada, grace, alan, edsger" "ada, grace, alan, edsger, barbara, ken, linus"; do
  notify Slack 0 "[acme] in $tier_group" "ada: the notes are up" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
done
notify "" 0 "New message in tier-room" $'app.slack.com\n\nada: the notes are up' '[]' '{}' 0 >/dev/null
notify Slack 0 "$tier_fits_person" "" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
notify smoke-shot 0 "$tier_wraps_image" "" '[]' "{\"image-path\": <\"$tier_image\">}" 0 >/dev/null
notify Slack 0 "$tier_wraps_person" "" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null
notify smoke-shot 0 "$tier_break_image" "" '[]' "{\"image-path\": <\"$tier_image\">}" 0 >/dev/null
# One card's tier, where its text block starts and its slot's size, as
# `tier=<tier> left=<px> slot=<px>x<px>`: the block starts at its title,
# its body or the workspace icon before the title, whichever is leftmost.
# `absent` before the card and `no-text` or `no-slot` before its text or
# slot shows.
tier_reading() { # SUMMARY
  local cards texts badges slots
  cards="$(ipc smoke layerItems vgs.notifications NotificationCard summary,mediaTier)" || return
  texts="$(ipc smoke layerItems vgs.notifications QQuickText text,visible,objectName)" || return
  badges="$(ipc smoke layerItems vgs.notifications ClippingRectangle visible,objectName)" || return
  slots="$(ipc smoke layerItems vgs.notifications MediaSlot visible)" || return
  python3 -c 'import json,sys
cards, texts, badges, slots = (json.loads(a) for a in sys.argv[2:6])
card = next(((s, r, v) for s, r, v in cards if v["summary"] == sys.argv[1]), None)
if card is None: print("absent"); sys.exit()
screen, (x, y, w, h), values = card
inside = lambda r: x <= r[0] < x + w and y <= r[1] < y + h
lines = [r for s, r, v in texts if s == screen and v["visible"] and v["text"] and v["objectName"] in ("notificationTitleText", "notificationBodyText") and inside(r)]
lines += [r for s, r, v in badges if s == screen and v["visible"] and v["objectName"] == "notificationBadge" and inside(r)]
slot = next((r for s, r, v in slots if s == screen and v["visible"] and inside(r)), None)
if not lines: print("no-text"); sys.exit()
if slot is None: print("no-slot"); sys.exit()
print("tier=%s left=%d slot=%dx%d" % (values["mediaTier"], min(r[0] for r in lines) - x, slot[2], slot[3]))' "$1" "$cards" "$texts" "$badges" "$slots"
}
# Every reading is of TIER, and they share one text x and one slot size.
tier_contract_value() { # TIER READING...
  python3 -c 'import re,sys
tier, readings = sys.argv[1], sys.argv[2:]
parsed = [re.fullmatch(r"tier=(\w+) left=(\d+) slot=(\d+)x(\d+)", t) for t in readings]
bad = [t for t, m in zip(readings, parsed) if not m]
if bad: print(bad[0]); sys.exit()
problems = []
if any(m.group(1) != tier for m in parsed): problems.append("tier")
if max(int(m.group(2)) for m in parsed) - min(int(m.group(2)) for m in parsed) > 1: problems.append("x")
if len({(m.group(3), m.group(4)) for m in parsed}) != 1 or any(m.group(3) != m.group(4) for m in parsed): problems.append("slot")
print("ok" if not problems else "violation " + ",".join(problems))' "$@"
}
checked_tier() { # TIER SUMMARY...
  local tier="$1" summary t readings=()
  shift
  for summary in "$@"; do
    t="$(tier_reading "$summary")" || return
    readings+=("$t")
  done
  tier_contract_value "$tier" "${readings[@]}"
}
note_tier_reading() { # SUMMARY
  local t
  t="$(tier_reading "$1")" || { fail "$1: no tier reading"; return; }
  ok "media tier measured: $1: $t"
}
# The faces in one card's slot, as JSON: the slot's rectangle and each
# visible face's rectangle and label, the label the chip's "+N" or the
# initials; `absent` before the card or its slot shows.
group_reading() { # SUMMARY
  local cards slots faces
  cards="$(ipc smoke layerItems vgs.notifications NotificationCard summary)" || return
  slots="$(ipc smoke layerItems vgs.notifications MediaSlot visible)" || return
  faces="$(ipc smoke layerItems vgs.notifications AvatarFace visible,initials)" || return
  python3 -c 'import json,sys
cards, slots, faces = (json.loads(a) for a in sys.argv[2:5])
card = next(((s, r) for s, r, v in cards if v["summary"] == sys.argv[1]), None)
if card is None: print("absent"); sys.exit()
screen, (x, y, w, h) = card
inside = lambda r: x <= r[0] < x + w and y <= r[1] < y + h
slot = next((r for s, r, v in slots if s == screen and v["visible"] and inside(r)), None)
if slot is None: print("absent"); sys.exit()
print(json.dumps({"slot": slot, "faces": [[r, v["initials"]] for s, r, v in faces if s == screen and v["visible"] and inside(r)]}))' "$1" "$cards" "$slots" "$faces"
}
# PLACES faces, each inside the slot, the last labelled CHIP when given.
group_fit_value() { # PLACES CHIP READING
  python3 -c 'import json,sys
t = sys.argv[3]
if not t.startswith("{"): print(t); sys.exit()
reading = json.loads(t)
sx, sy, sw, sh = reading["slot"]
faces = reading["faces"]
problems = []
if len(faces) != int(sys.argv[1]): problems.append("count")
if any(r[0] < sx - 1 or r[1] < sy - 1 or r[0] + r[2] > sx + sw + 1 or r[1] + r[3] > sy + sh + 1 for r, _ in faces): problems.append("outside")
if sys.argv[2] and (not faces or faces[-1][1] != sys.argv[2]): problems.append("chip")
print("ok" if not problems else "violation " + ",".join(problems))' "$@"
}
checked_group() { # PLACES CHIP SUMMARY
  local t
  t="$(group_reading "$3")" || return
  group_fit_value "$1" "$2" "$t"
}
expect "the tier predicate rejects two text starts in one tier" "violation x" tier_contract_value compact "tier=compact left=54 slot=28x28" "tier=compact left=66 slot=28x28"
expect "the tier predicate rejects a card of another tier" "violation tier" tier_contract_value compact "tier=compact left=54 slot=28x28" "tier=regular left=54 slot=28x28"
expect "the group predicate rejects a face outside the slot" "violation outside" group_fit_value 2 "" '{"slot": [0, 0, 40, 40], "faces": [[[0, 0, 24, 24], "A"], [[30, 16, 24, 24], "B"]]}'
expect "the group predicate rejects a missing face" "violation count" group_fit_value 3 "" '{"slot": [0, 0, 40, 40], "faces": [[[0, 0, 24, 24], "A"], [[16, 16, 24, 24], "B"]]}'
expect "the group predicate rejects a chip that counts wrong" "violation chip" group_fit_value 4 "+4" '{"slot": [0, 0, 40, 40], "faces": [[[0, 0, 24, 24], "A"], [[16, 0, 24, 24], "B"], [[16, 16, 24, 24], "C"], [[0, 16, 24, 24], "+3"]]}'
# A card's tier and slot size alone, from tier_reading.
tier_and_slot() { # SUMMARY
  local t
  t="$(tier_reading "$1")" || return
  [[ $t == tier=* ]] || { echo "$t"; return; }
  echo "${t%% left=*} slot=${t##* slot=}"
}
expect_poll "a summary-only person card whose title fits the compact width is compact" "tier=compact slot=28x28" tier_and_slot "$tier_fits_person"
expect_poll "a summary-only image card whose title wraps at the compact width is regular" "tier=regular slot=40x40" tier_and_slot "$tier_wraps_image"
expect_poll "a summary-only person card whose title wraps at the compact width is regular" "tier=regular slot=40x40" tier_and_slot "$tier_wraps_person"
expect_poll "a summary-only image card whose short title holds a line break is regular" "tier=regular slot=40x40" tier_and_slot "$tier_break_image"
expect_poll "every compact card starts its text at one x, whatever its media" ok checked_tier compact "${tier_compact[@]}"
expect_poll "every regular card starts its text at one x, whatever its media" ok checked_tier regular "${tier_regular[@]}"
expect_poll "two people fit the slot on its diagonal" ok checked_group 2 "" "[acme] in ada, grace"
expect_poll "three people fit the slot as a triangle" ok checked_group 3 "" "[acme] in ada, grace, alan"
expect_poll "four people fit the slot as a 2 by 2 cluster" ok checked_group 4 "" "[acme] in ada, grace, alan, edsger"
expect_poll "seven people fit the slot as three faces and a +4 chip" ok checked_group 4 "+4" "[acme] in ada, grace, alan, edsger, barbara, ken, linus"
for tier_summary in "${tier_compact[@]}" "${tier_regular[@]}"; do note_tier_reading "$tier_summary"; done
# A face's image is cut to a circle: in a slot grab, the point a tenth of
# the side in from the top left, outside the slot's inscribed circle and
# inside a corner radius under a fifth of the side, is clear, and the
# middle shows the image, RGB when given. The unit runner draws no shader
# effect, so the cut is read here. Grace's photo in acme's cache is
# 150,70,180; the control reads a thumbnail, cropped to a square with a
# small radius, whose corner point is drawn.
face_cut_value() { # PNG [R,G,B]
  python3 -c "$png_rgba_py"'
image = png_rgba(sys.argv[1])
if isinstance(image, str): print(image); sys.exit()
iw, ih, rows = image
def px(fx, fy):
    x, y = min(iw - 1, int(fx * iw)), min(ih - 1, int(fy * ih))
    return rows[y][4 * x:4 * x + 4]
problems = []
if px(0.1, 0.1)[3] > 25: problems.append("cut")
if len(sys.argv) > 2 and sys.argv[2]:
    want, centre = [int(v) for v in sys.argv[2].split(",")], px(0.5, 0.5)
    if centre[3] < 230 or any(abs(c - w) > 12 for c, w in zip(centre[:3], want)): problems.append("image")
print("ok" if not problems else "violation " + ",".join(problems))' "$@"
}
# The slot grabbed again on each poll, since the photo loads after the
# card shows; the grab itself lands a frame later.
grabbed_face_cut() { # PROPERTY VALUE PNG [R,G,B]
  local state
  [[ $(ipc smoke grabLayerItem vgs.notifications MediaSlot "$1" "$2" "$3") == grabbing ]] || { echo ungrabbed; return; }
  for _ in $(seq 1 20); do
    state="$(ipc smoke grabbed)" || return
    [[ $state == "saved $3" ]] && { face_cut_value "$3" "${4:-}"; return; }
    sleep 0.1
  done
  echo "grab=$state"
}
face_png="$sandbox/face-grace.png"
thumb_png="$sandbox/thumbnail-slot.png"
render expect_poll "a face's photo shows cut to a circle" ok grabbed_face_cut names "Grace Hopper" "$face_png" 150,70,180
render expect_poll "the cut predicate rejects a square corner" "violation cut" grabbed_face_cut kind thumbnail "$thumb_png"

# Custom emoji. The synthetic cache holds acme's :smoke-party:, which the
# helper made into a normalized image at start. A card in acme draws it
# inline, in the body's text at the body's height and at full strength;
# a shortcode acme lacks, and a card in globex, keep the text. The cards
# read the emoji from memory and start no helper run; a copy of the
# service that asks for a run from each card's lookup makes the same
# notifications count runs, so the count reads the rule, not a quiet
# helper.
emoji_count() { note_status slack.emoji.teams | py_reply 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], 0))' "$1"; }
expect_poll "the helper made acme's custom emoji at start" 1 emoji_count T0ACME
party_url() { python3 -c 'import json,sys; h=json.load(open(sys.argv[1] + "/T0ACME/emoji.json"))["map"]["smoke-party"]; print("file://%s/T0ACME/emoji/%s.png?v=%s" % (sys.argv[1], h, h))' "$slack_photos"; }
party="$(party_url)"
expect "the emoji image is a 48 px PNG" "PNG 48 48" python3 -c 'import struct,sys; b=open(sys.argv[1].split("?")[0][7:], "rb").read(24); print(b[1:4].decode(), *struct.unpack(">II", b[16:24]))' "$party"
# The drawn body texts that name an image, and the ImageText items' fade.
drawn_images() { ipc smoke layerItems vgs.notifications QQuickText text,visible | py_reply 'import json,sys; print(sum(1 for s, r, v in json.load(sys.stdin) if v["visible"] and ("<img src=\"" + sys.argv[1] + "\"") in v["text"]))' "$1"; }
body_fade() { ipc smoke layerItems vgs.notifications ImageText opacity,color | py_reply 'import json,sys; print(json.dumps(sorted(set((v["opacity"], str(v["color"])) for s, r, v in json.load(sys.stdin)))))'; }
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
# call to forty such rows naming theirs. The probe counts matching visible
# text items, one reading per IPC round trip. The budgets and their runs
# are in scripts/qml-smoke.sh's header.
emoji_body="ada: :smoke-party: ship :smoke-party: it :smoke-party: now :smoke-party: team, and a tail long enough to run onto a second line :smoke-party: here"
emoji_texts() { ipc smoke layerItemsWith vgs.notifications QQuickText text '<img src='; }
latency_bound_ms=5000
# latency_since LABEL START WANT CMD...: sets latency_ms to the
# milliseconds from START until CMD prints a count of WANT or more, or to
# -1 after latency_bound_ms. A read that fails or answers a state word
# counts nothing; a traceback fails LABEL at once, as harness.sh's
# reader_stderr says, and leaves -1. It runs in the row's shell, so the
# failure counts.
latency_since() {
  local label="$1" start="$2" want="$3" got=0 last=0 err="$sandbox/reader-$BASHPID.stderr" ipc_start_line=0 ipc_lines=""
  shift 3
  latency_ms=-1
  [[ -f $sandbox/ipc.log ]] && ipc_start_line="$(wc -l <"$sandbox/ipc.log")"
  while (( $(date +%s%3N) - start < latency_bound_ms )); do
    got="$("$@" 2>"$err")" || :
    reader_stderr "$label" "$err" || return 0
    last="$got"
    [[ $got =~ ^[0-9]+$ ]] || got=0
    if (( got >= want )); then latency_ms=$(( $(date +%s%3N) - start )); return 0; fi
  done
  printf '        %s: no reading of %s within %s ms; the last reading was %q\n' "$label" "$want" "$latency_bound_ms" "$last"
  if [[ -f $sandbox/ipc.log ]]; then
    ipc_lines="$(awk -v start="$ipc_start_line" 'NR > start && /^ipc: / { line = $0 } END { if (line != "") print line }' "$sandbox/ipc.log")"
    [[ -z $ipc_lines ]] || printf '        %s\n' "$ipc_lines"
  fi
}
ipc_cut_stand_in() { # PATH FAIL_COUNT|always THEN_REPLY
  local path="$1" fail_count="$2" reply="$3" counter_q fail_q reply_q
  printf -v counter_q '%q' "$path.count"
  printf -v fail_q '%q' "$fail_count"
  printf -v reply_q '%q' "$reply"
  cat >"$path" <<SH
#!/usr/bin/env bash
set -euo pipefail
counter=$counter_q
fail_count=$fail_q
reply=$reply_q
count=0
[[ -f \$counter ]] && count="\$(cat -- "\$counter")"
count=\$((count + 1))
printf '%s\n' "\$count" >"\$counter"
if [[ \$fail_count == always || \$count -le \$fail_count ]]; then
  printf '\033[31m ERROR\033[97m quickshell.ipc\033[0m: Socket Error QLocalSocket::PeerClosedError\n'
  printf '\033[31m ERROR\033[97m quickshell.ipc\033[0m: Error occurred while waiting for response.\n'
else
  printf '%s\n' "\$reply"
fi
SH
  chmod 755 "$1"
}
ipc_cut_retry_control() {
  local fake="$sandbox/vgsh-ipc-retry" start
  ipc_cut_stand_in "$fake" 1 1
  (ipc() { ipc_via "$fake" "$@"; }; latency_bound_ms=2000; latency_since "control retry" "$(date +%s%3N)" 1 emoji_texts >/dev/null; [[ $latency_ms =~ ^[0-9]+$ ]] && echo recovered || echo "latency=$latency_ms")
}
expect "control: a cut IPC reply is retried by the latency reader" recovered ipc_cut_retry_control
ipc_cut_failure_control() {
  local fake="$sandbox/vgsh-ipc-cut" out
  ipc_cut_stand_in "$fake" always 1
  out="$(ipc() { ipc_via "$fake" "$@"; }; latency_bound_ms=250; latency_since "control cut" "$(date +%s%3N)" 1 emoji_texts)"
  if [[ $out == *ipc-failed* && $out == *"Error occurred while waiting for response."* ]]; then echo named; else printf '%s\n' "$out"; fi
}
expect "control: a lasting cut IPC reply names the raw client line" named ipc_cut_failure_control
ipc_page_control() {
  local fake="$sandbox/vgsh-page-ok"
  cat >"$fake" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == ipc && ${2:-} == call && ${3:-} == smoke && ${4:-} == page ]]; then
  case "${6:-}" in
    0) echo '2 {"a":' ;;
    1) echo '2 1}' ;;
    *) echo "refused: page=${6:-} pages=2" ;;
  esac
else
  echo paged=7
fi
SH
  chmod 755 "$fake"
  ipc_via "$fake" smoke anything
}
expect "control: ipc_via reassembles a paged probe reply" '{"a":1}' ipc_page_control
ipc_page_failure_control() {
  local fake="$sandbox/vgsh-page-fails"
  cat >"$fake" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == ipc && ${2:-} == call && ${3:-} == smoke && ${4:-} == page ]]; then
  case "${6:-}" in
    0) echo '2 {"a":' ;;
    1) echo 'Function not found.' ;;
  esac
else
  echo paged=7
fi
SH
  chmod 755 "$fake"
  local got
  got="$(ipc_via "$fake" smoke anything || true)"
  printf '%s\n' "$got"
}
expect "control: a failed page yields ipc-failed, not a partial document" ipc-failed ipc_page_failure_control
ipc_oversize_control() {
  local fake="$sandbox/vgsh-oversize" chars=$((ipc_reply_chars + 1))
  cat >"$fake" <<SH
#!/usr/bin/env bash
head -c $chars /dev/zero | tr '\\0' x
echo
SH
  chmod 755 "$fake"
  (failures=0; ipc_oversize_log="$sandbox/ipc-oversize-control.log"; rm -f -- "$ipc_oversize_log"; ipc_via "$fake" product target >/dev/null; ipc_oversize_check control >/dev/null; [[ $failures -eq 1 && ! -s $ipc_oversize_log ]] && echo failed-once || echo "failures=$failures")
}
expect "control: an unpaged oversize reply fails its row once" failed-once ipc_oversize_control
expect "the smoke probe and harness agree on the page size" "$ipc_reply_chars" ipc smoke pageChars
# The control: a latency reader that raises fails its reading once.
latency_traceback_control() { (failures=0 behaviour_failures=0; latency_since "the planted latency reader" "$(date +%s%3N)" 1 python3 -c 'raise ValueError("planted")' >"$sandbox/latency-traceback-control.log"; echo "$failures $latency_ms"); }
expect "control: a latency reader that raises fails once and reads -1" "1 -1" latency_traceback_control
expect "control: the failed latency reading names the reader's traceback" 1 grep -c -F -- "the planted latency reader: the reader raised a Python traceback" "$sandbox/latency-traceback-control.log"
notify_now() { "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.Notify Slack 0 "" "$1" "$emoji_body" '[]' '{"desktop-entry": <"slack">}' 0 >/dev/null; }
within_budget() { python3 -c 'import sys; print(0 <= int(sys.argv[1]) <= int(sys.argv[2]))' "$1" "$2"; }
start="$(date +%s%3N)"
notify_now "[acme] in latency"
latency_since "the emoji toast latency reader" "$start" "$monitors" emoji_texts
emoji_toast_ms="$latency_ms"
printf '        latency_emoji_toast_ms=%s budget_ms=%s\n' "$emoji_toast_ms" "$emoji_toast_budget_ms"
expect "a toast with custom emoji names its images within its budget" True within_budget "$emoji_toast_ms" "$emoji_toast_budget_ms"
expect "dismissing the latency toast is allowed" ok notes dismiss-all
expect "Silence turns on for the inbox latency" on notes silence on
expect "clearing the history before the inbox latency is allowed" ok notes clear-history
for i in $(seq 1 40); do notify_now "[acme] in inbox $i"; done
expect_poll "the forty emoji notifications are in the history" 40 note_status history
start="$(date +%s%3N)"
notes history >/dev/null
latency_since "the emoji inbox latency reader" "$start" "$((40 * monitors))" emoji_texts
emoji_inbox_ms="$latency_ms"
printf '        latency_emoji_inbox_ms=%s budget_ms=%s\n' "$emoji_inbox_ms" "$emoji_inbox_budget_ms"
expect "an inbox of forty cards with custom emoji names their images within its budget" True within_budget "$emoji_inbox_ms" "$emoji_inbox_budget_ms"
raw_emoji_layer_items() { "${shell_env[@]}" "$repo/bin/vgsh" ipc call smoke layerItems vgs.notifications QQuickText text,visible 2>>"$sandbox/ipc.log" | tail -n 1; }
raw_paged() { local r; r="$(raw_emoji_layer_items)" || return; [[ $r =~ ^paged=[0-9]+$ ]] && echo paged || printf '%s\n' "$r"; }
emoji_layer_images() { ipc smoke layerItems vgs.notifications QQuickText text,visible | py_reply 'import json,sys; print(sum(1 for s, r, v in json.load(sys.stdin) if v["visible"] and "<img src=" in v["text"]))'; }
expect "the raw emoji inbox text reply is paged" paged raw_paged
emoji_layer_images_hold_all() { [[ $(emoji_layer_images) -ge $((40 * monitors)) ]] && echo True || echo False; }
expect "the paged emoji inbox text reply reassembles whole through ipc" True emoji_layer_images_hold_all
expect "the probe counts exactly the forty visible emoji inbox texts" "$((40 * monitors))" emoji_texts
# The history's slim scroll bar shows while forty cards overflow the
# screen and hides on a history that fits. The control for its rule is the
# SlimScrollBar mutation "a slim bar shows on content that fits"
# (tst_slimscrollbar.qml).
note_scroll_bars() { ipc smoke layerItems vgs.notifications SlimScrollBar visible | py_reply 'import json,sys; print(json.dumps(sorted(set(v["visible"] for s, r, v in json.load(sys.stdin)))))'; }
expect_poll "the forty-card history shows its scroll bar" '[true]' note_scroll_bars
expect "the emoji inbox closes" ok notes close
expect_poll "the emoji inbox closed" '""' read_notes panelMode
expect "clearing the emoji history is allowed" ok notes clear-history
notify_now "[acme] a history that fits"
expect_poll "the one-card history holds its card" 1 note_status history
notes history >/dev/null
expect_poll "a history that fits shows no scroll bar" '[false]' note_scroll_bars
expect "the one-card history closes" ok notes close
expect_poll "the one-card history closed" '""' read_notes panelMode
expect "clearing the one-card history is allowed" ok notes clear-history
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
input_all() { ipc smoke layerItems vgs.notifications Stack inputAll | py_reply 'import json,sys; print(sorted(set(v["inputAll"] for s, r, v in json.load(sys.stdin))))'; }
expect_poll "the stack takes the whole screen's presses while a panel is open" '[True]' input_all
notify smoke-app 0 "While open" "" '[]' '{"urgency": <byte 0>}' 0 >/dev/null
expect_poll "a toast arriving with the panel open shows" True has_row live "While open"
expect_poll "its clock does not run while the panel is open" paused clock_state "While open"
click_pill "Mark read" || fail "the click on Mark read failed"
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
click_pill "Clear history" || fail "the click on Clear history failed"
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
# A sender that replaces a silenced notification, held for the history,
# changes its summary and its body in one update: one new history entry
# records it, and the service holds one reference for it in place of the
# old. The notification carries no image file, so its copies are made at
# once and each property signal would find it held again under its new
# key; handling each signal would record the replacement twice.
quiet_id="$(notify smoke-app 0 "Quiet original" "The first body" '[]' '{}' 0)"
expect_poll "the notification to replace goes into the history" '"Quiet original"' state_at history.0.summary
held_before="$(note_status held)"
count_before="$(history_count)"
notify smoke-app "$quiet_id" "Quiet replaced" "The second body" '[]' '{}' 0 >/dev/null
entries_of() { note_state_py 'import json,sys; print(sum(1 for e in json.load(open(sys.argv[1]))["history"] if e["summary"] == sys.argv[2]))' "$1"; }
expect_poll "the replacement is recorded" '"Quiet replaced"' state_at history.0.summary
expect "one history entry records the replacement, not one per changed property" 1 entries_of "Quiet replaced"
expect "the history grew by that one entry" "$((count_before + 1))" history_count
expect "the replacement's body is the new one" '"The second body"' state_at history.0.body
expect "one reference is held for it in place of the old" "$held_before" note_status held
expect "the inbox opens under Silence" ok notes inbox
notify smoke-app 0 "Quiet while open" "" '[]' '{}' 0 >/dev/null
expect_poll "a silenced notification joins the open inbox" True has_row panel "Quiet while open"
notify smoke-chat 0 "Quiet pictured" "" '[]' "{\"image-path\": <\"$home/avatar.png\">}" 0 >/dev/null
expect_poll "a silenced notification with an image joins the open inbox" True has_row panel "Quiet pictured"
expect_poll "its row draws the copy, made before the row showed" True shows_slot "Quiet pictured"
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
# The notifications held for the history are bounded by it: none outlives
# its entry, so at most the kept hundred and the toasts on screen are held.
held_within_history() { notes status | py_reply 'import json,sys; d=json.load(sys.stdin); print(d["held"] <= d["history"] + d["onScreen"] and d["held"] >= d["history"])'; }
expect_poll "the held notifications are the kept hundred and the toasts on screen at most" True held_within_history
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
rest_on_card Survivor || fail "the pointer never rested on the restored toast"
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
everywhere() { ipc smoke layerItems vgs.notifications NotificationCard summary | py_reply 'import json,sys; print(sum(1 for s, r, v in json.load(sys.stdin) if v["summary"] == "Everywhere"))'; }
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
edge_values() { ipc smoke layerItems vgs.notifications EdgeLight "$1" | py_reply 'import json,sys; print(json.dumps(sorted(set(json.dumps(v[sys.argv[1]]) for s, r, v in json.load(sys.stdin)))))' "$1"; }
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
notification_holder() { lent holders.notifications | py_reply 'import json,sys; print("vgs.notifications" in (json.load(sys.stdin) or []))'; }
expect "the disabled plugin holds no notifications capability" False notification_holder
orphans() {
  python3 -c 'import json,os,sys
d = json.load(open(sys.argv[1]))
owned = {os.path.basename(e[r][7:]) for e in d["live"] + d["history"] for r in ("image", "appIcon") if e[r].startswith("file://")}
print(sorted(set(os.listdir(sys.argv[2])) - owned))' "$note_state" "$note_images"
}
expect "the images directory holds only what the stored entries own" '[]' orphans
