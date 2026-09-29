#!/usr/bin/env bash
# Controls for install.sh, the curl installer. Every row runs the script
# under env -i with a fresh fixture HOME, a scratch TMPDIR and a PATH of
# stubs and the tools it calls, never the developer's own home or package
# manager. Releases come from a file:// release fixture, VGS_RELEASE_API
# under VGS_TEST_RUN: the GitHub API's release documents and their assets,
# built from this repository's bin/ and installer. --git clones a local
# bare repository through the fixture home's url.insteadOf. A distribution
# is a fixture os-release bound over /etc/os-release under `unshare -rm`,
# the row then mapped back to the caller's uid, since the script refuses
# root.
#
# The drift rows hold the script's floor and package tables to their
# sources, bin/vgsh's preflight_floor and config/requirements.json, read by
# node below, and its package-manager choice and install command to
# `vgsh pkg detect` and `vgsh pkg plan` under the same os-release.
#
# /usr/bin/vgsh is not planted: no user namespace can create a file there,
# so the system-package rows use a stub pacman database instead.
#
# The controls at the end run copies of install.sh with one rule removed
# each, and every row that judges that rule must turn red on its copy.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

suite=test-install-sh
not_measured() { echo "$suite: status=not-measured missing=$1"; exit 77; }
unshare_bin="$(command -v unshare)" || not_measured unshare
"$unshare_bin" -rm true 2>/dev/null || not_measured user-namespaces
command -v gpg >/dev/null || not_measured gpg
command -v gpgconf >/dev/null || not_measured gpgconf
uid="$(id -u)" gid="$(id -g)"

installer="$repo/install.sh"

# The rows' PATH: floor stubs, then the tools install.sh, the release's
# installer and the namespace wrapper call. $tools_nogit lacks git, the tool
# the distribution rows leave missing.
stubs="$tmp/stubs"; tools="$tmp/tools"; tools_nogit="$tmp/tools-nogit"
mkdir -p "$stubs" "$tools" "$tools_nogit"
for tool in bash sh env readlink dirname mkdir rmdir mktemp mv rm ln cp cat head sed uname flock git python3 curl tar gzip sha256sum gpg unshare mount; do
  tool_bin="$(command -v "$tool")" || not_measured "$tool"
  ln -s -- "$tool_bin" "$tools/$tool"
  [[ $tool == git ]] || ln -s -- "$tool_bin" "$tools_nogit/$tool"
done
ln -s -- "$node_bin" "$tools/node"
ln -s -- "$node_bin" "$tools_nogit/node"
stub() { # DIR NAME STDOUT [STATUS]
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit %s\n' "$3" "${4:-0}" >"$1/$2"
  chmod +x "$1/$2"
}
stub "$stubs" qs "Quickshell 0.3.1 (revision 41651d7, distributed by fixture)"
stub "$stubs" Hyprland "Hyprland 0.56 built from branch fixture"
run_path="$stubs:$tools"

scratch="$tmp/scratch"; mkdir -p "$scratch"
gnupg_empty="$tmp/gnupg-empty"; mkdir -m 700 "$gnupg_empty"

# new_home NAME: sets h to a new, empty fixture home and d to its vgs data
# directory.
homes=0
new_home() {
  homes=$((homes + 1))
  h="$tmp/homes/$homes-$1"
  d="$h/.local/share/vgs"
  mkdir -p "$h"
}

# run BIN ARGS...: install.sh BIN from $h under the rows' environment.
# Stdout lands in $tmp/out, stderr in $tmp/err, the exit status in
# $status. RUN_PATH, RUN_RT (XDG_RUNTIME_DIR) and RUN_GNUPG replace the
# defaults; RUN_WRAP holds a command the script runs under.
RUN_WRAP=()
run() {
  local bin="$1"
  shift
  status=0
  env -i PATH="${RUN_PATH:-$run_path}" HOME="$h" TMPDIR="$scratch" VGS_TEST_RUN=1 VGS_RELEASE_API="file://$www" \
    XDG_RUNTIME_DIR="${RUN_RT:-$rt_empty}" GIT_CONFIG_NOSYSTEM=1 GNUPGHOME="${RUN_GNUPG:-$gnupg_empty}" \
    ${RUN_WRAP[@]+"${RUN_WRAP[@]}"} bash "$bin" "$@" >"$tmp/out" 2>"$tmp/err" </dev/null || status=$?
}
first_err() { local line=""; [[ -s $tmp/err ]] && IFS= read -r line <"$tmp/err"; printf '%s' "$line"; }
out_has() { grep -qxF -- "$1" "$tmp/out"; }
err_has() { grep -qxF -- "$1" "$tmp/err"; }
# refused STATUS FIRST_ERR: the last run exited STATUS with FIRST_ERR
# first on stderr.
refused() { [[ $status == "$1" && $(first_err) == "$2" ]]; }
scratch_empty() { [[ -z $(find "$scratch" -mindepth 1 -print -quit) ]]; }
no_stage() { ! compgen -G "$d/.self-update-*" >/dev/null; }
# with_os FILE: the next run sees FILE as /etc/os-release, as the caller's
# uid and gid; the caller clears RUN_WRAP after it.
with_os() {
  RUN_WRAP=(unshare -rm sh -c 'mount --bind "$1" /etc/os-release && u="$2" g="$3" && shift 3 && exec unshare --map-user="$u" --map-group="$g" "$@"' sh "$1" "$uid" "$gid")
}

