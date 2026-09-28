#!/usr/bin/env bash
# Controls for the shipped Hyprland target, themes/targets/hyprland: the
# file `vgsh theme apply` renders, the source line it keeps in
# hyprland.conf and the reload hook it runs. hyprctl is a stub on the rows'
# PATH that records its arguments and the instance signature it was
# handed, under a temporary HOME and XDG_RUNTIME_DIR, so no row reaches a
# running Hyprland.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree
runs="$tmp/hyprctl-runs"; pending="$state/reload-pending.json"; live="$state/theme"
# The stub exits with the status $tmp/hyprctl-exit holds, 0 when absent.
cat >"$stubs/hyprctl" <<EOF
#!/bin/sh
printf '%s sig=%s\n' "\$*" "\${HYPRLAND_INSTANCE_SIGNATURE:-none}" >>"$runs"
st=0
[ -f "$tmp/hyprctl-exit" ] && read -r st <"$tmp/hyprctl-exit"
exit "\$st"
EOF
chmod +x "$stubs/hyprctl"
export THEME_PATH="$stubs:$theme_path"
# The signature a Hyprland session exports; the hook names no instance of
# its own, so the stub must receive this one.
base_env+=(HYPRLAND_INSTANCE_SIGNATURE=vgs-rows-instance)

theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#112233", "background": "#0a0b0c" } } }'
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#445566" } } }'
fresh() { : >"$runs"; }
ran() { [[ "$(cat "$runs")" == "$1" ]]; }
no_pending() { [[ ! -e $pending ]]; }
# apply_json NAME WANT_EXIT WANT_FIRST_STDERR PACKAGE: an apply with --json,
# its result line kept in $tmp/apply.json.
apply_json() {
  tinst "$1" "$cfg" "$rt_empty" "$2" "$any_out" "$3" theme apply --json "$4"
  tail -n 1 "$tmp/out" >"$tmp/apply.json"
}
# result_is STATE SHELL HYPRLAND_STATE HYPRLAND_REASON: the kept result's
# state, shell and hyprland entry; every other shipped target is undetected.
result_is() {
  json_is "$tmp/apply.json" 'd["state"] == "'"$1"'" and d["shell"] == "'"$2"'" and [t for t in d["targets"] if t["name"] == "hyprland"] == [{"name": "hyprland", "state": "'"$3"'", "reason": '"$4"'}] and all(t["state"] == "skipped" for t in d["targets"] if t["name"] != "hyprland")'
}
source_first() { # CONF OWN_TEXT_FILE
  [[ "$(head -n 1 -- "$1")" == "source = $live/hyprland.conf" ]] && tail -n +2 -- "$1" | cmp -s - "$2"
}
reload_line="reload sig=vgs-rows-instance"

# A session with no hyprland.conf, as one configured by hyprland.lua, is
# skipped: no file is created and no hook runs.
cfg="$tmp/cfg-lua"; mkdir -p "$cfg/vgs"; fresh
apply_json "an apply with no hyprland.conf succeeds" 0 "" dusk
check "an apply with no hyprland.conf skips the target" result_is applied applied skipped '"wiring-file-absent"'
check "no hyprland.conf is created" test ! -e "$cfg/hypr"
check "a skipped target lands no file" test ! -e "$live/hyprland.conf"
check "a skipped target runs no hook" ran ""

# A session whose hyprland.conf exists takes the source line first, the
# rendered file and one hyprctl reload.
cfg="$tmp/cfg-hypr"; conf="$cfg/hypr/hyprland.conf"; mkdir -p "$cfg/vgs" "$cfg/hypr"
printf '# mine\ngeneral {\n    border_size = 3\n}\n' >"$conf"; cp -- "$conf" "$tmp/conf-own"; fresh
apply_json "an apply with a hyprland.conf succeeds" 0 "" dusk
check "an apply with a hyprland.conf writes the target" result_is applied applied written None
check "the accent is written with the hyprland encoder" grep -qxF -- '$vgs_accent = rgba(112233ff)' "$live/hyprland.conf"
check "the background is written with the hyprland encoder" grep -qxF -- '$vgs_background = rgba(0a0b0cff)' "$live/hyprland.conf"
check "the active border takes the accent" grep -qxF -- '    col.active_border = $vgs_accent' "$live/hyprland.conf"
check "the source line goes first and the file's own text is kept" source_first "$conf" "$tmp/conf-own"
check "the hook is one hyprctl reload naming no instance, with the session's signature" ran "$reload_line"
check "a hook that exits 0 leaves nothing pending" no_pending
fresh
apply_json "an apply of unchanged bytes succeeds" 0 "" dusk
check "unchanged Hyprland bytes are unchanged" result_is unchanged unchanged unchanged None
check "unchanged bytes run no hook" ran ""

# hyprctl fails when no Hyprland answers: the target stays pending until a
# reload with Hyprland up runs it again.
printf '1\n' >"$tmp/hyprctl-exit"; fresh
apply_json "an apply whose hyprctl fails is partial with exit 3" 3 "vgsh: refused: target=hyprland reason=reload-failed command=hyprctl status=1" nord
check "a failing hyprctl leaves the target reload-pending" result_is partial applied reload-pending '"reload-failed"'
check "the failed hook ran once" ran "$reload_line"
check "the failed reload is pending" test "$(cat "$pending")" == '{"schemaVersion":1,"targets":["hyprland"]}'
rm -- "$tmp/hyprctl-exit"; fresh
tinst "a reload runs hyprctl reload again" "$cfg" "$rt_empty" 0 '{"state":"reloaded","targets":[{"name":"hyprland","state":"reloaded","reason":null}],"reason":null}' "" theme reload --json
check "the reload ran the hook once" ran "$reload_line"
check "a successful reload clears the pending state" no_pending

# Must-fail controls, each on a copy of the tree whose target.json breaks
# one rule the rows above hold.
tree_control creates themes/targets/hyprland/target.json '"create": false' '"create": true'
cfg="$tmp/cfg-lua-control"; mkdir -p "$cfg/vgs"
tinst "the creating mutant applies with no hyprland.conf" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the creating mutant creates hyprland.conf" test -e "$cfg/hypr/hyprland.conf"
cfg="$tmp/cfg-hypr"
tree_control no-reload themes/targets/hyprland/target.json '"reload": { "command": ["hyprctl", "reload"], "timeoutMs": 5000 }' '"reload": null'
fresh
tinst "the hookless mutant applies changed bytes" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "the hookless mutant runs no hook" ran ""
tree_control hex8 themes/targets/hyprland/target.json '"encoder": "hyprland"' '"encoder": "hex8"'
tinst "the hex8 mutant applies changed bytes" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the hex8 mutant writes the accent without rgba()" grep -qxF -- '$vgs_accent = 112233ff' "$live/hyprland.conf"
unset THEME_BIN

rows_done test-vgsh-hyprland
