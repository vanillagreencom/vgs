#!/usr/bin/env bash
# The editor targets under themes/targets/, neovim and emacs, through
# `vgsh theme apply`: each renders its hand-written lines with its encoder,
# is skipped when its command is not on PATH, keeps its include line in the
# file its application reads, takes a package's curated file byte for byte
# and runs its reload hook. Every command is a stub on the rows' PATH under a
# temporary HOME and XDG_RUNTIME_DIR, so no row reaches an editor or the
# developer's session. The controls at the end apply a tree copy whose
# target.json lacks one rule and require the row's assertion to turn.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree emacs neovim
live="$state/theme"; client_args="$tmp/emacsclient-args"

# Detection never runs a command: nvim and emacs record a run and exit 1.
# emacsclient, the emacs hook, records its arguments one per line.
for stub in nvim emacs; do
  printf '#!/bin/sh\n: >"%s/ran-$(basename "$0")"\nexit 1\n' "$tmp" >"$stubs/$stub"
  chmod +x "$stubs/$stub"
done
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"%s"\n' "$client_args" >"$stubs/emacsclient"
chmod +x "$stubs/emacsclient"
with_stubs="$stubs:$theme_path"

# `dusk` and `nord` carry no terminal.json, so every slot is the shipped vgs
# slot: color0 #0b0b0b, color1 #f43f5e, color2 #b4c96f, color3 #ffb000.
# `curated` ships both editors' files, neovim's as Omarchy's packages do.
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#222222" } } }'
theme_pkg "$tree/themes/curated" '{ "schemaVersion": 1, "name": "curated", "tokens": {} }'
mkdir -p "$tree/themes/curated/targets"
printf 'return {\n\t{ "folke/tokyonight.nvim", priority = 1000 },\n\t{ "LazyVim/LazyVim", opts = { colorscheme = "tokyonight-night" } },\n}\n' >"$tree/themes/curated/targets/neovim.lua"
printf ';; curated\n(deftheme vgs)\n(provide-theme (quote vgs))\n' >"$tree/themes/curated/targets/emacs.el"

cfg="$tmp/cfg-editors"; mkdir -p "$cfg/vgs"
nvim_file="$cfg/nvim/lua/plugins/vgs-theme.lua"
result() { # EMACS_STATE EMACS_REASON NEOVIM_STATE NEOVIM_REASON THEME
  printf '{"state":"applied","shell":"applied","targets":[{"name":"emacs","state":"%s","reason":%s,"dropped":[]},{"name":"neovim","state":"%s","reason":%s,"dropped":[]}],"theme":"%s","reason":null}' "$@"
}
# Every quoted colour of FILE is `#rrggbb`, the one form both editors read.
colours_are_hex6() {
  local colours
  colours="$(grep -oE '"#[^"]*"' -- "$1")" || return 1
  ! grep -qvxE '"#[0-9a-f]{6}"' <<<"$colours"
}
file_is() { cmp -s -- "$1" <(printf '%s' "$2"); } # FILE TEXT
client_ran_with_hook() {
  file_is "$client_args" $'-a\ntrue\n--eval\n(when (custom-theme-enabled-p \'vgs) (load-theme \'vgs t))\n'
}

tinst "an apply with no editor on PATH skips both" "$cfg" "$rt_empty" 0 "$(result skipped '"not-detected"' skipped '"not-detected"' dusk)" "" theme apply --json dusk
check "an undetected editor gets no configuration file" test ! -e "$cfg/emacs" -a ! -e "$cfg/nvim"
check "an undetected emacs runs no hook" test ! -e "$client_args"

# emacs creates its theme file; neovim waits for the user's spec file.
THEME_PATH="$with_stubs" tinst "emacs lands and neovim without its spec file is skipped" "$cfg" "$rt_empty" 0 "$(result written null skipped '"wiring-file-absent"' nord)" "" theme apply --json nord
check "emacs's theme file is created holding the include line" file_is "$cfg/emacs/vgs-theme.el" "(load \"$live/emacs.el\" nil t)"$'\n'
check "emacs takes the accent as #rrggbb" grep -qxF " '(cursor ((t (:background \"#222222\"))))" "$live/emacs.el"
check "emacs takes the text and background tokens" grep -qxF " '(default ((t (:foreground \"#d7d7d9\" :background \"#000000\"))))" "$live/emacs.el"
check "emacs takes the shipped slots" grep -qxF " '(ansi-color-red ((t (:foreground \"#f43f5e\" :background \"#f43f5e\"))))" "$live/emacs.el"
check "every emacs colour is #rrggbb" colours_are_hex6 "$live/emacs.el"
check "the emacs hook re-loads an enabled vgs theme and tolerates no server" client_ran_with_hook
check "a skipped neovim creates no file" test ! -e "$cfg/nvim"