# The release fixture. Each release is a document under
# repos/vanillagreencom/vgs/releases/tags/v<X.Y.Z> naming its assets under
# dl/v<X.Y.Z>/; releases/latest is v0.2.0's.
www="$tmp/www"; releases="$www/repos/vanillagreencom/vgs/releases"; mkdir -p "$releases/tags"
release_doc() { # TAG ASSET...
  local tag="$1" name out=""
  shift
  for name in "$@"; do out+="${out:+,}{\"name\":\"$name\",\"browser_download_url\":\"file://$www/dl/$tag/$name\"}"; done
  printf '{"tag_name":"%s","assets":[%s]}\n' "$tag" "$out" >"$releases/tags/$tag"
}
# release VERSION [TOP_DIR]: the archive vgs-VERSION.tar.gz, whose one top
# directory is TOP_DIR, default vgs-VERSION, and its SHA256SUMS line.
release() {
  local v="$1" top="${2:-vgs-$1}" dir="$www/dl/v$1"
  mkdir -p "$dir" "$tmp/rel/$v"
  source_tree "$tmp/rel/$v/$top" "$v"
  tar -C "$tmp/rel/$v" -czf "$dir/vgs-$v.tar.gz" "$top"
  (cd "$dir" && sha256sum "vgs-$v.tar.gz" >SHA256SUMS)
  release_doc "v$v" "vgs-$v.tar.gz" SHA256SUMS
}
release 0.1.0
release 0.2.0
cp -- "$releases/tags/v0.2.0" "$releases/latest"
# v0.3.0's archive differs from its SHA256SUMS line, and v0.4.0's
# SHA256SUMS lists another file.
release 0.3.0
printf 'tampered\n' >>"$www/dl/v0.3.0/vgs-0.3.0.tar.gz"
release 0.4.0
printf '%064d  vgs-9.9.9.tar.gz\n' 0 >"$www/dl/v0.4.0/SHA256SUMS"
# v0.7.0 unpacks to a top directory of another name; v0.8.0's tag is no
# version.
release 0.7.0 vgs-main
release 0.8.0
sed -i 's/"v0.8.0"/"v0.8"/' "$releases/tags/v0.8.0"

# Signed releases: v0.5.0's SHA256SUMS signed by the release key, v0.6.0's
# by another key the keyring also holds. $signing is install.sh with the
# release key's fingerprint set, the one change a published key makes.
keys="$tmp/gnupg"; mkdir -m 700 "$keys"
trap 'gpgconf --homedir "$keys" --kill gpg-agent >/dev/null 2>&1 || true; rm -rf -- "${tmp:?}"' EXIT
gen_key() { # NAME: prints the new key's fingerprint
  GNUPGHOME="$keys" gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-gen-key "$1" ed25519 sign never >/dev/null 2>&1
  GNUPGHOME="$keys" gpg --batch --with-colons --list-keys -- "$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
}
release_fpr="$(gen_key "VGS release fixture")"
other_fpr="$(gen_key "Another key")"
[[ $release_fpr =~ ^[0-9A-F]{40}$ && $other_fpr =~ ^[0-9A-F]{40}$ ]] || { echo "$suite: gpg=keygen-failed" >&2; exit 1; }
signed_release() { # VERSION FINGERPRINT
  release "$1"
  GNUPGHOME="$keys" gpg --batch --quiet --local-user "$2" --armor --detach-sign --output "$www/dl/v$1/SHA256SUMS.asc" "$www/dl/v$1/SHA256SUMS"
  release_doc "v$1" "vgs-$1.tar.gz" SHA256SUMS SHA256SUMS.asc
}
signed_release 0.5.0 "$release_fpr"
signed_release 0.6.0 "$other_fpr"

copy_with signing "$installer" 'release_key=""' "release_key=\"$release_fpr\""
signing="$copy"

# The rows each judge one rule, on the install.sh BIN names, so a control
# can run them again on a copy with that rule removed.

