#!/usr/bin/env bash
# Drive the CI-coverage arm: which manifest rows .github/workflows/ci.yml actually runs,
# and what the readers still report when PyYAML, the only CI parser prerequisite, is absent.
# Each case requires its own diagnostic and a failing status.
set -euo pipefail

# shellcheck source=scripts/lib/validation-testkit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/validation-testkit.sh"

echo "=== check-validation-inventory.py CI-coverage arms ==="

# Simulate absent yaml on import. Non-YAML readers must still work and CI parsing must
# report the prerequisite without a module-import traceback.
pyyaml_out="$(python3 - "$repo_root" "$tmp" 2>&1 <<'NOYAML' || true
import pathlib, shlex, sys
from vgstk import manifest_module
sys.modules["yaml"] = None
root = pathlib.Path(sys.argv[1])
mod = manifest_module(root)
print("IMPORTED")
# Keep the real grammar producer, but give the row reader a fixed manifest.
probe = pathlib.Path(sys.argv[2]) / "noyaml-manifest"
probe.write_text(
    "#!/usr/bin/env bash\n"
    f"if [[ ${{1:-}} == --dump-grammar ]]; then exec bash {shlex.quote(str(root / 'scripts' / 'validate'))} --dump-grammar; fi\n"
    "cat <<'MANIFEST_EOF'\nqml | true\nhelper | false\nMANIFEST_EOF\n",
    encoding="utf-8",
)
print("ROWS", mod.manifest_rows(probe))
try:
    mod.ci_run_commands(root / ".github" / "workflows" / "ci.yml")
except mod.ManifestError as error:
    print("MANIFESTERROR", error)
NOYAML
)"
expect_contains "$pyyaml_out" "IMPORTED" "PyYAML absent"
expect_contains "$pyyaml_out" "ROWS [('qml', 'true'), ('helper', 'false')]" "PyYAML absent"
expect_contains "$pyyaml_out" "MANIFESTERROR PyYAML is not installed" "PyYAML absent"
expect_absent "$pyyaml_out" "Traceback" "PyYAML absent"
ok "without PyYAML the module imports, the other parsers work, and ci.yml fails with one line"

# Missing PyYAML must not replace another fixture's diagnostic. Use parseable manifest fixtures
# so execution reaches both the intended guard arm and the CI prerequisite.
noyaml_probe="$tmp/noyaml-probe"
noyaml_grammar="$tmp/noyaml-grammar.conf"

# Remove and verify every docs row so new rows cannot preserve the supposedly empty area.
python3 - "$runner" >"$noyaml_probe" <<'MUT'
import re
import sys
t = open(sys.argv[1], encoding="utf-8").read()
out = t.replace("docs      | ", "-         | ")
assert out != t, "no docs-tagged manifest row found; the tag column moved"
assert not re.search(r"^docs\s*\|", out, re.M), "a docs-tagged row survived, so the area is not empty"
print(out, end="")
MUT
chmod +x "$noyaml_probe"
run_guard "RUNNER_PATH=$noyaml_probe" "PYTHONPATH=$noyaml_path"
expect_refused "no-PyYAML fixture verdict" "no manifest row is tagged with it"
expect_contains "$guard_out" "CI coverage was NOT checked" "no-PyYAML fixture verdict"
expect_absent "$guard_out" "Traceback" "no-PyYAML fixture verdict"


printf '%s\ntoken nightly    inert\n' "${real_grammar/class argument   /$INERT_CLASS
class argument   }" >"$noyaml_grammar"
run_guard "GRAMMAR_PATH=$noyaml_grammar" "PYTHONPATH=$noyaml_path"
expect_refused "no-PyYAML fixture verdict" "does not act on it"
expect_contains "$guard_out" "CI coverage was NOT checked" "no-PyYAML fixture verdict"
expect_absent "$guard_out" "Traceback" "no-PyYAML fixture verdict"
ok "without PyYAML a fixture still reports its own verdict, and the prerequisite is named too"

# Add a real executable row outside scripts to verify CI coverage is not limited to script discovery.
offtree_runner="$tmp/offtree-runner"
awk '/^MANIFEST_EOF$/ && !seen {
  print "-         | .agents/skills/worktree/scripts/worktree"; seen = 1
} { print }' "$runner" >"$offtree_runner"
chmod +x "$offtree_runner"
run_guard "RUNNER_PATH=$offtree_runner"
expect_refused "off-tree manifest row" "which .github/workflows/ci.yml does not"
ok "a manifest row outside scripts/ that ci.yml never runs is reported"

# Replace one real CI invocation per case with a nonexecuting mention or conditional path.
# Arguments, comments, quoted separators, redirects, definitions, arrays, and optional branches
# cannot establish unconditional command execution. Heredoc terminators need a multiline fixture.
rows=0
while IFS='|' read -r shape replacement; do
  [[ -n "$shape" ]] || continue
  rows=$((rows + 1))
  doctored="$tmp/ci-$shape.yml"
  SHAPE_REPLACEMENT="$replacement" python3 - "$repo_root" "$doctored" <<'MENTION_ONLY'
import os, pathlib, sys
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
step = "        run: .agents/skills/doc-limits/scripts/doc-limits\n"
if step not in text:
    sys.exit("the doc-limits ci.yml step these fixtures doctor has moved")
body = os.environ["SHAPE_REPLACEMENT"].replace("@", ".agents/skills/doc-limits/scripts/doc-limits")
out.write_text(text.replace(step, f"        run: |\n          {body}\n", 1), encoding="utf-8")
MENTION_ONLY
  if [[ ! -s "$doctored" ]]; then
    fail "ci mention-only ($shape)" "the fixture workflow was not written (see the message above)"
    continue
  fi
  run_guard "CI_PATH=$doctored"
  expect_refused "ci mention-only ($shape)" "which .github/workflows/ci.yml does not"
done <<'SHAPES'
argument|echo @
comment|true  # was @
quoted-separator|echo "( @ )"
redirection|> @
function-definition|@() { :; }
short-circuit|true || @
conditional-branch|if false; then @; fi
array-element|saved=(@)
SHAPES
[[ $rows -eq 8 ]] || fail "SHAPES" "expected 8 table rows, drove $rows"
ok "a path CI only mentions in any shape above is not a path CI runs"

# For <<EOF, only the exact delimiter ends the body. An indented look-alike remains data
# and must not expose later payload lines as CI commands.
heredoc_ci="$tmp/ci-heredoc-terminator.yml"
python3 - "$repo_root" "$heredoc_ci" <<'HEREDOC_SHAPE'
import pathlib, sys
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
step = "        run: .agents/skills/doc-limits/scripts/doc-limits\n"
if step not in text:
    sys.exit("the doc-limits ci.yml step these fixtures doctor has moved")
# The space-indented EOF remains body text under the shell's delimiter rule.
out.write_text(text.replace(step,
    "        run: |\n"
    "          cat <<EOF\n"
    "           EOF\n"
    "          .agents/skills/doc-limits/scripts/doc-limits\n"
    "          EOF\n", 1), encoding="utf-8")
HEREDOC_SHAPE
if [[ ! -s "$heredoc_ci" ]]; then
  fail "ci heredoc terminator" "the fixture workflow was not written (see the message above)"
else
  run_guard "CI_PATH=$heredoc_ci"
  expect_refused "ci heredoc terminator" "which .github/workflows/ci.yml does not"
  ok "a path inside a heredoc body is data, whatever the body looks like"
fi

finish test-validation-ci-coverage