mkdir -p "$(dirname -- "$nvim_file")"; printf 'return {}\n' >"$nvim_file"
rm -f -- "$client_args"
THEME_PATH="$with_stubs" tinst "neovim lands once its spec file stands" "$cfg" "$rt_empty" 0 "$(result written null written null dusk)" "" theme apply --json dusk
check "the spec file returns the rendered spec ahead of its own" file_is "$nvim_file" "do return dofile(\"$live/neovim.lua\") end"$'\nreturn {}\n'
check "neovim takes the text and background tokens" grep -qxF '  hl("Normal", { fg = "#d7d7d9", bg = "#000000" })' "$live/neovim.lua"
check "neovim takes the accent as #rrggbb" grep -qxF '  hl("Special", { fg = "#111111" })' "$live/neovim.lua"
check "neovim takes the shipped slots" grep -qxF '    "#0b0b0b", "#f43f5e", "#b4c96f", "#ffb000",' "$live/neovim.lua"
check "every neovim colour is #rrggbb" colours_are_hex6 "$live/neovim.lua"
check "emacs's changed bytes run its hook again" client_ran_with_hook

THEME_PATH="$with_stubs" tinst "a package's curated editor files land" "$cfg" "$rt_empty" 0 "$(result written null written null curated)" "" theme apply --json curated
check "neovim takes the curated spec byte for byte" cmp -s -- "$tree/themes/curated/targets/neovim.lua" "$live/neovim.lua"
check "emacs takes the curated theme byte for byte" cmp -s -- "$tree/themes/curated/targets/emacs.el" "$live/emacs.el"

printf '{ "disabledTargets": ["neovim"] }\n' >"$cfg/vgs/shell.json"
THEME_PATH="$with_stubs" tinst "a disabled neovim" "$cfg" "$rt_empty" 0 "$(result written null skipped '"disabled"' dusk)" "" theme apply --json dusk
check "disabling neovim leaves the user's spec file as it was" file_is "$nvim_file" $'return {}\n'
check "a disabled neovim's file leaves theme/" test ! -e "$live/neovim.lua"
check "detection ran neither editor" test ! -e "$tmp/ran-nvim" -a ! -e "$tmp/ran-emacs"

# Controls: each mutant target.json drops one rule, and the assertion that
# pins it must turn. The rows above use the same assertions.
control_cfg() { cfg="$tmp/cfg-$1"; mkdir -p "$cfg/vgs"; rm -f -- "$client_args"; }
tree_control neovim-encoder themes/targets/neovim/target.json '"encoder": "hex6"' '"encoder": "hex8"'
control_cfg neovim-encoder; mkdir -p "$cfg/nvim/lua/plugins"; printf 'return {}\n' >"$cfg/nvim/lua/plugins/vgs-theme.lua"
THEME_PATH="$with_stubs" tinst "the neovim hex8 mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the neovim hex8 mutant's colours are not #rrggbb" test "$(colours_are_hex6 "$live/neovim.lua"; echo $?)" == 1
tree_control emacs-encoder themes/targets/emacs/target.json '"encoder": "hex6"' '"encoder": "hex8"'
control_cfg emacs-encoder
THEME_PATH="$with_stubs" tinst "the emacs hex8 mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the emacs hex8 mutant's colours are not #rrggbb" test "$(colours_are_hex6 "$live/emacs.el"; echo $?)" == 1
tree_control emacs-reload themes/targets/emacs/target.json '"-a", "true", ' ''
control_cfg emacs-reload
THEME_PATH="$with_stubs" tinst "the serverless-hook mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "the serverless-hook mutant's hook is not the pinned argv" test "$(client_ran_with_hook; echo $?)" == 1
tree_control neovim-create themes/targets/neovim/target.json '"create": false' '"create": true'
control_cfg neovim-create
THEME_PATH="$with_stubs" tinst "the creating mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the creating mutant writes a spec file the user never made" test -e "$cfg/nvim"
unset THEME_BIN

rows_done test-vgsh-editors
