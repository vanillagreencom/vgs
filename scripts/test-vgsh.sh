#!/usr/bin/env bash
# Controls for bin/vgsh against a stub qs on PATH. Each row pins a reply,
# an exit status or a keyed refusal the header promises. No shell starts:
# `run` execs the stub, which records the identity it was handed.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
# One row removes a directory's permission bits, which bind only a non-root
# uid; a run that could not measure it is not a pass.
if [[ $(id -u) == 0 ]]; then
  echo "test-vgsh: status=not-measured reason=euid-0"
  exit 77
fi
tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp:?}"' EXIT

# The stub answers `qs ipc ... call <target> <fn> ...` from STUB_REPLY and
# STUB_STATUS, prints STUB_NOISE on stdout before the reply (as qs does with
# its log) and STUB_STDERR on stderr after it. Invoked as the shell (no
# `ipc` argument) it records its pid, VGSH_RUNNER_PID and its arguments in
# STUB_RECORD and exits 0.
cat >"$tmp/qs" <<'EOF2'
#!/usr/bin/env bash
if [[ ${1:-} != ipc && ${1:-} != log ]]; then
  printf 'pid=%s runner=%s args=%s\n' "$$" "${VGSH_RUNNER_PID:-unset}" "$*" >"${STUB_RECORD:?}"
  exit 0
fi
printf '%s\n' "$*" >"${STUB_ARGS:-/dev/null}"
[[ -n ${STUB_NOISE:-} ]] && printf '%s\n' "$STUB_NOISE"
printf '%s\n' "${STUB_REPLY:-ok}"
[[ -n ${STUB_STDERR:-} ]] && printf '%s\n' "$STUB_STDERR" >&2
exit "${STUB_STATUS:-0}"
EOF2
chmod +x "$tmp/qs"

# Every row runs with this environment and nothing else. The runtime dir
# holds the lock file; `live` names a lock file recording this process,
# which is alive, so the CLI addresses it.
rt_live="$tmp/rt-live"; mkdir -p "$rt_live"; printf '%s\n' "$$" >"$rt_live/vgsh.lock"
rt_empty="$tmp/rt-empty"; mkdir -p "$rt_empty"
# node on PATH may be a version-manager shim that reads the developer's own
# configuration; the rows put the binary it resolves to ahead of it.
if ! node_bin="$(node -e 'process.stdout.write(process.execPath)')"; then
  echo "test-vgsh: status=not-measured missing=node"
  exit 77
