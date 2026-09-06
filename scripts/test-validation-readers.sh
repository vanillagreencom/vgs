#!/usr/bin/env bash
# Drive the two readers of the same manifest against each other: scripts/validate and
# scripts/lib/validation_manifest.py must classify every row alike, word every shared
# diagnostic as the grammar does, and refuse an unreadable or unlaunchable surface by name.
# Each case calls the library directly, because a guard run reports only the guard's own verdict.
set -euo pipefail

# The locale control needs a UTF-8 locale a machine may not provide. This suite is the one CI
# runs last, so it can report that as exit 77 without hiding the steps that would have followed;
# both the runner and CI still treat 77 as a failure.
SKIPS_ALLOWED=1
# shellcheck source=scripts/lib/validation-testkit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/validation-testkit.sh"

echo "=== scripts/validate and validation_manifest.py reader agreement ==="

# Call each delimiter reader directly. One sibling's refusal cannot prove the others reject the same input.
heredoc_said="$(python3 - "$repo_root" "$tmp" <<'HEREDOC' 2>&1 || true
import pathlib, sys
from vgstk import manifest_module
root, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
mod = manifest_module(root)
runner = root / "scripts" / "validate"
# Use the real grammar so a malformed manifest delimiter fails for its own cause.
rules = mod.grammar(runner)
mangled = tmp / "no-heredoc-runner"
mangled.write_text(
    runner.read_text(encoding="utf-8").replace("MANIFEST_EOF", "MANIFEST_END"),
    encoding="utf-8",
)
mangled.chmod(0o755)
work = tmp / "no-heredoc-work"
for label, call in (
    ("LOGIC", lambda: mod.runner_logic(mangled)),
    ("BUILD", lambda: mod.token_participates(mangled, rules, "always", work)),
):
    try:
        call()
        print(f"{label} ACCEPTED")
    except mod.ManifestError as error:
        print(f"{label} {error}")
HEREDOC
)"
for label in LOGIC BUILD; do
  expect_contains "$heredoc_said" "$label scripts/validate has no MANIFEST_EOF heredoc" \
    "heredoc miss is refused"
done
expect_absent "$heredoc_said" "ACCEPTED" "heredoc miss is refused"
expect_absent "$heredoc_said" "Traceback" "heredoc miss is refused"
ok "a runner whose manifest delimiter is renamed is refused by runner_logic and by the probe builder"

# Inject launch OSError for both row syntax and grammar dump subprocesses.
# Report the unavailable Bash invocation without an unrelated traceback.
launch_out="$(python3 - "$repo_root" 2>&1 <<'NOBASH' || true
import pathlib, subprocess, sys
from vgstk import manifest_module
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
runner = root / "scripts" / "validate"
rules = mod.grammar(runner)  # Collect a real dump before replacing Bash launch behavior.

def boom(*_args, **_kwargs):
    raise PermissionError(13, "Permission denied")

subprocess.run = boom
try:
    mod._check_shell_syntax("true", "qml | true", rules)
    print("ACCEPTED")
except mod.ManifestError as error:
    print("SYNTAX", error)
try:
    mod.grammar(runner)
    print("ACCEPTED")
except mod.ManifestError as error:
    print("DUMP", error)
NOBASH
)"
expect_contains "$launch_out" "SYNTAX could not run bash" "bash unlaunchable"
expect_contains "$launch_out" "DUMP could not run validate --dump-grammar" "bash unlaunchable"
expect_absent "$launch_out" "Traceback" "bash unlaunchable"
expect_absent "$launch_out" "ACCEPTED" "bash unlaunchable"
ok "an unlaunchable bash raises ManifestError at both call sites, not a traceback"

