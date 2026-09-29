#!/usr/bin/env bash
# Capture the shell's surfaces in the nested Hyprland sandbox with grim.
#
# Usage: scripts/sandbox-shots.sh [--out DIR] [--rev REV] [--modes LIST]
#                                 [--scale N] [--timeout SECONDS] [--keep]
#                                 [SCENE...]
#
# The sandbox is the smoke's own (scripts/smoke/harness.sh): its own HOME,
# runtime dir, buses and nested compositor, with the shell started inside
# it. grim is pointed at the nested compositor's socket alone
# (scripts/smoke/shot.sh refuses the host socket), so nothing is captured
# or started on the live desktop. It needs the smoke's prerequisites,
# WAYLAND_DISPLAY and XDG_RUNTIME_DIR included, plus grim.
#
# SCENE is gallery, settings, manager, launcher or notifications. The
# default is gallery, the plugin manager's scene, the launcher and the
# notifications, or gallery and the manager's scene with --rev; the
# manager's scene is `settings` for a tree that ships vgs.settings and
# `manager`, the bar's manager panel, for one that ships the bar's manager
# built-in. A scene the tree does not ship is refused as
# `sandbox-shots: refused: scene=<scene> tree=<rev or checkout>`. --modes is a comma list of dark
# and light, dark by default with --rev and both otherwise: dark is the
# defaults (theme `vgs`), light is this checkout's themes/light package.
# --rev REV runs that revision's shell, bin, config and themes (git archive),
# with the runtime helpers a revision before bin/lib kept under scripts/,
# under this checkout's harness and probe, for a before shot; the plugin
# fixtures a scene installs are that revision's, which its judge accepts.
# --scale is 1, the default, or 2: at 2 the harness holds the nested
# output at double its mode and scale 2 before the shell starts
# (shell_output_scale in scripts/smoke/harness.sh), so the layout keeps its
# logical size and the shell draws each PNG in device pixels. Each shot at
# scale 2 first checks that the output still reads that mode and scale,
# since a host resize or a configuration reload resets them, and fails
# when it does not. Another value is refused as
# `sandbox-shots: refused: scale=<value>`.
#
# PNGs go to DIR, which must lie under this checkout's tmp/; the default is
# tmp/sandbox-shots/<UTC time>[-REV][-x2]. shots.tsv beside them lists each shot
# with the sha256 of its file and how it was proved current (shot.sh).
#
# Exit 0 when every shot was taken. Exit 77 when a prerequisite is missing
# or when every failure was a grim that got no frame from the nested
# compositor (nested-window=not-drawn: enable render_unfocused for class
# aquamarine in the host Hyprland window rules, or keep the window visible).
# Exit 1 when any other step or shot failed.
set -euo pipefail

timeout_s=60
keep=false
out=""
rev=""
modes=""
scale=1
scenes=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --rev) rev="$2"; shift 2 ;;
    --modes) modes="$2"; shift 2 ;;
    --scale) scale="$2"; shift 2 ;;
    --timeout) timeout_s="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    gallery|settings|manager|launcher|notifications) scenes+=("$1"); shift ;;
    *) printf 'sandbox-shots: refused: argument=%s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -n $modes ]] || { if [[ -n $rev ]]; then modes=dark; else modes=dark,light; fi; }
IFS=, read -r -a mode_list <<<"$modes"
for mode in "${mode_list[@]}"; do
  [[ $mode == dark || $mode == light ]] || { printf 'sandbox-shots: refused: mode=%s\n' "$mode" >&2; exit 2; }
done
[[ $scale == 1 || $scale == 2 ]] || { printf 'sandbox-shots: refused: scale=%s\n' "$scale" >&2; exit 2; }

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
checkout="$repo"
if ! command -v grim >/dev/null 2>&1; then
  printf 'sandbox-shots: status=not-measured missing=grim\n'
  exit 77
fi
source "$checkout/scripts/smoke/shot.sh"
source "$checkout/scripts/smoke/tree.sh"
[[ -n $out ]] || out="$checkout/tmp/sandbox-shots/$(date -u +%Y%m%dT%H%M%SZ)${rev:+-$rev}$([[ $scale == 1 ]] || echo "-x$scale")"
SHOT_DIR="$(shot_dir_under "$checkout" "$out")" || exit 2
if [[ -e $SHOT_DIR/shots.tsv ]]; then printf 'sandbox-shots: refused: out-dir-used=%s\n' "$SHOT_DIR" >&2; exit 2; fi

