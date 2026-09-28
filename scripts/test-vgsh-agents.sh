#!/usr/bin/env bash
# Controls for the agent CLI targets of `vgsh theme apply`: Claude Code,
# Codex, Gemini CLI, Hermes Agent, oh-my-pi, opencode and Pi. Each lands its
# file with the hex6 encoder, keeps its entry in the CLI's themes directory
# (Gemini keeps none) and sets each theme key its `select` names in the
# CLI's own settings file, every other byte of that file kept. Every detect
# command is a stub on the rows' PATH and opencode's reload probe reads stub
# process lists, under a temporary HOME, XDG_CONFIG_HOME and XDG_RUNTIME_DIR,
# so no row reaches a real CLI, a live settings file or the developer's
# session.
#
# No judge copy creates an absent settings file: two rules stand between the
# plan and a create, the plan's skip, whose control is below and whose row
# shows the file stays absent, and selectedText's refusal of an absent file,
# whose control is in scripts/test-theme-select.js.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
agents="claude codex gemini hermes omp opencode pi"
# shellcheck disable=SC2086
theme_tree $agents
live="$state/theme"; pending="$state/reload-pending.json"; home="$tmp/home"
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#222222" } } }'

# Each CLI is detected by a stub of its command, which records a run and
# exits 1, so detection never runs it. opencode's hook runs a real sh and
# id, with pgrep and ps stubs naming process shapes that do and do not mount
# the TUI theme handler.
hook_tools="$tmp/hook-tools"; mkdir -p "$hook_tools"
for tool in sh id; do
  tool_bin="$(command -v "$tool")" || { echo "test-vgsh-agents: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$hook_tools/$tool"
done
for stub in $agents; do
  printf '#!/bin/sh\n: >"%s/ran-$(basename "$0")"\nexit 1\n' "$tmp" >"$stubs/$stub"
  chmod +x "$stubs/$stub"
done
mkdir -p "$tmp/project" "$tmp/opencode-cwd/web"
opencode_pids=()
start_opencode_probe() { # LABEL [CWD]
  local cwd="${2:-$PWD}"
  ( cd "$cwd" && "$node_bin" -e "const fs = require('fs'); const label = process.argv[1]; const root = process.argv[2]; fs.writeFileSync(root + '/opencode-' + label + '-ready', 'ready'); process.on('SIGUSR2', () => { fs.writeFileSync(root + '/opencode-' + label + '-signaled', label); process.exit(0); }); setInterval(() => {}, 10000);" "$1" "$tmp" ) &
  printf -v "opencode_$1" '%s' "$!"
  opencode_pids+=("$!")
}
start_opencode_probe bare
start_opencode_probe serve
start_opencode_probe run
start_opencode_probe option_serve
start_opencode_probe web "$tmp/opencode-cwd"
start_opencode_probe attach
start_opencode_probe project
trap 'kill "${opencode_pids[@]}" 2>/dev/null || true; rm -rf -- "${tmp:?}"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -e $tmp/opencode-bare-ready && -e $tmp/opencode-serve-ready && -e $tmp/opencode-run-ready && -e $tmp/opencode-option_serve-ready && -e $tmp/opencode-web-ready && -e $tmp/opencode-attach-ready && -e $tmp/opencode-project-ready ]] && break
  sleep 0.1
done
printf '#!/bin/sh\nprintf "%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n"\n' "$opencode_bare" "$opencode_serve" "$opencode_run" "$opencode_option_serve" "$opencode_web" "$opencode_attach" "$opencode_project" >"$hook_tools/pgrep"
cat >"$hook_tools/ps" <<EOF
#!/bin/sh
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -p) pid="\$2"; shift 2;;
    *) shift;;
  esac
done
case "\$pid" in
  $opencode_bare) printf 'opencode\\n';;
  $opencode_serve) printf 'opencode serve\\n';;
  $opencode_run) printf 'opencode run\\n';;
  $opencode_option_serve) printf 'opencode --log-level INFO serve\\n';;
  $opencode_web) printf 'opencode web\\n';;
  $opencode_attach) printf 'opencode attach\\n';;
  $opencode_project) printf 'opencode $tmp/project\\n';;
  *) exit 1;;