mismatch_row() { # BIN: a checksum mismatch refuses and leaves nothing
  new_home mismatch
  run "$1" --version 0.3.0
  [[ $status == 1 && $(first_err) == "install.sh: refused: checksum=mismatch name=vgs-0.3.0.tar.gz "* ]] &&
    [[ ! -e $h/.local ]] && scratch_empty
}
unlisted_row() { # BIN: an archive SHA256SUMS does not list refuses
  new_home unlisted
  run "$1" --version 0.4.0
  refused 1 "install.sh: refused: checksum=unlisted name=vgs-0.4.0.tar.gz count=0" && [[ ! -e $h/.local ]]
}
tag_row() { # BIN
  new_home tag
  run "$1" --version 0.8.0
  refused 1 "install.sh: refused: tag=v0.8 reason=not-a-version"
}
layout_row() { # BIN: an archive with another top directory refuses under the lock and changes nothing
  new_home layout
  run "$1" --version 0.1.0
  run "$1" --version 0.7.0
  refused 1 "install.sh: refused: archive=layout name=vgs-0.7.0.tar.gz top=vgs-main" &&
    [[ $(readlink -- "$d/current") == 0.1.0 && ! -e $d/0.7.0 ]] && no_stage
}
busy_row() { # BIN
  new_home busy
  mkdir -p "$d"
  exec 7>>"$d/.self.lock"
  flock 7
  run "$1"
  exec 7>&-
  refused 75 "install.sh: refused: self=busy path=$d/.self.lock" && [[ ! -e $d/0.2.0 && ! -e $d/current ]]
}
signature_other_row() { # BIN: a signature by another key in the keyring refuses and leaves nothing
  new_home sig-other
  RUN_GNUPG="$keys" run "$1" --version 0.6.0
  refused 1 "install.sh: refused: signature=bad name=SHA256SUMS key=$release_fpr" && [[ ! -e $h/.local ]]
}
root_row() { # BIN
  new_home root
  RUN_WRAP=(unshare -r)
  run "$1"
  RUN_WRAP=()
  refused 1 "install.sh: refused: user=root" && [[ ! -e $h/.local ]]
}
darwin="$tmp/darwin"; mkdir -p "$darwin"; stub "$darwin" uname Darwin
os_row() { # BIN
  new_home os
  RUN_PATH="$darwin:$run_path" run "$1"
  refused 1 "install.sh: refused: os=Darwin" && [[ ! -e $h/.local ]]
}
vgs_db="$tmp/vgs-db"; mkdir -p "$vgs_db"
cat >"$vgs_db/pacman" <<'SH'
#!/bin/sh
[ "$1" = -Q ] && [ "$3" = vgs-git ] && { echo "vgs-git 0.1.0.r1.gabc1234-1"; exit 0; }
exit 1
SH
chmod +x "$vgs_db/pacman"
system_row() { # BIN: vgs-git in the pacman database refuses
  new_home system
  RUN_PATH="$vgs_db:$run_path" run "$1"
  refused 1 "install.sh: refused: system=package manager=pacman package=vgs-git" && [[ ! -e $h/.local ]]
}
foreign_row() { # BIN: a ~/.local/bin/vgsh install.sh did not make refuses and stays
  new_home foreign
  mkdir -p "$h/.local/bin"
  ln -s /opt/elsewhere/vgsh "$h/.local/bin/vgsh"
  run "$1"
  refused 1 "install.sh: refused: link=foreign path=$h/.local/bin/vgsh" &&
    [[ $(readlink -- "$h/.local/bin/vgsh") == /opt/elsewhere/vgsh && ! -e $d ]]
}

# The --git fixture: a bare repository main is cloned from, through the
# fixture home's url.insteadOf.
bare="$tmp/vgs.git"; seed="$tmp/seed"
source_tree "$seed" 0.2.0
g init -q -b main "$seed"; g -C "$seed" add -A; g -C "$seed" commit -q -m seed
g init -q --bare "$bare"; g -C "$seed" push -q "$bare" main
# git_home NAME: a new home with release v0.1.0 and a --git clone installed.
git_home() {
  new_home "$1"
  HOME="$h" GIT_CONFIG_NOSYSTEM=1 git config --global url."file://$bare".insteadOf https://github.com/vanillagreencom/vgs.git
  run "$installer" --version 0.1.0
  [[ $status == 0 ]] || { echo "$suite: fixture=release status=$status" >&2; cat "$tmp/err" >&2; exit 1; }
  run "$installer" --git
  [[ $status == 0 ]] || { echo "$suite: fixture=git status=$status" >&2; cat "$tmp/err" >&2; exit 1; }
}
modified_row() { # BIN: --uninstall refuses a clone with changes
  git_home modified
  printf 'change\n' >>"$d/git/VERSION"
  run "$1" --uninstall
  refused 1 "install.sh: refused: modified=$d/git" && [[ -d $d/git && -d $d/0.1.0 && -L $h/.local/bin/vgsh ]]
}
unpublished_row() { # BIN: --uninstall refuses a clone with a commit on HEAD no remote branch has
  git_home unpublished
  g -C "$d/git" commit -q --allow-empty -m local
  run "$1" --uninstall
  refused 1 "install.sh: refused: unpublished=1 path=$d/git" && [[ -d $d/git ]]
}
branch_row() { # BIN: --uninstall refuses a clone whose other local branch holds such a commit
  git_home branch
  g -C "$d/git" switch -q -c topic
  g -C "$d/git" commit -q --allow-empty -m local
  g -C "$d/git" switch -q main
  run "$1" --uninstall
  refused 1 "install.sh: refused: unpublished=1 path=$d/git" && [[ -d $d/git ]]
}
stash_row() { # BIN: --uninstall refuses a clone holding a stash
  git_home stash
  printf 'change\n' >>"$d/git/VERSION"
  g -C "$d/git" stash -q
  run "$1" --uninstall
  refused 1 "install.sh: refused: stash=present path=$d/git" && [[ -d $d/git ]]
}
rt_shell="$tmp/rt-shell"; mkdir -p "$rt_shell"
running_row() { # BIN: --uninstall refuses while the running shell was started from a tree it removes
  local pid ok=0
  git_home running
  # A stand-in for the running shell: one process whose command line names
  # the tree as `qs -p <tree>/shell` does, ended once the row has run.
  python3 -c 'import time; time.sleep(30)' -p "$d/0.1.0/shell" </dev/null >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$rt_shell/vgsh.lock"
  RUN_RT="$rt_shell" run "$1" --uninstall --force
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  refused 1 "install.sh: refused: shell=running pid=$pid path=$d/0.1.0" && [[ -d $d/0.1.0 ]] || ok=1
  return "$ok"
}
keep_foreign_row() { # BIN: --uninstall removes the install and keeps a foreign link
  new_home keep-foreign
  run "$installer"
  ln -sfn /opt/elsewhere/vgsh "$h/.local/bin/vgsh"
  run "$1" --uninstall
  [[ $status == 0 && ! -e $d/current && ! -e $d/0.2.0 && $(readlink -- "$h/.local/bin/vgsh") == /opt/elsewhere/vgsh ]] &&
    out_has "kept=$h/.local/bin/vgsh reason=foreign"
}

