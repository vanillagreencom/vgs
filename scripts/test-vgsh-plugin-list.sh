#!/usr/bin/env bash
# Controls for `vgsh plugin list`: the lines bin/vgsh-plugin-judge prints
# from the shell's listPlugins reply, which a stub qs hands over. A missing
# requirement's package comes from `vgsh pkg detect`, so the rows that name
# one run under `unshare -rm` with a Void os-release bound over
# /etc/os-release and a stub xbps-install on PATH; without user namespaces
# they cannot run and the suite exits 77. The controls run the rows against
# a copy of the tree whose judge lacks one rule, and each must turn a row
# red.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

if ! unshare -rm true 2>/dev/null; then
  echo "test-vgsh-plugin-list: status=not-measured missing=user-namespaces"
  exit 77
fi

printf '#!/bin/sh\nprintf "%%s\\n" "$STUB_REPLY"\n' >"$tmp/qs"
chmod +x "$tmp/qs"
rt_live="$tmp/rt-live"; mkdir -p "$rt_live"; printf '%s\n' "$$" >"$rt_live/vgsh.lock"
managers="$tmp/managers"; mkdir -p "$managers"
printf '#!/bin/sh\nexit 99\n' >"$managers/xbps-install"; chmod +x "$managers/xbps-install"
os_release="$tmp/os-release"; printf 'NAME="Void"\nID="void"\n' >"$os_release"

# A reply of plugin acme.need holding REQUIREMENTS, a JSON list of rows.
reply() { # REQUIREMENTS [UNKNOWN]
  printf '{"plugins":[{"id":"acme.need","version":"1.0","kinds":["service"],"enabled":false,"dir":"/x","requirements":%s}],"errors":[],"collisions":[],"unknown":%s,"scanError":"","scanned":true}' "$1" "${2:-[]}"
}
req() { # COMMAND STATE OPTIONAL PACKAGES
  printf '{"command":"%s","packages":%s,"optional":%s,"purpose":"p","state":"%s"}' "$1" "$4" "$3" "$2"
}

# case_out BIN BOUND REPLY: `plugin list` through BIN with REPLY; BOUND is
# `bound` for the os-release fixture, else `plain`. Sets out, err, status.
case_out() {
  local bin="$1" bound="$2" rep="$3" run=()
  [[ $bound == bound ]] && run=(unshare -rm sh -c 'mount --bind "$1" /etc/os-release && shift && exec "$@"' sh "$os_release")
  set +e
  out="$("${run[@]}" "${base_env[@]}" PATH="$managers:$base_path" XDG_RUNTIME_DIR="$rt_live" STUB_REPLY="$rep" "$bin" plugin list 2>"$tmp/err")"
  status=$?
  set -e
  err=""
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
}

# rows: name | bound | reply | want last stdout line | want exit | want first stderr line
declare -a ROWS=(
  "a plugin row per plugin|plain|$(reply '[]')|acme.need                    1.0      disabled  kinds=service|0|"
  "a configured id no plugin has|plain|$(reply '[]' '[{"id":"vgs.background","key":"disabledPlugins"}]')|unknown vgs.background in disabledPlugins|0|"
  "a present requirement prints no line|plain|$(reply "[$(req gum present false '{"xbps":"gum"}')]")|acme.need                    1.0      disabled  kinds=service|0|"
  "a missing requirement with no package names its command|plain|$(reply "[$(req gum missing false '{}')]")|missing acme.need gum|0|"
  "a missing optional requirement says so|plain|$(reply "[$(req fzf missing true '{}')]")|missing acme.need fzf optional|0|"
  "a missing requirement names this system's package|bound|$(reply "[$(req gum missing false '{"pacman":"gum-arch","xbps":"gum-void"}')]")|missing acme.need gum (gum-void)|0|"
  "a package for no manager here names the command alone|bound|$(reply "[$(req gum missing false '{"apt":"gum"}')]")|missing acme.need gum|0|"
  "missing lines follow the unknown lines|plain|$(reply "[$(req gum missing false '{}')]" '[{"id":"vgs.background","key":"disabledPlugins"}]')|missing acme.need gum|0|"
)