esac
EOF
chmod +x "$hook_tools/pgrep" "$hook_tools/ps"
export THEME_PATH="$stubs:$hook_tools:$theme_path"

target_state() { # NAME: the target's state and reason in $tmp/apply.json
  python3 -c 'import json,sys; print(*[(t["state"], t["reason"]) for t in json.load(open(sys.argv[1]))["targets"] if t["name"] == sys.argv[2]][0])' "$tmp/apply.json" "$1"
}
apply_json() { # NAME WANT_EXIT PACKAGE [WANT_FIRST_STDERR]: apply with --json into $tmp/apply.json
  tinst "$1" "$cfg" "$rt_empty" "$2" "$any_out" "${4:-}" theme apply --json "$3"
  tail -n 1 "$tmp/out" >"$tmp/apply.json"
}
all_state() { # WANT: every agent target's "name state reason;", in name order
  local name got=""
  for name in $agents; do got+="$name $(target_state "$name");"; done
  [[ $got == "$1" ]]
}
links_to() { [[ -L $1 && "$(readlink -- "$1")" == "$2" ]]; } # PATH TARGET
regular_with() { [[ -f $1 && ! -L $1 && "$(cat -- "$1"; printf x)" == "$2"x ]]; } # PATH TEXT
same_file() { [[ -f $1 && ! -L $1 ]] && cmp -s -- "$1" "$2"; } # COPY SOURCE
has_text() { [[ "$(cat -- "$1"; printf x)" == "$2"x ]]; } # FILE TEXT: the file's bytes, trailing newlines included
stamp() { stat -L -c '%i %Y' -- "$@" | tr '\n' ' '; } # PATH...: each file's inode and modification time
entry_stamp() { stat -c '%i %Y' -- "$@" | tr '\n' ' '; } # PATH...
disable() { printf '{ "disabledTargets": [%s] }\n' "$1" >"$cfg/vgs/shell.json"; }

# The CLIs' own settings files, each holding keys of the user's beside the
# one apply sets. Codex's is a dotfile manager's link to an owner-only file.
cfg="$tmp/cfg-agents"; dotfiles="$tmp/dotfiles"
mkdir -p "$cfg/vgs" "$cfg/opencode" "$home/.claude" "$home/.codex" "$home/.gemini" "$home/.hermes" "$home/.omp/agent" "$home/.pi/agent" "$dotfiles"
claude_settings="$home/.claude/settings.json"; codex_config="$home/.codex/config.toml"; gemini_settings="$home/.gemini/settings.json"
hermes_config="$home/.hermes/config.yaml"; omp_config="$home/.omp/agent/config.yml"; opencode_tui="$cfg/opencode/tui.json"; pi_settings="$home/.pi/agent/settings.json"
claude_text=$'{\n  "model": "opus",\n  "permissions": { "allow": ["Bash(ls)"] }\n}\n'
claude_selected=$'{\n  "theme": "custom:vgs",\n  "model": "opus",\n  "permissions": { "allow": ["Bash(ls)"] }\n}\n'
codex_text=$'model = "o3"\n\n[tui]\nanimations = false\n\n[mcp_servers.docs]\ncommand = "docs"\n'
codex_selected=$'model = "o3"\n\n[tui]\ntheme = "vgs"\nanimations = false\n\n[mcp_servers.docs]\ncommand = "docs"\n'
gemini_text=$'{\n  "ui": {\n    "hideBanner": true\n  }\n}\n'
gemini_selected=$'{\n  "ui": {\n    "theme": "'"$live"$'/gemini.json",\n    "hideBanner": true\n  }\n}\n'
hermes_text=$'model: hermes-4\ndisplay:\n  compact: true  # mine\n'
hermes_selected=$'model: hermes-4\ndisplay:\n  skin: vgs\n  compact: true  # mine\n'
# oh-my-pi keeps one theme per terminal background, and both slots take vgs.
omp_text=$'theme:\n  dark: titanium\n  light: light\nsymbolPreset: nerd  # mine\n'
omp_selected=$'theme:\n  dark: vgs\n  light: vgs\nsymbolPreset: nerd  # mine\n'
opencode_text=$'{\n  "$schema": "https://opencode.ai/tui.json"\n}\n'
opencode_selected=$'{\n  "theme": "vgs",\n  "$schema": "https://opencode.ai/tui.json"\n}\n'
pi_text=$'{"defaultModel":"x"}'
pi_selected=$'{"theme": "vgs", "defaultModel":"x"}'
settings=("$claude_settings" "$codex_config" "$gemini_settings" "$hermes_config" "$omp_config" "$opencode_tui" "$pi_settings")
seed() { # each settings file as the user left it; a link a row left in its place goes first
  rm -f -- "${settings[@]}"
  printf '%s' "$claude_text" >"$claude_settings"; chmod 640 -- "$claude_settings"
  printf '%s' "$codex_text" >"$dotfiles/codex.toml"; chmod 600 -- "$dotfiles/codex.toml"
  ln -sfn -- "$dotfiles/codex.toml" "$codex_config"
  printf '%s' "$gemini_text" >"$gemini_settings"
  printf '%s' "$hermes_text" >"$hermes_config"
  printf '%s' "$omp_text" >"$omp_config"
  printf '%s' "$opencode_text" >"$opencode_tui"
  printf '%s' "$pi_text" >"$pi_settings"
}
selected() { # every settings file holds its selection and the rest of its text
  has_text "$claude_settings" "$claude_selected" && has_text "$codex_config" "$codex_selected" && has_text "$gemini_settings" "$gemini_selected" &&
    has_text "$hermes_config" "$hermes_selected" && has_text "$omp_config" "$omp_selected" && has_text "$opencode_tui" "$opencode_selected" && has_text "$pi_settings" "$pi_selected"
}
seed