source_tree=""
# The harness's own cleanup removes the export on every exit once it has
# armed; this trap covers the prerequisite checks it makes before that.
trap '[[ -z $source_tree ]] || rm -rf -- "$source_tree"' EXIT
if [[ -n $rev ]]; then
  git -C "$checkout" rev-parse --verify --quiet "$rev^{commit}" >/dev/null || { printf 'sandbox-shots: refused: rev=%s\n' "$rev" >&2; exit 2; }
  source_tree="$(mktemp -d "${TMPDIR:-/tmp}/vgsh-shots-tree.XXXXXX")"
  if ! tree_export "$checkout" "$rev" "$source_tree"; then
    rm -rf -- "$source_tree"
    printf 'sandbox-shots: refused: rev-export=%s\n' "$rev" >&2
    exit 2
  fi
fi

# Which plugin manager the tree ships picks the manager's scene.
tree="${source_tree:-$checkout}"
manager_scene=""
if [[ -f $tree/shell/plugins/vgs.settings/manifest.json ]]; then manager_scene=settings
elif [[ -f $tree/shell/plugins/vgs.bar/Manager.qml ]]; then manager_scene=manager
fi
if [[ ${#scenes[@]} -eq 0 ]]; then
  scenes=(gallery)
  [[ -z $manager_scene ]] || scenes+=("$manager_scene")
  [[ -n $rev ]] || scenes+=(launcher notifications)
fi
for scene in "${scenes[@]}"; do
  if [[ ($scene == settings || $scene == manager) && $scene != "$manager_scene" ]]; then
    printf 'sandbox-shots: refused: scene=%s tree=%s\n' "$scene" "${rev:-checkout}" >&2
    exit 2
  fi
done

# shellcheck disable=SC2034 # the harness sourced below reads it
shell_output_scale="$scale"
source "$checkout/scripts/smoke/harness.sh"
# The harness copied the tree into the sandbox; the export is no longer read.
[[ -z $source_tree ]] || rm -rf -- "$source_tree"
# The plugin fixtures a scene installs: this checkout's, or with --rev that
# revision's, since its manifest judge is the one that reads them.
fixtures="$checkout/scripts/smoke/fixtures/plugins"
if [[ -n $rev ]]; then
  fixtures="$sandbox/rev-fixtures/scripts/smoke/fixtures/plugins"
  mkdir -p -- "$sandbox/rev-fixtures"
  git -C "$checkout" archive "$rev" scripts/smoke/fixtures/plugins | tar -x -C "$sandbox/rev-fixtures" || fail "the fixtures of $rev could not be exported"
fi

# The kind a first-party window has in the tree the sandbox runs: `window`
# since D044, or `panel` in a tree from before, which shipped it as a layer
# panel; and the surface it is drawn in, as surface_box names one.
summoned_kind() { # ID
  python3 -c 'import json,sys; print("window" if "window" in json.load(open(sys.argv[1]))["kinds"] else "panel")' "$repo/shell/plugins/$1/manifest.json"
}
summoned_surface() { # KIND TITLE
  if [[ $1 == window ]]; then echo "window:$2"; else echo vgs:panel; fi
}
surface_count() { # SURFACE
  if [[ $1 == window:* ]]; then window_count "${1#window:}"; else layer_count "$1"; fi
}
gallery_kind="$(summoned_kind vgs.gallery)" || fail "the gallery's manifest is unreadable"
gallery_surface="$(summoned_surface "$gallery_kind" Gallery)"
settings_kind=panel
if [[ $manager_scene == settings ]]; then settings_kind="$(summoned_kind vgs.settings)" || fail "the Settings manifest is unreadable"; fi
settings_surface="$(summoned_surface "$settings_kind" Settings)"
settings_count() { surface_count "$settings_surface"; }

SHOT_RUNTIME_DIR="$rt_dir"
if ! SHOT_SOCKET="$(shot_socket "$rt_dir" "$nested_socket" "$host_socket")"; then
  fail "the nested socket is not safe to capture"
  exit 1
fi
ok "grim captures only $SHOT_SOCKET"
# Hyprland's own notice that it was not started through start-hyprland
# would sit over the top right of every shot.
expect "the nested compositor's notices are dismissed" ok hypr dismissnotify
main_name="$(first_name)" || { fail "the monitor is unreadable"; exit 1; }
# The monitor's logical size, the layout coordinates the pointer helper
# takes, and the space the bar reserves at its top.
read -r mon_w mon_h bar_reserved < <(hypr -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print(round(m["width"] / m["scale"]), round(m["height"] / m["scale"]), m["reserved"][1])')

undrawn=0
# take NAME: one shot, refused while the output has left a mode the run
# holds, so a PNG never shows a reset output under a held mode's name.
take() { # NAME
  local status=0
  if [[ ${#mode_hold[@]} -gt 0 && $(held_mode_state) != held ]]; then
    fail "shot $1 not taken: ${mode_hold[0]} reads $(mode_scale_of "${mode_hold[0]}" || echo unreadable), not the held ${mode_hold[1]}; a host resize or a configuration reload reset it"
    return
  fi
  shot "$1" || status=$?
  case $status in
    0) ;;
    2) undrawn=$((undrawn + 1)); fail "grim got no frame from the nested compositor for $1" ;;
    *) fail "shot $1 failed" ;;
  esac
}
centre_of() { python3 -c 'import json,sys; t=sys.argv[1]; r=json.loads(t) if t.startswith("[") else None; print("%d %d" % (r[0] + r[2] / 2, r[1] + r[3] / 2) if r else "none")' "$1"; }
# hover_on LABEL HOST ID TYPE TEXT: the pointer on the centre of that item,
# arriving by two motions: the launcher follows the pointer only once it
# has moved over the list (selectFromPointer in its Launcher.qml).
hover_on() {
  local label="$1" rect at="" x y
  for _ in $(seq 1 25); do
    rect="$(ipc smoke itemGeometry "$2" "$3" "$4" "$5")" && at="$(centre_of "$rect")" && [[ $at != none ]] && break
    at=""; sleep 0.2
  done
  if [[ -z $at ]]; then fail "$label: no $4 \"$5\" under $2 $3"; return 1; fi
  read -r x y <<<"$at"
  if ! hover "$((x - 6))" "$y" || ! hover "$x" "$y"; then fail "$label: the hover failed"; return 1; fi
  ok "$label"
}
park_pointer() { hover "$((mon_w - 2))" "$((mon_h - 2))" || fail "parking the pointer failed"; }

theme_file="$home/.config/vgs/theme.json"
set_mode() { # dark|light
  local name
  case $1 in
    dark) printf '{ "schemaVersion": 1, "name": "vgs", "tokens": {} }\n' >"$theme_file.tmp"; name=vgs ;;
    light) cp -- "$checkout/themes/light/theme.json" "$theme_file.tmp"; name=light ;;
  esac
  mv -T -- "$theme_file.tmp" "$theme_file"
  expect_poll "the $1 theme ($name) is published" "$name" ipc smoke themeName
}

# One shot per page of the gallery's scrolling list, a page's height less
# 40 px apart so each page repeats the last lines of the one before.
scene_gallery() { # MODE
  local page=1 y=0 at cy ch h
  expect "the gallery summons" ok ipc shell summon "$gallery_kind" vgs.gallery '{}'
  expect_poll "the gallery maps its surface" 1 surface_count "$gallery_surface"
  expect_poll "the gallery draws every component" '[]' ipc smoke galleryMissing "$gallery_kind" vgs.gallery
  while (( page <= 12 )); do
    at="$(ipc smoke scrollTo "$gallery_kind" vgs.gallery "$y")" || at=""
    if [[ $at != "["* ]]; then fail "the gallery did not scroll: ${at:-no reply}"; break; fi
    read -r cy ch h < <(python3 -c 'import json,sys; print(*(int(v) for v in json.loads(sys.argv[1])))' "$at")
    take "gallery-$1-p$page"
    (( cy + h < ch )) || break
    y=$(( cy + h - 40 )); page=$(( page + 1 ))
  done
  expect "the gallery hides" ok ipc shell hide "$gallery_kind" vgs.gallery
  expect_poll "the gallery's surface is gone" 0 surface_count "$gallery_surface"
}

settings_page() { ipc smoke readInstance "$settings_kind" vgs.settings page; }
settings_menu_open() { ipc smoke menus "$settings_kind" vgs.settings | python3 -c 'import json,sys; m=json.load(sys.stdin); print(len(m) == 1 and m[0]["opened"])'; }
# The page's one scroll area as the probe reads it.
settings_scroll() { ipc smoke scrollAreas "$settings_kind" vgs.settings | python3 -c 'import json,sys; a=json.load(sys.stdin); print(json.dumps(a[0]) if len(a) == 1 else "areas=%d" % len(a))'; }
settings_close() {
  expect "the Settings window closes" ok ipc shell hide "$settings_kind" vgs.settings
  expect_poll "the Settings window is gone" 0 settings_count
}
# The single-workspace token's store command: the last line of the Slack
# section, on the page of this checkout and of a revision before per-workspace
# tokens alike.
slack_legacy_command="secret-tool store --label='VGS notifications Slack token' service vgs-notifications account slack"
# The Slack section of the notifications' page in its scroll area's content
# coordinates, as `START END HEIGHT`: its heading's top, the bottom of its
# last line's command, and the area's height. The bar spans the area, so its
# top is the area's.
slack_section() {
  local area header last
  area="$(settings_scroll)" && [[ $area == \{* ]] || { echo "area=${area:-unread}"; return 1; }
  header="$(ipc smoke windowGeometry "$settings_kind" vgs.settings SectionHeader Slack)" && [[ $header == \[* ]] || { echo "heading=${header:-unread}"; return 1; }
  last="$(ipc smoke windowGeometry "$settings_kind" vgs.settings CodeLine "$slack_legacy_command")" && [[ $last == \[* ]] || { echo "last-line=${last:-unread}"; return 1; }
  python3 -c 'import json,sys
a, h, l = (json.loads(v) for v in sys.argv[1:4])
top, y = a["bar"][1], a["contentY"]
print(int(h[1] - top + y), int(l[1] + l[3] - top + y), int(a["height"]))' "$area" "$header" "$last"
}
# settings_scroll_to Y: the page's scroll area moved to about contentY Y,
# held inside its content, by dragging its bar's thumb as the scrolled
# probe page's shot does: the thumb travels the bar less its own length
# while the content travels its height less the area's.
settings_scroll_to() {
  local area move tx ty
  area="$(settings_scroll)" && [[ $area == \{* ]] || return 1
  move="$(python3 -c 'import json,sys
a, want = json.loads(sys.argv[1]), int(sys.argv[2])
most = a["contentHeight"] - a["height"]
travel = a["bar"][3] - a["thumb"][3]
print(0 if most <= 0 or travel <= 0 else round((max(0, min(want, most)) - a["contentY"]) * travel / most))' "$area" "$1")" || return 1
  [[ $move -ne 0 ]] || return 0
  read -r tx ty < <(at_centre "$settings_surface" "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["thumb"]))' "$area")") || return 1
  drag "$tx" "$ty" "$tx" "$((ty + move))"
}
# Whether every status row of the notifications' page is reported.
notifications_reported() { ipc smoke readInstance "$settings_kind" vgs.settings plugins | python3 -c 'import json,sys; r=[p for p in json.load(sys.stdin) if p["id"] == "vgs.notifications"]; print(len(r) == 1 and len(r[0]["status"]) > 0 and all(s["report"] == "reported" for s in r[0]["status"]))'; }
# The Settings window: the list opened from the gear, the pointer on the
# gear; a plugin page with many grouped settings at its top and dragged
# down its scroll bar; a plugin with keys; the title's menu open with its
# scroll bar under the pointer; the notifications' page scrolled to its
# Slack token rows, over two shots when they are taller than the page; and
# the list and a page on a monitor narrower than the window's width token.
scene_settings() { # MODE
  local area at tx ty title x y
  click_centre "$(bar_key)" vgs.settings || fail "the click on the gear failed"
  expect_poll "the gear opens the Settings window" 1 settings_count
  expect_poll "the Settings window holds the keyboard" true ipc smoke activeFocusIn "$settings_kind" vgs.settings
  take "settings-$1-list"
  # The gear draws no text, so it is found by its label.
  if at="$(centre_of "$(ipc smoke labelledGeometry "$(bar_key)" vgs.settings IconButton Settings)")" && [[ $at != none ]]; then
    read -r x y <<<"$at"
    if hover "$((x - 6))" "$y" && hover "$x" "$y"; then take "settings-$1-gear"; else fail "the hover on the gear failed"; fi
  else
    fail "the gear has no box"
  fi
  park_pointer
  expect "the window opens the probe's page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin acme.probe
  expect_poll "the probe's page is shown" '"acme.probe"' settings_page
  take "settings-$1-page"
  if area="$(settings_scroll)" && [[ $area == \{* ]]; then
    read -r tx ty < <(at_centre "$settings_surface" "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["thumb"]))' "$area")")
    drag "$tx" "$ty" "$tx" "$((ty + 120))" || fail "the drag on the page's thumb failed"
    hover "$tx" "$((ty + 120))" || fail "the hover on the dragged thumb failed"
    take "settings-$1-page-scrolled"
  else
    fail "the probe's page scroll area is unreadable: ${area:-}"
  fi
  park_pointer
  expect "the window opens the launcher's page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.launcher
  expect_poll "the launcher's page is shown" '"vgs.launcher"' settings_page
  take "settings-$1-keys"
  click_in "$settings_surface" "$settings_kind" vgs.settings TitleButton Launcher || fail "the click on the title failed"
  expect_poll "the title's menu opens" True settings_menu_open
  # The menu opens under the title; the pointer rests inside it, which
  # shows its scroll bar.
  if title="$(ipc smoke windowGeometry "$settings_kind" vgs.settings TitleButton Launcher)" && [[ $title == \[* ]]; then
    read -r x y < <(at_centre "$settings_surface" "$(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); print(json.dumps([r[0], r[1] + r[3] + 40, 80, 40]))' "$title")")
    hover "$x" "$y" || fail "the hover inside the title's menu failed"
  fi
  take "settings-$1-menu"
  type_keys -k Escape || fail "sending Escape to the title's menu failed"
  expect_poll "the title's menu closes" False settings_menu_open
  expect "the window opens the Bar plugin page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.bar
  expect_poll "the Bar plugin page is shown" '"vgs.bar"' settings_page
  take "settings-$1-bar-page"
  park_pointer
  expect "the window opens the notifications' page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.notifications
  expect_poll "the notifications' page is shown" '"vgs.notifications"' settings_page
  expect_poll "the notifications' status rows are reported" True notifications_reported
  # The Slack section in view: its heading at the top, and, when the
  # section is taller than the area, a second shot with its last line at
  # the bottom, so every line and command shows across the two.
  local section start end height margin=12
  if section="$(slack_section)"; then
    read -r start end height <<<"$section"
    settings_scroll_to "$((start - margin))" || fail "the scroll to the Slack section failed"
    park_pointer
    take "settings-$1-slack"
    if (( end - start + 2 * margin > height )); then
      settings_scroll_to "$((end + margin - height))" || fail "the scroll to the Slack section's end failed"
      park_pointer
      take "settings-$1-slack-end"
    fi
  else
    fail "the notifications' Slack section is unreadable: $section"
  fi
  settings_close
  # The monitor made narrower than the window: the nested output holds a
  # mode 480 by 720 logical pixels at the run's scale for the shot, then
  # its own mode again. The gear opens the window on its bar's monitor, the
  # list first and then a page.
  local main_mode narrow_mode="$((480 * scale))x$((720 * scale))"
  main_mode="$(first_mode)" || fail "the monitor's mode is unreadable"
  [[ $scale == 1 ]] || release_mode "the run's scale-2 hold ends for the narrow monitor" "$main_name" "$main_mode" "$scale"
  hold_mode "the monitor is made narrower than the window" "$main_name" "$narrow_mode" "$scale"
  expect_poll "the monitor is 480 logical pixels wide" 480 first_width
  expect "the gear opens the window on the narrow monitor" ok ipc smoke invokeInstance "$(bar_key)" vgs.settings toggle ''
  expect_poll "the narrow window maps" 1 settings_count
  take "settings-$1-narrow-list"
  expect "the narrow window opens the probe's page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin acme.probe
  expect_poll "the probe's page is shown on the narrow monitor" '"acme.probe"' settings_page
  take "settings-$1-narrow-page"
  settings_close
  release_mode "the monitor's own mode is restored" "$main_name" "$main_mode" "$scale"
  [[ $scale == 1 ]] || hold_mode "the monitor holds its scale-2 mode again" "$main_name" "$main_mode" "$scale"
  expect_poll "the monitor has its width back" "$mon_w" first_width
}

# The bar's manager panel of a tree before the Settings plugin: opened by a
# click on its button, then with the pointer on its first row. The click
# is the popup's first pointer event on that bar: an anchored popup that
# grabs focus maps on a fresh bar only after one, so a summon over IPC
# alone leaves it unmapped.
manager_listed() { ipc smoke readInstance panel vgs.bar plugins | python3 -c 'import json,sys; t=sys.stdin.read(); print(t.startswith("[") and len(json.loads(t)) > 0)'; }
manager_mapped() { [[ $(ipc smoke instanceGeometry panel vgs.bar) != absent ]] && echo mapped || echo absent; }
scene_manager() { # MODE
  local first
  click_centre "$(bar_key)" vgs.bar/right-manager || fail "the click on the manager button failed"
  expect_poll "the manager panel maps under its button" mapped manager_mapped
  expect_poll "the manager panel lists its plugins" True manager_listed
  take "manager-$1"
  first="$(ipc smoke readInstance panel vgs.bar plugins | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["name"])')" || first=""
  hover_on "the pointer rests on the manager's first row" panel vgs.bar ListItem "$first" && take "manager-$1-hover"
  park_pointer
  expect "the manager panel closes" ok ipc smoke invokeInstance "$(bar_key)" vgs.bar/right-manager toggle ''
}

launcher_rows() { ipc smoke launcherRows overlay vgs.launcher; }
launcher_listed() { launcher_rows | python3 -c 'import json,sys; t=sys.stdin.read(); print(t.startswith("[") and len(json.loads(t)) > 2)'; }
scene_launcher() { # MODE
  local second
  expect "the launcher summons" ok ipc vgs.launcher invoke summon '{}'
  expect_poll "the launcher maps its overlay" 1 layer_count vgs:overlay
  expect_poll "the launcher holds the keyboard" true ipc smoke activeFocusIn overlay vgs.launcher
  take "launcher-$1-open"
  # The orbiting edge light: frames a moment apart, each proved to differ
  # from the one before, so the light is seen moving.
  for i in 1 2 3; do sleep 0.3; SHOT_SETTLE_S=1 take "launcher-$1-orbit-$i"; done
  type_keys -M ctrl -k b -m ctrl || fail "sending Ctrl+B failed"
  expect_poll "the launcher lists its categories" True launcher_listed
  take "launcher-$1-list"
  type_keys -k Down || fail "sending Down failed"
  expect_poll "Down selects the second row" 1 ipc smoke readInstance overlay vgs.launcher selectedIndex
  take "launcher-$1-selected"
  second="$(launcher_rows | python3 -c 'import json,sys; print(json.load(sys.stdin)[2][1])')" || second=""
  hover_on "the pointer rests on the launcher's third row" overlay vgs.launcher QQuickText "$second" && take "launcher-$1-hover"
  park_pointer
  type_keys -k Escape -k Escape || fail "sending Escape failed"
  expect_poll "the launcher closes" 0 layer_count vgs:overlay
}

notify() { # APP SUMMARY BODY ACTIONS HINTS: prints the id
  "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify "$1" 0 "" "$2" "$3" "$4" "$5" 30000 | python3 -c 'import re,sys; print(re.search(r"uint32 (\d+)", sys.stdin.read()).group(1))'
}
notes() { ipc vgs.notifications invoke "$1" "${2:-}"; }
card_centre() { ipc smoke layerItems vgs.notifications NotificationCard summary | python3 -c 'import json,sys; y0=int(sys.argv[2])
for screen, (x, y, w, h), v in json.load(sys.stdin):
    if v["summary"] == sys.argv[1]: print(x + w // 2, y0 + y + h // 2); break' "$1" "$bar_reserved"; }
on_screen() { notes status | python3 -c 'import json,sys; print(json.load(sys.stdin)["onScreen"])'; }
acme_emoji() { notes status | python3 -c 'import json,sys; print(json.load(sys.stdin)["slack"]["emoji"]["teams"].get("T0ACME", 0))'; }
slack_badges() { ipc smoke layerItems vgs.notifications NotificationCard showsBadge,app | python3 -c 'import json,sys; print(json.dumps([v["showsBadge"] for _, _, v in json.load(sys.stdin) if v["app"] == "Slack"][:3]))'; }
scene_notifications() { # MODE
  local ids=() at
  ids+=("$(notify smoke-build "Build finished" "vgs main is green in 2 min" '[]' '{}')")
  ids+=("$(notify smoke-power "Battery low" "12% left" '[]' '{"urgency": <byte 2>}')")
  ids+=("$(notify smoke-chat "New message" "Lunch at noon?" '["default", "Open", "reply", "Reply"]' '{}')")
  expect_poll "three toasts are on screen" 3 on_screen
  take "notifications-$1-toasts"
  at="$(card_centre "New message")" || at=""
  if [[ -n $at ]]; then
    # shellcheck disable=SC2086
    hover $at || fail "the hover over the actionable toast failed"
    take "notifications-$1-hover"
  else
    fail "the actionable toast has no card"
  fi
  park_pointer
  expect "the inbox opens" ok notes inbox
  expect_poll "the panel is the inbox" '"inbox"' ipc smoke readInstance service vgs.notifications panelMode
  take "notifications-$1-inbox"
  expect "the inbox closes" ok notes close
  for id in "${ids[@]}"; do
    "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
      --method org.freedesktop.Notifications.CloseNotification "$id" >/dev/null || fail "closing notification $id failed"
  done
  expect "the history clears" ok notes clear-history
  expect_poll "no toast is left" 0 on_screen
  # Slack-shaped notifications, as Slack's web client titles them, from the
  # synthetic Slack under the sandbox's configuration: a direct message, a
  # group message past three people and a channel mention with the
  # workspace's custom emoji, each with the workspace's icon in place of its
  # bracketed name. An older revision draws the shortcode as text.
  [[ -n $rev ]] || expect_poll "acme's custom emoji are made" 1 acme_emoji
  ids=()
  ids+=("$(notify Slack "[acme] in eng-core" "Grace Hopper: @ada the build is green :smoke-party: ship it :smoke-party:" '["default", "View"]' '{"desktop-entry": <"slack">}')")
  ids+=("$(notify Slack "[acme] in ada, grace, alan, edsger, barbara" "alan: lunch at noon?" '["default", "View"]' '{"desktop-entry": <"slack">}')")
  ids+=("$(notify Slack "[acme] from Ada Lovelace" "Did you see the notes?" '["default", "View"]' '{"desktop-entry": <"slack">}')")
  expect_poll "three Slack toasts are on screen" 3 on_screen
  # An older revision's card has no workspace icon to read back.
  [[ -n $rev ]] || expect_poll "each Slack toast draws the workspace icon" '[true, true, true]' slack_badges
  take "notifications-$1-slack"
  for id in "${ids[@]}"; do
    "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
      --method org.freedesktop.Notifications.CloseNotification "$id" >/dev/null || fail "closing notification $id failed"
  done
  expect "the history clears" ok notes clear-history
  expect_poll "no toast is left" 0 on_screen
  # Heights: a one-line card, a two-line card and one past its most lines,
  # which stops at the look's maximum height.
  ids=()
  ids+=("$(notify smoke-heights "Screenshot saved" "" '[]' '{}')")
  ids+=("$(notify smoke-heights "Download complete" "report.pdf is in Downloads" '[]' '{}')")
  ids+=("$(notify smoke-heights "Release notes" "$(printf 'A body long enough to run past every line the card may show. %.0s' $(seq 1 12))" '[]' '{}')")
  expect_poll "three height toasts are on screen" 3 on_screen
  take "notifications-$1-heights"
  for id in "${ids[@]}"; do
    "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
      --method org.freedesktop.Notifications.CloseNotification "$id" >/dev/null || fail "closing notification $id failed"
  done
  expect "the history clears" ok notes clear-history
  expect_poll "no toast is left" 0 on_screen
}

for scene in "${scenes[@]}"; do
  case $scene in
    launcher|notifications)
      # The notifications read the synthetic Slack's workspace list once,
      # when they start, beside a stub libsecret that holds no token: the
      # photo helper refuses any other secret-tool in the sandbox, and with
      # the stub it builds the custom emoji from the synthetic cache alone.
      if [[ $scene == notifications ]]; then
        mkdir -p -- "$home/.config/Slack"
        cp -R -- "$checkout/scripts/smoke/fixtures/slack/." "$home/.config/Slack/"
        printf '#!/usr/bin/env bash\nexit 1\n' >"$shim/secret-tool"
        chmod 755 "$shim/secret-tool"
      fi
      expect "enabling vgs.$scene is allowed" ok ipc shell setPluginEnabled "vgs.$scene" true
      expect_poll "vgs.$scene is built" True record_exists "vgs.$scene" ;;
    settings)
      # The Settings window lists the probe fixture, a plugin with many
      # grouped settings, and the launcher, a plugin with a key; both
      # enabled, so their pages are editable. Three more fixtures make the
      # plugin list longer than the title menu's nine rows, so the menu
      # scrolls.
      for fixture in acme.probe acme.bare acme.idle acme.locker; do
        mkdir -p "$home/.config/vgs/plugins/$fixture"
        cp -R -- "$fixtures/$fixture/." "$home/.config/vgs/plugins/$fixture/"
      done
      # The notifications' page reads the synthetic Slack's workspace list
      # and a stub libsecret, whose `<account> <state>` lines answer the
      # token probe's search as libsecret's secret-tool does: acme's own
      # token stored, globex's locked, the single-workspace one stored. A
      # lookup finds no token, so the photo helper calls nothing.
      mkdir -p -- "$home/.config/Slack"
      cp -R -- "$checkout/scripts/smoke/fixtures/slack/." "$home/.config/Slack/"
      printf '%s\n' "slack:T0ACME present" "slack:T0GLOBEX locked" "slack present" >"$shim/secret-tool.states"
      cat >"$shim/secret-tool" <<SH
#!/usr/bin/env bash
[[ \${1:-} == search && \${2:-} == service && \${3:-} == vgs-notifications && \${4:-} == account && \$# -eq 5 ]] || exit 1
account="\$5" state=absent
while read -r name answer; do [[ \$name == "\$account" ]] && state="\$answer"; done <"$shim/secret-tool.states"
case "\$state" in
  present) printf '[/1]\\nlabel = VGS notifications Slack token\\n'; printf 'attribute.service = vgs-notifications\\nattribute.account = %s\\n' "\$account" >&2 ;;
  locked) printf '[/1]\\nlabel = VGS notifications Slack token\\n'; printf 'secret-tool: Cannot get secret of a locked object\\nattribute.service = vgs-notifications\\nattribute.account = %s\\n' "\$account" >&2 ;;
esac
SH
      chmod 755 "$shim/secret-tool"
      expect "the fixtures are scanned" ok ipc shell rescanPlugins
      expect_poll "the probe fixture is listed" True plugin_known acme.probe
      for id in acme.probe vgs.launcher vgs.notifications vgs.settings; do
        expect "enabling $id is allowed" ok ipc shell setPluginEnabled "$id" true
        expect_poll "$id is built" True record_exists "$id"
      done ;;
  esac
done

# The first shot is the bare desktop; every later shot must differ from the
# one before it, which is what proves grim reads the frame being drawn now.
park_pointer
take "00-desktop"
for mode in "${mode_list[@]}"; do
  set_mode "$mode"
  for scene in "${scenes[@]}"; do "scene_$scene" "$mode"; done
done

echo "sandbox-shots: dir=$SHOT_DIR shots=$(wc -l <"$SHOT_DIR/shots.tsv" 2>/dev/null || echo 0) failures=$failures"
if [[ $failures -gt 0 && $failures -eq $undrawn ]]; then
  printf 'sandbox-shots: status=not-measured nested-window=not-drawn\n'
  exit 77
fi
[[ $failures -eq 0 ]] || exit 1
