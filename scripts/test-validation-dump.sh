#!/usr/bin/env bash
# Drive the decoder that reads `scripts/validate --dump-grammar`: what it refuses in a corrupt
# dump, and what it must preserve from a valid one. A runner defect can emit records no grammar
# fixture produces, so the dumps here are stubbed rather than parsed from a grammar file.
set -euo pipefail

# shellcheck source=scripts/lib/validation-testkit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/validation-testkit.sh"
assert_fragments_live

echo "=== validation_manifest.grammar dump decoding ==="

# Stub corrupt runner dumps to test the decoder's own refusal. A runner bug can emit data
# that normal grammar fixtures never produce. Require a dump-specific collected diagnostic.
dump_stub="$tmp/dump-stub/scripts/validate"
mkdir -p "$tmp/dump-stub/scripts/lib"
cp "$repo_root/scripts/lib/validation-grammar.conf" "$tmp/dump-stub/scripts/lib/"
good_dump="$("$runner" --dump-grammar)"
# Each row names the record it damages and the diagnostic that record must produce.
# APPEND adds the `from` line to a valid dump, DROP removes every line that starts with it,
# and BLANK empties the field beside it; any other `to` replaces the `from` text.
while IFS=';' read -r label from to expect; do
  [[ -n "$label" ]] || continue
  case "$to" in
    APPEND) corrupt="$good_dump
$from" ;;
    DROP) corrupt="$(printf '%s\n' "$good_dump" | grep -v "^$from ")" ;;
    BLANK) corrupt="$(printf '%s\n' "$good_dump" | sed -e "s|^$from .*|$from|")" ;;
    *) corrupt="${good_dump/$from/$to}" ;;
  esac
  [[ "$corrupt" != "$good_dump" ]] ||
    fail "$label" "the dump mutation did not apply, so the case cannot fail"
  printf '#!/usr/bin/env bash\ncat <<%s\n%s\nDUMP_EOF\n' "'DUMP_EOF'" "$corrupt" >"$dump_stub"
  chmod +x "$dump_stub"
  run_guard "RUNNER_PATH=$dump_stub"
  expect_refused "$label" "$expect"
  expect_absent "$guard_out" "Traceback" "$label"
done <<'DUMPS'
a non-integer count in the dump is refused;skips=no min=1 max=-;skips=no min=banana max=-;defect in the runner's dump
a dash min in the dump is refused;skips=no min=1 max=-;skips=no min=- max=-;defect in the runner's dump
a non-canonical count in the dump is refused;skips=no min=1 max=-;skips=no min=08 max=-;defect in the runner's dump
an unknown class field in the dump is refused;skips=no min=1;skips=no bogus=yes min=1;defect in the runner's dump
a non-boolean class field in the dump is refused;class area selects=yes;class area selects=maybe;defect in the runner's dump
a missing class field in the dump is refused;universal=no skips=no min=1 max=-;universal=no min=1 max=-;defect in the runner's dump
a repeated class field in the dump is refused;class area selects=yes;class area selects=yes selects=no;defect in the runner's dump
a malformed token line in the dump is refused;token go area;token go area extra;defect in the runner's dump
a duplicated token in the dump is refused;token qml area;APPEND;defect in the runner's dump
a message with no text in the dump is refused;message grammar-arity grammar line has the wrong number of fields;message grammar-arity;defect in the runner's dump
a second default in the dump is refused;default qml;APPEND;defect in the runner's dump
an unknown dump line kind is refused;bogus line;APPEND;defect in the runner's dump
a non-hex whitespace codepoint is refused;whitespace 20 09;whitespace 20 tab;defect in the runner's dump
an odd-length whitespace codepoint is refused;whitespace 20 09;whitespace 20 9;defect in the runner's dump
an uppercase whitespace codepoint is refused;whitespace 20 09;whitespace 20 0A;defect in the runner's dump
a non-ASCII whitespace codepoint is refused;whitespace 20 09;whitespace 20 a0;defect in the runner's dump
a repeated whitespace codepoint is refused;whitespace 20 09;whitespace 20 20;defect in the runner's dump
a second whitespace line is refused;whitespace 20 09 0a 0d 0c 0b;APPEND;defect in the runner's dump
a dump with no source line is refused;source;DROP;no `source` line
a dump with no default line is refused;default;DROP;no `default` line
a dump with no whitespace line is refused;whitespace;DROP;no `whitespace` line
a dump whose source field is empty is refused;source;BLANK;`source` line is empty
DUMPS
ok "a corrupt dump is refused, naming the record at fault"

# Compare bare --list with the default resolved by the real dump.
dumped_default="$("$runner" --dump-grammar | sed -n 's/^default //p')"
[[ -n "$dumped_default" ]] || fail "default resolves" "the runner dumped no default area"
if [[ "$("$runner" --list)" != "$("$runner" --list "$dumped_default")" ]]; then
  fail "default resolves" "a bare --list does not match --list $dumped_default"
