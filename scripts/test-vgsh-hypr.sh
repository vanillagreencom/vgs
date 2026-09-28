#!/usr/bin/env bash
# Controls for `vgsh hypr`: wire and unwire keep or remove the line that
# loads the Hyprland layer in hyprland.lua, under a temporary HOME and
# XDG_CONFIG_HOME, and render asks a running shell through a stub qs. No row
# reads or writes the developer's own Hyprland configuration.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

# The stub answers `qs ipc ... call <target> <fn>` with STUB_REPLY and
# records its arguments in STUB_ARGS, as test-vgsh.sh's does.
cat >"$tmp/qs" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${STUB_ARGS:-/dev/null}"
printf '%s\n' "${STUB_REPLY:-ok}"
EOF
chmod +x "$tmp/qs"
rt_live="$tmp/rt-live"; mkdir -p "$rt_live"; printf '%s\n' "$$" >"$rt_live/vgsh.lock"

layer="$tmp/home/.local/state/vgs/hypr/vgs.lua"
line="pcall(dofile, \"$layer\")"
wired_first() { # LUA OWN_TEXT_FILE
  [[ "$(head -n 1 -- "$1")" == "$line" ]] && tail -n +2 -- "$1" | cmp -s - "$2"
}

# No hyprland.lua: wire refuses and creates nothing; unwire has nothing to
# remove.
cfg="$tmp/cfg-none"; mkdir -p "$cfg"
inst "wire with no hyprland.lua is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: hypr=wiring-file-absent path=$cfg/hypr/hyprland.lua" hypr wire
check "wire creates no hyprland.lua" test ! -e "$cfg/hypr"
inst "unwire with no hyprland.lua changes nothing" "$cfg" "$rt_empty" 0 "ok hypr=unchanged path=$cfg/hypr/hyprland.lua" "" hypr unwire
check "unwire creates no hyprland.lua" test ! -e "$cfg/hypr"

# A hyprland.lua takes the line first and keeps every other byte; a second
# wire, and a line the user moved lower, change nothing; the line inside a
# comment is no line.
cfg="$tmp/cfg-lua"; lua="$cfg/hypr/hyprland.lua"; mkdir -p "$cfg/hypr"
printf -- '-- mine: %s\nhl.config({ general = { border_size = 3 } })\n' "$line" >"$lua"; cp -- "$lua" "$tmp/own"
inst "wire keeps the line in hyprland.lua" "$cfg" "$rt_empty" 0 "ok hypr=wired path=$lua" "" hypr wire
check "the line goes first and every other byte stays" wired_first "$lua" "$tmp/own"
cp -- "$lua" "$tmp/wired"
inst "a second wire changes nothing" "$cfg" "$rt_empty" 0 "ok hypr=unchanged path=$lua" "" hypr wire
check "the second wire leaves the file byte for byte" cmp -s -- "$lua" "$tmp/wired"
{ tail -n +2 -- "$tmp/wired"; printf '%s\n' "$line"; } >"$lua"; cp -- "$lua" "$tmp/moved"
inst "a wire over a line the user moved changes nothing" "$cfg" "$rt_empty" 0 "ok hypr=unchanged path=$lua" "" hypr wire
check "the moved line stays where the user put it" cmp -s -- "$lua" "$tmp/moved"
printf '%s\n' "$line" >>"$lua"
inst "unwire removes the line" "$cfg" "$rt_empty" 0 "ok hypr=unwired path=$lua" "" hypr unwire
check "unwire removes every copy and leaves the file as it was before wire" cmp -s -- "$lua" "$tmp/own"
inst "a second unwire changes nothing" "$cfg" "$rt_empty" 0 "ok hypr=unchanged path=$lua" "" hypr unwire

# A symlinked hyprland.lua, as a dotfile manager keeps it: the file it names
# is edited with its mode, and the link stays a link.
cfg="$tmp/cfg-link"; mkdir -p "$cfg/hypr" "$tmp/dotfiles"
printf 'hl.config({})\n' >"$tmp/dotfiles/hyprland.lua"; chmod 600 -- "$tmp/dotfiles/hyprland.lua"; cp -- "$tmp/dotfiles/hyprland.lua" "$tmp/linked-own"
ln -s -- "$tmp/dotfiles/hyprland.lua" "$cfg/hypr/hyprland.lua"
inst "wire through a symlink" "$cfg" "$rt_empty" 0 "ok hypr=wired path=$cfg/hypr/hyprland.lua" "" hypr wire
check "the symlink stays a link to the same file" test "$(readlink -- "$cfg/hypr/hyprland.lua")" == "$tmp/dotfiles/hyprland.lua"
check "the linked file takes the line first" wired_first "$tmp/dotfiles/hyprland.lua" "$tmp/linked-own"
check "the linked file keeps its mode" test "$(stat -c %a -- "$tmp/dotfiles/hyprland.lua")" == 600