apply_json "the agent targets land" 0 dusk
check "every agent target is written" all_state "claude written None;codex written None;gemini written None;hermes written None;omp written None;opencode written None;pi written None;"
check "detection never ran a CLI" test -z "$(find "$tmp" -maxdepth 1 -name 'ran-*' -print)"
check "no hook is left pending" test ! -e "$pending"
check "opencode's hook signals only TUI invocations" test -f "$tmp/opencode-bare-signaled" -a -f "$tmp/opencode-attach-signaled" -a -f "$tmp/opencode-project-signaled" -a ! -e "$tmp/opencode-serve-signaled" -a ! -e "$tmp/opencode-run-signaled" -a ! -e "$tmp/opencode-option_serve-signaled" -a ! -e "$tmp/opencode-web-signaled"
check "opencode's hook disables globbing before splitting argv" grep -qF 'set -f; set -- $args' "$tree/themes/targets/opencode/target.json"

# Each file parses as its CLI reads it and holds hex6 colours: dusk's accent
# is #111111, the table's background #000000 and the shipped slot color5
# #a855f7.
hex6='^#[0-9a-f]{6}$'
check "Claude's theme is dark-based JSON whose overrides are all hex6" python3 -c 'import json,re,sys; t = json.load(open(sys.argv[1])); o = t["overrides"]; sys.exit(0 if t["name"] == "vgs" and t["base"] == "dark" and o["claude"] == "#111111" and o["inverseText"] == "#000000" and all(re.match(sys.argv[2], v) for v in o.values()) else 1)' "$live/claude.json" "$hex6"
check "Claude's theme leaves the diff fills to its base" python3 -c 'import json,sys; sys.exit(0 if not [k for k in json.load(open(sys.argv[1]))["overrides"] if k.startswith("diff")] else 1)' "$live/claude.json"
check "Codex's theme is a TextMate plist whose foregrounds are all hex6" python3 -c 'import plistlib,re,sys; t = plistlib.load(open(sys.argv[1], "rb")); f = [s["settings"]["foreground"] for s in t["settings"]]; h = [s["settings"]["foreground"] for s in t["settings"] if s.get("scope") == "markup.heading, entity.name.section"]; sys.exit(0 if t["name"] == "vgs" and h == ["#111111"] and all(re.match(sys.argv[2], v) for v in f) else 1)' "$live/codex.tmTheme" "$hex6"
check "Gemini's theme is a custom JSON theme with the accent" python3 -c 'import json,sys; t = json.load(open(sys.argv[1])); sys.exit(0 if t["type"] == "custom" and t["text"]["accent"] == "#111111" and t["background"]["primary"] == "#000000" and t["ui"]["gradient"][1] == "#a855f7" else 1)' "$live/gemini.json"
check "Hermes's skin names itself vgs" grep -qxF -- 'name: vgs' "$live/hermes.yaml"
check "every Hermes colour is a double-quoted hex6" python3 -c 'import re,sys; l = open(sys.argv[1]).read().split("colors:\n")[1].splitlines(); sys.exit(0 if len(l) == 30 and all(re.fullmatch(r"  [a-z_]+: \"#[0-9a-f]{6}\"", x) for x in l) and "  banner_title: \"#111111\"" in l else 1)' "$live/hermes.yaml"
check "oh-my-pi's theme holds its 67 colours and 3 export colours as hex6" python3 -c 'import json,re,sys; t = json.load(open(sys.argv[1])); c = t["colors"]; e = t["export"]; sys.exit(0 if t["name"] == "vgs" and len(c) == 67 and sorted(e) == ["cardBg", "infoBg", "pageBg"] and c["accent"] == "#111111" and c["statusLineModel"] == "#111111" and all(re.match(sys.argv[2], v) for v in list(c.values()) + list(e.values())) else 1)' "$live/omp.json" "$hex6"
check "opencode's theme holds its 52 colours as hex6" python3 -c 'import json,re,sys; t = json.load(open(sys.argv[1])); c = t["theme"]; sys.exit(0 if t["$schema"] == "https://opencode.ai/theme.json" and len(c) == 52 and c["primary"] == "#111111" and all(re.match(sys.argv[2], v) for v in c.values()) else 1)' "$live/opencode.json" "$hex6"
check "Pi's theme holds its 56 colours and 3 export colours as hex6" python3 -c 'import json,re,sys; t = json.load(open(sys.argv[1])); c = t["colors"]; e = t["export"]; sys.exit(0 if t["name"] == "vgs" and len(c) == 56 and sorted(e) == ["cardBg", "infoBg", "pageBg"] and c["accent"] == "#111111" and all(re.match(sys.argv[2], v) for v in list(c.values()) + list(e.values())) else 1)' "$live/pi.json" "$hex6"

