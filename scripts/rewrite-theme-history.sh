#!/usr/bin/env bash
# Drop every past revision of the theme imagery from git history, then commit the
# two bundled themes' imagery back as new content (D015 § 6).
#
# Usage: scripts/rewrite-theme-history.sh [--force]
#
# Run this ONCE, on main, in a full clone, after the deletion has merged, and
# only when main is the remote's only branch. It rewrites every commit and tag,
# so main and every v* tag must then be force-pushed and every existing clone
# is invalidated. It does not push; it prints the push commands.
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
# The only refspec that gives this clone every branch. A narrower one hides
# branches from the survey below, which is the one thing it must not miss.
readonly FULL_REFSPEC='+refs/heads/*:refs/remotes/origin/*'

force=0
for argument in "$@"; do
  case "$argument" in
    --force) force=1 ;;
    # Print the comment block by content. A line range goes stale the next time
    # a sentence in the header wraps, and takes the last option with it.
    -h|--help) sed -n '2,/^[^#]/{/^#/p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "rewrite-theme-history: unknown option $argument" >&2; exit 2 ;;
  esac
done

# Everything after filter-repo starts runs with history already destroyed, so
# the staging copy is the only imagery left and the operator has to be told so.
keep=""
rewritten=0
completed=0

# filter-repo removes the origin remote at its start and creates its own state
# directory, and its pre-flight refusals leave both untouched. Observed state,
# not a flag set at one line, is what says whether the rewrite began: filter-repo
# resets and repacks after that point, so a failure inside it has already
# rewritten the clone.
rewrite_began() {
  [[ ! -e "$git_dir/filter-repo" ]] || return 0
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 0
  return 1
}

# Whether the commit checked out carries the bundled themes' imagery. After a
# finished run it does; after a rewrite that died before the re-add commit it
# does not, and those two states need opposite advice.
head_has_bundled_imagery() {
  local theme shot walls
  for theme in "${BUNDLED[@]}"; do
    shot="$(git -C "$root" ls-tree --name-only HEAD -- "themes/$theme/preview.png")" || return 1
    walls="$(git -C "$root" ls-tree -r --name-only HEAD -- "themes/$theme/backgrounds")" || return 1
    [[ -n "$shot" && -n "$walls" ]] || return 1
  done
  return 0
}

on_exit() {
  local status=$?
  # A refusal after a clean rewrite exits non-zero too, and so does one that
  # never reached filter-repo. Only an unfinished rewrite leaves the clone in
  # the state this banner describes.
  if [[ "$rewritten" -eq 1 && "$completed" -eq 0 && "$status" -ne 0 ]] && rewrite_began; then
    cat >&2 <<EOF

rewrite-theme-history: FAILED AFTER THE REWRITE BEGAN (exit $status).

  What already happened, and does not undo itself:
    - the history of this clone was rewritten, or partly rewritten
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
  if [[ -n "$keep" ]]; then
    rm -rf -- "${keep:?}"
  fi
  # A conditional as the trap's last command replaces the status the script
  # asked for with its own, so 130 and 143 arrive as 1.
  return 0
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
# stops refusing. What that marker means depends on how far the earlier run got.
if [[ -e "$git_dir/filter-repo/already_ran" && "$force" -eq 0 ]]; then
  if head_has_bundled_imagery; then
    echo "rewrite-theme-history: this clone has already been rewritten and carries the re-add commit. The remaining work is the push, not another rewrite: see the procedure this script printed. Pass --force to rewrite again anyway." >&2
  else
    echo "rewrite-theme-history: this clone was rewritten by an earlier run that never made the re-add commit, so the bundled themes have no imagery here and pushing it would publish that. Delete this clone, clone again, and run this script from the fresh clone." >&2
  fi
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
# A --single-branch clone is not shallow, so the check above admits it, and its
# refs/remotes hold one branch however many the remote has.
if ! refspec="$(git -C "$root" config --get remote.origin.fetch)"; then
  echo "rewrite-theme-history: cannot read remote.origin.fetch, so whether this clone tracks every branch is unknown." >&2
  exit 1
fi
if [[ "$refspec" != "$FULL_REFSPEC" ]]; then
  echo "rewrite-theme-history: this clone fetches '$refspec' rather than '$FULL_REFSPEC', so it does not track every branch. Clone without --single-branch and run again." >&2
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

# git clone fetches every branch, so any branch left on the remote keeps its own
# history in a fresh clone however thoroughly $PUBLISH_BRANCH is rewritten:
# publishing then invalidates every existing clone without shrinking a new one.
# Ask the remote rather than this clone's copy of it, which is a snapshot taken
# at clone time, and refuse when the answer cannot be had.
if ! remote_heads="$(git -C "$root" ls-remote --heads origin)"; then
  echo "rewrite-theme-history: cannot list the remote's branches, so whether one still carries the imagery is unknown." >&2
  exit 1
fi
stale_branches=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  name="${line#*$'\t'}"
  name="${name#refs/heads/}"
  case "$name" in "$PUBLISH_BRANCH"|"$branch") continue ;; esac
  stale_branches+=("$name")