# Mutate the runner whitespace set and require the library to consume that same dumped set.
ws_probe="$tmp/ws-probe/scripts/validate"
mkdir -p "$tmp/ws-probe/scripts/lib"
cp "$repo_root/scripts/lib/validation-grammar.conf" "$tmp/ws-probe/scripts/lib/"
python3 - "$runner" >"$ws_probe" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "ASCII_SPACE=$' \\t\\n\\r\\f\\v'"
assert t.count(old) == 1, "the ASCII_SPACE constant moved"
t = t.replace(old, "ASCII_SPACE=$' \\n\\r\\f\\v'")
# Use the removed whitespace character in a real row. Checking only the dumped set
# cannot detect a reader that applies a separate hardcoded pattern.
row = "qml       | scripts/check-naming.sh"
assert t.count(row) == 1, "the naming-check manifest row moved"
print(t.replace(row, "qml\t      | scripts/check-naming.sh"), end="")
MUT
chmod +x "$ws_probe"
ws_dumped="$("$ws_probe" --dump-grammar | sed -n 's/^whitespace //p')"
[[ "$ws_dumped" == "20 0a 0d 0c 0b" ]] ||
  fail "whitespace is dumped" "the probe dumped \`$ws_dumped\`, so the mutation did not reach the dump"
ws_decoded="$(WS_PROBE="$ws_probe" python3 - "$repo_root" <<'LIB'
import os, pathlib, sys
from vgstk import manifest_module
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
g = mod.grammar(pathlib.Path(os.environ["WS_PROBE"]))
print(" ".join(f"{ord(c):02x}" for c in g.whitespace))
LIB
)" || true
[[ "$ws_decoded" == "$ws_dumped" ]] ||
  fail "whitespace is read" "the library decoded \`$ws_decoded\` where the runner dumped \`$ws_dumped\`"

# Compare each reader's actual row outcome, not only the decoded whitespace value.
ws_rc=0
LC_ALL=C "$ws_probe" --list docs >/dev/null 2>"$tmp/stderr" || ws_rc=$?
ws_runner_said="$(LC_ALL=C sed -e 's/^scripts\/validate: //' -e 's/`.*//' \
  -e 's/[ \t]*$//' "$tmp/stderr" | head -1)"
[[ "$ws_rc" != 0 ]] || ws_runner_said="ACCEPTED"
# Capture unexpected module failures for later diagnostic assertions instead of aborting the suite under errexit.
ws_library_said="$(WS_PROBE="$ws_probe" python3 - "$repo_root" <<'LIB'
import os, pathlib, re, sys
from vgstk import manifest_module
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
try:
    mod.manifest_rows(pathlib.Path(os.environ["WS_PROBE"]))
    print("ACCEPTED")
except mod.ManifestError as error:
    print(re.sub(r"`.*", "", str(error).replace("scripts/validate: ", "")).strip())
LIB
)" || true
[[ "$ws_runner_said" == "$ws_library_said" ]] ||
  fail "whitespace is applied" "a tag field carrying the dropped character is classified differently:
  runner : ${ws_runner_said:-accepted}
  library: ${ws_library_said:-accepted}"
expect_contains "$ws_library_said" "malformed tag field" "whitespace is applied"
ok "the whitespace set travels from the runner's constant to the pattern each reader applies"

# A CRLF runner must still expose its manifest delimiter. Use a manifest-only row
# to make an unstripped result unambiguous.
crlf_said="$(python3 - "$repo_root" "$tmp" <<'CRLF' 2>&1 || true
import pathlib, sys
from vgstk import manifest_module
root, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
mod = manifest_module(root)
runner = root / "scripts" / "validate"
crlf = tmp / "validate-crlf"
crlf.write_bytes(runner.read_bytes().replace(b"\n", b"\r\n"))
row = "scripts/test-owned-skills-e2e.py"
assert row in runner.read_text(encoding="utf-8"), "the owned-skills-e2e manifest row moved"
try:
    logic = mod.runner_logic(crlf)
except mod.ManifestError as error:
    # A delimiter refusal must remain a named result so the assertion can reject it without a traceback.
    print(f"REFUSED {error}")