echo "releases"
new_home latest
run "$installer"
check "the newest release installs" test "$status" = 0
check "it names the release it installed" out_has "ok installed=vgs version=0.2.0 path=$d/0.2.0"
check "a release with no signature says so" out_has "signature=unchecked reason=no-signature"
check "the version directory holds the release's runtime tree" test -f "$d/0.2.0/bin/vgsh" -a -f "$d/0.2.0/VERSION" -a ! -e "$d/0.2.0/share"
check "current is a relative link to the version" test -L "$d/current" -a "$(readlink -- "$d/current")" = 0.2.0
check "the command links to current's vgsh" test -L "$h/.local/bin/vgsh" -a "$(readlink -- "$h/.local/bin/vgsh")" = "$d/current/bin/vgsh"
check "it prints the Hyprland autostart line" out_has "  hl.on(\"hyprland.start\", function () hl.exec_cmd(\"$h/.local/bin/vgsh run\") end)"
check "it names a command directory missing from PATH" out_has "path=missing dir=$h/.local/bin: add it to PATH to run vgsh by name"
check "it leaves no staging directory" no_stage
check "it leaves nothing in TMPDIR" scratch_empty
check "the linked vgsh runs the installed tree" test "$("${base_env[@]}" HOME="$h" "$h/.local/bin/vgsh" --version)" = "vgs 0.2.0"
"${base_env[@]}" HOME="$h" XDG_CONFIG_HOME="$h/.config" VGS_RELEASE_API=http://127.0.0.1:9 "$h/.local/bin/vgsh" self status --json >"$tmp/status.json" 2>/dev/null
check "vgsh self status judges the layout a curl install" json_is "$tmp/status.json" 'd["method"] == "curl" and d["version"] == "0.2.0" and d["current"] == "0.2.0"'

new_home pinned
run "$installer" --version v0.1.0
check "--version installs the release it names" test "$status" = 0 -a "$(readlink -- "$d/current")" = 0.1.0
run "$installer" --version 0.2.0
check "a reinstall of a newer release succeeds" test "$status" = 0
check "the reinstall swaps current to the new version" test -L "$d/current" -a "$(readlink -- "$d/current")" = 0.2.0
check "the reinstall keeps the earlier version's tree" test -f "$d/0.1.0/VERSION"
run "$installer"
check "the installed release again is up to date" out_has "ok up-to-date=vgs version=0.2.0 path=$d/0.2.0"
check "an up-to-date run leaves current alone" test "$(readlink -- "$d/current")" = 0.2.0
new_home stage
mkdir -p "$d/.self-update-dead"
run "$installer"
check "a writer under the lock removes a dead run's staging directory" no_stage

check "a checksum mismatch refuses and leaves nothing: no data directory, no link, no download" mismatch_row "$installer"
check "an archive SHA256SUMS does not list refuses and leaves nothing" unlisted_row "$installer"
check "a release tag that is no version refuses" tag_row "$installer"
new_home missing
run "$installer" --version 0.9.0
check "a release that does not exist refuses on the fetch" test "$status" = 1 -a "$(first_err | cut -d' ' -f3-4)" = "release=failed url=file://$www/repos/vanillagreencom/vgs/releases/tags/v0.9.0"
check "an archive with another top directory refuses and leaves current, no version and no stage" layout_row "$installer"
check "a held self lock refuses with 75 and installs nothing" busy_row "$installer"

echo "signatures"
new_home sig-none
run "$installer" --version 0.5.0
check "with no release key published the signature is unchecked" out_has "signature=unchecked reason=no-release-key"
new_home sig-good
RUN_GNUPG="$keys" run "$signing" --version 0.5.0
check "a signature by the release key passes" test "$status" = 0
check "it names the key" out_has "signature=good key=$release_fpr"
check "a signature by another key in the keyring refuses and leaves nothing" signature_other_row "$signing"
new_home sig-unimported
run "$signing" --version 0.5.0
check "a release key gpg does not hold leaves the signature unchecked" out_has "signature=unchecked reason=key-not-imported key=$release_fpr"

