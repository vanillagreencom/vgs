#!/usr/bin/env bash
# Capture the shell's surfaces in the nested Hyprland sandbox with grim.
#
# Usage: scripts/sandbox-shots.sh [--out DIR] [--rev REV] [--modes LIST]
#                                 [--size WxH] [--scale N]
#                                 [--theme-card NAME] [--hidden]
#                                 [--timeout SECONDS] [--keep] [SCENE...]
#
# The sandbox is the smoke's own (scripts/smoke/harness.sh): its own HOME,
# runtime dir, buses and nested compositor, with the shell started inside
# it. grim is pointed at the nested compositor's socket alone
# (scripts/smoke/shot.sh refuses the host socket), so nothing is captured
# or started on the live desktop. It needs the smoke's prerequisites,
# WAYLAND_DISPLAY and XDG_RUNTIME_DIR included, plus grim.
#
# SCENE is gallery, settings, manager, launcher, notifications, bar,
# panels, devtools, dialog, lock, polkit, narrow, theme-browser or
# wallpaper-browser. settings takes the automations' and the Jarvis
# pages among the plugin pages, each when the tree ships its plugin. bar
# is the bar with every first-party widget and each widget's tooltip or
# hover; panels is the Agent Warden panel, the updates flyout and the
# themes panel, each opened from its widget over planted status or
# packages, the themes panel's apply held and answered by a stand-in
# runner that changes no theme; devtools is the
# Dev Tools window; dialog is the core's requirement notice; lock is the
# vgs.lock screen, locked and after wrong attempts; polkit is the
# vgs.polkit prompt, asking and after a failed attempt; narrow holds a
# monitor 480 by 720 logical pixels and takes the bar, panels, devtools,
# dialog, lock, launcher, notifications and the first gallery pages again, each
# shot named <scene>-<mode>-narrow-*; theme-browser and wallpaper-browser
# are the vgs.themes browsers, taken only when named: the theme view
# loaded, with the pointer on a card, with a filter no card matches, with
# a refused card's failure line, on the chosen catalog card, on it
# installed and with its wallpaper offer; the wallpaper view on its Theme
# source, with the pointer on a card, on its download card and on All.
# Each leaves vgs and the mode's theme applied. The default is every
# other scene the tree ships, or gallery and the manager's scene with
# --rev; the manager's scene is `settings` for a tree that ships
# vgs.settings and `manager`, the bar's manager panel, for one that ships
# the bar's manager built-in. A scene the tree does not ship is refused as
# `sandbox-shots: refused: scene=<scene> tree=<rev or checkout>`. --modes is a comma list of dark,
# light and rounded, dark by default with --rev and dark and light
# otherwise: dark is the defaults (theme `vgs`), light is this checkout's
# themes/light package, and rounded is the defaults with `radius.sm`,
# `radius.md` and `radius.lg` at 6, 12 and 16, so every theme-rounded
# component shows whether its content clears its corners.
# --rev REV runs that revision's shell, bin, config and themes (git archive),
# with the runtime helpers a revision before bin/lib kept under scripts/,
# under this checkout's harness and probe, for a before shot; the plugin
# fixtures a scene installs are that revision's, which its judge accepts.
# A scene reaches what that tree ships: the gear's and the launcher and
# themes entries' item types, a search cleared by keys where no Clear
# search exists, and Install where a Dev Tools row has no Details.
# --scale is 1, the default, or 2: at 2 the harness holds the nested
# output at double its mode and scale 2 before the shell starts
# (shell_output_scale in scripts/smoke/harness.sh), so the layout keeps its
# logical size and the shell draws each PNG in device pixels. Each shot at
# scale 2 checks before and after its capture (shot_held in
# scripts/smoke/shot.sh) that the output still reads that mode, since a
# host resize or refocus, or a writer not identified, resets it
# (held_mode_state in scripts/smoke/harness.sh), and fails when it does
# not. Another value is refused as
# `sandbox-shots: refused: scale=<value>`.
# --size WxH holds the nested output at W by H logical pixels, at the run's
# scale, for every scene, so a shot's width does not depend on the host's
# window; another shape is refused as `sandbox-shots: refused: size=<value>`.
# --theme-card NAME is the catalog theme the theme-browser scene selects,
# frankenstein by default. A name other than lowercase letters, digits and
# hyphens is refused as `sandbox-shots: refused: theme-card=<value>`, and
# with the theme-browser scene a name the tree's catalog lacks as
# `sandbox-shots: refused: theme-card=<value> tree=<rev or checkout>`.
# The lock scene enables vgs.lock with its sleep hook and idle watch off,
# locks the nested session, and shoots the lock screen, then after one and
# after ten wrong attempts. No password is typed and no PAM runs: the
# probe calls the service's `fail()`, the step PAM's refusal takes, and
# releases the lock with `sessionUnlock`, test code that never ships
# (docs/architecture/lock-polkit.md § Validation). It disables the probe
# fixture, which holds `lock`, while it runs, when the settings scene
# enabled it.
# The polkit scene builds the plugin's own Prompt.qml over a stand-in
# authentication flow the probe owns, in a stand-in of the summon host's
# overlay surface (polkitStandInOpen in scripts/smoke/Probe.qml), with
# vgs.polkit disabled, so no agent and no request exist. Nothing is typed,
# the stand-in's submit only counts, and the scene reads that no request
# went live and no authentication helper ran. The Settings scene enables
# vgs.automations over the harness's automations_stand_ins for its page's
# shot, so no call reaches the host's systemd user manager, and disables it
# again. It enables vgs.jarvis for its page's shot, once the daemon
# answers, over the J09 world the harness prepares for every sandbox
# (scripts/smoke/harness.sh), so the child reaches no audio, account,
# network or desktop, and disables it again.
# --hidden refuses every shot not taken with the nested window hidden on
# the host (SHOT_WINDOW_REQUIRE in scripts/smoke/shot.sh), so a run that
# exits 0 proves each shot's frame arrived while the window was hidden.
#
# PNGs go to DIR, which must lie under this checkout's tmp/; the default is
# tmp/sandbox-shots/<UTC time>[-REV][-x2]. shots.tsv beside them lists each shot
# with the sha256 of its file, how it was proved current and whether the
# host showed the nested window while it was taken (shot.sh). Each shot is
# of the nested compositor's first output alone, which the harness sized
# (grim -o), so an output a scene adds never enters a capture. The last
# line counts the shots taken with the window hidden as hidden=N; the host
# window's state is the one read this runner makes of the host compositor
# (scripts/smoke/host-window.sh).
#
# Exit 0 when every shot was taken. Exit 77 when a prerequisite is missing
# or when every failure was a grim that got no frame from the nested
# compositor (nested-window=not-drawn: the host sends a hidden window no
# frame callbacks unless a host window rule gives class aquamarine
# render_unfocused, docs/architecture/validation-smoke-faults.md). Exit 1
# when any other step or shot failed.
set -euo pipefail

timeout_s=60
keep=false
out=""
rev=""
modes=""
scale=1
shot_size=""
theme_card="frankenstein"
require_window=""
scenes=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --rev) rev="$2"; shift 2 ;;
    --modes) modes="$2"; shift 2 ;;
    --size) shot_size="$2"; shift 2 ;;
    --scale) scale="$2"; shift 2 ;;
    --theme-card) theme_card="$2"; shift 2 ;;
    --hidden) require_window=hidden; shift ;;
    --timeout) timeout_s="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    gallery|settings|manager|launcher|notifications|bar|panels|devtools|dialog|lock|polkit|narrow|theme-browser|wallpaper-browser) scenes+=("$1"); shift ;;
    *) printf 'sandbox-shots: refused: argument=%s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -n $modes ]] || { if [[ -n $rev ]]; then modes=dark; else modes=dark,light; fi; }
IFS=, read -r -a mode_list <<<"$modes"
for mode in "${mode_list[@]}"; do
  [[ $mode == dark || $mode == light || $mode == rounded ]] || { printf 'sandbox-shots: refused: mode=%s\n' "$mode" >&2; exit 2; }
