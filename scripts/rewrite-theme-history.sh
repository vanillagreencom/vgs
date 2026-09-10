#!/usr/bin/env bash
# Drop every past revision of the theme imagery from git history, then commit the
# two bundled themes' imagery back as new content (D015 § 6).
#
# Usage: scripts/rewrite-theme-history.sh [--force]
#
# Run this ONCE, on main, in a fresh clone, after the deletion has merged.
# It rewrites every commit and tag, so main and every v* tag must then be
# force-pushed and every existing clone and open branch is invalidated.
# It does not push. It prints the push commands and the new size-pack.
#
# --force: pass git-filter-repo --force, and proceed when this clone has been
#          rewritten before. Both refusals are safeguards; override them only
#          when the clone is disposable.
# -h, --help: print this help.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
git_dir="$(git -C "$root" rev-parse --absolute-git-dir)"
readonly BUNDLED=(bauhaus roseofdune)
# The two globs the imagery lives under. filter-repo drops every blob matching
# them from every commit; anything outside them is untouched.
readonly IMAGERY_GLOBS=('themes/*/backgrounds/*' 'themes/*/preview.png')
# The branch the re-add commit has to land on, because the printed procedure
# publishes it and every consumer reads it.
readonly PUBLISH_BRANCH=main

force=0
for argument in "$@"; do
  case "$argument" in
    --force) force=1 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "rewrite-theme-history: unknown option $argument" >&2; exit 2 ;;
  esac
done

# Everything below the rewrite runs with history already destroyed, so the
# staging copy is the only imagery left and the operator has to be told so.
keep=""
rewritten=0

on_exit() {
  local status=$?
  if [[ "$rewritten" -eq 1 && "$status" -ne 0 ]]; then
    cat >&2 <<EOF

rewrite-theme-history: FAILED AFTER THE REWRITE (exit $status).

  What already happened, and does not undo itself:
    - every commit and tag in this clone was rewritten
    - git-filter-repo removed the 'origin' remote
    - the reflog was expired, so the old commits are not reachable here

  The bundled themes' imagery is at:
    $keep
  It is NOT deleted, because this clone may no longer hold a copy anywhere else.

  Recovery: delete this clone, clone again from the remote, and run this script
  from the fresh clone. Copy nothing out of this one except that directory.
EOF
    exit "$status"
  fi
  [[ -n "$keep" ]] && rm -rf -- "${keep:?}"
}
trap on_exit EXIT
# An interrupt after the rewrite must take the same path as a failure, not the
# silent cleanup bash would otherwise run.
trap 'exit 130' INT
trap 'exit 143' TERM

if ! command -v git-filter-repo >/dev/null; then
  echo "rewrite-theme-history: git-filter-repo is not on PATH. Install it (Arch: git-filter-repo) and run again." >&2
  exit 1
fi

# filter-repo rewrites every ref, but the re-add commit lands on HEAD alone.
# On any other branch, main ends with both bundled themes carrying no imagery
# while the printed procedure force-pushes it.
if ! branch="$(git -C "$root" rev-parse --abbrev-ref HEAD)"; then
  echo "rewrite-theme-history: cannot read the checked-out branch, so whether the re-add commit would land on $PUBLISH_BRANCH is unknown." >&2
  exit 1
fi
if [[ "$branch" != "$PUBLISH_BRANCH" ]]; then
  echo "rewrite-theme-history: HEAD is $branch, not $PUBLISH_BRANCH. The re-add commit lands on HEAD, so running here would leave $PUBLISH_BRANCH with no bundled imagery. Check out $PUBLISH_BRANCH and run again." >&2
  exit 1
fi

# git-filter-repo refuses a clone it has not seen, then records already_ran and
# stops refusing. A second run rewrites the history a second time and adds a
# duplicate re-add commit.
if [[ -e "$git_dir/filter-repo/already_ran" && "$force" -eq 0 ]]; then
  echo "rewrite-theme-history: this clone has already been rewritten ($git_dir/filter-repo/already_ran exists). The remaining work is the push, not another rewrite: see the procedure this script printed. Pass --force to rewrite again anyway." >&2
  exit 1
fi

# A rewrite of dirty or partial history silently discards work.
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "rewrite-theme-history: the working tree is not clean. Commit or stash first; a rewrite over uncommitted changes loses them." >&2
  exit 1
fi
# An ignored file under themes/ is invisible to --porcelain, survives the
# rewrite, and keeps a backgrounds/ directory alive that the restore then
# copies into rather than creating. git writes <file>.orig itself on a
# conflicted merge, and .gitignore hides it.
if ! leftovers="$(git -C "$root" status --porcelain --ignored=matching -- themes/)"; then
  echo "rewrite-theme-history: cannot list ignored files under themes/, so whether a leftover would corrupt the restore is unknown." >&2
  exit 1
fi
if [[ -n "$leftovers" ]]; then
  echo "rewrite-theme-history: themes/ holds ignored files, which survive the rewrite and corrupt the restore:" >&2
  printf '%s\n' "$leftovers" >&2
  echo "rewrite-theme-history: remove them and run again." >&2
  exit 1
