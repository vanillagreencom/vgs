#!/usr/bin/env bash
# Drive the validate-area list a document states: the anchored region `prose_areas` reads
# and the fenced blocks `_strip_fenced_blocks` removes before reading it.
# One table mutates the real AGENTS.md anchor; one writes synthetic pages whose fences decide
# which region is live. Every row names its verdict, and a refusing row that can be answered
# by the wrong arm also names the arm that must stay silent.
set -euo pipefail

# shellcheck source=scripts/lib/validation-testkit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/validation-testkit.sh"
assert_fragments_live

echo "=== check-validation-inventory.py document area arms ==="

# Mutate the anchored region of the real document the guard reads. The mutator refuses a
# document that no longer anchors its list exactly once, so a moved anchor fails here
# rather than leaving a row that cannot apply its own defect.
anchored="$tmp/anchored-agents.md"
while IFS='|' read -r label mutation verdict; do
  [[ -n "$label" ]] || continue
  if ! MUTATION="$mutation" python3 - "$repo_root/AGENTS.md" >"$anchored" <<'MUT'
import os, pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
OPEN, CLOSE = "<!-- validate-areas -->", "<!-- /validate-areas -->"
if (source.count(OPEN), source.count(CLOSE)) != (1, 1):
    sys.exit("the document no longer anchors its validate area list exactly once")
mode, _, argument = os.environ["MUTATION"].partition(" ")
if mode == "drop-anchor":
    out = source.replace(OPEN, "").replace(CLOSE, "")
elif mode == "drop-closer":
    out = source.replace(CLOSE, "")
elif mode == "replace-region":
    out = re.sub(
        re.escape(OPEN) + ".*?" + re.escape(CLOSE),
        OPEN + argument + CLOSE,
        source,
        flags=re.DOTALL,
    )
elif mode == "append":
    out = source + argument + "\n"
else:
    sys.exit(f"unknown mutation mode {mode!r}")
if out == source:
    sys.exit(f"the `{mode}` mutation changed nothing, so the row cannot fail")
print(out, end="")
MUT
  then
    fail "document anchor" "$label: the mutation did not apply (see the message above)"
    continue
  fi
  run_guard "AGENTS_PATH=$anchored"
  if [[ "$verdict" == clean ]]; then
    expect_clean_run "document anchor: $label"
  else
    expect_refused "document anchor: $label" "${verdict#refuse:}"
  fi
done <<'ANCHOR_MUTATIONS'
the anchor is gone|drop-anchor|refuse:anchor around its validate area list
the prose inside the anchor is reworded|replace-region one area per run, spelled `go` / `qml` / `helper` / `packaging` / `docs`; or `all`|clean
an area is missing from the anchored list|replace-region areas `go`, `qml`, `helper`, `packaging`, `all`|refuse:enumerates the validate areas but omits
the anchor is opened and never closed|drop-closer|refuse:but never closes it
a second anchored region follows|append <!-- validate-areas -->areas `go`<!-- /validate-areas -->|refuse:must be anchored exactly once
a second closing marker follows|append stray `docs-only`<!-- /validate-areas -->|refuse:must be anchored exactly once
the anchored list names an area the runner refuses|replace-region areas `go`, `qml`, `helper`, `packaging`, `docs`, `docs-only`, `all`|refuse:as a validate area, but scripts/validate does not
ANCHOR_MUTATIONS
ok "the anchored region decides the stated area list, and every way of breaking it is named"

# Every clean page below carries the live area list. Derive it from the tokens the runner
# offers, so an area added later fails on the row that states a wrong list rather than on
# every page that merely quotes the right one.
live_areas="$("$runner" --dump-grammar | awk '
  $1 == "class" && /cli=yes/ { cli[$2] = 1 }
  $1 == "token" && cli[$3] { printf "`%s`, ", $2 }
')"
live_areas="${live_areas%, }"
# shellcheck disable=SC2016  # the backticks quote an area name in a markdown fixture
[[ "$live_areas" == *'`docs`'* ]] ||
  fail "live area list" "the extractor read \`$live_areas\` from the dump, which names no \`docs\` area, so no clean row below states a complete list"
LIVE_ANCHOR="areas: <!-- validate-areas -->$live_areas<!-- /validate-areas -->"