# The entries stand where each CLI reads its themes; Claude Code, Hermes,
# oh-my-pi and Pi get watched copies, Codex and opencode keep links, and
# Gemini reads its theme by the path its setting names and takes none.
check "Claude's theme copy stands in its themes directory" same_file "$home/.claude/themes/vgs.json" "$live/claude.json"
check "Codex's theme link stands in its themes directory" links_to "$home/.codex/themes/vgs.tmTheme" "$live/codex.tmTheme"
check "Hermes's skin copy stands in its skins directory" same_file "$home/.hermes/skins/vgs.yaml" "$live/hermes.yaml"
check "oh-my-pi's theme copy stands in its themes directory" same_file "$home/.omp/agent/themes/vgs.json" "$live/omp.json"
check "opencode's theme link stands in its themes directory" links_to "$cfg/opencode/themes/vgs.json" "$live/opencode.json"
check "Pi's theme copy stands in its themes directory" same_file "$home/.pi/agent/themes/vgs.json" "$live/pi.json"
check "Gemini keeps no link" test ! -e "$home/.gemini/themes"

# The selection: the one key set, every other byte kept; a symlinked file
# stays a link and every file keeps its mode.
check "each settings file takes its theme key and keeps the rest of its text" selected
check "Codex's symlinked config stays a link to the dotfile" links_to "$codex_config" "$dotfiles/codex.toml"
check "the modes of Codex's dotfile and Claude's settings are kept" test "$(stat -c %a -- "$dotfiles/codex.toml" "$claude_settings" | tr '\n' ' ')" == "600 640 "