fi
if [[ "$(git -C "$root" rev-parse --is-shallow-repository)" != "false" ]]; then
  echo "rewrite-theme-history: this is a shallow clone, so the rewrite would drop the history it cannot see. Clone with full history." >&2
  exit 1
fi

# The bundled imagery is re-added from the tree this script runs against, so it
# has to be there. Refuse rather than rewrite history into a set with no wallpapers.
staged=()
for theme in "${BUNDLED[@]}"; do
  directory="$root/themes/$theme"
  if [[ ! -d "$directory/backgrounds" || ! -f "$directory/preview.png" ]]; then
    echo "rewrite-theme-history: themes/$theme has no backgrounds/ or no preview.png, so the rewrite would leave the bundled themes with no imagery." >&2
    exit 1
  fi
  staged+=("themes/$theme/backgrounds" "themes/$theme/preview.png")
done

# A fresh clone fetches every branch, so a branch still carrying the imagery
# keeps it in the pack however thoroughly main is rewritten. Read the remote
# now: filter-repo removes it.
imagery_paths_on() {
  git -C "$root" ls-tree -r --name-only "$1" -- themes |
    awk '/^themes\/[^\/]+\/backgrounds\// || /^themes\/[^\/]+\/preview\.png$/ {n++} END {print n+0}'
}
stale_report=()
while IFS= read -r ref; do
  # refname:short renders refs/remotes/origin/HEAD as plain "origin", so strip
  # the full ref instead: the symbolic HEAD is not a branch to rewrite.
  name="${ref#refs/remotes/origin/}"
  case "$name" in "$PUBLISH_BRANCH"|HEAD|"$ref") continue ;; esac
  stale_report+=("$name $(imagery_paths_on "$ref")")
done < <(git -C "$root" for-each-ref --format='%(refname)' 'refs/remotes/origin/**')

# filter-repo removes the imagery from history, including the current commit, so
# the bundled themes' files must survive outside the repository across the run.
keep="$(mktemp -d)"
for theme in "${BUNDLED[@]}"; do
  mkdir -p -- "$keep/$theme"
  cp -a -- "$root/themes/$theme/backgrounds" "$keep/$theme/backgrounds"
  cp -a -- "$root/themes/$theme/preview.png" "$keep/$theme/preview.png"
done

before="$(git -C "$root" count-objects -vH | sed -n 's/^size-pack: //p')"

filter_args=()
for glob in "${IMAGERY_GLOBS[@]}"; do
  filter_args+=(--path-glob "$glob")
done
if [[ "$force" -eq 1 ]]; then
  filter_args+=(--force)
fi
git -C "$root" filter-repo "${filter_args[@]}" --invert-paths
rewritten=1

for theme in "${BUNDLED[@]}"; do
  # Copy the contents into a directory this script creates. cp -a of the
  # directory itself nests one level deep when the destination survived the
  # rewrite, which puts the wallpapers at a path no consumer reads.
  install -d -- "$root/themes/$theme/backgrounds"
  cp -a -- "$keep/$theme/backgrounds/." "$root/themes/$theme/backgrounds/"
  cp -a -- "$keep/$theme/preview.png" "$root/themes/$theme/preview.png"
  if ! nested="$(find "$root/themes/$theme/backgrounds" -mindepth 1 -type d -print -quit)"; then
    echo "rewrite-theme-history: cannot inspect themes/$theme/backgrounds after the restore, so whether the wallpapers landed flat is unknown." >&2
    exit 1
  fi
  if [[ -n "$nested" ]]; then
    echo "rewrite-theme-history: themes/$theme/backgrounds holds a subdirectory ($nested), so the wallpapers are not where the theme reads them." >&2
    exit 1
  fi
done
git -C "$root" add -- "${staged[@]}"
git -C "$root" commit -m "feat(themes): re-add the bundled themes' imagery after the history rewrite

The imagery of every other theme now ships as a release archive (D015). This
commit restores the wallpapers and screenshot of the two themes the packages
install, as new content with no prior revisions behind it."

after="$(git -C "$root" count-objects -vH | sed -n 's/^size-pack: //p')"
cat <<EOF

rewrite-theme-history: done, nothing pushed.
  size-pack before: $before
  size-pack after:  $after
EOF

if [[ ${#stale_report[@]} -gt 0 ]]; then
  cat <<EOF

${#stale_report[@]} remote branch(es) besides $PUBLISH_BRANCH still carry their own
history. git clone fetches every branch, so a fresh clone stays large until each
one is deleted on the remote, or rewritten the same way and force-pushed.
Imagery paths each one holds:

EOF
  printf '  %s\n' "${stale_report[@]}"
fi

# filter-repo drops the remote, so the operator sets it again before pushing.
cat <<EOF

git-filter-repo removed the 'origin' remote. To publish the rewrite:

  git remote add origin git@github.com:vanillagreencom/vgs.git
  git push --force origin $PUBLISH_BRANCH
  git push --force --tags origin

Every existing clone and open branch is invalidated by this push.
EOF