# Write each page from its row and require the verdict the fence rules give it. `@LIVE@` stands
# for the live anchored line above; a row that needs a partial or wrong list spells it out.
# The rows carry `;` and `|` inside their documents, so `~` separates the columns.
areas_probe="$tmp/areas-probe.md"
while IFS='~' read -r label document verdict wrong; do
  [[ -n "$label" ]] || continue
  printf '%b' "${document//@LIVE@/$LIVE_ANCHOR}" >"$areas_probe"
  run_guard "AGENTS_PATH=$areas_probe"
  if [[ "$verdict" == clean ]]; then
    expect_clean_run "fenced document: $label"
  else
    expect_refused "fenced document: $label" "${verdict#refuse:}"
  fi
  # A refusal reached through the wrong arm names a defect the page does not have.
  [[ -z "$wrong" ]] || expect_absent "$guard_out" "$wrong" "fenced document: $label"
done <<'FENCE_DOCS'
an anchor holding prose but no area names~see the runner for the areas <!-- validate-areas -->run it for what you touched<!-- /validate-areas -->\n~refuse:anchors an empty validate area list~
a marker inside a code fence~the guard reads markers like this:\n\n```markdown\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\n```\n~refuse:but only inside a code fence~Restore the anchor
a closing marker inside a code fence~areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`\n\n```markdown\n<!-- /validate-areas -->\n```\n~refuse:but only inside a code fence~never closes it
a closing marker that precedes the opening one~<!-- /validate-areas -->areas <!-- validate-areas -->`go`\n~refuse:a reversed pair anchors nothing~never closes it
a real anchor beside a fenced illustration~@LIVE@\n\n```markdown\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\n```\n~clean~
an unclosed longer fence swallowing the anchor~````bash\n@LIVE@\n\n```markdown\n<!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n```\n~refuse:a code fence is opened and never closed~
an unclosed fence above the anchor~````bash\n@LIVE@\n\n```sh\nan ordinary illustration\n```\n~refuse:a code fence is opened and never closed~anchor around its validate area list
several balanced fences~@LIVE@\n\n```sh\nfirst\n```\n\n```markdown\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\n```\n\n```sh\nthird\n```\n~clean~
an info string on a closing run~```markdown\nan illustration\n``` not-a-closing-fence\n@LIVE@\n~refuse:a code fence is opened and never closed~
spaces and a tab after a closing run~@LIVE@\n\n```sh\nfirst\n```  \t\n~clean~
a CRLF page whose fences are balanced~@LIVE@\r\n\r\n```markdown\r\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\r\n```\r\n~clean~
a backtick inside an opening info string~````markdown with a `tick` in the info string\n<!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `all`<!-- /validate-areas -->\n````\n<!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n````markdown with a `tick` in the info string\n````\n~refuse:omits `docs`~never closed
an indented fence around a second marker~@LIVE@\n\n- demonstrated under a bullet:\n\n  ```markdown\n  <!-- validate-areas -->areas `go`<!-- /validate-areas -->\n  ```\n~refuse:must be anchored exactly once~
an indented fence marker with nothing after it~@LIVE@\n\n- a lone fence marker quoted in prose:\n\n  ```\n~clean~
a marker nested two fences deep~how to write the anchor:\n\n````markdown\n```md\n<!-- validate-areas -->areas `bogus-area`<!-- /validate-areas -->\n```\n````\n~refuse:but only inside a code fence~bogus-area
a nested fenced illustration beside a real anchor~@LIVE@\n\n````markdown\n```md\n<!-- validate-areas -->areas `bogus-area`<!-- /validate-areas -->\n```\n````\n~clean~
punctuation and a line break inside the anchor~<!-- validate-areas -->areas `go`; `qml` / `helper`\n| `packaging` | `docs` | and `all`.<!-- /validate-areas -->\n~clean~
FENCE_DOCS
ok "a fence decides whether the markers it holds are a picture or the contract"

# Require actual documents to yield lists so wording controls cannot pass on an empty extraction.
python3 - "$repo_root" <<'PROBE' || fail "enumerating docs" "a named document yields no area list today"
import pathlib, sys
from vgstk import guard_module
root = pathlib.Path(sys.argv[1])
mod = guard_module(root)
rules = mod.grammar(root / "scripts" / "validate")
for doc in mod.AREA_ENUMERATING_DOCS:
    stated = mod.prose_areas(doc, rules)
    assert stated, doc
    print(f"  ok    {doc.name} states {len(stated)} areas")
PROBE
ok "every named document states its area list today"

finish test-validation-areas