# Unchanged: a second apply writes no settings file.
touch -d @1000 -- "${settings[@]}"
if ! before="$(stamp "${settings[@]}")"; then fail "the settings files can be read before the unchanged apply"; before=none; fi
if ! entries_before="$(entry_stamp "$home/.claude/themes/vgs.json" "$home/.hermes/skins/vgs.yaml" "$home/.omp/agent/themes/vgs.json" "$home/.pi/agent/themes/vgs.json")"; then fail "the copied theme entries can be read before the unchanged apply"; entries_before=none; fi
apply_json "an unchanged apply" 0 dusk
check "an unchanged apply leaves every agent target unchanged" all_state "claude unchanged None;codex unchanged None;gemini unchanged None;hermes unchanged None;omp unchanged None;opencode unchanged None;pi unchanged None;"
check "an unchanged apply writes no settings file" test "$(stamp "${settings[@]}")" == "$before"
check "an unchanged apply writes no copied theme entry" test "$(entry_stamp "$home/.claude/themes/vgs.json" "$home/.hermes/skins/vgs.yaml" "$home/.omp/agent/themes/vgs.json" "$home/.pi/agent/themes/vgs.json")" == "$entries_before"

# A changed theme replaces each watched copy and writes no settings file.
apply_json "a changed theme" 0 nord
check "the Claude copy takes the new render" same_file "$home/.claude/themes/vgs.json" "$live/claude.json"
check "the changed apply wrote no settings file" test "$(stamp "${settings[@]}")" == "$before"

# A key changed by hand comes back on the next apply, unchanged bytes and
# all, and the rest of the file stays.
printf '%s' "${claude_selected/custom:vgs/dark}" >"$claude_settings"
printf '%s' "${codex_selected/\"vgs\"/\"catppuccin-mocha\"}" >"$dotfiles/codex.toml"
apply_json "an apply after a hand edit" 0 nord
check "the hand-edited targets are unchanged" test "$(target_state claude)$(target_state codex)" == "unchanged Noneunchanged None"
check "the hand-edited keys are set again" selected
check "the restored Codex config is still a link" links_to "$codex_config" "$dotfiles/codex.toml"

# An absent settings file skips its target and is never created, a
# dangling link included; a file whose key cannot be read without guessing
# skips its target and stays byte for byte.
rm -- "$pi_settings"
ln -sfn -- "$tmp/nowhere.yaml" "$hermes_config"
printf '{\n  // mine\n  "model": "opus"\n}\n' >"$claude_settings"; cp -- "$claude_settings" "$tmp/claude.jsonc"
printf '[tui]\nanimations = false\n[tui]\n' >"$dotfiles/codex.toml"; cp -- "$dotfiles/codex.toml" "$tmp/codex.twice"
apply_json "an apply over absent and refused settings files" 0 dusk
check "an absent settings file skips Pi" test "$(target_state pi)" == "skipped selection-file-absent"
check "an absent settings file stays absent" test ! -e "$pi_settings"
check "a dangling settings link skips Hermes" test "$(target_state hermes)" == "skipped selection-file-absent"
check "a dangling settings link stays dangling" test -L "$hermes_config" -a ! -e "$tmp/nowhere.yaml"
check "a JSON file with a comment skips Claude" test "$(target_state claude)" == "skipped selection-refused"
check "the commented file is left byte for byte" cmp -s -- "$tmp/claude.jsonc" "$claude_settings"
check "a Codex config with two [tui] tables skips Codex" test "$(target_state codex)" == "skipped selection-refused"
check "the doubled table is left byte for byte" cmp -s -- "$tmp/codex.twice" "$dotfiles/codex.toml"
check "a skipped target keeps its last theme file" test -f "$live/pi.json" -a -f "$live/claude.json"

# The must-fail control: a judge copy that drops the plan's skip reaches
# the wiring step, which fails the targets and still creates and edits
# nothing.
judge_control plan-refusal-dropped 'if (selected.value !== null) return skipped(selected.value);' ''
apply_json "the plan-dropping mutant applies" 3 nord "vgsh: refused: target=claude reason=selection-refused path=$claude_settings format=json cause=unparseable key=theme"
check "the plan-dropping mutant fails the refused and absent targets" test "$(target_state claude)|$(target_state codex)|$(target_state hermes)|$(target_state pi)" == "failed selection-refused|failed selection-refused|failed selection-file-absent|failed selection-file-absent"
check "the plan-dropping mutant still creates no settings file" test ! -e "$pi_settings" -a ! -e "$tmp/nowhere.yaml"
check "the plan-dropping mutant still edits no refused file" test "$(cmp -s -- "$tmp/claude.jsonc" "$claude_settings"; echo $?)$(cmp -s -- "$tmp/codex.twice" "$dotfiles/codex.toml"; echo $?)" == 00
unset THEME_BIN