echo "refusals"
new_home args
run "$installer" --version 1.2
check "a malformed --version exits 2" refused 2 "install.sh: refused: version=1.2"
run "$installer" --git --uninstall
check "--git with --uninstall exits 2" refused 2 "install.sh: refused: argument=--uninstall conflict=--git"
run "$installer" --version 0.1.0 --git
check "--version with --git exits 2" refused 2 "install.sh: refused: argument=--version conflict=--git"
check "root is refused" root_row "$installer"
check "a system other than Linux is refused" os_row "$installer"
check "an installed system package is refused" system_row "$installer"
RUN_PATH="$vgs_db:$run_path" run "$installer" --force
check "--force installs beside a system package" test "$status" = 0
check "a command install.sh did not make is refused and stays" foreign_row "$installer"
run "$installer" --force
check "--force replaces the foreign link" test "$status" = 0 -a "$(readlink -- "$h/.local/bin/vgsh")" = "$d/current/bin/vgsh"

echo "floor"
arch_os="$tmp/os-arch"; printf 'NAME="Arch Linux"\nID=arch\n' >"$arch_os"
pm_all="$tmp/pm-all"; mkdir -p "$pm_all"
for pm in pacman apt-get dnf5 dnf xbps-install emerge nix; do stub "$pm_all" "$pm" "" 1; done
low="$tmp/low"; mkdir -p "$low"
stub "$low" Hyprland "Hyprland 0.55.2 built from branch fixture"
new_home floor
with_os "$arch_os"
RUN_PATH="$low:$pm_all:$tools_nogit" run "$installer" --version 0.1.0
RUN_WRAP=()
check "a floor miss exits 78" test "$status" = 78
check "a missing tool is named with have=none" err_has "install.sh: refused: floor=quickshell have=none need=0.3.1"
check "a tool below its floor names its version" err_has "install.sh: refused: floor=hyprland have=0.55.2 need=0.56"
check "every miss is named, not the first alone" err_has "install.sh: refused: floor=git have=none need=present"
check "the miss names the distribution's install command" err_has "Install them as root: pacman -S --needed -- quickshell hyprland git"
check "the floor miss writes nothing" test ! -e "$h/.local"
check "the floor miss leaves nothing in TMPDIR" scratch_empty

# Hyprland's main() throws before it parses --version when XDG_RUNTIME_DIR
# is unset: an uncaught std::runtime_error, so SIGABRT and 134.
# $needs_rt's Hyprland answers only with XDG_RUNTIME_DIR set, $aborts'
# never does.
hyprland_abort() { # DIR CONDITION: a Hyprland that aborts while CONDITION holds
  cat >"$1/Hyprland" <<SH
#!/bin/sh
if $2; then
  echo "terminate called after throwing an instance of 'std::runtime_error'" >&2
  echo "  what():  XDG_RUNTIME_DIR is not set!" >&2
  exit 134
fi
echo "Hyprland 0.56 built from branch fixture"
SH
  chmod +x "$1/Hyprland"
}
needs_rt="$tmp/needs-rt"; aborts="$tmp/aborts"; mkdir -p "$needs_rt" "$aborts"
hyprland_abort "$needs_rt" '[ -z "${XDG_RUNTIME_DIR:-}" ]'
hyprland_abort "$aborts" true
runtime_row() { # BIN: a Hyprland that aborts with no XDG_RUNTIME_DIR meets the floor when the caller has none
  new_home runtime
  RUN_WRAP=(env -u XDG_RUNTIME_DIR)
  RUN_PATH="$needs_rt:$run_path" run "$1" --version 0.1.0
  RUN_WRAP=()
  [[ $status == 0 ]] && ! grep -q -e '^install\.sh: refused: floor=' -e '^Install them' "$tmp/err" && scratch_empty
}
unreadable_row() { # BIN: an installed Hyprland whose version cannot be read is named with its cause, not an install command
  new_home unreadable
  with_os "$arch_os"
  RUN_PATH="$aborts:$stubs:$pm_all:$tools" run "$1" --version 0.1.0
  RUN_WRAP=()
  refused 78 "install.sh: refused: floor=hyprland have=unknown need=0.56" &&
    err_has "hyprland is installed, but its version could not be read: Hyprland --version exited 134:" &&
    err_has "    what():  XDG_RUNTIME_DIR is not set!" &&
    ! grep -q -e '^Install them' -e '^No supported package manager' "$tmp/err" &&
    [[ ! -e $h/.local ]] && scratch_empty
}
check "a Hyprland that needs a runtime directory meets the floor from a shell with none" runtime_row "$installer"
check "an installed Hyprland whose version cannot be read is named with its exit and error, not an install command" unreadable_row "$installer"

