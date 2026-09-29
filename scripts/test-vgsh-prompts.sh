#!/usr/bin/env bash
# Controls for the questions bin/vgsh asks on a terminal before it adds or
# removes: the git URL `plugin add` and `theme add` ask for with gum input
# when the command line names none, the prompt the core floating TUIs
# `core/plugin-add` and `core/theme-add` show, and the `remove <id>? [y/N]`
# question `plugin remove` asks before it deletes, which the Settings
# window's Remove button shows in its floating TUI. Each terminal row runs
# vgsh on a pseudo-terminal script(1) opens, with the answer typed on it.
# gum is a stub ahead of the host's PATH that records its argv and prints
# the line typed on the terminal, or exits 130 on `cancel`; a row that
# needs no gum runs on a PATH without one. Without script(1) the suite
# exits 77.
#
# Each control runs every row against a copy of the tree with one rule
# removed from bin/vgsh, and the rows must fail against it.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
command -v script >/dev/null || { echo "test-vgsh-prompts: status=not-measured missing=script"; exit 77; }

theme_tree
stubs="$tmp/prompt-stubs"; mkdir -p "$stubs"
gum_args="$tmp/gum-args"
cat >"$stubs/gum" <<EOF
#!/bin/sh
case "\${1:-}" in
  input)
    printf '%s\n' "\$@" >"$gum_args.input"
    IFS= read -r line </dev/tty
    [ "\$line" = cancel ] && exit 130
    printf '%s\n' "\$line"
    ;;
  confirm)
    printf '%s\n' "\$@" >"$gum_args.confirm"
    IFS= read -r line </dev/tty
    [ "\$line" = cancel ] && exit 130
    case "\$line" in y|Y|yes|YES|Yes) exit 0 ;; *) exit 1 ;; esac
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$stubs/gum"
prompt_path="$stubs:$base_path"
# The PATH without gum: only what bin/vgsh runs before it looks gum up, and
# script(1), which on_terminal starts through it.
bare_path="$tmp/bare-path"; mkdir -p "$bare_path"
for tool in bash readlink dirname script; do
  found="$(command -v "$tool")" || { echo "test-vgsh-prompts: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$(readlink -f -- "$found")" "$bare_path/$tool"
done
check "the rows' gum is the stub and the bare PATH has none" test "$(PATH="$prompt_path" command -v gum):$(PATH="$bare_path" command -v gum || echo none)" == "$stubs/gum:none"

source_repo probe "$(manifest acme.probe 0.1.0)"
theme_source moss "$(doc moss)"

# term BIN ANSWER ARGS...: vgsh BIN on a terminal with the stub gum ahead.
term() { local bin="$1"; shift; INST_BIN="$bin" INST_PATH="$prompt_path" on_terminal "$@"; }
out_has() { tr -d '\r' <"$tmp/out" | grep -qxF -- "$1"; }
out_holds() { tr -d '\r' <"$tmp/out" | grep -qF -- "$1"; }
gum_asked() { [[ "$(cat -- "$gum_args.input" 2>/dev/null)" == "$(printf '%s\n' input --prompt "$1" --placeholder https://)" ]]; }
gum_confirmed() { [[ "$(cat -- "$gum_args.confirm" 2>/dev/null)" == "$(printf '%s\n' confirm --default=false -- "$1")" ]]; }
installed() { [[ -f $cfg/vgs/plugins/acme.probe/manifest.json ]]; }
theme_file() { [[ -f $cfg/vgs/theme.json ]]; }
# A fresh configuration directory per row; add_probe installs the fixture
# into it, the URL on the command line. The question and what follows it
# share a line: the terminal echoes the typed answer before the question
# is asked, so no newline follows the question.
fresh_cfg() { config_count=$((config_count + 1)); cfg="$tmp/cfg-$config_count"; rm -f -- "$gum_args".*; }
add_probe() { INST_BIN="$1" inst "the fixture installs for a remove row" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git" >/dev/null; }
add_moss() { "${base_env[@]}" PATH="$prompt_path" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="$rt_empty" "$1" theme add "$tmp/tsrc/moss.git" >/dev/null 2>"$tmp/err" </dev/null; }
run_theme_add_arg() {
  local bin="$1" status=0 out
  set +e
  out="$("${base_env[@]}" PATH="$prompt_path" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="$rt_empty" "$bin" theme add "$tmp/tsrc/moss.git" 2>"$tmp/err" </dev/null)"
  status=$?
  set -e
  printf '%s\n' "$out" >"$tmp/out"
  return "$status"
}

row_plugin_url() {
  fresh_cfg
  term "$1" "  $tmp/src/probe.git  " plugin add
  [[ $term_status == 0 ]] && gum_asked "Git URL of the plugin: " && out_holds "ok added=acme.probe path=$cfg/vgs/plugins/acme.probe" && installed
}
row_theme_url() {
  fresh_cfg
  term "$1" "$tmp/tsrc/moss.git"$'\n'"n" theme add
  [[ $term_status == 0 ]] \
    && gum_asked "Git URL of the theme: " \
    && gum_confirmed "Apply theme moss now?" \
    && out_has "ok added=moss path=$cfg/vgs/themes/moss" \
    && out_has "apply: vgsh theme apply moss" \
    && ! out_holds "ok theme=moss" \
    && ! theme_file
}
row_theme_apply_yes() {
  fresh_cfg
  term "$1" "$tmp/tsrc/moss.git"$'\n'"y" theme add
  [[ $term_status == 0 ]] \
    && gum_asked "Git URL of the theme: " \
    && gum_confirmed "Apply theme moss now?" \
    && out_has "ok added=moss path=$cfg/vgs/themes/moss" \
    && out_has "apply: vgsh theme apply moss" \
    && out_has "ok theme=moss state=applied shell=applied" \
    && theme_file
}
row_theme_arg_no_offer() {
  fresh_cfg
  run_theme_add_arg "$1" || return 1
  out_has "ok added=moss path=$cfg/vgs/themes/moss" \
    && [[ ! -e $gum_args.confirm ]] \
    && ! out_holds "apply:" \
    && ! theme_file
}
row_theme_refused_no_offer() {
  fresh_cfg
  add_moss "$1" || return 1
  term "$1" "$tmp/tsrc/moss.git"$'\n'"y" theme add
  [[ $term_status == 1 ]] \
    && gum_asked "Git URL of the theme: " \
    && [[ ! -e $gum_args.confirm ]] \
    && out_has "vgsh: refused: theme=moss reason=exists path=$cfg/vgs/themes/moss" \
    && ! out_holds "apply:" \
    && ! theme_file
}
row_empty_url() {
  fresh_cfg
  term "$1" "   " plugin add
  [[ $term_status == 2 ]] && out_has "vgsh: refused: url=missing" && [[ ! -e $cfg/vgs/plugins ]] || return 1
  term "$1" "" theme add
  [[ $term_status == 2 ]] && out_has "vgsh: refused: url=missing" && [[ ! -e $cfg/vgs/themes ]]
}
row_cancelled_url() {
  fresh_cfg
  term "$1" cancel plugin add
  [[ $term_status == 1 ]] && out_has "vgsh: refused: cancelled=url"
}
row_gum_missing() {
  fresh_cfg
  INST_BIN="$1" INST_PATH="$bare_path" on_terminal "$tmp/src/probe.git" plugin add
  [[ $term_status == 1 ]] && out_has "vgsh: refused: gum=missing" && ! installed
}
row_remove_no_terminal() {
  fresh_cfg; add_probe "$1"
  INST_BIN="$1" inst "remove without a terminal" "$cfg" "$rt_empty" 1 "" "vgsh: refused: no-terminal=acme.probe" plugin remove acme.probe >/dev/null
  grep -qxF "vgsh: refused: no-terminal=acme.probe" "$tmp/err" && installed
}
row_remove_declined() {
  fresh_cfg; add_probe "$1"
  term "$1" n plugin remove acme.probe
  [[ $term_status == 1 ]] && out_holds "vgsh: remove acme.probe? [y/N] vgsh: refused: declined=acme.probe" && installed
}
row_remove_confirmed() {
  fresh_cfg; add_probe "$1"
  term "$1" y plugin remove acme.probe
  [[ $term_status == 0 ]] && out_holds "vgsh: remove acme.probe? [y/N] ok removed=acme.probe" && ! installed
}
row_remove_yes() {
  fresh_cfg; add_probe "$1"
  INST_BIN="$1" inst "remove --yes" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin remove --yes acme.probe >/dev/null
  has_line "ok removed=acme.probe" && ! installed
}

# rows: label | function. Each runs against the vgsh it is handed.
declare -a ROWS=(
  "plugin add without a url asks for one with gum and trims it|row_plugin_url"
  "theme add without a url asks for one with gum and declines apply on no|row_theme_url"
  "theme add applies the new package on an apply yes|row_theme_apply_yes"
  "theme add with a url keeps non-interactive add behaviour|row_theme_arg_no_offer"
  "a refused theme add offers no apply|row_theme_refused_no_offer"
  "an empty url refuses both adds with exit 2 and adds nothing|row_empty_url"
  "a cancelled prompt refuses add as cancelled|row_cancelled_url"
  "add refuses a terminal prompt without gum|row_gum_missing"
  "remove without a terminal refuses and keeps the plugin|row_remove_no_terminal"
  "remove declined on a terminal keeps the plugin|row_remove_declined"
  "remove confirmed on a terminal deletes the plugin|row_remove_confirmed"
  "remove --yes deletes the plugin without a question|row_remove_yes"
)
config_count=0
# run_rows BIN QUIET: every row through BIN; prints ok/FAIL lines unless
# QUIET and returns the number of rows that failed.
run_rows() {
  local bin="$1" quiet="$2" row name fn red=0 before="$failures"
  for row in "${ROWS[@]}"; do
    IFS='|' read -r name fn <<<"$row"
    if "$fn" "$bin"; then
      [[ $quiet == quiet ]] || ok "$name"
    else
      red=$((red + 1))
      [[ $quiet == quiet ]] || fail "$name: exit=${term_status:-} out=[$(tr -d '\r' <"$tmp/out" | tail -n 3)]"
    fi
  done
  # The inst calls inside a row count their own misses; a row's verdict is
  # its own.
  failures="$before"
  [[ $quiet == quiet ]] || failures=$((failures + red))
  return "$red"
}
run_rows "$tree/bin/vgsh" loud || true

# Usage: a second argument is refused before any question.
cfg="$tmp/cfg-usage"
tinst "plugin add refuses a second argument" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=x" plugin add "$tmp/src/probe.git" x
tinst "plugin remove refuses a second argument" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=x" plugin remove acme.probe x
tinst "plugin add without a url or a terminal is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: url=missing" plugin add

# controls: label, the text in bin/vgsh and its replacement, one control per
# three entries.
declare -a CONTROLS=(
  "plugin add asks for a missing url" '        if [[ -z $url ]]; then url="$(ask_url plugin)" || exit $?; fi' ''
  "theme add asks for a missing url" '        if [[ -z $arg && $sub == add ]]; then arg="$(ask_url theme)" || exit $?; prompted=1; fi' ''
  "prompted theme add offers the apply" '        if [[ $sub == add && $prompted == 1 ]]; then offer_theme_apply "$theme_added"; fi' ''
  "theme add with a url stays non-interactive" '        if [[ $sub == add && $prompted == 1 ]]; then offer_theme_apply "$theme_added"; fi' '        if [[ $sub == add ]]; then offer_theme_apply "$theme_added"; fi'
  "the apply offer runs apply on yes" '  "$self" theme apply "$name"' '  :'
  "the apply offer skips apply on no" '    1 | 130) return 0 ;;' '    1 | 130) ;;'
  "a refused theme add offers nothing" '  [[ -e $target || -L $target ]] && refuse 1 "theme=$name reason=exists path=$target"' '  [[ -e $target || -L $target ]] && { offer_theme_apply "$name"; refuse 1 "theme=$name reason=exists path=$target"; }'
  "the url loses its leading blanks" 'url="${url#"${url%%[![:space:]]*}"}"' ':'
  "the url loses its trailing blanks" 'url="${url%"${url##*[![:space:]]}"}"' ':'
  "an empty url refuses" '  [[ -n $url ]] || refuse 2 "url=missing"' '  [[ -n $url ]] || true'
  "a cancelled prompt is its own refusal" '    130) refuse 1 "cancelled=url" ;;' ''
  "the prompt needs gum" '  command -v gum >/dev/null || refuse 1 "gum=missing"' '  true || refuse 1 "gum=missing"'
  "remove asks before it deletes" '  confirm_change remove "$id" "$dir stays installed"' ''
  "remove takes --yes" '        if [[ ${1:-} == --yes ]]; then assume_yes=1; shift; fi' '        if [[ ${1:-} == --yes && $sub == update ]]; then assume_yes=1; shift; fi'
)
for ((i = 0; i < ${#CONTROLS[@]}; i += 3)); do
  label="${CONTROLS[i]}"
  tree_control "prompt-$((i / 3))" bin/vgsh "${CONTROLS[i + 1]}" "${CONTROLS[i + 2]}"
  if run_rows "$THEME_BIN" quiet; then fail "control: $label: the rows pass without the rule"; else ok "control: the rows fail without the rule: $label"; fi
  unset THEME_BIN
done

rows_done test-vgsh-prompts