done <<< "$remote_heads"
if [[ ${#stale_branches[@]} -gt 0 ]]; then
  cat >&2 <<EOF
rewrite-theme-history: the remote carries ${#stale_branches[@]} branch(es) besides $PUBLISH_BRANCH:
EOF
  printf '  %s\n' "${stale_branches[@]}" >&2
  cat >&2 <<EOF
Delete each on the remote, or rewrite it the same way and force-push it, then
run this script again. Rewriting and pushing now would invalidate every existing
clone while a new one still fetches the imagery through those branches.
Nothing has been rewritten.
EOF
  exit 1
fi

# The size a fresh clone would transfer. count-objects' size-pack counts packed
# objects only, and objects sit loose on both sides of the run: git clone leaves
# small object counts unpacked (transfer.unpackLimit), and the re-add commit is
# loose until something packs it. Reading size-pack without packing first
# reports a few KiB for a clone holding tens of megabytes, and that one number
# is the only evidence the operator has that this run did what it was for.
packed_size() {
  git -C "$root" gc --quiet --prune=now || return 1
  git -C "$root" count-objects -vH | sed -n 's/^size-pack: //p'
}

# filter-repo removes the imagery from history, including the current commit, so
# the bundled themes' files must survive outside the repository across the run.
keep="$(mktemp -d)"
for theme in "${BUNDLED[@]}"; do
  mkdir -p -- "$keep/$theme"
  cp -a -- "$root/themes/$theme/backgrounds" "$keep/$theme/backgrounds"
  cp -a -- "$root/themes/$theme/preview.png" "$keep/$theme/preview.png"
done

# Before the destructive step, so a repository too broken to measure refuses
# here rather than after its history is gone.
if ! before="$(packed_size)"; then
  echo "rewrite-theme-history: cannot pack this clone to measure it (git gc failed), so the before and after this run reports would both be wrong. Fix the repository and run again." >&2
  exit 1
fi

filter_args=()
for glob in "${IMAGERY_GLOBS[@]}"; do
  filter_args+=(--path-glob "$glob")
done
if [[ "$force" -eq 1 ]]; then
  filter_args+=(--force)
fi
rewritten=1
git -C "$root" filter-repo "${filter_args[@]}" --invert-paths

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

completed=1
# A failed measurement here costs the number, not the run: the rewrite and the
# re-add commit are already done, and withholding the push procedure over a gc
# would help nobody.
if ! after="$(packed_size)"; then
  after="NOT MEASURED: git gc failed, so the re-add commit is still loose and size-pack would understate this clone. Run 'git gc --prune=now' and 'git count-objects -vH' by hand."
fi
# filter-repo drops the remote, so the operator sets it again before pushing.
cat <<EOF

rewrite-theme-history: done, nothing pushed.
  size-pack before: $before
  size-pack after:  $after

git-filter-repo removed the 'origin' remote. To publish the rewrite:

  git remote add origin git@github.com:vanillagreencom/vgs.git
  git push --force origin $PUBLISH_BRANCH
  git push --force --tags origin

Every existing clone is invalidated by this push.
EOF
