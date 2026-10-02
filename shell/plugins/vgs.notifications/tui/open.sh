#!/usr/bin/env bash
# The vgs.notifications `open` floating TUI: opens the file a notification's
# x-vgs-open hint names, when its x-vgs-click hint is `open`
# (docs/architecture/notification-hints.md). It runs $EDITOR on the file,
# split on white space so `code --wait` works, in this terminal, so a
# terminal editor has a window; with EDITOR unset or empty it hands the
# file to xdg-open. The path is absolute, so no editor reads it as an
# option.
#
#   open.sh <absolute path>
#
# Exits with the editor's or xdg-open's status. Refusals, one keyed line on
# stderr: `notifications: refused: tui=missing`, exit 2, outside the
# presenter; `notifications: refused: argument=<count>`, exit 2;
# `notifications: refused: path=<path> reason=relative`, exit 2;
# `notifications: refused: file=unreadable path=<path>`, exit 1;
# `notifications: refused: opener=missing`, exit 1, with EDITOR unset and
# no xdg-open. The TUI's presentation is `plain`, since the editor owns the
# window: a failure holds the window on vgs_tui_close_prompt, so the user
# reads it before it closes.
set -Eeuo pipefail

refuse() { # STATUS FIRST_LINE [ENGLISH...]
  local status="$1"
  printf 'notifications: refused: %s\n' "$2" >&2
  shift 2
  [[ $# -gt 0 ]] && printf '%s\n' "$@" >&2
  exit "$status"
}

[[ -n ${VGS_TUI_LIB:-} ]] || refuse 2 "tui=missing" "Open this file from its notification."
# shellcheck source=SCRIPTDIR/../../../../bin/lib/tui.sh
source "$VGS_TUI_LIB"
trap 'status=$?; [[ $status == 0 ]] || vgs_tui_close_prompt "$status"' EXIT
[[ $# -eq 1 ]] || refuse 2 "argument=$#" "The notification must name one file."
file="$1"
[[ $file == /* ]] || refuse 2 "path=$file reason=relative" "The notification must name a full file path."
[[ -f $file && -r $file ]] || refuse 1 "file=unreadable path=$file" "The file is missing or cannot be read."
if [[ -n ${EDITOR:-} ]]; then
  read -r -a editor <<<"$EDITOR"
  "${editor[@]}" "$file"
  exit
fi
command -v xdg-open >/dev/null || refuse 1 "opener=missing" "Open Notifications in Settings. Select Install under Requirements to add the file opener."
xdg-open "$file"