# Refusals: a hyprland.lua that cannot be read, a state directory no Lua
# string can hold, and bad invocations.
cfg="$tmp/cfg-dir"; mkdir -p "$cfg/hypr/hyprland.lua"
inst "an unreadable hyprland.lua is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: hypr=unreadable path=$cfg/hypr/hyprland.lua error=EISDIR" hypr wire
cfg="$tmp/cfg-lua"
saved_env=("${base_env[@]}")
base_env+=(XDG_STATE_HOME="$tmp/st\"ate")
inst "a state directory holding a quote is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: hypr=unquotable path=$tmp/st\"ate/vgs/hypr/vgs.lua" hypr wire
base_env=("${saved_env[@]}")
check "the refused wire leaves hyprland.lua" cmp -s -- "$lua" "$tmp/own"
inst "an unknown hypr subcommand is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: hypr-subcommand=frobnicate" hypr frobnicate
inst "a missing hypr subcommand is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: hypr-subcommand=missing" hypr
inst "an argument after wire is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=now" hypr wire now

# render asks the running shell, and needs one.
inst "render with no shell exits 69" "$cfg" "$rt_empty" 69 "" "vgsh: refused: shell=not-running lock=$rt_empty/vgsh.lock" hypr render
INST_REPLY=ok inst "render prints the shell's ok" "$cfg" "$rt_live" 0 "ok" "" hypr render
check "render calls the shell's renderHyprland" test "$(cat "$tmp/args")" == "ipc --pid $$ call shell renderHyprland"
INST_REPLY="refused: hyprland=pending" inst "a shell refusal is a refusal with exit 1" "$cfg" "$rt_live" 1 "" "vgsh: refused: hyprland=pending" hypr render

# Must-fail controls, each on a copy of the runner whose judge breaks one
# rule the rows above hold.
theme_tree
cfg="$tmp/cfg-control"; lua="$cfg/hypr/hyprland.lua"
tree_control creates bin/vgsh-hypr-judge 'editFile("hypr", file, false,' 'editFile("hypr", file, true,'
INST_BIN="$THEME_BIN" inst "the creating mutant wires with no hyprland.lua" "$cfg" "$rt_empty" 0 "$any_out" "" hypr wire
check "the creating mutant creates hyprland.lua" test -e "$lua"
rm -rf -- "${cfg:?}"; mkdir -p "$cfg/hypr"; cp -- "$tmp/own" "$lua"
tree_control unquoted bin/vgsh-hypr-judge 'if (/["\\\n\r]/.test(layer))' 'if (false)'
saved_env=("${base_env[@]}")
base_env+=(XDG_STATE_HOME="$tmp/st\"ate")
INST_BIN="$THEME_BIN" inst "the unquoted mutant wires a quoted state directory" "$cfg" "$rt_empty" 0 "$any_out" "" hypr wire
base_env=("${saved_env[@]}")
check "the unquoted mutant writes a line a Lua string cannot hold" grep -qF -- "$tmp/st\"ate" "$lua"
cp -- "$tmp/own" "$lua"
tree_control wires-on-unwire bin/vgsh-hypr-judge 'unwire: render.unwiredText' 'unwire: render.wiredText'
INST_BIN="$THEME_BIN" inst "the wiring mutant runs unwire" "$cfg" "$rt_empty" 0 "$any_out" "" hypr unwire
check "the wiring mutant adds the line unwire must remove" grep -qxF -- "$line" "$lua"
cp -- "$tmp/own" "$lua"
tree_control always-changed bin/vgsh-hypr-judge 'changed = typeof next === "string";' 'changed = true;'
INST_BIN="$THEME_BIN" inst "the always-changed mutant reports an unchanged unwire as a change" "$cfg" "$rt_empty" 0 "ok hypr=unwired path=$lua" "" hypr unwire
unset THEME_BIN

rows_done test-vgsh-hypr