# Disabled, a target loses its link and leaves its theme key as it stands:
# the user's previous theme is not known.
seed
apply_json "the agent targets land again" 0 dusk
disable '"claude"'
apply_json "a disabled Claude" 0 nord
check "a disabled Claude is skipped" test "$(target_state claude)" == "skipped disabled"
check "a disabled Claude loses its copy" test ! -e "$home/.claude/themes/vgs.json"
check "a disabled Claude leaves its theme key" has_text "$claude_settings" "$claude_selected"
disable ''

# The must-fail control: a judge copy that never keeps the selection leaves
# a hand-edited key.
printf '%s' "${claude_selected/custom:vgs/dark}" >"$claude_settings"
judge_control selection-skipped 'if (failure === null && entry.target.select !== undefined) {' 'if (false) {'
apply_json "the selection-skipping mutant applies" 0 dusk
check "the selection-skipping mutant leaves the hand-edited key" has_text "$claude_settings" "${claude_selected/custom:vgs/dark}"
unset THEME_BIN

# No agent template names a translucent token: hex6 drops alpha, so a
# 14 % fill would draw as the whole colour. Each template is rendered
# against the shipped vgs package with the hex8 encoder, which writes every
# resolved colour whole; the count of colours each writes must equal the
# `#@{` placeholders its template holds, and each must be opaque.
translucent_check() { # ROOT: the tree whose agent targets are judged
  "$node_bin" - "$1" $agents <<'EOF'
"use strict";
const fs = require("fs");
const path = require("path");
const [root, ...names] = process.argv.slice(2);
const { load } = require(path.join(root, "scripts", "qml-library.js"));
const logic = load(path.join(root, "shell", "Commons", "ThemeLogic.js"));
const tokens = load(path.join(root, "shell", "Commons", "Tokens.js")).TOKENS;
const render = require(path.join(root, "bin", "lib", "theme-render.js"));
const vgs = path.join(root, "themes", "vgs");
const pkg = logic.acceptPackage(tokens, { directoryName: "vgs", themeJson: fs.readFileSync(path.join(vgs, "theme.json"), "utf8"), terminalJson: fs.readFileSync(path.join(vgs, "terminal.json"), "utf8"), shipped: true });
let bad = 0;
for (const name of names) {
    const dir = path.join(root, "themes", "targets", name);
    const target = render.acceptTarget(logic, name, fs.readFileSync(path.join(dir, "target.json"), "utf8")).target;
    const templates = new Map(target.files.map(file => [file.template, fs.readFileSync(path.join(dir, file.template), "utf8")]));
    const out = render.renderTarget(logic, tokens, Object.assign({}, target, { encoder: "hex8" }), templates, { values: pkg.values, slots: pkg.terminal, curated: new Map() });
    const written = out.files.map(file => file.bytes.toString("utf8")).join("").match(/#[0-9a-f]{8}/g) || [];
    const placeholders = [...templates.values()].join("").split("#@{").length - 1;
    if (placeholders < 10 || written.length !== placeholders) {
        console.log("translucent-check: broken extractor target=" + name + " placeholders=" + placeholders + " colours=" + written.length);
        bad++;
    }
    for (const colour of written.filter(hex => !hex.endsWith("ff"))) {
        console.log("translucent-check: translucent target=" + name + " colour=" + colour);
        bad++;
    }
}
process.exit(bad === 0 ? 0 : 1);
EOF
}
check "no agent template names a translucent token" translucent_check "$tree"
tree_control translucent-token themes/targets/pi/pi.json '"selectedBg": "#@{color.surfaceHover}"' '"selectedBg": "#@{color.accentSubtle}"'
check "the translucent-token mutant fails the check" test "$(translucent_check "$tmp/tree-translucent-token" >/dev/null; echo $?)" == 1
unset THEME_BIN

rows_done test-vgsh-agents