fi
base_env=(env -i PATH="$tmp:$(dirname -- "$node_bin"):$PATH" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" GIT_CONFIG_NOSYSTEM=1)

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# rows: name | runtime dir | env | args | want stdout (last line) | want exit | want stderr (first line)
# A refusal row pins its keyed first line; a success row pins an empty stderr.
run_row() { # NAME RT ENVSTR ARGS WANT_OUT WANT_EXIT WANT_ERR
  local name="$1" rt="$2" envstr="$3" args="$4" want_out="$5" want_exit="$6" want_err="$7" out status err=""
  set +e
  # shellcheck disable=SC2086
  out="$("${base_env[@]}" XDG_RUNTIME_DIR="$rt" $envstr "$repo/bin/vgsh" $args 2>"$tmp/err")"
  status=$?
  set -e
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  local last="${out##*$'\n'}"
  if [[ $status == "$want_exit" && $last == "$want_out" && $err == "$want_err" ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit last=[$last] want=[$want_out] stderr=[$err] want=[$want_err]"; fi
}

list_json='{"plugins":[{"id":"vgs.bar","version":"0.1.0","kinds":["bar"],"enabled":true,"dir":"/x"}],"errors":[],"collisions":[],"scanError":"","scanned":true}'
dead_pid="$(( $(cat /proc/sys/kernel/pid_max) + 1 ))"

run_row "enable prints ok" "$rt_live" "STUB_REPLY=ok" "plugin enable vgs.clock" "ok" 0 ""
run_row "reply is the last stdout line, log noise ahead of it is ignored" "$rt_live" "STUB_REPLY=ok STUB_NOISE=INFO:something" "plugin enable vgs.clock" "ok" 0 ""
run_row "stderr after the reply does not become the reply" "$rt_live" "STUB_REPLY=ok STUB_STDERR=WARN:late" "plugin enable vgs.clock" "ok" 0 "WARN:late"
run_row "an unexpected reply is a refusal" "$rt_live" "STUB_REPLY=ok_hidden" "plugin disable vgs.bar" "" 1 "vgsh: refused: ok_hidden"
run_row "a guard refusal from the shell is a refusal with exit 1" "$rt_live" "STUB_REPLY=refused:_guard=unowned" "plugin enable vgs.clock" "" 1 "vgsh: refused: refused:_guard=unowned"
run_row "unknown id is a refusal with exit 1" "$rt_live" "STUB_REPLY=unknown:_x" "plugin enable x" "" 1 "vgsh: refused: unknown:_x"
run_row "an ipc failure exits 69 on enable" "$rt_live" "STUB_STATUS=1 STUB_REPLY=none" "plugin enable vgs.clock" "" 69 "vgsh: refused: shell=not-running pid=$$"
run_row "an ipc failure exits 69 on list" "$rt_live" "STUB_STATUS=1 STUB_REPLY=none" "plugin list" "" 69 "vgsh: refused: shell=not-running pid=$$"
run_row "no lock file exits 69 without calling qs" "$rt_empty" "STUB_REPLY=ok" "plugin enable vgs.clock" "" 69 "vgsh: refused: shell=not-running lock=$rt_empty/vgsh.lock"
run_row "no lock file exits 69 on ipc" "$rt_empty" "STUB_REPLY=ok" "ipc call shell ping" "" 69 "vgsh: refused: shell=not-running lock=$rt_empty/vgsh.lock"
run_row "pid prints the pid the lock file records" "$rt_live" "" "pid" "$$" 0 ""
run_row "pid with no lock file exits 69" "$rt_empty" "" "pid" "" 69 "vgsh: refused: shell=not-running lock=$rt_empty/vgsh.lock"
run_row "list formats one row per plugin" "$rt_live" "STUB_REPLY=$list_json" "plugin list" "vgs.bar                      0.1.0    enabled   kinds=bar" 0 ""
run_row "missing id is exit 2" "$rt_live" "" "plugin enable" "" 2 "vgsh: refused: id=missing"
run_row "unknown subcommand is exit 2" "$rt_live" "" "plugin frobnicate" "" 2 "vgsh: refused: plugin-subcommand=frobnicate"
run_row "unknown command is exit 2" "$rt_live" "" "frobnicate" "" 2 "vgsh: refused: command=frobnicate"
run_row "run refuses an argument" "$rt_live" "STUB_RECORD=$tmp/never" "run --daemonize" "" 2 "vgsh: refused: argument=--daemonize"
if [[ ! -e $tmp/never ]]; then ok "a refused run never started the shell"; else fail "a refused run started the shell"; fi

# The recorded pid must be a dead process for the not-running refusal, and
# a pid nothing can own is the one past the kernel's maximum.
rt_dead="$tmp/rt-dead"; mkdir -p "$rt_dead"; printf '%s\n' "$dead_pid" >"$rt_dead/vgsh.lock"
run_row "a lock file naming a dead pid exits 69" "$rt_dead" "STUB_REPLY=ok" "plugin list" "" 69 "vgsh: refused: shell=not-running pid=$dead_pid"
run_row "pid with a lock file naming a dead pid exits 69" "$rt_dead" "" "pid" "" 69 "vgsh: refused: shell=not-running pid=$dead_pid"
rt_junk="$tmp/rt-junk"; mkdir -p "$rt_junk"; printf 'x\n' >"$rt_junk/vgsh.lock"
run_row "a lock file holding no pid exits 69" "$rt_junk" "STUB_REPLY=ok" "plugin list" "" 69 "vgsh: refused: shell=not-running lock=$rt_junk/vgsh.lock"

# Every call addresses the recorded pid, never whichever instance qs picks.
"${base_env[@]}" XDG_RUNTIME_DIR="$rt_live" STUB_ARGS="$tmp/args" STUB_REPLY=ok "$repo/bin/vgsh" plugin enable vgs.clock >/dev/null
if [[ "$(cat "$tmp/args")" == "ipc --pid $$ call shell setPluginEnabled vgs.clock true" ]]; then ok "a manager call names the runner's pid"; else fail "manager call args: $(cat "$tmp/args")"; fi
"${base_env[@]}" XDG_RUNTIME_DIR="$rt_live" STUB_ARGS="$tmp/args" STUB_REPLY=ok "$repo/bin/vgsh" ipc call shell ping >/dev/null
if [[ "$(cat "$tmp/args")" == "ipc --pid $$ call shell ping" ]]; then ok "a raw ipc call names the runner's pid"; else fail "ipc args: $(cat "$tmp/args")"; fi

# The hidden reply carries a space, which env cannot pass; call directly.
set +e
out="$("${base_env[@]}" XDG_RUNTIME_DIR="$rt_live" STUB_REPLY='ok hidden=vgs.clock,vgs.workspaces' "$repo/bin/vgsh" plugin disable vgs.bar 2>/dev/null)"
status=$?
set -e
if [[ $status == 0 && $out == $'ok hidden=vgs.clock,vgs.workspaces\nthose bar widgets stay enabled and return when a bar is enabled' ]]; then ok "disable prints the hidden widgets and the note"; else fail "hidden reply: exit=$status out=[$out]"; fi

# The instance lock. With no holder, run takes the lock, records its pid
# and execs the shell with that pid as its identity; with a holder it exits
# 75 before any shell starts.
rt_run="$tmp/rt-run"; mkdir -p "$rt_run"
set +e
"${base_env[@]}" XDG_RUNTIME_DIR="$rt_run" STUB_RECORD="$tmp/record" "$repo/bin/vgsh" run 2>"$tmp/err"
status=$?
set -e
if [[ $status == 0 && -f $tmp/record ]]; then
  record="$(cat "$tmp/record")"
  pid="${record#pid=}"; pid="${pid%% *}"
  runner="${record#*runner=}"; runner="${runner%% *}"
  args="${record#*args=}"
  if [[ $pid == "$runner" ]]; then ok "run execs the shell with its own pid as the runner identity"; else fail "run identity: $record"; fi
  if [[ "$(cat "$rt_run/vgsh.lock")" == "$pid" ]]; then ok "run records the shell's pid in the lock file"; else fail "lock file holds [$(cat "$rt_run/vgsh.lock")] want $pid"; fi
  if [[ $args == "-p $repo/shell" ]]; then ok "run passes qs the shell path and nothing else"; else fail "run args: $args"; fi
else
  fail "unlocked run: exit=$status record=$([[ -f $tmp/record ]] && echo present || echo absent) stderr=$(head -n 1 "$tmp/err")"
fi

rt_held="$tmp/rt-held"; mkdir -p "$rt_held"; printf '%s\n' "$$" >"$rt_held/vgsh.lock"
exec 8>>"$rt_held/vgsh.lock"
flock 8
set +e
"${base_env[@]}" XDG_RUNTIME_DIR="$rt_held" STUB_RECORD="$tmp/record-held" "$repo/bin/vgsh" run 2>"$tmp/err"
status=$?
set -e
exec 8>&-
if [[ $status == 75 && ! -e $tmp/record-held ]]; then ok "a held lock makes run exit 75 without starting the shell"; else fail "held lock: exit=$status record=$([[ -e $tmp/record-held ]] && echo present || echo absent) stderr=$(head -n 1 "$tmp/err")"; fi
if [[ "$(head -n 1 "$tmp/err")" == "vgsh: refused: lock=$rt_held/vgsh.lock" ]]; then ok "the lock refusal names the lock file"; else fail "lock refusal line: $(head -n 1 "$tmp/err")"; fi
if [[ "$(cat "$rt_held/vgsh.lock")" == "$$" ]]; then ok "a refused run leaves the holder's pid in the lock file"; else fail "lock file after refusal: $(cat "$rt_held/vgsh.lock")"; fi

# Install, update and remove, with local bare repositories as the source.
# Every git call here and in vgsh runs with no system or user git
# configuration, so the developer's hooks and settings never reach a row.
git_env=(env -i PATH="$PATH" HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
  GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid)
g() { "${git_env[@]}" git -c init.defaultBranch=main "$@"; }

# A plugin source: a work tree at $tmp/src/NAME and its bare repository at
# $tmp/src/NAME.git, holding one commit with MANIFEST and a service entry.
source_repo() { # NAME MANIFEST
  local work="$tmp/src/$1"
  mkdir -p "$work"
  printf '%s\n' "$2" >"$work/manifest.json"
  printf 'import QtQuick\nItem { property var shell: null }\n' >"$work/Service.qml"
  g init -q "$work"
  g -C "$work" add -A
  g -C "$work" commit -q -m init
  g init -q --bare "$work.git"
  g -C "$work" push -q "$work.git" main
}
# Commit MANIFEST in source NAME and push it.
source_commit() { # NAME MANIFEST
  local work="$tmp/src/$1"
  printf '%s\n' "$2" >"$work/manifest.json"
  g -C "$work" commit -q -am change
  g -C "$work" push -q "$work.git" main
}
manifest() { # ID VERSION [EXTRA_JSON_MEMBERS]
  printf '{ "schemaVersion": 1, "id": "%s", "name": "Probe", "version": "%s", "author": "acme", "description": "fixture",\n  "kinds": ["service"], "entryPoints": { "service": "Service.qml" }%s }' "$1" "$2" "${3:-}"
}
source_repo probe "$(manifest acme.probe 0.1.0)"
source_repo broken "$(manifest acme.broken 0.1.0 ', "requires": []')"
source_repo taken "$(manifest vgs.bar 0.1.0)"

# inst NAME CONFIG_HOME RUNTIME_DIR WANT_EXIT WANT_LAST_STDOUT WANT_FIRST_STDERR ARGS...
# Stdout lands in $tmp/out for rows that read more than its last line.
inst() {
  local name="$1" cfg="$2" rt="$3" want_exit="$4" want_out="$5" want_err="$6" out err status
  shift 6
  set +e
  out="$("${base_env[@]}" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="$rt" STUB_ARGS="$tmp/args" STUB_REPLY="${INST_REPLY:-ok}" "$repo/bin/vgsh" "$@" 2>"$tmp/err")"
  status=$?
  set -e
  printf '%s\n' "$out" >"$tmp/out"
  err=""
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  local last="${out##*$'\n'}"
  if [[ $status == "$want_exit" && $last == "$want_out" && $err == "$want_err" ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit last=[$last] want=[$want_out] stderr=[$err] want=[$want_err]"; fi
}
check() { # NAME CMD...
  local name="$1"; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
no_residue() { # CONFIG_HOME: nothing staged is left and no plugin landed
  local left
  left="$(find "$1/vgs" -mindepth 1 -maxdepth 2 \( -name '.vgsh-add.*' -o -path "$1/vgs/plugins/*" \) -print)" || return 1
  [[ -z $left ]]
}
json_is() { # FILE PYTHON_EXPR_ON_d: the expression must be true
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"
}
head_of() { g -C "$1" rev-parse HEAD; }

cfg="$tmp/cfg-add"; plugin="$cfg/vgs/plugins/acme.probe"
inst "add installs the plugin and reports no running shell" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
check "add names the plugin, its path and an unchanged configuration" test "$(head -n 1 "$tmp/out")" == "ok added=acme.probe path=$plugin config=unchanged"
check "add lands the plugin under the user plugin directory" json_is "$plugin/manifest.json" 'd["id"] == "acme.probe"'
check "add leaves no staging directory" test -z "$(find "$cfg/vgs" -maxdepth 1 -name '.vgsh-add.*' -print)"
check "add writes no user file for a plugin the configuration does not enable" test ! -e "$cfg/vgs/shell.json"

cfg="$tmp/cfg-listed"; mkdir -p "$cfg/vgs"
printf '{ "version": 1, "plugins": [ { "id": "acme.probe", "label": "kept" } ] }\n' >"$cfg/vgs/shell.json"
inst "add of a plugin the configuration lists succeeds" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
check "add of a listed plugin reports the user file written" test "$(head -n 1 "$tmp/out")" == "ok added=acme.probe path=$cfg/vgs/plugins/acme.probe config=written"
check "add lands a listed plugin disabled and keeps its settings row" json_is "$cfg/vgs/shell.json" 'd["disabledPlugins"] == ["acme.probe"] and d["plugins"] == [{"id": "acme.probe", "label": "kept"}]'

cfg="$tmp/cfg-live"
inst "add rescans a running shell" "$cfg" "$rt_live" 0 "shell=rescan-started" "" plugin add "$tmp/src/probe.git"
check "the rescan names the runner's pid" test "$(cat "$tmp/args")" == "ipc --pid $$ call shell rescanPlugins"
# The plugin landed before the rescan was asked for; a reply the runner does
# not know is a refusal that names it, after the landing line.
cfg="$tmp/cfg-weird"
INST_REPLY=weird inst "add refuses an unknown rescan reply after landing the plugin" "$cfg" "$rt_live" 1 "ok added=acme.probe path=$cfg/vgs/plugins/acme.probe config=unchanged" "vgsh: refused: rescan=weird" plugin add "$tmp/src/probe.git"

cfg="$tmp/cfg-refused"
inst "add refuses a manifest the judge refuses" "$cfg" "$rt_empty" 1 "" "vgsh: refused: manifest=$tmp/src/broken.git" plugin add "$tmp/src/broken.git"
check "a refused manifest leaves no plugin and no staging directory" no_residue "$cfg"
inst "add refuses an id a bundled plugin owns" "$cfg" "$rt_empty" 1 "" "vgsh: refused: id-owned=vgs.bar owner=$repo/shell/plugins/vgs.bar" plugin add "$tmp/src/taken.git"
check "a refused bundled id leaves no plugin and no staging directory" no_residue "$cfg"
inst "add refuses an unreachable source" "$cfg" "$rt_empty" 1 "" "vgsh: refused: clone=$tmp/src/absent.git" plugin add "$tmp/src/absent.git"
check "a refused clone leaves no plugin and no staging directory" no_residue "$cfg"
inst "add without a url is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: url=missing" plugin add

cfg="$tmp/cfg-add"
inst "add refuses an id an installed plugin owns" "$cfg" "$rt_empty" 1 "" "vgsh: refused: id-owned=acme.probe owner=$plugin" plugin add "$tmp/src/probe.git"
cfg="$tmp/cfg-occupied"; mkdir -p "$cfg/vgs/plugins/acme.probe"
inst "add refuses a target directory that holds no plugin" "$cfg" "$rt_empty" 1 "" "vgsh: refused: exists=$cfg/vgs/plugins/acme.probe" plugin add "$tmp/src/probe.git"
# A plugin directory the scan cannot read may hold the id. Permission bits
# bind only a non-root uid.
if [[ $(id -u) != 0 ]]; then
  cfg="$tmp/cfg-locked"; mkdir -p "$cfg/vgs/plugins/locked"; chmod 000 "$cfg/vgs/plugins/locked"
  inst "add refuses when a plugin directory cannot be read" "$cfg" "$rt_empty" 1 "" "vgsh: refused: unreadable=$cfg/vgs/plugins/locked error=cannot read manifest: Permission denied" plugin add "$tmp/src/probe.git"
  chmod 700 "$cfg/vgs/plugins/locked"
fi
cfg="$tmp/cfg-unparseable"; mkdir -p "$cfg/vgs"; printf '{ nope\n' >"$cfg/vgs/shell.json"
inst "add refuses while the user file does not parse" "$cfg" "$rt_empty" 1 "" "vgsh: refused: user-config=unparseable path=$cfg/vgs/shell.json" plugin add "$tmp/src/probe.git"
check "a refused user file leaves no plugin and no staging directory" no_residue "$cfg"
cfg="$tmp/cfg-malformed"; mkdir -p "$cfg/vgs"; printf '{ "version": 1, "plugins": [ { "id": "acme.probe" }, "junk" ] }\n' >"$cfg/vgs/shell.json"
inst "add refuses a user file the config judge refuses" "$cfg" "$rt_empty" 1 "" "vgsh: refused: user-config=malformed path=$cfg/vgs/shell.json error=plugins.1 must be an object with a string id" plugin add "$tmp/src/probe.git"
check "a malformed user file leaves no plugin and no staging directory" no_residue "$cfg"
check "a malformed user file is left as it was" grep -q '"junk"' "$cfg/vgs/shell.json"

# Update against the plugin the first add row installed.
cfg="$tmp/cfg-add"
inst "update with nothing new is up to date" "$cfg" "$rt_empty" 0 "ok up-to-date=acme.probe" "" plugin update acme.probe
source_commit probe "$(manifest acme.probe 0.2.0)"
before="$(head_of "$plugin")"
inst "update fast-forwards a new commit" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin update acme.probe
after="$(head_of "$plugin")"
check "update reports both commits" grep -qx "ok updated=acme.probe from=${before:0:12} to=${after:0:12}" "$tmp/out"
check "update prints the incoming diff" grep -q '^+.*"version": "0.2.0"' "$tmp/out"
check "update leaves the new version installed" json_is "$plugin/manifest.json" 'd["version"] == "0.2.0"'

printf 'local\n' >"$plugin/notes.txt"
inst "update refuses a checkout with an untracked file" "$cfg" "$rt_empty" 1 "" "vgsh: refused: modified=$plugin" plugin update acme.probe
rm -f -- "$plugin/notes.txt"

# A refused update still shows its diff first; its last line ends stdout.
diff_last() { local d; d="$(g -C "$tmp/src/probe" diff "$good" HEAD)" || return 1; printf '%s\n' "${d##*$'\n'}"; }
good="$(head_of "$plugin")"
source_commit probe "$(manifest acme.probe 0.3.0 ', "requires": []')"
inst "update refuses a new manifest the judge refuses" "$cfg" "$rt_empty" 1 "$(diff_last)" "vgsh: refused: manifest=acme.probe rolled-back=${good:0:12}" plugin update acme.probe
check "a refused manifest rolls the checkout back" test "$(head_of "$plugin")" == "$good"
check "a refused manifest leaves the accepted version in place" json_is "$plugin/manifest.json" 'd["version"] == "0.2.0"'
source_commit probe "$(manifest acme.renamed 0.3.0)"
inst "update refuses a new manifest naming another id" "$cfg" "$rt_empty" 1 "$(diff_last)" "vgsh: refused: manifest-id=acme.renamed want=acme.probe rolled-back=${good:0:12}" plugin update acme.probe
check "a renamed id rolls the checkout back" test "$(head_of "$plugin")" == "$good"

# Rewrite the installed commit itself, so the installed head is no ancestor.
g -C "$tmp/src/probe" reset -q --hard "$good"
g -C "$tmp/src/probe" commit -q --amend -m rewritten
g -C "$tmp/src/probe" push -q --force "$tmp/src/probe.git" main
inst "update refuses a source that rewrote its history" "$cfg" "$rt_empty" 1 "" "vgsh: refused: not-fast-forward=acme.probe" plugin update acme.probe
check "a refused rewrite leaves the checkout alone" test "$(head_of "$plugin")" == "$good"

cfg="$tmp/cfg-live"
source_commit probe "$(manifest acme.probe 0.4.0)"
inst "update rescans a running shell" "$cfg" "$rt_live" 0 "shell=rescan-started" "" plugin update acme.probe

# A checkout add did not make: no .git, or a branch with no upstream. Each
# refusal names git's own cause after its key.
cfg="$tmp/cfg-nogit"
inst "add installs a plugin to break" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
rm -rf -- "${cfg:?}/vgs/plugins/acme.probe/.git"
inst "update refuses a plugin directory that is not a checkout" "$cfg" "$rt_empty" 1 "" "vgsh: refused: not-a-checkout=$cfg/vgs/plugins/acme.probe" plugin update acme.probe
check "the not-a-checkout refusal carries git's cause" grep -q '^fatal: not a git repository' "$tmp/err"
cfg="$tmp/cfg-noupstream"
inst "add installs a plugin to detach" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
g -C "$cfg/vgs/plugins/acme.probe" branch --unset-upstream
inst "update refuses a checkout with no upstream" "$cfg" "$rt_empty" 1 "" "vgsh: refused: upstream=missing path=$cfg/vgs/plugins/acme.probe" plugin update acme.probe
check "the upstream refusal carries git's cause" grep -q '^fatal: no upstream configured' "$tmp/err"

# Remove.
cfg="$tmp/cfg-add"
inst "remove refuses a bundled id" "$cfg" "$rt_empty" 1 "" "vgsh: refused: bundled=vgs.bar" plugin remove vgs.bar
inst "update refuses a bundled id" "$cfg" "$rt_empty" 1 "" "vgsh: refused: bundled=vgs.bar" plugin update vgs.bar
inst "remove refuses an unknown id" "$cfg" "$rt_empty" 1 "" "vgsh: refused: unknown=acme.absent" plugin remove acme.absent
inst "remove refuses a path that leaves the plugin directory" "$cfg" "$rt_empty" 1 "" "vgsh: refused: outside=$cfg/vgs" plugin remove ..
inst "remove deletes the installed plugin" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin remove acme.probe
check "remove leaves no plugin directory" test ! -e "$plugin"
cfg="$tmp/cfg-link"; mkdir -p "$cfg/vgs/plugins" "$tmp/elsewhere/acme.probe"
manifest acme.probe 0.1.0 >"$tmp/elsewhere/acme.probe/manifest.json"
ln -s "$tmp/elsewhere/acme.probe" "$cfg/vgs/plugins/acme.probe"
inst "remove refuses a symlinked plugin directory" "$cfg" "$rt_empty" 1 "" "vgsh: refused: symlink=$cfg/vgs/plugins/acme.probe" plugin remove acme.probe
check "a refused symlink leaves its target" test -f "$tmp/elsewhere/acme.probe/manifest.json"
# A plugin present under the user directory but not the way add lands one: a
# directory named differently from its id owns the id and is not installed;
# a directory named for the id whose manifest names another id is refused.
cfg="$tmp/cfg-misnamed"; mkdir -p "$cfg/vgs/plugins/elsewhere"
manifest acme.probe 0.1.0 >"$cfg/vgs/plugins/elsewhere/manifest.json"
inst "remove refuses a plugin whose directory is not named for its id" "$cfg" "$rt_empty" 1 "" "vgsh: refused: not-installed=acme.probe owner=$cfg/vgs/plugins/elsewhere" plugin remove acme.probe
cfg="$tmp/cfg-renamed"; mkdir -p "$cfg/vgs/plugins/acme.probe"
manifest acme.other 0.1.0 >"$cfg/vgs/plugins/acme.probe/manifest.json"
inst "remove refuses a directory whose manifest names another id" "$cfg" "$rt_empty" 1 "" "vgsh: refused: manifest-id=acme.other path=$cfg/vgs/plugins/acme.probe" plugin remove acme.probe
check "a refused id mismatch leaves the directory" test -f "$cfg/vgs/plugins/acme.probe/manifest.json"
cfg="$tmp/cfg-live"
inst "remove rescans a running shell" "$cfg" "$rt_live" 0 "shell=rescan-started" "" plugin remove acme.probe
INST_REPLY=busy inst "add while a scan runs says the rescan is queued" "$cfg" "$rt_live" 0 "shell=rescan-queued" "" plugin add "$tmp/src/probe.git"

# --help prints the header comment of the script itself on stderr and exits
# 0; the expected first line is read from the script, not restated here.
set +e
help_out="$("${base_env[@]}" XDG_RUNTIME_DIR="$rt_empty" "$repo/bin/vgsh" --help 2>"$tmp/err")"
status=$?
set -e
help_first=""; IFS= read -r help_first <"$tmp/err" || true
want_first="$(sed -n '2{s/^# \{0,1\}//;p}' "$repo/bin/vgsh")"
if [[ $status == 0 && -z $help_out && -n $want_first && $help_first == "$want_first" ]]; then ok "help prints the script header on stderr and exits 0"; else fail "help: exit=$status stdout=[$help_out] first=[$help_first] want=[$want_first]"; fi

if [[ $failures -gt 0 ]]; then echo "test-vgsh: failed=$failures"; exit 1; fi
echo "test-vgsh: ok"