else:
    print("STRIPPED" if row not in logic and "MANIFEST_EOF" not in logic else "SURVIVED")
CRLF
)"
expect_contains "$crlf_said" "STRIPPED" "CRLF manifest heredoc"
ok "a CRLF-lined runner's manifest is still stripped from the logic the tag check scans"

# Substitute directories for files to force OSError and require named read diagnostics.
unreadable_out="$(python3 - "$repo_root" "$tmp" 2>&1 <<'UNREADABLE' || true
import pathlib, sys
from vgstk import manifest_module
root, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
mod = manifest_module(root)
nowhere = tmp / "a-directory-where-a-file-should-be"
nowhere.mkdir(exist_ok=True)
runner = root / "scripts" / "validate"


def participate():
    # Point the decoded source at the unreadable grammar so this reaches file copying,
    # not merely dump decoding.
    rules = mod.grammar(runner)
    rules.source = nowhere
    return mod.token_participates(runner, rules, "always", tmp / "participate-work")


for label, call in (
    ("ROWS", lambda: mod.manifest_rows(nowhere)),
    ("PROSE", lambda: mod.prose_areas(nowhere, mod.grammar(runner))),
    ("LOGIC", lambda: mod.runner_logic(nowhere)),
    ("CI", lambda: mod.ci_run_commands(nowhere)),
    ("PARTICIPATE", participate),
):
    try:
        call()
        print(f"{label} ACCEPTED")
    except mod.ManifestError as error:
        print(f"{label} {error}")
UNREADABLE
)"
for label in ROWS PROSE LOGIC PARTICIPATE; do
  expect_contains "$unreadable_out" "$label could not read" "unreadable surface"
done
if [[ $have_yaml -eq 1 ]]; then
  expect_contains "$unreadable_out" "CI could not read" "unreadable surface"
else
  # Without PyYAML, CI parsing stops before file reading; assert that prerequisite instead.
  expect_contains "$unreadable_out" "CI PyYAML is not installed" "unreadable surface"
fi
expect_absent "$unreadable_out" "Traceback" "unreadable surface"
expect_absent "$unreadable_out" "ACCEPTED" "unreadable surface"
ok "an unreadable surface raises ManifestError naming the path, not a traceback"

# Require shared diagnostics to match the definition, not merely another reader that can drift with them.
drift_probe="$fixture_dir/scripts/drift-probe"
cp "$repo_root/scripts/lib/validation-grammar.conf" "$fixture_dir/scripts/lib/"
while IFS=';' read -r key row; do
  [[ -n "$key" ]] || continue
  text="$(sed -n "s/^message  *$key  *//p" "$repo_root/scripts/lib/validation-grammar.conf")"
  if [[ -z "$text" ]]; then
    fail "shared diagnostics" "the grammar declares no message for \`$key\`"
    continue
  fi
  ROW="$row" python3 - "$runner" >"$drift_probe" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "qml       | scripts/check-naming.sh"
assert t.count(old) == 1, "the naming-check manifest row moved"
print(t.replace(old, os.environ["ROW"]), end="")
MUT
  chmod +x "$drift_probe"
  runner_said="$("$drift_probe" --list docs 2>&1 >/dev/null || true)"
  library_said="$(GRAMMAR_PROBE="$drift_probe" python3 - "$repo_root" <<'LIB'
import os, pathlib, sys
from vgstk import manifest_module
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
try:
    mod.manifest_rows(pathlib.Path(os.environ["GRAMMAR_PROBE"]))
    print("ACCEPTED")
except mod.ManifestError as error:
    print(error)
LIB
)"
  expect_contains "$runner_said" "$text" "shared diagnostic $key (runner)"
  expect_contains "$library_said" "$text" "shared diagnostic $key (library)"