fi
python3 - "$repo_root" "$dumped_default" <<'DEF' || fail "default resolves" "the decoder disagrees with the dumped default"
import pathlib, sys
from vgstk import manifest_module
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
g = mod.grammar(root / "scripts" / "validate")
sys.exit(0 if g.default_area == sys.argv[2] else 1)
DEF
ok "the real grammar resolves one default, and every consumer reads the same one"

# Compare decoded valid grammar with the emitted dump so dropped records or invented defaults fail.
run_guard
expect_clean_run "dump is the guard's only source"
python3 - "$repo_root" <<'DUMP' || fail "dump agreement" "the decoded grammar does not match the dump"
import pathlib, subprocess, sys
from vgstk import manifest_module
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
runner = root / "scripts" / "validate"
dump = subprocess.run(
    ["bash", str(runner), "--dump-grammar"], capture_output=True, text=True, check=True
).stdout
g = mod.grammar(runner)
whitespace = " ".join(f"{ord(c):02x}" for c in g.whitespace)
lines = [f"source {g.source}", f"default {g.default_area}", f"whitespace {whitespace}"]
for name in sorted(g.classes):
    props = " ".join(f"{p}={'yes' if g.classes[name][p] else 'no'}" for p in mod.CLASS_PROPERTIES)
    counts = g.counts[name]
    lines.append(
        f"class {name} {props} min={counts.get('min', 0)} "
        f"max={counts['max'] if 'max' in counts else '-'}"
    )
for token, cls in g.token_class.items():
    lines.append(f"token {token} {cls}")
for key in sorted(g.messages):
    lines.append(f"message {key} {g.messages[key]}")
if "\n".join(lines) + "\n" != dump:
    import difflib
    sys.stdout.writelines(difflib.unified_diff(
        dump.splitlines(True), [line + "\n" for line in lines],
        "dump", "decoded"))
    sys.exit(1)
print(f"  ok    the decoder round-trips all {len(dump.splitlines())} dumped records")
DUMP
ok "the guard's grammar is exactly what the runner dumped, with nothing supplied"

# Drive control characters through the real grammar dump. Both subprocess capture and
# decoder splitting must preserve non-newline whitespace within a message record.
dump_line_dir="$tmp/dump-line"
mkdir -p "$dump_line_dir/scripts/lib"
cp "$runner" "$dump_line_dir/scripts/validate"
chmod +x "$dump_line_dir/scripts/validate"
while IFS=';' read -r label escape; do
  [[ -n "$label" ]] || continue
  printf -v control_char '%b' "$escape"
  MARK="$control_char" python3 - "$repo_root/scripts/lib/validation-grammar.conf" \
    >"$dump_line_dir/scripts/lib/validation-grammar.conf" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = [line for line in t.split("\n") if line.startswith("message row-empty-tags")]
assert len(old) == 1, "the row-empty-tags message moved"
print(t.replace(old[0], old[0] + f" ({os.environ['MARK']}marked)"), end="")
MUT
  dumped_line="$("$dump_line_dir/scripts/validate" --dump-grammar)" ||
    fail "dump line boundary" "the runner refused a grammar whose message carries $label"
  # Require the control character in the emitted dump before testing decoding.
  [[ "$dumped_line" == *"$control_char"* ]] ||
    fail "dump line boundary" "the runner dropped $label before dumping, so the case cannot fail"
  dump_line_said="$(DUMP_PROBE="$dump_line_dir/scripts/validate" MARK="$control_char" \
    python3 - "$repo_root" <<'LIB'
import os, pathlib, sys
from vgstk import manifest_module
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
try:
    rules = mod.grammar(pathlib.Path(os.environ["DUMP_PROBE"]))
except mod.ManifestError as error:
    print(f"REFUSED {error}")
else:
    text = rules.messages["row-empty-tags"]
    print("DECODED" if text.endswith(f"({os.environ['MARK']}marked)") else f"LOST {text!r}")
LIB
  )" || true
  expect_contains "$dump_line_said" "DECODED" "dump line boundary ($label)"
done <<'DUMPLINES'
a vertical tab;\x0b
a carriage return;\x0d
DUMPLINES
ok "a \\v or \\r inside a dumped message is one dump line to the decoder, as the runner emitted it"

# Build a real fixture tree under a spaced path so the emitted source field exercises its transport.
spaced="$tmp/a directory with spaces"
mkdir -p "$spaced/scripts/lib"
cp "$runner" "$spaced/scripts/validate"
chmod +x "$spaced/scripts/validate"
cp "$repo_root/scripts/lib/validation-grammar.conf" "$spaced/scripts/lib/"
rc=0
"$spaced/scripts/validate" --list docs >/dev/null 2>"$tmp/stderr" || rc=$?
[[ "$rc" == 0 ]] || fail "spaced path" "the runner failed at a spaced path (rc $rc): $(cat "$tmp/stderr")"
run_guard "RUNNER_PATH=$spaced/scripts/validate"
expect_absent "$guard_out" "cannot read" "spaced path"
expect_clean_run "spaced path"
ok "a checkout under a path containing a space runs, and the guard reads its dump"

finish test-validation-dump