# run_rows BIN QUIET: every row through BIN; prints ok/FAIL lines unless
# QUIET and returns the number of rows that failed.
run_rows() {
  local bin="$1" quiet="$2" row name bound rep want_out want_exit want_err red=0
  for row in "${ROWS[@]}"; do
    IFS='|' read -r name bound rep want_out want_exit want_err <<<"$row"
    case_out "$bin" "$bound" "$rep"
    if [[ $status == "$want_exit" && ${out##*$'\n'} == "$want_out" && $err == "$want_err" ]]; then
      [[ $quiet == quiet ]] || ok "$name"
    else
      red=$((red + 1))
      [[ $quiet == quiet ]] || fail "$name: exit=$status want=$want_exit last=[${out##*$'\n'}] want=[$want_out] stderr=[$err] want=[$want_err]"
    fi
  done
  return "$red"
}
run_rows "$repo/bin/vgsh" loud || true

# A tree the judge resolves its siblings in: bin/ copied, its loader
# included, and the shell libraries it loads linked.
tree="$tmp/tree"; mkdir -p "$tree/shell/Core" "$tree/shell/Ui/icons"
cp -R -- "$repo/bin" "$tree/"
ln -s -- "$repo/shell/Core/PluginLogic.js" "$tree/shell/Core/PluginLogic.js"
ln -s -- "$repo/shell/Core/PackageManagers.js" "$tree/shell/Core/PackageManagers.js"
ln -s -- "$repo/shell/Ui/icons/Lucide.js" "$tree/shell/Ui/icons/Lucide.js"

# Detection that cannot run is a refusal naming it, never a line without
# its package: the tree's vgsh-pkg is set aside for the one run. Returns 1
# when the refusal is not the one printed.
detect_failure_row() { # QUIET
  local good=0
  mv -- "$tree/bin/vgsh-pkg" "$tmp/vgsh-pkg.aside"
  case_out "$tree/bin/vgsh" plain "$(reply "[$(req gum missing false '{"xbps":"gum"}')]")"
  mv -- "$tmp/vgsh-pkg.aside" "$tree/bin/vgsh-pkg"
  [[ $status == 1 && $err == "vgsh: refused: detect=failed exit=1" ]] || good=1
  [[ $1 == quiet ]] && return "$good"
  if [[ $good == 0 ]]; then ok "a detection that fails refuses the list"; else fail "a detection that fails: exit=$status stderr=[$err]"; fi
  return 0
}
detect_failure_row loud

# controls: label, then the text in bin/vgsh-plugin-judge, then its
# replacement, one control per three entries. The copy replaces the judge in
# the tree; every row and the detection refusal run against it.
declare -a CONTROLS=(
  "a missing requirement is listed" 'if (r.state === "missing") missing.push' 'if (false) missing.push'
  "the package is this system's pick" 'logic.PackageManagers.packageFor(m.requirement.packages, found)' 'null'
  "an optional requirement says so" '(m.requirement.optional ? " optional" : "")' '""'
  "a failed detection refuses" 'if (r.error !== undefined || r.status !== 0) {' 'if (false) {'
)
judge_src="$(<"$repo/bin/vgsh-plugin-judge")"
for ((i = 0; i < ${#CONTROLS[@]}; i += 3)); do
  label="${CONTROLS[i]}" needle="${CONTROLS[i + 1]}" replacement="${CONTROLS[i + 2]}"
  count="$(grep -c -F -- "$needle" "$repo/bin/vgsh-plugin-judge")" || count=0
  if [[ $count != 1 ]]; then fail "control: $label: the text to replace occurs $count times, not once"; continue; fi
  printf '%s\n' "${judge_src/"$needle"/"$replacement"}" >"$tree/bin/vgsh-plugin-judge"
  if cmp -s -- "$repo/bin/vgsh-plugin-judge" "$tree/bin/vgsh-plugin-judge"; then fail "control: $label: the copy is unchanged"; continue; fi
  if run_rows "$tree/bin/vgsh" quiet && detect_failure_row quiet; then fail "control: $label: the rows pass on a judge without the rule"; else ok "control: the rows fail without the rule: $label"; fi
done

rows_done test-vgsh-plugin-list