done <<'SHAPES'
row-no-separator;scripts/check-naming.sh
row-empty-tags;          | scripts/check-naming.sh
row-malformed-tags;notatoken | scripts/check-naming.sh
row-not-standalone;may-skip  | scripts/check-naming.sh
row-empty-command;qml       |
row-bad-syntax;qml       | scripts/check-naming.sh &&
SHAPES
ok "both readers word every shared diagnostic exactly as the grammar does"

# Compare reader diagnostics on duplicate tags. Membership can use a set, but cardinality
# must retain repetitions where they affect the diagnosis.
agree_probe="$fixture_dir/scripts/agree-probe"
# Use a function entrypoint for control-character rows that cannot be represented by a quoted fixture table.
agree_row() {
  local row_tags="$1" label="${2:-$1}"
  ROW="$row_tags" python3 - "$runner" >"$agree_probe" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "qml       | scripts/check-naming.sh"
assert t.count(old) == 1, "the naming-check manifest row moved"
print(t.replace(old, f"{os.environ['ROW']} | scripts/check-naming.sh"), end="")
MUT
  chmod +x "$agree_probe"
  local runner_rc=0 runner_said library_said library_rc=0
  "$agree_probe" --list docs >/dev/null 2>"$tmp/stderr" || runner_rc=$?
  # Normalize trailing diagnostic whitespace consistently before comparing readers.
  runner_said="$(sed -e 's/^scripts\/validate: //' -e 's/`.*//' -e 's/[[:space:]]*$//' "$tmp/stderr" | head -1)"
  library_said="$(AGREE_PROBE="$agree_probe" python3 - "$repo_root" <<'LIB'
import os, pathlib, re, sys
from vgstk import manifest_module
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
try:
    mod.manifest_rows(pathlib.Path(os.environ["AGREE_PROBE"]))
    print("")
except mod.ManifestError as error:
    print(re.sub(r"`.*", "", str(error).replace("scripts/validate: ", "")).strip())
LIB
)"
  [[ -n "$library_said" ]] && library_rc=2
  [[ "$runner_rc" == 0 ]] && runner_said=""
  if [[ "$runner_said" != "$library_said" ]]; then
    fail "reader agreement" "row $label classified differently:
  runner  ($runner_rc): ${runner_said:-accepted}
  library ($library_rc): ${library_said:-accepted}"
  fi
}
while IFS= read -r row_tags; do
  [[ -n "$row_tags" ]] || continue
  agree_row "$row_tags"
done <<'ROWS'
may-skip,may-skip
qml,qml
always,always
qml,may-skip,may-skip
may-skip
-,-
qml,
notatoken
ROWS
ok "both readers classify every duplicate and malformed row identically"

# Require accepted control rows to be listed by both readers. Agreement on refusal cannot prove whitespace acceptance.
agree_accepts() {
  local row_tags="$1" label="${2:-$1}" rc=0 listed library
  agree_row "$row_tags" "$label"
  listed="$("$agree_probe" --list qml 2>"$tmp/stderr")" || rc=$?
  if [[ "$rc" != 0 ]]; then
    fail "reader agreement" "row $label was refused by the runner (rc $rc): $(head -1 "$tmp/stderr")"
  fi
  expect_contains "$listed" "scripts/check-naming.sh" "reader agreement: runner lists $label"
  library="$(AGREE_PROBE="$agree_probe" python3 - "$repo_root" <<'LIB'
import os, pathlib, sys
from vgstk import manifest_module
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
try:
    rows = mod.manifest_rows(pathlib.Path(os.environ["AGREE_PROBE"]))
except mod.ManifestError as error:
    print(f"REFUSED {error}")
else:
    print("LISTED" if ("qml", "scripts/check-naming.sh") in rows else f"MISSING {rows[:3]}")
LIB
)" || true
  expect_contains "$library" "LISTED" "reader agreement: library lists $label"
}

# Split rows on newline only. Vertical tab, form feed, and carriage return belong to the
# ASCII whitespace set and must not create extra rows through splitlines or newline translation.
for control in '\v' '\f' '\r'; do
  printf -v control_tags 'qml%b' "$control"
  agree_accepts "$control_tags" "qml followed by a literal $control"