# The distributions: os-release text and the package managers on PATH. Each
# row leaves git missing and compares the command install.sh names with the
# one `vgsh pkg detect` and `vgsh pkg plan install` give on the same system.
pm_dnf4="$tmp/pm-dnf4"; mkdir -p "$pm_dnf4"; stub "$pm_dnf4" dnf "" 1
pm_none="$tmp/pm-none"; mkdir -p "$pm_none"
distros=(
  "arch|ID=arch|$pm_all"
  "cachyos|ID=cachyos\nID_LIKE=arch|$pm_all"
  "fedora with dnf5|ID=fedora|$pm_all"
  "fedora with dnf 4|ID=fedora|$pm_dnf4"
  "debian|ID=debian|$pm_all"
  "pop, like ubuntu|ID=pop\nID_LIKE=\"ubuntu debian\"|$pm_all"
  "void|ID=\"void\"|$pm_all"
  "gentoo|ID=gentoo|$pm_all"
  "nixos|ID=nixos|$pm_all"
  "an unknown distribution|ID=plan9|$pm_all"
  "arch without pacman|ID=arch|$pm_none"
)
# The package config/requirements.json names for COMMAND on MANAGER.
requirement_package() { # COMMAND MANAGER
  python3 -c 'import json, sys
rows = [r for r in json.load(open(sys.argv[1])) if r["command"] == sys.argv[2]]
print(rows[0]["packages"][sys.argv[3]])' "$repo/config/requirements.json" "$1" "$2"
}
distro_row() { # BIN NAME OS_TEXT PM_DIR: install.sh names the command vgsh pkg plans
  local os="$tmp/os-row" want detect id plan
  printf '%b\n' "$3" >"$os"
  detect="$("$unshare_bin" -rm sh -c 'mount --bind "$1" /etc/os-release && shift && exec "$@"' sh "$os" \
    "${base_env[@]}" PATH="$4:$tools" "$repo/bin/vgsh" pkg detect --json)" || return 1
  id="$(python3 -c 'import json, sys
p = json.loads(sys.argv[1])["primary"]
print(p["id"] if p else "-")' "$detect")"
  if [[ $id == - ]]; then
    want="No supported package manager found: install git with your distribution's package manager."
  elif plan="$("${base_env[@]}" PATH="$4:$tools" "$repo/bin/vgsh" pkg plan install "$id" "$(requirement_package git "$id")" 2>/dev/null)"; then
    want="$(python3 -c 'import json, sys
p = json.loads(sys.argv[1])
print(("Install them as root: " if p["elevate"] else "Install them: ") + " ".join(p["steps"][0]))' "$plan")"
  else
    want="Add these $id packages to your system configuration: $(requirement_package git "$id")"
  fi
  new_home distro
  with_os "$os"
  RUN_PATH="$stubs:$4:$tools_nogit" run "$1" --version 0.1.0
  RUN_WRAP=()
  if [[ $status == 78 ]] && err_has "$want"; then return 0; fi
  printf '    want [%s]\n' "$want"
  sed 's/^/    got  /' "$tmp/err"
  return 1
}
for row in "${distros[@]}"; do
  IFS='|' read -r name os_text pm_dir <<<"$row"
  check "on $name install.sh names vgsh pkg's install command" distro_row "$installer" "$name" "$os_text" "$pm_dir"
done

# The tables against their sources, read by node from the files themselves.
drift_row() { # BIN: prints each drift, fails on any
  node - "$1" "$repo/bin/vgsh" "$repo/config/requirements.json" <<'JS'
"use strict";
const fs = require("fs");
const [installer, vgsh, requirementsFile] = process.argv.slice(2);
const block = (text, name, file) => {
    const m = new RegExp("\\n\\s*" + name + "='\\n([\\s\\S]*?)\\n'\\n").exec(text);
    if (m === null) { console.log("extractor=broken block=" + name + " file=" + file); process.exit(1); }
    return m[1].split("\n").filter(l => l.trim() !== "").map(l => l.trim().split(/\s+/));
};
const script = fs.readFileSync(installer, "utf8");
const floor = block(script, "floor", installer);
const packages = block(script, "packages", installer);
const preflight = block(fs.readFileSync(vgsh, "utf8"), "preflight_floor", vgsh);
const required = JSON.parse(fs.readFileSync(requirementsFile, "utf8")).filter(r => !r.optional);
// Floors: a broken extractor reads fewer rows than the sources hold today.
if (floor.length < 6 || packages.length < 6 || preflight.length < 5 || required.length < 4) {
    console.log("extractor=broken floor=" + floor.length + " packages=" + packages.length + " preflight=" + preflight.length + " required=" + required.length);
    process.exit(1);
}
const drift = [];
const floorRow = new Map(floor.map(r => [r[0], r]));
for (const p of preflight) {
    const f = floorRow.get(p[0]);
    if (f === undefined) { drift.push("floor=" + p[0] + " reason=missing"); continue; }
    if (f[1] !== p[1]) drift.push("floor=" + p[0] + " need=" + f[1] + " preflight=" + p[1]);
    // Hyprland alone is probed differently: its binary, not the session.
    if (p[0] !== "hyprland" && f.slice(2).join(" ") !== p.slice(2).join(" ")) drift.push("floor=" + p[0] + " reason=probe");
}
const packageRow = new Map(packages.map(r => [r[0], new Map(r.slice(1).map(pair => pair.split("=")))]));
for (const r of required) {
    if (!floorRow.has(r.command)) drift.push("floor=" + r.command + " reason=missing-requirement");
    const mine = packageRow.get(r.command);
    if (mine === undefined) { drift.push("packages=" + r.command + " reason=missing"); continue; }
    const want = Object.entries(r.packages).sort().join(" ");
    const have = [...mine.entries()].sort().join(" ");
    if (want !== have) drift.push("packages=" + r.command + " have=" + have + " want=" + want);
}
for (const tool of floorRow.keys()) if (!packageRow.has(tool)) drift.push("packages=" + tool + " reason=no-row");
for (const d of drift) console.log(d);
process.exit(drift.length === 0 ? 0 : 1);
JS
}
check "the floor and package tables match bin/vgsh and config/requirements.json" drift_row "$installer"

