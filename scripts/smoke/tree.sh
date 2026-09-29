# Sourced by scripts/sandbox-shots.sh, scripts/smoke/harness.sh and
# scripts/test-sandbox-shots.sh: how another revision's tree reaches the
# sandbox copy.
#
# A revision from before bin/lib kept the runtime helpers its bin/ loads
# under scripts/, which this checkout's scripts/ no longer holds. The
# revision's export carries whichever of them it has, and the sandbox copy
# takes them over this checkout's scripts/, so a before shot runs that
# revision's own helpers.
tree_runtime_helpers=(scripts/qml-library.js scripts/check-manifests.js)

# tree_export CHECKOUT REV DIR: extract REV's shell, bin, config and themes,
# and those of its runtime helpers it has, into DIR. Non-zero when git or
# tar fails; the caller runs under pipefail.
tree_export() {
  local checkout="$1" rev="$2" dir="$3" helpers paths=(shell bin config themes)
  helpers="$(git -C "$checkout" ls-tree --name-only "$rev" -- "${tree_runtime_helpers[@]}")" || return 1
  [[ -z $helpers ]] || mapfile -t -O "${#paths[@]}" paths <<<"$helpers"
  git -C "$checkout" archive "$rev" "${paths[@]}" | tar -x -C "$dir"
}

# tree_overlay_helpers TREE TARGET: copy what TREE, an export tree_export
# made, carries under scripts/ over the sandbox copy's scripts/ at TARGET.
# An export with no helpers changes nothing.
tree_overlay_helpers() {
  local tree="$1" target="$2"
  [[ -d $tree/scripts ]] || return 0
  cp -R -- "$tree/scripts/." "$target/scripts/"
}