done
ok "a row tagged with a \\v, \\f or \\r is one row to both readers, and taken by both"

# Use a locale that changes Unicode whitespace classification and measure that property directly.
# A bounded, deterministic locale sample avoids exhaustive subprocess work without assuming
# the ambient locale can distinguish ASCII stripping from locale-resolved space classes.
LOCALE_SAMPLE=2
PREFERRED_LOCALE=en_US.utf8
locales=()
utf8_locales=()
c_locales=()
while IFS= read -r loc; do
  case "$loc" in
    # Keep C.utf8 as a fallback because its classification depends on libc.
    # Measure the selected locale rather than inferring its behavior from the name.
    C.utf8 | C.UTF-8) c_locales+=("$loc") ;;
    *.utf8 | *.UTF-8) utf8_locales+=("$loc") ;;
  esac
done < <(locale -a 2>/dev/null | LC_ALL=C sort)
utf8_locales+=("${c_locales[@]}")
for loc in "$PREFERRED_LOCALE" "${utf8_locales[@]}"; do
  [[ ${#locales[@]} -lt $LOCALE_SAMPLE ]] || break
  # Use the preferred locale only when installed.
  printf '%s\n' "${utf8_locales[@]}" | grep -qxF -- "$loc" || continue
  printf '%s\n' "${locales[@]}" | grep -qxF -- "$loc" && continue
  locales+=("$loc")
done

# A locale that exposes no class difference cannot prove this control and must skip.
# Feed fixed UTF-8 bytes so locale-dependent escape encoding cannot change the input.
locale_resolves_class() {
  local stripped
  stripped="$(LC_ALL="$1" bash -c \
    'x="$(printf "x\xe2\x80\x82")"; printf "%s" "${x//[[:space:]]/}"')" || return 1
  [[ "$stripped" == "x" ]]
}

locale_sample_is_degenerate=1
for loc in ${locales[@]+"${locales[@]}"}; do
  if locale_resolves_class "$loc"; then
    locale_sample_is_degenerate=0
  fi
done

if [[ ${#locales[@]} -eq 0 ]]; then
  # Run the named locale explicitly so a substitute cannot satisfy its coverage claim.
  skip "C4 locale control" \
    "this system provides no UTF-8 locale (locale -a), so the one condition that" \
    "distinguishes an ASCII rule from a locale-resolved class could not be created." \
    "The rule is NOT proven on this machine."
else
  space_probe="$fixture_dir/scripts/space-probe"
  for codepoint in 00A0 2002 3000; do
    CODEPOINT="$codepoint" python3 - "$runner" >"$space_probe" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "qml       | scripts/check-naming.sh"
assert t.count(old) == 1, "the naming-check manifest row moved"
tag = "qml" + chr(int(os.environ["CODEPOINT"], 16))
print(t.replace(old, f"{tag}       | scripts/check-naming.sh"), end="")
MUT
    chmod +x "$space_probe"
    verdicts=()
    for loc in C "${locales[@]}"; do
      rc=0
      LC_ALL="$loc" "$space_probe" --list docs >/dev/null 2>"$tmp/stderr" || rc=$?
      said="accepted"
      # Compare diagnostics as well as statuses, trimming with the explicit ASCII set.
      [[ "$rc" != 0 ]] && said="$(LC_ALL=C sed -e 's/^scripts\/validate: //' -e 's/`.*//' \
        -e 's/[ \t]*$//' "$tmp/stderr" | head -1)"
      verdicts+=("runner/$loc: $rc $said")
      lib="$(LC_ALL="$loc" SPACE_PROBE="$space_probe" python3 - "$repo_root" <<'LIB'
import os, pathlib, re, sys
from vgstk import manifest_module
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
try:
    mod.manifest_rows(pathlib.Path(os.environ["SPACE_PROBE"]))
    print("0 accepted")
except mod.ManifestError as error:
    print("2 " + re.sub(r"`.*", "", str(error).replace("scripts/validate: ", "")).strip())
LIB
)"
      verdicts+=("library/$loc: $lib")
    done

    first="${verdicts[0]#*: }"
    for verdict in "${verdicts[@]}"; do
      if [[ "${verdict#*: }" != "$first" ]]; then
        fail "C4 locale control" "U+$codepoint in a tag field is classified differently:
$(printf '  %s\n' "${verdicts[@]}")"
        break
      fi
    done
    # Require refusal too; readers agreeing to accept Unicode whitespace would still violate the grammar.
    [[ "$first" == 2\ * ]] ||
      fail "C4 locale control" "U+$codepoint in a tag field is ACCEPTED ($first)"
  done
  if [[ $locale_sample_is_degenerate -eq 1 ]]; then
    # shellcheck disable=SC2016  # the backticks quote a shell pattern in the notice
    skip "C4 locale control" \
      "no locale this system provides (${locales[*]}) resolves a Unicode space" \
      'through `[[:space:]]`, measured directly, so the one condition that' \
      "distinguishes an ASCII rule from a locale-resolved class could not be created." \
      "Both readers agreed on every codepoint, but the rule is NOT proven here."
  else
    ok "C4 holds for both readers under C and ${locales[*]}"
  fi
fi

# Wrap each producer to emit valid bytes and then fail. Collection must preserve that status
# so partial grammar or manifest output cannot silently narrow validation.
wrapper_dir="$tmp/failing-producers"
mkdir -p "$wrapper_dir"
while IFS=';' read -r tool invocations label; do
  [[ -n "$tool" ]] || continue
  real="$(command -v "$tool")"
  [[ -n "$real" ]] || { fail "$label" "no $tool on PATH to wrap"; continue; }
  printf '#!/usr/bin/env bash\n%s "$@"\nexit 42\n' "$real" >"$wrapper_dir/$tool"
  chmod +x "$wrapper_dir/$tool"
  # Grammar-only dumping does not collect the manifest; choose invocations that reach the mutated producer.
  # shellcheck disable=SC2086  # the invocation list is a deliberate word list
  for invocation in $invocations; do
    invocation="${invocation//+/ }"
    rc=0
    # shellcheck disable=SC2086  # the invocation is a deliberate word list
    out="$(PATH="$wrapper_dir:$PATH" "$runner" $invocation 2>"$tmp/stderr")" || rc=$?
    err="$(cat "$tmp/stderr")"
    [[ "$rc" == 2 ]] || fail "$label" "exited $rc for \`$invocation\`, not 2"
    expect_absent "$out" "scripts/" "$label ($invocation)"
    # Transport failure needs a read diagnostic, not malformed-grammar advice.
    expect_contains "$err" "collection exited 42" "$label ($invocation)"
    expect_contains "$err" "read/transport failure" "$label ($invocation)"
  done
  rm -f "$wrapper_dir/$tool"
done <<'PRODUCERS'
sed;--list+docs --list+all docs --dump-grammar;a failing grammar producer exits 2 with nothing listed
cat;--list+docs --list+all docs;a failing manifest producer exits 2 with nothing listed
PRODUCERS
ok "a producer that emits valid bytes and then fails still exits 2 with nothing listed"

# The same wrapper with successful status must pass so wrapper presence alone cannot satisfy the refusal.
real_sed="$(command -v sed)"
printf '#!/usr/bin/env bash\n%s "$@"\n' "$real_sed" >"$wrapper_dir/sed"
chmod +x "$wrapper_dir/sed"
rc=0
PATH="$wrapper_dir:$PATH" "$runner" --list docs >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]] || fail "producer wrapper" "a passthrough wrapper changed the outcome (rc $rc)"
rm -f "$wrapper_dir/sed"
ok "a passthrough wrapper is transparent, so the cases above catch the status"

finish test-validation-readers