echo "git"
git_home git
check "--git clones main" test "$(g -C "$d/git" rev-parse HEAD)" = "$(g -C "$bare" rev-parse main)"
check "--git names the clone" out_has "ok installed=vgs git=$d/git"
check "--git points the command at the clone" test "$(readlink -- "$h/.local/bin/vgsh")" = "$d/git/bin/vgsh"
check "--git leaves the release's current alone" test "$(readlink -- "$d/current")" = 0.1.0
"${base_env[@]}" HOME="$h" XDG_CONFIG_HOME="$h/.config" "$h/.local/bin/vgsh" self status --json >"$tmp/status.json" 2>/dev/null
check "vgsh self status judges the clone a checkout" json_is "$tmp/status.json" 'd["method"] == "checkout"'
run "$installer" --git
check "a second --git refuses" refused 1 "install.sh: refused: git=exists path=$d/git"

echo "uninstall"
check "--uninstall refuses a clone with changes and removes nothing" modified_row "$installer"
check "--uninstall refuses a clone with a commit no remote branch has" unpublished_row "$installer"
check "--uninstall refuses a clone whose other local branch holds such a commit" branch_row "$installer"
check "--uninstall refuses a clone holding a stash" stash_row "$installer"
check "--uninstall refuses while the running shell was started from a tree it removes" running_row "$installer"
git_home uninstall
mkdir -p "$h/.config/vgs" "$h/.local/state/vgs"
printf 'mine\n' >"$h/.config/vgs/shell.json"; printf 'mine\n' >"$h/.local/state/vgs/applied.json"
printf 'other\n' >"$d/notes"
run "$installer" --uninstall
check "--uninstall succeeds" test "$status" = 0
check "it removes the versions, current and the clone" test ! -e "$d/0.1.0" -a ! -e "$d/current" -a ! -e "$d/git"
check "it keeps a file it did not install" test -f "$d/notes"
check "it says it kept the data directory" out_has "kept=$d reason=not-vgs-files"
check "it removes the link" test ! -e "$h/.local/bin/vgsh" -a ! -L "$h/.local/bin/vgsh"
check "it keeps the configuration" test -f "$h/.config/vgs/shell.json"
check "it names the configuration it kept" out_has "kept=$h/.config/vgs"
check "it keeps the state" test -f "$h/.local/state/vgs/applied.json"
check "it names the state it kept" out_has "kept=$h/.local/state/vgs"
lock_kept_row() { # BIN: --uninstall keeps the lock file, the inode a concurrent writer may hold open
  local inode
  git_home lock-kept
  inode="$(stat -c %i -- "$d/.self.lock")"
  run "$1" --uninstall
  [[ $status == 0 && ! -e $d/current && $(stat -c %i -- "$d/.self.lock" 2>/dev/null) == "$inode" ]]
}
check "it keeps the lock a concurrent writer may hold open" lock_kept_row "$installer"
check "--uninstall keeps a foreign link and names it" keep_foreign_row "$installer"