done
[[ $scale == 1 || $scale == 2 ]] || { printf 'sandbox-shots: refused: scale=%s\n' "$scale" >&2; exit 2; }
[[ -z $shot_size || $shot_size =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || { printf 'sandbox-shots: refused: size=%s\n' "$shot_size" >&2; exit 2; }
[[ $theme_card =~ ^[a-z0-9][a-z0-9-]*$ ]] || { printf 'sandbox-shots: refused: theme-card=%s\n' "$theme_card" >&2; exit 2; }

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
  mkdir -p -- "${TMPDIR:-$checkout/tmp}"
  source_tree="$(mktemp -d "${TMPDIR:-$checkout/tmp}/vgsh-shots-tree.XXXXXX")"
  if ! tree_export "$checkout" "$rev" "$source_tree"; then
    rm -rf -- "$source_tree"
    printf 'sandbox-shots: refused: rev-export=%s\n' "$rev" >&2
    exit 2
  fi
fi

# Which plugin manager the tree ships picks the manager's scene.
tree="${source_tree:-$checkout}"
# What the tree draws decides how a scene reaches it, so a --rev tree from
# before a control existed is still captured: the bar's gear and the
# launcher's bar entry are BarItems or older items, the Settings list may
# have no Clear search, and a Dev Tools row may have no Details.
tree_has() { grep -qF -- "$2" "$tree/$1" 2>/dev/null; }
gear_type=IconButton
[[ -f $tree/shell/Ui/controls/BarItem.qml ]] && gear_type=BarItem
launcher_entry_item=false
tree_has shell/plugins/vgs.launcher/Widget.qml "BarItem {" && launcher_entry_item=true
has_clear_search=false
tree_has shell/plugins/vgs.settings/ListPage.qml '"Clear search"' && has_clear_search=true
devtools_hover=Install
themes_entry_type=IconButton
tree_has shell/plugins/vgs.themes/Widget.qml "BarItem {" && themes_entry_type=BarItem
tree_has shell/plugins/vgs.devtools/ToolRow.qml '"Details"' && devtools_hover=Details
card_hover_state=false
tree_has shell/Ui/layout/AngledCard.qml "property bool hovered" && card_hover_state=true
manager_scene=""
if [[ -f $tree/shell/plugins/vgs.settings/manifest.json ]]; then manager_scene=settings
elif [[ -f $tree/shell/plugins/vgs.bar/Manager.qml ]]; then manager_scene=manager
fi
# scene_ships SCENE: whether the tree ships what SCENE draws. The dialog is
# the core's notice, raised for the checkout's acme.needs fixture.
ships_plugin() { local id; for id; do [[ -f $tree/shell/plugins/$id/manifest.json ]] || return 1; done; }
scene_ships() {
  case $1 in
    settings|manager) [[ $1 == "$manager_scene" ]] ;;
    gallery) ships_plugin vgs.gallery ;;
    launcher|notifications) ships_plugin "vgs.$1" ;;
    bar) ships_plugin vgs.bar vgs.launcher vgs.agent-warden vgs.updates vgs.themes ;;
    panels) ships_plugin vgs.agent-warden vgs.updates vgs.themes ;;
    devtools) ships_plugin vgs.devtools ;;
    theme-browser|wallpaper-browser) ships_plugin vgs.themes ;;
    dialog) [[ -f $tree/shell/Hosts/NoticeHost.qml ]] ;;
    lock) ships_plugin vgs.lock ;;
    polkit) ships_plugin vgs.polkit ;;
    narrow) scene_ships bar && scene_ships panels && scene_ships devtools && scene_ships dialog && scene_ships launcher && scene_ships notifications && scene_ships gallery ;;
    *) printf 'sandbox-shots: refused: scene=%s reason=unknown\n' "$1" >&2; exit 2 ;;
  esac
}
if [[ ${#scenes[@]} -eq 0 ]]; then
  if [[ -n $rev ]]; then
    scenes=(gallery)
    [[ -z $manager_scene ]] || scenes+=("$manager_scene")
  else
    for scene in gallery settings launcher notifications bar panels devtools dialog lock polkit narrow; do
      if scene_ships "$scene"; then scenes+=("$scene"); fi
    done
  fi
fi
for scene in "${scenes[@]}"; do
  if ! scene_ships "$scene"; then
    printf 'sandbox-shots: refused: scene=%s tree=%s\n' "$scene" "${rev:-checkout}" >&2
    exit 2
  fi
  if [[ $scene == theme-browser && ! -f $tree/themes/catalog/$theme_card/theme.json ]]; then
    printf 'sandbox-shots: refused: theme-card=%s tree=%s\n' "$theme_card" "${rev:-checkout}" >&2
    exit 2
  fi
done

# shellcheck disable=SC2034 # the harness sourced below reads it
shell_output_scale="$scale"
source "$checkout/scripts/smoke/harness.sh"
# The harness copied the tree into the sandbox; the export is no longer
# read, and every later read of the tree reads the sandbox's copy.
[[ -z $source_tree ]] || rm -rf -- "$source_tree"
tree="$repo"
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
  python3 -c 'import json,sys; print("window" if "window" in json.load(open(sys.argv[1]))["kinds"] else "panel")' "$tree/shell/plugins/$1/manifest.json"
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
has_agent_warden=false
has_bar_plugin=false
has_automations=false
has_jarvis=false
has_setup_steps=false
[[ -f $tree/shell/Ui/feedback/CommandDisclosure.qml ]] && has_setup_steps=true
[[ -f $tree/shell/plugins/vgs.agent-warden/manifest.json ]] && has_agent_warden=true
[[ -f $tree/shell/plugins/vgs.automations/manifest.json ]] && has_automations=true
[[ -f $tree/shell/plugins/vgs.jarvis/manifest.json ]] && has_jarvis=true
[[ -f $tree/shell/plugins/vgs.bar/manifest.json ]] && has_bar_plugin=true
settings_count() { surface_count "$settings_surface"; }

SHOT_RUNTIME_DIR="$rt_dir"
if ! SHOT_SOCKET="$(shot_socket "$rt_dir" "$nested_socket" "$host_socket")"; then
  fail "the nested socket is not safe to capture"
  exit 1
fi
ok "grim captures only $SHOT_SOCKET"
# Each shot records whether the host showed the nested window while it was
# taken: the one read this runner makes of the host compositor.
source "$checkout/scripts/smoke/host-window.sh"
nested_window_state() { host_window_state "$compositor_pid"; }
SHOT_WINDOW_READER=nested_window_state
SHOT_WINDOW_REQUIRE="$require_window"
# Hyprland's own notice that it was not started through start-hyprland
# would sit over the top right of every shot.
expect "the nested compositor's notices are dismissed" ok hypr dismissnotify
main_name="$(first_name)" || { fail "the monitor is unreadable"; exit 1; }
# Every shot is of this output alone, so an output a scene adds, such as a
# headless one with no size, never enters a capture.
SHOT_OUTPUT="$main_name"
ok "grim captures only the output $SHOT_OUTPUT"
# --size: the output holds WxH logical pixels at the run's scale for every
# scene. At scale 2 the harness's own hold ends first and the run's mode
# becomes the doubled size, which a scene that leaves the hold returns to.
if [[ -n $shot_size ]]; then
  size_mode="$shot_size"
  [[ $scale == 1 ]] || size_mode="$((${shot_size%x*} * 2))x$((${shot_size#*x} * 2))"
  [[ $scale == 1 ]] || release_mode "the run's scale-2 hold ends for the requested shot size" "$main_name" "$shell_output_mode" "$scale"
  hold_mode "the nested output holds the requested shot size" "$main_name" "$size_mode" "$scale"
  [[ $scale == 1 ]] || shell_output_mode="$size_mode"
fi
# The monitor's logical size, the layout coordinates the pointer helper
# takes, and the space the bar reserves at its top.
read -r mon_w mon_h bar_reserved < <(hypr -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print(round(m["width"] / m["scale"]), round(m["height"] / m["scale"]), m["reserved"][1])')
run_w="$mon_w" run_h="$mon_h"

undrawn=0
# hold_left: what the output reads in place of the held mode.
hold_left() {
  echo "${mode_hold[0]} reads $(mode_scale_of "${mode_hold[0]}" || echo unreadable), not the held ${mode_hold[1]}; a host resize or refocus, or another writer, reset it"
}
# take NAME: one shot. While the run holds a mode, shot_held refuses it
# when the output has left that mode, and fails it when the output left it
# while shot waited for a settled frame, so a PNG never shows a reset
# output under a held mode's name.
take() { # NAME
  local status=0
  if [[ ${#mode_hold[@]} -eq 0 ]]; then
    shot "$1" || status=$?
  else
    shot_held "$1" held_mode_state || status=$?
  fi
  case $status in
    0) ;;
    2) undrawn=$((undrawn + 1)); fail "grim got no frame from the nested compositor for $1" ;;
    3) fail "shot $1 not taken: $(hold_left)" ;;
    4) fail "shot $1 not accepted: $(hold_left)" ;;
    *) fail "shot $1 failed" ;;
  esac
}
centre_of() { python3 -c 'import json,sys; t=sys.argv[1]; r=json.loads(t) if t.startswith("[") else None; print("%d %d" % (r[0] + r[2] / 2, r[1] + r[3] / 2) if r else "none")' "$1"; }
# hover_on LABEL HOST ID TYPE TEXT [SURFACE]: the pointer on the centre of
# that item, held until the item reports the pointer over it twice in a
# row, so a hover shot shows the hover state; an item that has no hover
# state of its own is hover_text's. A layer's item is found through
# point_item in scripts/smoke/harness.sh; a window's item needs SURFACE,
# the window's surface name, since its box is read in the window.
# window_point SURFACE HOST ID TYPE TEXT: that window item's centre on the
# output, as `X Y`.
# arriving by two motions: the launcher follows the pointer only once it
# has moved over the list (selectFromPointer in its Launcher.qml).
window_point() {
  local rect
  rect="$(ipc smoke windowGeometry "$2" "$3" "$4" "$5")" && [[ $rect == \[* ]] || return 1
  at_centre "$1" "$rect"
}
hover_on() {
  local x y i held=0
  if [[ -z ${6:-} ]]; then
    if ! point_item "$2" "$3" "$4" "$5" >/dev/null; then fail "$1: $4 \"$5\" under $2 $3 never reported the pointer"; return 1; fi
    ok "$1"; return 0
  fi
  for i in $(seq 1 50); do
    if read -r x y < <(window_point "$6" "$2" "$3" "$4" "$5"); then
      hover "$((x + i % 2))" "$y" || { fail "$1: the hover failed"; return 1; }
      if [[ $(ipc smoke itemHovered "$2" "$3" "$4" "$5") == true ]]; then held=$((held + 1)); else held=0; fi
      if (( held >= 2 )); then ok "$1"; return 0; fi
    fi
    sleep 0.1
  done
  fail "$1: $4 \"$5\" in $6 never reported the pointer"
  return 1
}
# hover_text LABEL HOST ID TYPE TEXT: the pointer on the centre of a text
# that has no hover state; the caller proves the state the hover drives.
hover_text() {
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
# narrow_begin: the nested output holds a mode 480 by 720 logical pixels at
# the run's scale, and the pointer helpers take that size, until
# narrow_end gives the run's mode back. At scale 2 the run's mode is the
# one the harness held before the shell started, since the monitor may
# read a reset one by now; at scale 1 it is the monitor's own mode.
narrow_main_mode=""
narrow_begin() {
  if [[ $scale == 2 ]]; then
    narrow_main_mode="$shell_output_mode"
  else
    narrow_main_mode="$(first_mode)" || fail "the monitor's mode is unreadable"
  fi
  [[ $scale == 1 ]] || release_mode "the run's scale-2 hold ends for the narrow monitor" "$main_name" "$narrow_main_mode" "$scale"
  hold_mode "the monitor is made narrower than the window" "$main_name" "$((480 * scale))x$((720 * scale))" "$scale"
  expect_poll "the monitor is 480 logical pixels wide" 480 first_width
  mon_w=480 mon_h=720
}
narrow_end() {
  release_mode "the run's mode is restored" "$main_name" "$narrow_main_mode" "$scale"
  [[ $scale == 1 ]] || hold_mode "the monitor holds its scale-2 mode again" "$main_name" "$narrow_main_mode" "$scale"
  expect_poll "the monitor has its width back" "$run_w" first_width
  mon_w="$run_w" mon_h="$run_h"
}

theme_file="$home/.config/vgs/theme.json"
set_mode() { # dark|light|rounded
  local name
  case $1 in
    dark) printf '{ "schemaVersion": 1, "name": "vgs", "tokens": {} }\n' >"$theme_file.tmp"; name=vgs ;;
    rounded) printf '{ "schemaVersion": 1, "name": "rounded", "tokens": { "radius": { "sm": 6, "md": 12, "lg": 16 } } }\n' >"$theme_file.tmp"; name=rounded ;;
    light) cp -- "$checkout/themes/light/theme.json" "$theme_file.tmp"; name=light ;;
  esac
  mv -T -- "$theme_file.tmp" "$theme_file"
  expect_poll "the $1 theme ($name) is published" "$name" ipc smoke themeName
}

# The gallery's field in error, scrolled to a third of the way down the
# view and clicked, so the shot shows its focus ring in the error colour.
gallery_error_focus() { # MODE
  local box y x
  ipc smoke scrollTo "$gallery_kind" vgs.gallery 0 >/dev/null || { fail "the gallery did not scroll to its top"; return; }
  box="$(ipc smoke windowGeometry "$gallery_kind" vgs.gallery TextField taken)"
  [[ $box == \[* ]] || { fail "the gallery's field in error has no box: $box"; return; }
  y="$(python3 -c 'import json,sys; print(max(0, int(json.loads(sys.argv[1])[1]) - 200))' "$box")"
  ipc smoke scrollTo "$gallery_kind" vgs.gallery "$y" >/dev/null || { fail "the gallery did not scroll to its field in error"; return; }
  read -r x y < <(window_point "$gallery_surface" "$gallery_kind" vgs.gallery TextField taken) || { fail "the gallery's field in error has no box on the output"; return; }
  if hover "$((x - 1))" "$y" && click "$x" "$y"; then
    expect_poll "the field in error holds the keyboard" true ipc smoke activeFocusIn "$gallery_kind" vgs.gallery
    take "gallery-$1-error-focus"
  else
    fail "the click on the gallery's field in error failed"
  fi
  park_pointer
}

# One shot per page of the gallery's scrolling list, a page's height less
# 40 px apart so each page repeats the last lines of the one before, up to
# gallery_pages pages.
gallery_pages=12
scene_gallery() { # MODE
  local page=1 y=0 at cy ch h
  expect "the gallery summons" ok ipc shell summon "$gallery_kind" vgs.gallery '{}'
  expect_poll "the gallery maps its surface" 1 surface_count "$gallery_surface"
  expect_poll "the gallery draws every component" '[]' ipc smoke galleryMissing "$gallery_kind" vgs.gallery
  while (( page <= gallery_pages )); do
    at="$(ipc smoke scrollTo "$gallery_kind" vgs.gallery "$y")" || at=""
    if [[ $at != "["* ]]; then fail "the gallery did not scroll: ${at:-no reply}"; break; fi
    read -r cy ch h < <(python3 -c 'import json,sys; print(*(int(v) for v in json.loads(sys.argv[1])))' "$at")
    take "gallery-$1-p$page"
    (( cy + h < ch )) || break
    y=$(( cy + h - 40 )); page=$(( page + 1 ))
  done
  gallery_error_focus "$1"
  expect "the gallery hides" ok ipc shell hide "$gallery_kind" vgs.gallery
  expect_poll "the gallery's surface is gone" 0 surface_count "$gallery_surface"
}

settings_page() { ipc smoke readInstance "$settings_kind" vgs.settings page; }
settings_menu_hovered() { ipc smoke menus "$settings_kind" vgs.settings | py_reply 'import json,sys; m=json.load(sys.stdin); print(len(m) == 1 and m[0].get("barHovered") is True)'; }
settings_menu_open() { ipc smoke menus "$settings_kind" vgs.settings | python3 -c 'import json,sys; m=json.load(sys.stdin); print(len(m) == 1 and m[0]["opened"])'; }
# The page's one scroll area as the probe reads it.
settings_scroll() { ipc smoke scrollAreas "$settings_kind" vgs.settings | python3 -c 'import json,sys; a=json.load(sys.stdin); print(json.dumps(a[0]) if len(a) == 1 else "areas=%d" % len(a))'; }
settings_drag_page_down() { # LABEL
  local area tx ty
  if area="$(settings_scroll)" && [[ $area == \{* ]]; then
    read -r tx ty < <(at_centre "$settings_surface" "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["thumb"]))' "$area")")
    drag "$tx" "$ty" "$tx" "$((ty + 120))" || { fail "the drag on $1's thumb failed"; return 1; }
    hover "$tx" "$((ty + 120))" || { fail "the hover on $1's dragged thumb failed"; return 1; }
    return 0
  fi
  fail "$1 scroll area is unreadable: ${area:-}"
  return 1
}
settings_at_top() { settings_scroll | python3 -c 'import json,sys; t=sys.stdin.read(); a=json.loads(t) if t.startswith("{") else None; print(a is not None and int(a["contentY"]) == 0)'; }
settings_close() {
  expect "the Settings window closes" ok ipc shell hide "$settings_kind" vgs.settings
  expect_poll "the Settings window is gone" 0 settings_count
}
# The single-workspace token's store command: the last line of the Slack
# section, on the page of this checkout and of a revision before per-workspace
# tokens alike. A tree that keeps the command behind Show command (D058)
# ends the section with that line's Show command button instead.
slack_legacy_command="secret-tool store --label='VGS notifications Slack token' service vgs-notifications account slack"
# settings_section HEADING [SCOPE_TYPE SCOPE_TEXT] TYPE TEXT: the page's
# section headed HEADING, through the item TYPE TEXT, inside the first
# shown SCOPE_TYPE that draws SCOPE_TEXT when one is named, in its scroll
# area's content coordinates, as
# `START END HEIGHT`: the heading's top, that item's bottom, and the area's
# height. The bar spans the area, so its top is the area's.
settings_section() {
  local area header last
  area="$(settings_scroll)" && [[ $area == \{* ]] || { echo "area=${area:-unread}"; return 1; }
  header="$(ipc smoke windowGeometry "$settings_kind" vgs.settings SectionHeader "$1")" && [[ $header == \[* ]] || { echo "heading=${header:-unread}"; return 1; }
  if [[ $# -eq 5 ]]; then last="$(ipc smoke scopedWindowGeometry "$settings_kind" vgs.settings "$2" "$3" "$4" "$5")"
  else last="$(ipc smoke windowGeometry "$settings_kind" vgs.settings "$2" "$3")"
  fi
  [[ $last == \[* ]] || { echo "last-line=${last:-unread}"; return 1; }
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
# Whether every status row of plugin ID's page is reported.
page_reported() { # ID
  ipc smoke readInstance "$settings_kind" vgs.settings plugins | python3 -c 'import json,sys; r=[p for p in json.load(sys.stdin) if p["id"] == sys.argv[1]]; print(len(r) == 1 and len(r[0]["status"]) > 0 and all(s["report"] == "reported" for s in r[0]["status"]))' "$1"
}
# `ready` once the Jarvis service's first child has answered hello, as the
# probe reads it (jarvisProcess in scripts/smoke/Probe.qml); a restart
# never counts.
jarvis_started() { ipc smoke jarvisProcess | py_reply 'import json,sys; d=json.load(sys.stdin); print("ready" if d["retries"] == 0 and d["lifetime"]["kind"] == "ready" else "retries=%d kind=%s" % (d["retries"], d["lifetime"]["kind"]))'; }
# Whether the Jarvis page's Status rows draw its Daemon row as ready.
jarvis_page_ready() { ipc smoke itemTexts "$settings_kind" vgs.settings StatusRow | py_reply 'import json,sys; print(any("Daemon" in r and "Ready; no capture" in r for r in json.load(sys.stdin)))'; }
# slack_section: the Slack section through its last line: on a tree with
# the setup steps of D058, the single-workspace token's Show command, else
# the command that line draws.
slack_section() {
  if "$has_setup_steps"; then settings_section Slack StatusLine "Single-workspace token" Button "Show command"
  else settings_section Slack CodeLine "$slack_legacy_command"
  fi
}
# The setup steps of D058 on the open Settings window: Globex's Connect with
# its masked field typed into, Acme's command behind Show command, the
# status fixture's Set up token and Install the tool, Automations' Enable
# while logged out, Themes' Install browser theming once the chromium
# target ships, and Settings' own page with its command revealed.
automations_offers() { ipc smoke readInstance "$settings_kind" vgs.settings plugins | python3 -c 'import json,sys; print(str(any(s["action"] and s["action"]["offered"] for p in json.load(sys.stdin) if p["id"] == "vgs.automations" for s in p["status"])).lower())'; }
scene_setup_steps() { # MODE
  local section start end height
  if section="$(slack_section)"; then
    read -r start end height <<<"$section"
    settings_scroll_to "$((start - 12))" || fail "the scroll to the Slack section failed"
  fi
  settings_press "Connect" StatusLine "Globex" || fail "the click on Globex's Connect failed"
  type_keys "xoxp-shot-token" || fail "typing into the masked field failed"
  park_pointer
  take "setup-$1-slack-connect"
  type_keys -k Escape || fail "sending Escape to the masked field failed"
  settings_press "Show command" StatusLine "Acme Corp (acme)" || fail "the click on Acme's Show command failed"
  park_pointer
  take "setup-$1-slack-show-command"
  expect "the status fixture publishes its token absent" ok ipc acme.status invoke set 'token="absent"'
  expect "the status fixture publishes a check that offers its install" ok ipc acme.status invoke set 'check={"tone":"warning","text":"Tool missing","action":true}'
  expect "the window opens the status fixture's page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin acme.status
  expect_poll "the status fixture's page is shown" '"acme.status"' settings_page
  settings_press "Show command" || fail "the click on the Token's Show command failed"
  park_pointer
  take "setup-$1-actions"
  expect "the window opens the Automations page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.automations
  expect_poll "the Automations page is shown" '"vgs.automations"' settings_page
  expect_poll "Automations offers Enable while logged out" true automations_offers
  settings_scroll_to 0 >/dev/null || fail "the Automations page did not scroll to the top"
  expect_poll "the Automations page is at its top" True settings_at_top
  park_pointer
  take "setup-$1-automations"
  expect "the window opens the Themes page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.themes
  expect_poll "the Themes page is shown" '"vgs.themes"' settings_page
  settings_scroll_to 0 >/dev/null || fail "the Themes page did not scroll to the top"
  expect_poll "the Themes page is at its top" True settings_at_top
  park_pointer
  take "setup-$1-browser-theming"
  expect "the window opens its own page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.settings
  expect_poll "its own page is shown" '"vgs.settings"' settings_page
  settings_press "Show command" || fail "the click on the own page's Show command failed"
  park_pointer
  take "setup-$1-settings-command"
}
# The Settings window: the list opened from the gear, the pointer on the
# gear; a search nothing matches; a plugin page with many grouped settings at its top, dragged down
# its scroll bar, and with its Mode select open; a plugin with keys; the
# automations' page at its Status section; the Jarvis page with its
# daemon ready; the
# title's menu open with its scroll bar under the pointer; the notifications' page scrolled to its
# Slack token rows, over two shots when they are taller than the page; and
# the list and a page on a monitor narrower than the window's width token.
settings_empty() { [[ $(ipc smoke itemGeometry "$settings_kind" vgs.settings Label 'No plugin matches "zzqxv"') == \[* ]] && echo shown || echo hidden; }
scene_settings() { # MODE
  # A section shot keeps its heading margin px below the area's top edge.
  local area at tx ty title x y section start end height margin=12
  click_centre "$(bar_key)" vgs.settings || fail "the click on the gear failed"
  expect_poll "the gear opens the Settings window" 1 settings_count
  expect_poll "the Settings window holds the keyboard" true ipc smoke activeFocusIn "$settings_kind" vgs.settings
  take "settings-$1-list"
  # A search nothing matches: the empty state and its way back.
  type_keys "zzqxv" || fail "typing a search nothing matches failed"
  expect_poll "the list shows its empty state" shown settings_empty
  take "settings-$1-empty"
  if "$has_clear_search"; then
    if read -r x y < <(window_point "$settings_surface" "$settings_kind" vgs.settings Button "Clear search") && hover "$((x - 1))" "$y" && click "$x" "$y"; then :; else fail "the click on Clear search failed"; fi
  else
    type_keys -k BackSpace -k BackSpace -k BackSpace -k BackSpace -k BackSpace || fail "erasing the search failed"
  fi
  expect_poll "the search is empty again" '""' ipc smoke readShownDescendant "$settings_kind" vgs.settings TextField text
  park_pointer
  # The gear draws no text, so it is found by its label.
  if at="$(centre_of "$(ipc smoke labelledGeometry "$(bar_key)" vgs.settings "$gear_type" Settings)")" && [[ $at != none ]]; then
    read -r x y <<<"$at"
    if hover "$((x - 6))" "$y" && hover "$x" "$y" \
      && expect_poll "the gear shows its hover" true ipc smoke readDescendant "$(bar_key)" vgs.settings "$gear_type" hovered; then take "settings-$1-gear"; else fail "the hover on the gear failed"; fi
  else
    fail "the gear has no box"
  fi
  park_pointer
  expect "the window opens the probe's page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin acme.probe
  expect_poll "the probe's page is shown" '"acme.probe"' settings_page
  take "settings-$1-page"
  park_pointer
  if area="$(settings_scroll)" && [[ $area == \{* ]]; then
    read -r tx ty < <(at_centre "$settings_surface" "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["thumb"]))' "$area")")
    drag "$tx" "$ty" "$tx" "$((ty + 120))" || fail "the drag on the page's thumb failed"
    hover "$tx" "$((ty + 120))" || fail "the hover on the dragged thumb failed"
    take "settings-$1-page-scrolled"
  else
    fail "the probe's page scroll area is unreadable: ${area:-}"
  fi
  park_pointer
  # The probe's Mode select, scrolled into view and opened by a click on
  # its chevron end: the inline row's right 40 px, one row height tall.
  local field
  if field="$(ipc smoke windowGeometry "$settings_kind" vgs.settings SettingField Mode)" && [[ $field == \[* ]] \
    && area="$(settings_scroll)" && [[ $area == \{* ]] \
    && settings_scroll_to "$(python3 -c 'import json,sys; f, a = json.loads(sys.argv[1]), json.loads(sys.argv[2]); print(int(f[1] - a["bar"][1] + a["contentY"]) - 60)' "$field" "$area")" \
    && field="$(ipc smoke windowGeometry "$settings_kind" vgs.settings SettingField Mode)" && [[ $field == \[* ]] \
    && read -r x y < <(at_centre "$settings_surface" "$(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); h=json.loads(sys.argv[2]); print(json.dumps([r[0] + r[2] - 40, r[1], 40, h]))' "$field" "$(ipc smoke themeValue row.height)")") \
    && hover "$((x - 1))" "$y" && click "$x" "$y"; then
    expect_poll "the Mode select opens its list" true ipc smoke readShownDescendant "$settings_kind" vgs.settings Select listOpen
    take "settings-$1-select"
    type_keys -k Escape || fail "sending Escape to the Mode select failed"
    expect_poll "the Mode select closes its list" false ipc smoke readShownDescendant "$settings_kind" vgs.settings Select listOpen
  else
    fail "the probe's Mode field is unreadable: ${field:-}"
  fi
  park_pointer
  expect "the window opens the launcher's page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.launcher
  expect_poll "the launcher's page is shown" '"vgs.launcher"' settings_page
  take "settings-$1-keys"
  if "$has_agent_warden"; then
    expect "the window opens the Agent Warden page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.agent-warden
    expect_poll "the Agent Warden page is shown" '"vgs.agent-warden"' settings_page
    settings_scroll_to 0 >/dev/null || fail "the Agent Warden page did not scroll to the top"
    expect_poll "the Agent Warden page is at its top" True settings_at_top
    take "settings-$1-agent-warden"
    settings_drag_page_down "the Agent Warden page" || true
    take "settings-$1-agent-warden-scrolled"
  fi
  if "$has_bar_plugin"; then
    expect "the window opens the Bar page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.bar
    expect_poll "the Bar page is shown" '"vgs.bar"' settings_page
    settings_scroll_to 0 >/dev/null || fail "the Bar page did not scroll to the top"
    expect_poll "the Bar page is at its top" True settings_at_top
    take "settings-$1-bar"
    settings_drag_page_down "the Bar page" || true
    take "settings-$1-bar-scrolled"
  fi
  # The automations' page at its top, the plugin enabled over the stand-ins
  # rows/automations.sh reads (automations_stand_ins in
  # scripts/smoke/harness.sh), so no call reaches the host's systemd user
  # manager; disabled again and the stand-ins removed after the shot.
  if "$has_automations"; then
    automations_stand_ins "$sandbox/shots-automations-$1"
    expect "the automations' stand-ins are scanned" ok ipc shell rescanPlugins
    expect "enabling vgs.automations is allowed" ok ipc shell setPluginEnabled vgs.automations true
    expect_poll "vgs.automations is built" True record_exists vgs.automations
    expect "the window opens the automations' page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.automations
    expect_poll "the automations' page is shown" '"vgs.automations"' settings_page
    expect_poll "the automations' status rows are reported" True page_reported vgs.automations
    # The Status section's heading at the top.
    if section="$(settings_section Status SectionHeader Status)"; then
      read -r start _ _ <<<"$section"
      settings_scroll_to "$((start - margin))" || fail "the scroll to the automations' status failed"
    else
      fail "the automations' Status section is unreadable: $section"
    fi
    park_pointer
    take "settings-$1-automations"
    expect "disabling vgs.automations is allowed" ok ipc shell setPluginEnabled vgs.automations false
    expect_poll "vgs.automations is gone" False record_exists vgs.automations
    automations_stand_ins_restore "$sandbox/shots-automations-$1"
  fi
  # The Jarvis page at its top, the daemon's status reported: the plugin
  # enabled over the J09 world the harness prepares for every sandbox, as
  # rows/jarvis.sh enables it, so the child reaches no audio, account,
  # network or desktop; disabled again after the shot.
  if "$has_jarvis"; then
    expect "enabling vgs.jarvis is allowed" ok ipc shell setPluginEnabled vgs.jarvis true
    expect_poll "the Jarvis daemon answers hello without a restart" ready jarvis_started
    expect "the window opens the Jarvis page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.jarvis
    expect_poll "the Jarvis page is shown" '"vgs.jarvis"' settings_page
    expect_poll "the Jarvis page shows its daemon ready" True jarvis_page_ready
    settings_scroll_to 0 >/dev/null || fail "the Jarvis page did not scroll to the top"
    expect_poll "the Jarvis page is at its top" True settings_at_top
    park_pointer
    take "settings-$1-jarvis"
    expect "disabling vgs.jarvis is allowed" ok ipc shell setPluginEnabled vgs.jarvis false
    expect_poll "vgs.jarvis is gone" absent ipc smoke jarvisProcess
  fi
  expect "the window opens the launcher's page again" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin vgs.launcher
  expect_poll "the launcher's page is shown again" '"vgs.launcher"' settings_page
  click_in "$settings_surface" "$settings_kind" vgs.settings TitleButton Launcher || fail "the click on the title failed"
  expect_poll "the title's menu opens" True settings_menu_open
  # The menu opens under the title; the pointer rests inside it, which
  # shows its scroll bar.
  if title="$(ipc smoke windowGeometry "$settings_kind" vgs.settings TitleButton Launcher)" && [[ $title == \[* ]]; then
    read -r x y < <(at_centre "$settings_surface" "$(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); print(json.dumps([r[0], r[1] + r[3] + 40, 80, 40]))' "$title")")
    hover "$x" "$y" || fail "the hover inside the title's menu failed"
    expect_poll "the title's menu reports the pointer inside it" True settings_menu_hovered
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
  expect_poll "the notifications' status rows are reported" True page_reported vgs.notifications
  # The Slack section in view: its heading at the top, and, when the
  # section is taller than the area, a second shot with its last line at
  # the bottom, so every line and command shows across the two.
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
  if "$has_setup_steps"; then scene_setup_steps "$1"; fi
  settings_close
  # The monitor made narrower than the window (narrow_begin): the gear
  # opens the window on its bar's monitor, the list first and then a page.
  narrow_begin
  expect "the gear opens the window on the narrow monitor" ok ipc smoke invokeInstance "$(bar_key)" vgs.settings toggle ''
  expect_poll "the narrow window maps" 1 settings_count
  take "settings-$1-narrow-list"
  expect "the narrow window opens the probe's page" ok ipc smoke invokeInstance "$settings_kind" vgs.settings openPlugin acme.probe
  expect_poll "the probe's page is shown on the narrow monitor" '"acme.probe"' settings_page
  take "settings-$1-narrow-page"
  settings_close
  narrow_end
}

# The browsers' readings: the theme view's shown card count, whether it
# names a problem, the card it offers wallpapers for, and the wallpaper
# view's selected card kind.
theme_view_count() { ipc smoke readDescendant overlay vgs.themes ThemeView shownCards | py_reply 'import json,sys; print(len(json.load(sys.stdin)))'; }
theme_view_problem() { ipc smoke readDescendant overlay vgs.themes ThemeView problem | py_reply 'import json,sys; print(json.load(sys.stdin) != "")'; }
theme_view_offer() { ipc smoke readDescendant overlay vgs.themes ThemeView offer | py_reply 'import json,sys; o=json.load(sys.stdin); print(json.dumps(None if o is None else o["name"]))'; }
wallpaper_selected_kind() { ipc smoke readDescendant overlay vgs.themes WallpaperView selected | py_reply 'import json,sys; s=json.load(sys.stdin); print(json.dumps(None if s is None else s["kind"]))'; }
# themes_restore MODE LABEL: vgs applied, which draws no background, then
# the mode's theme, after a scene applied another package.
themes_restore() {
  "${shell_env[@]}" "$repo/bin/vgsh" theme apply vgs >/dev/null || fail "vgs applies after $2"
  expect_poll "no background is drawn after $2" 0 layer_count vgs:background
  set_mode "$1"
}
# browser_card_right: the centre of the card right of the selected one on
# a browser's rail, the selected card being the largest, as `X Y`.
browser_card_right() {
  ipc smoke descendantGeometry overlay vgs.themes | py_reply 'import json,sys
cards = [r["box"] for r in json.load(sys.stdin) if r["type"] == "AngledCard" and r["box"][2] > 0 and r["box"][3] > 0]
selected = max(cards, key=lambda b: b[2] * b[3]) if cards else None
right = [b for b in cards if selected is not None and b[0] > selected[0]]
b = min(right, key=lambda b: b[0]) if right else None
print("none" if b is None else "%d %d" % (b[0] + b[2] / 2, b[1] + b[3] / 2))'
}
rail_card_hovered() { ipc smoke itemValues overlay vgs.themes AngledCard hovered | py_reply 'import json,sys; print(any(v["hovered"] is True for v in json.load(sys.stdin)))'; }
# hover_card LABEL: the pointer on that card, held until a card reports it
# twice in a row. A tree whose cards draw no hover takes the shot once the
# pointer is there.
hover_card() {
  local at x y i held=0
  at="$(browser_card_right)" && [[ $at != none ]] || { fail "$1: no card right of the selected one"; return 1; }
  read -r x y <<<"$at"
  if ! "$card_hover_state"; then
    hover "$x" "$y" || { fail "$1: the hover failed"; return 1; }
    ok "$1 (the tree's cards draw no hover)"; return 0
  fi
  for i in $(seq 1 50); do
    hover "$((x + i % 2))" "$y" || { fail "$1: the hover failed"; return 1; }
    if [[ $(rail_card_hovered) == True ]]; then held=$((held + 1)); else held=0; fi
    if (( held >= 2 )); then ok "$1"; return 0; fi
    sleep 0.1
  done
  fail "$1: no card reported the pointer"
  return 1
}
scene_theme-browser() { # MODE
  local selected preview_path
  selected_path() { ipc smoke readDescendant overlay vgs.themes ThemeView selected | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("sharpenedImage") or d.get("image") or d.get("previewImage") or "")'; }
  selected_ready() { selected="$(selected_path)" && [[ -n $selected ]] && ipc smoke images overlay vgs.themes | python3 -c 'import json,sys; path=sys.argv[1]; print(any(i[0] == path and i[1] == "ready" for i in json.load(sys.stdin)))' "$selected"; }
  preview_cached() { ipc smoke readDescendant overlay vgs.themes ThemeView previewCache | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.loads(t) if t.startswith("{") else {}; print(sys.argv[1] in d and bool(d[sys.argv[1]]))' "$1"; }
  card_image() { ipc smoke images overlay vgs.themes | python3 -c 'import json,sys; r=[i[1] for i in json.load(sys.stdin) if i[0]==sys.argv[1]]; print(r[0] if r else "none")' "$1"; }
  preview_path_of() { ipc smoke readDescendant overlay vgs.themes ThemeView previewCache | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.loads(t) if t.startswith("{") else {}; print(d.get(sys.argv[1], ""))' "$1"; }
  wait_preview_cached() { local _; for _ in $(seq 1 50); do [[ $(preview_cached "$1") == True ]] && return 0; sleep 0.2; done; return 1; }
  mkdir -p -- "$themes_mismatch"
  printf '%s\n' '{ "schemaVersion": 1, "name": "other", "tokens": {} }' >"$themes_mismatch/theme.json"
  expect "vgs.themes enables for the theme browser shot" ok ipc shell setPluginEnabled vgs.themes true
  expect_poll "vgs.themes is built for the theme browser shot" True record_exists vgs.themes
  expect "the theme browser opens" ok ipc shell summon overlay vgs.themes '{"view":"themes"}'
  expect_poll "the theme browser maps" 1 layer_count vgs:overlay
  expect_poll "the theme browser holds the keyboard" true ipc smoke activeFocusIn overlay vgs.themes
  expect_poll "the theme browser reads its cards" true ipc smoke readDescendant overlay vgs.themes ThemeView loaded
  park_pointer
  take "theme-browser-$1-loaded"
  hover_card "the pointer rests on the theme browser's next card" && take "theme-browser-$1-hover"
  park_pointer
  type_keys zzqx || fail "typing the theme browser's empty filter failed"
  expect_poll "the theme browser's filter matches no card" 0 theme_view_count
  take "theme-browser-$1-empty"
  type_keys -k Escape || fail "clearing the theme browser's filter failed"
  type_keys mismatch || fail "typing the refused package's name failed"
  expect_poll "the theme browser selects the refused package" '"mismatch"' ipc smoke readDescendant overlay vgs.themes ThemeView selectedName
  type_keys -k Return || fail "Enter on the refused package failed"
  expect_poll "the theme browser names the refused package's problem" True theme_view_problem
  take "theme-browser-$1-failure"
  # A new open starts with no filter and no problem line.
  expect "the theme browser hides before the catalog shot" ok ipc shell hide overlay vgs.themes
  expect_poll "the theme browser is gone before the catalog shot" 0 layer_count vgs:overlay
  expect "the theme browser opens for the catalog shot" ok ipc shell summon overlay vgs.themes '{"view":"themes"}'
  expect_poll "the theme browser reads its cards for the catalog shot" true ipc smoke readDescendant overlay vgs.themes ThemeView loaded
  type_keys "$theme_card" || fail "typing the theme-browser card failed"
  expect_poll "the theme browser selects $theme_card" "\"$theme_card\"" ipc smoke readDescendant overlay vgs.themes ThemeView selectedName
  if wait_preview_cached "$theme_card"; then
    ok "the selected catalog preview is cached"
    preview_path="$(preview_path_of "$theme_card")"
    expect_poll "the selected catalog preview image is ready" ready card_image "$preview_path"
    take "theme-browser-$1-catalog-$theme_card-sharpened"
  else
    expect_poll "the selected catalog image is ready" True selected_ready
    take "theme-browser-$1-catalog-$theme_card"
  fi
  # Enter installs and applies the catalog card, whose wallpapers are not
  # downloaded, so the view offers them; Not now declines, and vgs and
  # the mode's theme are applied again before the installed shot.
  type_keys -k Return || fail "Enter on the catalog theme-browser card failed"
  expect_poll "the theme browser offers $theme_card's wallpapers" "\"$theme_card\"" theme_view_offer
  park_pointer
  take "theme-browser-$1-download"
  click_item overlay vgs.themes Button "Not now" || fail "the click on Not now failed"
  expect_poll "Not now declines the offer" null theme_view_offer
  park_pointer
  expect "the theme browser hides before the installed shot" ok ipc shell hide overlay vgs.themes
  expect_poll "the theme browser is gone before the installed shot" 0 layer_count vgs:overlay
  themes_restore "$1" "the theme browser's install"
  rm -rf -- "${home:?}/.config/vgs/themes/${theme_card:?}"
  mkdir -p -- "$home/.config/vgs/themes/$theme_card/backgrounds"
  cp -- "$repo/themes/catalog/$theme_card/theme.json" "$home/.config/vgs/themes/$theme_card/theme.json"
  [[ ! -f $repo/themes/catalog/$theme_card/terminal.json ]] || cp -- "$repo/themes/catalog/$theme_card/terminal.json" "$home/.config/vgs/themes/$theme_card/terminal.json"
  "$imagemagick" "$repo/themes/catalog/thumbnails/$theme_card.jpg" -resize 2560x1440\! "$home/.config/vgs/themes/$theme_card/backgrounds/preview.jpg"
  expect "the theme browser opens for the installed shot" ok ipc shell summon overlay vgs.themes '{"view":"themes"}'
  expect_poll "the installed theme browser reads its cards" true ipc smoke readDescendant overlay vgs.themes ThemeView loaded
  type_keys "$theme_card" || fail "typing the installed theme-browser card failed"
  expect_poll "the theme browser selects installed $theme_card" "\"$theme_card\"" ipc smoke readDescendant overlay vgs.themes ThemeView selectedName
  expect_poll "the installed theme browser image is ready" True selected_ready
  take "theme-browser-$1-installed-$theme_card"
  expect "the theme browser hides" ok ipc shell hide overlay vgs.themes
  expect_poll "the theme browser is gone" 0 layer_count vgs:overlay
  # The next mode's catalog shot must show the card as the catalog has it.
  rm -rf -- "${home:?}/.config/vgs/themes/${theme_card:?}" "${themes_mismatch:?}"
}

# The wallpaper browser over nord, applied with two images, and a second
# monitor, which gives the browser its monitor scope. The scene removes the
# monitor and restores the mode's theme, so a later scene starts from the
# run's own state.
wallpaper_output="VGS-SHOT"
# overlays_on OUTPUT: the live vgs:overlay layers on that output.
overlays_on() { hypr -j layers | python3 -c 'import json,sys; m=json.load(sys.stdin).get(sys.argv[1]); print(0 if m is None else sum(1 for lv in m["levels"].values() for l in lv if l["namespace"]=="vgs:overlay" and l["pid"]!=-1))' "$1"; }
scene_wallpaper-browser() { # MODE
  local theme_dir="$home/.config/vgs/themes/nord"
  # The runner's install writes the catalog marker, with no wallpapers, so
  # the Theme source ends on the download card.
  rm -rf -- "${theme_dir:?}"
  "${shell_env[@]}" "$repo/bin/vgsh" theme install nord >/dev/null || fail "nord installs for the wallpaper browser shot"
  mkdir -p -- "$theme_dir/backgrounds"
  cp -- "$checkout/themes/catalog/thumbnails/nord.jpg" "$theme_dir/backgrounds/a.jpg"
  cp -- "$checkout/themes/catalog/thumbnails/akane.jpg" "$theme_dir/backgrounds/b.jpg"
  "${shell_env[@]}" "$repo/bin/vgsh" theme apply nord >/dev/null || fail "nord applies for the wallpaper browser shot"
  expect_poll "nord is published for the wallpaper browser shot" nord ipc smoke themeName
  expect "the nested compositor adds a monitor for the wallpaper browser shot" ok hypr output create headless "$wallpaper_output"
  expect "vgs.themes enables for the wallpaper browser shot" ok ipc shell setPluginEnabled vgs.themes true
  expect_poll "vgs.themes is built for the wallpaper browser shot" True record_exists vgs.themes
  expect "the wallpaper browser opens" ok ipc shell summon overlay vgs.themes '{"view":"wallpapers"}'
  expect_poll "the wallpaper browser maps" 1 layer_count vgs:overlay
  expect_poll "the wallpaper browser holds the keyboard" true ipc smoke activeFocusIn overlay vgs.themes
  expect_poll "the wallpaper browser reads its cards" true ipc smoke readDescendant overlay vgs.themes WallpaperView loaded
  expect_poll "the wallpaper browser is on $SHOT_OUTPUT" 1 overlays_on "$SHOT_OUTPUT"
  expect_poll "the wallpaper browser shows its monitor scope" true ipc smoke readDescendant overlay vgs.themes WallpaperView scoped
  park_pointer
  take "wallpaper-browser-$1"
  hover_card "the pointer rests on the wallpaper browser's next card" && take "wallpaper-browser-$1-hover"
  park_pointer
  type_keys -k End || fail "End in the wallpaper browser failed"
  expect_poll "End selects the wallpaper download card" '"download"' wallpaper_selected_kind
  take "wallpaper-browser-$1-download"
  type_keys -M alt -k s -m alt || fail "Alt+S in the wallpaper browser failed"
  expect_poll "Alt+S shows every source's images" '"all"' ipc smoke readDescendant overlay vgs.themes WallpaperView source
  take "wallpaper-browser-$1-all"
  expect "the wallpaper browser hides" ok ipc shell hide overlay vgs.themes
  expect_poll "the wallpaper browser is gone" 0 layer_count vgs:overlay
  expect "the wallpaper browser shot's monitor is removed" ok hypr output remove "$wallpaper_output"
  # vgs has no backgrounds, so applying it removes nord's image.
  "${shell_env[@]}" "$repo/bin/vgsh" theme apply vgs >/dev/null || fail "vgs applies after the wallpaper browser shot"
  expect_poll "no background is drawn after the wallpaper browser shot" 0 layer_count vgs:background
  rm -rf -- "${theme_dir:?}"
  set_mode "$1"
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
# settled_box HOST ID TYPE TEXT: `same` when two readings of that item's box
# a frame apart agree, `moving` when they differ.
settled_box() {
  local first second
  first="$(ipc smoke itemGeometry "$@")" || return 1
  sleep 0.05
  second="$(ipc smoke itemGeometry "$@")" || return 1
  [[ $first == \[* && $first == "$second" ]] && echo same || echo moving
}
launcher_file_listed() { launcher_rows | python3 -c 'import json,sys; t=sys.stdin.read(); print(t.startswith("[") and any(r[0] == "file" and r[1] == sys.argv[1] for r in json.loads(t)))' "$1"; }
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
  hover_text "the pointer rests on the launcher's third row" overlay vgs.launcher QQuickText "$second" \
    && expect_poll "the pointer selects the third row" 2 ipc smoke readInstance overlay vgs.launcher selectedIndex \
    && take "launcher-$1-hover"
  # The file flyout: a right click on a file hit, then the pointer on one of
  # its entries, whose highlight draws over the flyout's glass.
  touch -- "$home/shots-flyout.txt"
  type_keys "f:shots-flyout" || fail "typing a file search failed"
  expect_poll "the file search lists the planted file" True launcher_file_listed shots-flyout.txt
  if file_at="$(centre_of "$(ipc smoke itemGeometry overlay vgs.launcher QQuickText shots-flyout.txt)")" && [[ $file_at != none ]] && read -r fx fy <<<"$file_at" && hover "$fx" "$fy" && right_click "$fx" "$fy"; then
    # The flyout grows in from the click; its entries hold still once it has.
    expect_poll "the flyout has opened" same settled_box overlay vgs.launcher QQuickText "Copy path"
    hover_text "the pointer rests on the flyout's Copy path" overlay vgs.launcher QQuickText "Copy path" && take "launcher-$1-flyout"
  else
    fail "the right click on the planted file failed"
  fi
  park_pointer
  type_keys -k Escape -k Escape -k Escape || fail "sending Escape failed"
  expect_poll "the launcher closes" 0 layer_count vgs:overlay
}

notify() { # APP SUMMARY BODY ACTIONS HINTS: prints the id
  "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify "$1" 0 "" "$2" "$3" "$4" "$5" 30000 | python3 -c 'import re,sys; print(re.search(r"uint32 (\d+)", sys.stdin.read()).group(1))'
}
notes() { ipc vgs.notifications invoke "$1" "${2:-}"; }
card_hovered() { ipc smoke layerItems vgs.notifications NotificationCard summary,hovered | py_reply 'import json,sys; print(any(v["hovered"] for s, r, v in json.load(sys.stdin) if v["summary"] == sys.argv[1]))' "$1"; }
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
    expect_poll "the actionable toast reports the pointer" True card_hovered "New message"
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

# hover_widget LABEL ID: the pointer on the centre of bar widget ID,
# arriving by two motions.
hover_widget() {
  local at x y
  at="$(centre_of "$(ipc smoke instanceGeometry "$(bar_key)" "$2")")" || at=none
  if [[ $at == none ]]; then fail "$1: widget $2 has no box"; return 1; fi
  read -r x y <<<"$at"
  if ! hover "$((x - 6))" "$y" || ! hover "$x" "$y"; then fail "$1: the hover failed"; return 1; fi
}
themes_widget_placed() { [[ $(ipc smoke instanceGeometry "$(bar_key)" vgs.themes) == \[* ]] && echo placed || echo absent; }
tooltip_opened() { ipc smoke readDescendant "$(bar_key)" "$1" Tooltip opened; }
warden_detail_state() { ipc vgs.agent-warden invoke status '' | py_reply 'import json,sys; d=json.load(sys.stdin).get("detail"); print(d["state"] if d else "unpublished")'; }
# warden_status NAME STATE: the warden's status-NAME.json written fresh,
# read back as STATE, so a surface never shows the status gone stale.
warden_status() {
  warden_put "$1" 0 >/dev/null || fail "writing the warden's $1 status failed"
  expect_poll "the warden reads its $1 status as $2" "$2" warden_detail_state
}
# The pointer on each bar widget: the tooltip of each widget that declares
# one, open, and the hover of the themes widget and the launcher's, which
# declare none; then
# the bar at rest, which a run that starts with this scene has drawn since
# before its first shot.
scene_bar() { # MODE
  local id
  warden_status calm calm
  for id in vgs.agent-warden vgs.updates; do
    hover_widget "the pointer rests on $id" "$id" || continue
    expect_poll "the $id tooltip opens" true tooltip_opened "$id"
    take "bar-$1-tip-${id#vgs.}"
    park_pointer
    expect_poll "the $id tooltip closes" false tooltip_opened "$id"
  done
  hover_widget "the pointer rests on the themes widget" vgs.themes \
    && { [[ $themes_entry_type != BarItem ]] || expect_poll "the themes widget shows its hover" true ipc smoke readDescendant "$(bar_key)" vgs.themes BarItem hovered; } \
    && take "bar-$1-hover-themes"
  park_pointer
  hover_widget "the pointer rests on the launcher's widget" vgs.launcher \
    && { ! "$launcher_entry_item" || expect_poll "the launcher's widget shows its hover" true ipc smoke readDescendant "$(bar_key)" vgs.launcher BarItem hovered; } \
    && take "bar-$1-hover-launcher"
  park_pointer
  take "bar-$1"
}

# The Agent Warden panel opened from its shield over a calm status and then
# a problem one, and the updates flyout opened from its widget over the
# planted snapshot, with its System row expanded and then the pointer on
# a row. Nothing presses Refresh, so no check runs.
warden_panel_texts() { ipc smoke itemTexts panel vgs.agent-warden Panel; }
warden_panel_lines() { warden_panel_texts | py_reply 'import json,sys; print(sys.argv[1] in json.load(sys.stdin)[0])' "$shots_vsys_line"; }
updates_flyout() { [[ $(ipc smoke readInstance panel vgs.updates rows) != absent ]] && echo open || echo closed; }
updates_pending() { ipc vgs.updates invoke status '' | py_reply 'import json,sys; print(json.load(sys.stdin).get("pending"))'; }
updates_checking() { ipc vgs.updates invoke status '' | py_reply 'import json,sys; print(json.load(sys.stdin).get("checking"))'; }
scene_panels() { # MODE
  warden_status calm calm
  click_centre "$(bar_key)" vgs.agent-warden || fail "the click on the shield failed"
  expect_poll "the shield opens the warden's panel" True warden_panel_lines
  park_pointer
  take "panels-$1-warden-calm"
  warden_status holding-off problem
  take "panels-$1-warden-problem"
  hover_on "the pointer rests on the panel's Open vsys" panel vgs.agent-warden Button "Open vsys" && take "panels-$1-warden-hover"
  park_pointer
  expect "the warden's panel hides" ok ipc shell hide panel vgs.agent-warden
  expect_poll "the warden's panel is gone" absent warden_panel_texts
  warden_status calm calm
  click_centre "$(bar_key)" vgs.updates || fail "the click on the updates widget failed"
  expect_poll "the widget opens the updates flyout" open updates_flyout
  park_pointer
  take "panels-$1-updates"
  click_item panel vgs.updates ListItem System || fail "the click on the flyout's System row failed"
  park_pointer
  take "panels-$1-updates-open"
  hover_on "the pointer rests on the flyout's VGS row" panel vgs.updates ListItem VGS && take "panels-$1-updates-hover"
  park_pointer
  expect "the updates flyout hides" ok ipc shell hide panel vgs.updates
  expect_poll "the updates flyout is gone" closed updates_flyout
  expect "the flyout started no check" False updates_checking
  scene_themes_panel "$1"
}

# The themes panel opened from its widget over the shipped and catalog
# packages and a refused one: its top, the pointer on a row, its catalog
# scrolled into view, a click on the vgs row held behind a gate and the
# partial result the gate lets through. The stand-in runner answers every
# apply with that result, which changes no theme, polls the gate every
# 50 ms for at most 10 s and hands every other command to the real runner.
themes_mismatch="$home/.config/vgs/themes/mismatch"
themes_gate="$sandbox/shots-themes-gate"
themes_result='{"state":"partial","shell":"unchanged","targets":[{"name":"kitty","state":"failed","reason":"placeholder"}],"theme":"vgs","reason":null}'
themes_panel_listed() { ipc smoke readInstance panel vgs.themes catalogEntries | py_reply 'import json,sys; t=sys.stdin.read(); print(t.startswith("[") and len(json.loads(t)) > 0)'; }
themes_panel_shown() { [[ $(ipc smoke readInstance panel vgs.themes packages) != absent ]] && echo open || echo closed; }
themes_panel_last() { ipc smoke readInstance panel vgs.themes last | py_reply 'import json,sys; l=json.load(sys.stdin); print("applying" if l["applying"] else "result" if l["result"] else "none")'; }
themes_stand_in() {
  cp -p -- "$repo/bin/vgsh" "$repo/bin/vgsh.real" || return 1
  cat >"$repo/bin/vgsh.next" <<SH || return 1
#!/usr/bin/env bash
if [[ \${1:-} == theme && \${2:-} == apply ]]; then
  for _ in \$(seq 1 200); do [[ -e $(printf %q "$themes_gate") ]] && break; sleep 0.05; done
  printf '%s\n' $(printf %q "$themes_result")
  exit 3
fi
exec $(printf %q "$repo/bin/vgsh.real") "\$@"
SH
  chmod 755 -- "$repo/bin/vgsh.next" && mv -T -- "$repo/bin/vgsh.next" "$repo/bin/vgsh"
}
scene_themes_panel() { # MODE
  mkdir -p -- "$themes_mismatch"
  printf '%s\n' '{ "schemaVersion": 1, "name": "other", "tokens": {} }' >"$themes_mismatch/theme.json"
  click_centre "$(bar_key)" vgs.themes || fail "the click on the themes widget failed"
  expect_poll "the widget opens the themes panel" True themes_panel_listed
  park_pointer
  take "panels-$1-themes"
  hover_on "the pointer rests on the themes panel's vgs row" panel vgs.themes ListItem vgs && take "panels-$1-themes-hover"
  park_pointer
  ipc smoke scrollTo panel vgs.themes 100000 >/dev/null || fail "the themes panel did not scroll to its catalog"
  take "panels-$1-themes-catalog"
  ipc smoke scrollTo panel vgs.themes 0 >/dev/null || fail "the themes panel did not scroll to its top"
  rm -f -- "$themes_gate"
  themes_stand_in || fail "the themes panel's stand-in runner could not be written"
  click_item panel vgs.themes ListItem vgs || fail "the click on the themes panel's vgs row failed"
  expect_poll "the themes panel shows the held apply" applying themes_panel_last
  park_pointer
  take "panels-$1-themes-applying"
  touch -- "$themes_gate"
  expect_poll "the themes panel shows the partial result" result themes_panel_last
  take "panels-$1-themes-failure"
  mv -T -- "$repo/bin/vgsh.real" "$repo/bin/vgsh" || fail "the real runner could not be restored"
  rm -f -- "$themes_gate"
  expect "the themes panel hides" ok ipc shell hide panel vgs.themes
  expect_poll "the themes panel is gone" closed themes_panel_shown
  rm -rf -- "${themes_mismatch:?}"
}

# The Dev Tools window: its top, the pointer on an Install button, and one
# shot per page down its list, at most four.
devtools_shown() { [[ $(ipc smoke instanceGeometry window vgs.devtools) != absent ]] && echo shown || echo hidden; }
devtools_sections() { ipc smoke itemTexts window vgs.devtools SectionHeader | py_reply 'import json,sys; print(len(json.load(sys.stdin)) > 1)'; }
scene_devtools() { # MODE
  local page=1 y=0 at cy ch h
  expect "the Dev Tools window summons" ok ipc vgs.devtools invoke open ''
  expect_poll "the Dev Tools window is shown" shown devtools_shown
  expect_poll "the Dev Tools window draws its sections" True devtools_sections
  park_pointer
  take "devtools-$1-top"
  # The VGS row's Details button: the sandbox's install method is always
  # unknown, so it shows on the first page whatever the other scenes set up.
  hover_on "the pointer rests on the VGS row's $devtools_hover button" window vgs.devtools Button "$devtools_hover" "window:Dev Tools" && take "devtools-$1-hover"
  park_pointer
  while (( page <= 4 )); do
    at="$(ipc smoke scrollTo window vgs.devtools "$y")" || at=""
    if [[ $at != "["* ]]; then fail "the Dev Tools window did not scroll: ${at:-no reply}"; break; fi
    read -r cy ch h < <(python3 -c 'import json,sys; print(*(int(v) for v in json.loads(sys.argv[1])))' "$at")
    (( page == 1 )) || take "devtools-$1-p$page"
    (( cy + h < ch )) || break
    y=$(( cy + h - 40 )); page=$(( page + 1 ))
  done
  expect "the Dev Tools window hides" ok ipc shell hide window vgs.devtools
  expect_poll "the Dev Tools window is gone" hidden devtools_shown
}

# The core's requirement notice, raised by enabling the acme.needs
# fixture, which misses a command it needs; Escape closes it, and the
# fixture is disabled again so the next mode raises it anew.
notice_plugin() { notice_shown | py_reply 'import json,sys; s=json.load(sys.stdin); print(json.dumps(s[0] if s else None))'; }
scene_dialog() { # MODE
  expect "enabling acme.needs is allowed" ok ipc shell setPluginEnabled acme.needs true
  expect_poll "the notice shows for acme.needs" '"acme.needs"' notice_plugin
  expect_poll "the notice maps its surface" 1 layer_count vgs:notice
  park_pointer
  take "dialog-$1"
  type_keys -k Escape || fail "sending Escape to the notice failed"
  expect_poll "Escape closes the notice" 0 layer_count vgs:notice
  expect "disabling acme.needs is allowed" ok ipc shell setPluginEnabled acme.needs false
}

# Every surface class again on a monitor 480 by 720 logical pixels.
scene_narrow() { # MODE
  narrow_begin
  gallery_pages=2
  scene_bar "$1-narrow"
  scene_panels "$1-narrow"
  scene_devtools "$1-narrow"
  scene_dialog "$1-narrow"
  ! scene_ships lock || scene_lock "$1-narrow"
  scene_launcher "$1-narrow"
  scene_notifications "$1-narrow"
  scene_gallery "$1-narrow"
  gallery_pages=12
  narrow_end
}

lock_core() { ipc shell lent | py_reply 'import json,sys; l=json.load(sys.stdin)["lock"]; print(json.dumps([l["requested"], l["secure"], l["content"]]))'; }
lock_failures() { ipc vgs.lock invoke status '' | py_reply 'import json,sys; print(json.load(sys.stdin)["failures"])'; }
# lock_fail N: N wrong attempts through the service's own failure step,
# with no PAM.
lock_fail() {
  local i
  for ((i = 0; i < $1; i++)); do
    [[ $(ipc smoke invokeInstance service vgs.lock fail '') != no-function ]] || { fail "vgs.lock has no fail()"; return; }
  done
}
scene_lock() { # MODE
  local probe
  probe="$(plugin_enabled acme.probe)" || probe=unreadable
  [[ $probe != True ]] || expect "disabling the probe fixture, which holds lock, is allowed" ok ipc shell setPluginEnabled acme.probe false
  expect "enabling vgs.lock is allowed" ok ipc shell setPluginEnabled vgs.lock true
  expect_poll "vgs.lock is built" True record_exists vgs.lock
  expect "the lock answers ok" ok ipc vgs.lock invoke lock ''
  expect_poll "the lock is confirmed with the lock screen" '[true, true, true]' lock_core
  take "lock-$1"
  lock_fail 1
  expect_poll "one wrong attempt is shown" 1 lock_failures
  take "lock-$1-wrong"
  lock_fail 9
  expect_poll "ten wrong attempts are shown" 10 lock_failures
  take "lock-$1-pause"
  expect "the probe releases the lock" ok ipc smoke sessionUnlock
  expect_poll "the core holds no lock" '[false, false, true]' lock_core
  expect "disabling vgs.lock is allowed" ok ipc shell setPluginEnabled vgs.lock false
  expect_poll "vgs.lock is gone" False record_exists vgs.lock
  [[ $probe != True ]] || expect "re-enabling the probe fixture is allowed" ok ipc shell setPluginEnabled acme.probe true
}

# The vgs.polkit prompt, asking and after a failed attempt, over the
# probe's stand-in flow (polkitStandInOpen in scripts/smoke/Probe.qml): the
# plugin's own Prompt.qml in a stand-in of the summon host's overlay
# surface. vgs.polkit stays disabled and nothing is typed; the scene reads
# that no request went live, that the stand-in was never submitted and
# that no authentication helper ran while it was open, as rows/polkit.sh
# reads them (docs/architecture/lock-polkit.md § Validation).
polkit_flows() { ipc shell lent | py_reply 'import json,sys; print(json.load(sys.stdin)["polkitFlows"])'; }
scene_polkit() { # MODE
  local watch_log="$sandbox/shots-polkit-$1-auth.log"
  auth_watch_start "$watch_log"
  expect "vgs.polkit stays disabled for its prompt's shots" False plugin_enabled vgs.polkit
  expect "the stand-in prompt opens" ok ipc smoke polkitStandInOpen "$repo/shell/plugins/vgs.polkit/Prompt.qml"
  expect_poll "the stand-in prompt maps its surface" 1 layer_count vgs:overlay
  park_pointer
  take "polkit-$1"
  expect "the stand-in flow reads a failed attempt" ok ipc smoke polkitStandInFail
  take "polkit-$1-failed"
  expect "the prompt closes and cancels only the stand-in, which was never submitted" '{"submits":0,"cancels":1}' ipc smoke polkitStandInDrop
  expect_poll "the stand-in prompt's surface is gone" 0 layer_count vgs:overlay
  expect "no authentication request went live in this shell" 0 polkit_flows
  expect "no authentication helper runs under the shell" none auth_helpers "$shell_qs_pid"
  kill "$auth_watch_pid" 2>/dev/null || fail "stopping the helper watcher pid $auth_watch_pid failed"
  expect "while the prompt was open, the watcher saw no authentication helper" "" cat -- "$watch_log"
}

# The setup each scene needs, once each, in the order the scenes first
# need them: the bar draws the launcher's and the panels' widgets, and the
# narrow pass takes every other scene's surfaces again.
setups=()
need_setup() { local s; for s in "${setups[@]}"; do [[ $s == "$1" ]] && return 0; done; setups+=("$1"); }
for scene in "${scenes[@]}"; do
  case $scene in
    bar) need_setup launcher; need_setup panels; need_setup bar ;;
    narrow) for s in launcher panels bar devtools dialog notifications gallery; do need_setup "$s"; done
      ! scene_ships lock || need_setup lock ;;
    *) need_setup "$scene" ;;
  esac
done
# What vsys's summary reads as in the warden's panel: one warning, as
# rows/agent-warden.sh's stand-in answers.
shots_vsys_line='vsys sees one thing worth a look on this computer.'
for scene in "${setups[@]}"; do
  case $scene in
    gallery|manager|polkit|theme-browser|wallpaper-browser) ;;
    bar)
      # The gear, the Settings plugin's widget, and the themes widget: the
      # sandbox starts vgs.themes enabled and unplaced, and enabling a
      # plugin places its unplaced widget in its default section.
      expect "enabling vgs.settings is allowed" ok ipc shell setPluginEnabled vgs.settings true
      expect_poll "vgs.settings is built" True record_exists vgs.settings
      expect "disabling vgs.themes is allowed" ok ipc shell setPluginEnabled vgs.themes false
      expect "enabling vgs.themes places its widget" ok ipc shell setPluginEnabled vgs.themes true
      expect_poll "the themes widget is in the bar" placed themes_widget_placed ;;
    panels)
      # The warden reads a fresh status from its runtime dir, with a vsys
      # whose summary names one warning and a notify-send that sends
      # nothing; the updates service reads the planted snapshot, checked
      # now, so no check runs while it is younger than the interval.
      printf '#!/usr/bin/env bash\nexit 0\n' >"$shim/notify-send"
      cat >"$shim/vsys" <<'SH'
#!/usr/bin/env bash
[[ "$*" == "--once --summary" ]] || exit 0
printf '%s\n' '{"schema": "vsys.summary.v1", "time": 1, "verdict": [{"cause": "memory-high", "level": "warn", "subject": "/agents.slice"}], "meters": [], "errors": []}'
SH
      chmod 755 "$shim/notify-send" "$shim/vsys"
      mkdir -p -- "$warden_dir" "$home/.local/state/vgs/updates"
      warden_put calm 0 >/dev/null || fail "writing the warden's calm status failed"
      python3 - "$checkout/scripts/smoke/fixtures/updates-status.json" "$home/.local/state/vgs/updates/status.json" <<'PY2' || fail "planting the updates snapshot failed"
import json, sys, time
doc = json.load(open(sys.argv[1]))
now = int(time.time() * 1000)
doc["checkedAt"] = now
for source in doc["sources"]:
    source["checkedAt"] = now
json.dump(doc, open(sys.argv[2], "w"))
PY2
      expect "the panels' stand-ins are scanned" ok ipc shell rescanPlugins
      for id in vgs.agent-warden vgs.updates; do
        expect "enabling $id is allowed" ok ipc shell setPluginEnabled "$id" true
        expect_poll "$id is built" True record_exists "$id"
      done
      expect_poll "the updates service reads the planted snapshot" 6 updates_pending
      expect "the updates service runs no check" False updates_checking
      # The themes widget: the sandbox starts vgs.themes enabled and
      # unplaced, and enabling a plugin places its unplaced widget.
      expect "disabling vgs.themes is allowed" ok ipc shell setPluginEnabled vgs.themes false
      expect "enabling vgs.themes places its widget" ok ipc shell setPluginEnabled vgs.themes true
      expect_poll "the themes widget is in the bar" placed themes_widget_placed ;;
    devtools)
      devtools_stand_ins
      expect "the Dev Tools stand-ins are scanned" ok ipc shell rescanPlugins
      expect "enabling vgs.devtools is allowed" ok ipc shell setPluginEnabled vgs.devtools true
      expect_poll "vgs.devtools is built" True record_exists vgs.devtools ;;
    dialog)
      mkdir -p "$home/.config/vgs/plugins/acme.needs"
      cp -R -- "$fixtures/acme.needs/." "$home/.config/vgs/plugins/acme.needs/"
      expect "the needs fixture is scanned" ok ipc shell rescanPlugins
      expect_poll "the needs fixture is listed" True plugin_known acme.needs ;;
    lock)
      # The sleep hook and the idle watch stay off: no logind stand-in runs
      # here, and an idle lock would cover the other scenes.
      python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
path = sys.argv[1]
config = json.load(open(path))
rows = config.setdefault("plugins", [])
row = next((r for r in rows if r.get("id") == "vgs.lock"), None)
if row is None:
    row = {"id": "vgs.lock"}
    rows.append(row)
row.update({"lockBeforeSleep": False, "idleLockSeconds": 0})
with open(path + ".tmp", "w") as out:
    json.dump(config, out)
os.replace(path + ".tmp", path)
PY
      ;;
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
      # A tree with the setup steps of D058 holds globex's token absent, so
      # its line offers Connect.
      if "$has_setup_steps"; then globex_state=absent; else globex_state=locked; fi
      printf '%s\n' "slack:T0ACME present" "slack:T0GLOBEX $globex_state" "slack present" >"$shim/secret-tool.states"
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
      done
      if "$has_setup_steps"; then
        # The setup steps' pages: the status fixture, Automations over
        # stand-ins that answer lingering off and reach no systemd, and
        # Themes with the chromium target shipped, so a host with a
        # Chromium-family browser and no writer offers its install.
        mkdir -p "$home/.config/vgs/plugins/acme.status"
        cp -R -- "$fixtures/acme.status/." "$home/.config/vgs/plugins/acme.status/"
        printf '#!/usr/bin/env bash\necho no\n' >"$shim/loginctl"
        printf '#!/usr/bin/env bash\nexit 0\n' >"$shim/systemctl"
        chmod 755 "$shim/loginctl" "$shim/systemctl"
        cp -R -- "$checkout/themes/targets/chromium" "$repo/themes/targets/chromium"
        expect "the status fixture is scanned" ok ipc shell rescanPlugins
        expect_poll "the status fixture is listed" True plugin_known acme.status
        for id in acme.status vgs.automations; do
          expect "enabling $id is allowed" ok ipc shell setPluginEnabled "$id" true
          expect_poll "$id is built" True record_exists "$id"
        done
        expect "the themes plugin is disabled to read the shipped target" ok ipc shell setPluginEnabled vgs.themes false
        expect_poll "the themes service is gone" False record_exists vgs.themes
        expect "the themes plugin is enabled with the target shipped" ok ipc shell setPluginEnabled vgs.themes true
        expect_poll "the themes service is built" True record_exists vgs.themes
      fi ;;
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

# No scene may authenticate against the host user: harness.sh's sentinels
# log any call, and a logged one fails the run (rows/auth-sentinel.sh).
if [[ -s $auth_log ]]; then fail "a scene reached an authentication sentinel: $(tr '\n' ';' <"$auth_log")"; else ok "no scene reached an authentication sentinel"; fi
echo "sandbox-shots: dir=$SHOT_DIR shots=$(wc -l <"$SHOT_DIR/shots.tsv" 2>/dev/null || echo 0) failures=$failures hidden=$(awk -F '\t' '$5 == "hidden"' "$SHOT_DIR/shots.tsv" 2>/dev/null | wc -l)"
if [[ $failures -gt 0 && $failures -eq $undrawn ]]; then
  printf 'sandbox-shots: status=not-measured nested-window=not-drawn\n'
  exit 77
fi
[[ $failures -eq 0 ]] || exit 1