echo "truncation"
# truncated_row BIN: no prefix of BIN piped to bash runs a command. The
# cuts are every line end, every 97th byte and every byte of the last 256,
# which hold main's call; bash -x traces each command it runs as a line
# starting with +.
truncated_row() {
  local size cut body LC_ALL=C
  local -a cuts
  # A cut that drops only the trailing newlines leaves the whole script.
  body="$(<"$1")"
  size="${#body}"
  mapfile -t cuts < <({ LC_ALL=C awk '{ n += length($0) + 1; print n }' "$1"; seq 97 97 "$size"; seq $((size > 256 ? size - 256 : 1)) "$size"; } | sort -nu)
  ((${#cuts[@]} > 300)) || { echo "    cuts=${#cuts[@]}: the cut extractor read too few"; return 1; }
  new_home truncated
  for cut in "${cuts[@]}"; do
    ((cut < size)) || continue
    head -c "$cut" "$1" | env -i PATH="$run_path" HOME="$h" TMPDIR="$scratch" VGS_TEST_RUN=1 VGS_RELEASE_API="file://$www" \
      XDG_RUNTIME_DIR="$rt_empty" bash -x >/dev/null 2>"$tmp/trace" || true
    if grep -q '^+' "$tmp/trace"; then
      echo "    cut=$cut ran: $(grep -m1 '^+' "$tmp/trace")"
      return 1
    fi
  done
  [[ ! -e $h/.local ]]
}
check "no truncated download of install.sh runs a command" truncated_row "$installer"

echo "controls"
# control NAME ROW [ARGS...]: ROW must fail on $copy, which the caller made.
control() {
  local name="$1" row="$2"
  shift 2
  if "$row" "$copy" "$@" >/dev/null; then fail "control: $name: $row passed on the copy"; else ok "control: $name"; fi
}
# unwrap NAME DROP...: sets copy to install.sh without the wrapper lines
# DROP names: group-open, main-open, main-close, call, group-close.
unwrap() {
  local name="$1"
  shift
  copy="$tmp/copies/$name"
  mkdir -p "$tmp/copies"
  python3 - "$installer" "$copy" "$@" <<'PY'
import sys
source, target, drop = sys.argv[1], sys.argv[2], set(sys.argv[3:])
lines = open(source).read().split("\n")
closes = [i for i, l in enumerate(lines) if l == "}"]
wrapper = {
    "group-open": lines.index("{"),
    "main-open": lines.index("main() {"),
    "main-close": closes[-2],
    "call": lines.index('main "$@"'),
    "group-close": closes[-1],
}
order = [wrapper[k] for k in ("group-open", "main-open", "main-close", "call", "group-close")]
if order != sorted(order) or len(set(order)) != 5:
    sys.exit("unwrap: wrapper=unrecognised lines=" + str(order))
cut = {wrapper[k] for k in drop}
open(target, "w").write("\n".join(l for i, l in enumerate(lines) if i not in cut))
PY
}
unwrap unwrapped group-open main-open main-close call group-close
control "a copy with the body outside main runs a truncated download" truncated_row
unwrap ungrouped group-open group-close
control "a copy whose call of main stands outside the group runs a cut after the word main" truncated_row

# rule NAME ROW NEEDLE REPLACEMENT: a copy of install.sh without one rule,
# NEEDLE replaced, on which ROW, the row that judges the rule, must fail.
rule() {
  copy_with "$1" "$installer" "$3" "$4"
  control "a copy without the $1 rule" "$2"
}
rule checksum mismatch_row '[[ $got == "$want" ]] ||' '[[ $got == "$got" ]] ||'
rule sum-count unlisted_row '((count == 1)) || refuse 1 "checksum=unlisted' '((count == count)) || refuse 1 "checksum=unlisted'
rule tag tag_row '[[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||' '[[ v0.8.0 =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||'
rule layout layout_row 'if ((${#top[@]} != 1)) || [[' 'if ((${#top[@]} != 1)) && [['
rule lock busy_row 'flock -n 9 || refuse 75' 'flock -n 9 || true || refuse 75'
rule root root_row '((EUID != 0)) ||' '((EUID != -1)) ||'
rule os os_row '[[ $os == Linux ]] ||' '[[ $os == "$os" ]] ||'
rule package-database system_row 'pacman -Q -- "$name" >/dev/null 2>&1; then' 'pacman -Q -- "$name" >/dev/null 2>&1 && false; then'
rule foreign-link foreign_row '&& $(link_state) == foreign ]]' '&& $(link_state) == none ]]'
rule modified-clone modified_row '[[ -z $out ]] || refuse 1 "modified=' 'true || refuse 1 "modified='
rule unpublished-commit unpublished_row '((out == 0)) || refuse 1 "unpublished=' 'true || refuse 1 "unpublished='
rule other-branches branch_row 'rev-list --count HEAD --branches --not --remotes' 'rev-list --count HEAD --not --remotes'
rule stash stash_row 'if "${git_in[@]}" rev-parse -q --verify refs/stash >/dev/null; then' 'if false; then'
rule running-shell running_row 'if [[ $tree == "$(readlink -f -- "$data")"/* ]]; then' 'if false; then'
rule keep-foreign-link keep_foreign_row '[[ $state != ours ]] || rm -f -- "$link"' 'rm -f -- "$link"'
rule keep-lock lock_kept_row '^(current|git|\.self-update-.*|[0-9]+' '^(current|git|\.self\.lock|\.self-update-.*|[0-9]+'
rule floor-need drift_row 'quickshell 0.3.1   ^Quickshell' 'quickshell 0.3.0   ^Quickshell'
rule requirement-package drift_row 'dnf=util-linux-core' 'dnf=util-linux'
rule probe-runtime runtime_row 'XDG_RUNTIME_DIR="$tmp/runtime" "${argv[@]}"' 'XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" "${argv[@]}"'
rule unknown-not-installable unreadable_row '[[ $have == unknown ]] || names+=' '[[ $have == nothing ]] || names+='
copy_with manager-order "$installer" 'fedora        dnf5,dnf' 'fedora        dnf,dnf5'
control "a copy that prefers dnf 4 over dnf5" distro_row "fedora with dnf5" "ID=fedora" "$pm_all"
copy_with any-key "$signing" '[[ ${field[2]} == "$release_key" ||' '[[ -n ${field[2]} ||'
control "a copy that accepts a signature by any key in the keyring" signature_other_row

rows_done "$suite"
