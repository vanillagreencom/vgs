"""Parsers for the VGS validation manifest and the docs that restate it.

Its one importer today is scripts/check-validation-inventory.py, which owns the
RULES — which checks are excluded, which are local-only, what CI must contain.
This module owns only the READING.

Every function takes the path it reads rather than resolving one. That is what
makes scripts/test-validation-inventory.sh possible: it drives the guard against
MUTATED COPIES of the runner and of the docs, by patching the guard's own path
constants, which only works because nothing here resolves a path of its own.

Parse problems raise ManifestError rather than SystemExit, and carry no caller
name — the importer prefixes its own. A module that brands its errors with one
consumer's name cannot honestly gain a second.

Library, not a check: no shebang, no `__main__`, never executed directly.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path


class ManifestError(Exception):
    """A surface this module reads does not say what it must say."""



# ASCII whitespace only, matching the runner's `[[:space:]]` exactly. Python's
# str.split()/strip() also eat Unicode whitespace, which made a non-breaking
# space normalise away here and survive there: the same bytes then produced a
# valid tag for this reader and an unknown one for the runner.
_ASCII_SPACE = re.compile(r"[ \t\n\r\f\v]")


def manifest_rows(runner: Path) -> list[tuple[str, str]]:
    """`(tags, command)` pairs from the scripts/validate manifest heredoc.

    Parsed statically, not via `scripts/validate --list`: this check must report
    a manifest the runner cannot even parse.

    THE MANIFEST IS THE ONE THING STILL READ TWICE, and deliberately: this must
    report a manifest with its PER-ROW TAGS, which `--list` does not carry, and
    it must report one the runner refuses rather than relaying a refusal. The
    grammar it applies is not a second copy — it comes from the runner's dump —
    but the row loop is a second reader, and scripts/test-validate.sh's
    parser-agreement case plus this file's reader-agreement cases are what hold
    the two to one answer. Rows are refused in the same ORDER the runner refuses
    them (tag field, tag pattern, class rules, command) so one malformed line
    gets one diagnosis, not two readers naming different defects on it.
    """
    text = runner.read_text(encoding="utf-8")
    block = re.search(r"<<'MANIFEST_EOF'\n(.*?)\nMANIFEST_EOF\n", text, re.DOTALL)
    if not block:
        raise ManifestError(
            "scripts/validate has no MANIFEST_EOF heredoc; "
            "this check parses that block, so moving it silently empties the inventory"
        )
    rules = grammar(runner)
    pattern = rules.tag_pattern()
    rows: list[tuple[str, str]] = []
    for line in block.group(1).splitlines():
        if not _ASCII_SPACE.sub("", line):
            continue
        if "|" not in line:
            raise rules.row_error("row-no-separator", line)
        tags, command = line.split("|", 1)
        tags = _ASCII_SPACE.sub("", tags)
        if not tags:
            raise rules.row_error("row-empty-tags", line)
        if not pattern.match(tags):
            raise rules.row_error("row-malformed-tags", line, tags)
        # LENGTH FROM THE LIST, MEMBERSHIP FROM THE SET. Collapsing duplicates
        # before asking "is this the row's only tag" made `may-skip,may-skip`
        # look like a lone modifier here and a selector-less row to the runner —
        # the same row, two classifications, from a set() the runner had no
        # equivalent of.
        row_tag_list = tags.split(",")
        row_tags = set(row_tag_list)
        # The class properties ARE the rules. `exclusive` needs no special case:
        # its class has selects=yes, so the selector test below already covers
        # it — naming the class here was a rule the definition already stated.
        if len(row_tag_list) == 1 and not (row_tags & rules.standalone):
            raise rules.row_error("row-not-standalone", line, tags)
        if not (row_tags & rules.selectors):
            raise rules.row_error("row-no-selector", line, tags)
        command = _ASCII_SPACE.sub(" ", command).strip(" ")
        if not command:
            raise rules.row_error("row-empty-command", line)
        _check_shell_syntax(command, line, rules)
        rows.append((tags, command))
    if not rows:
        raise ManifestError("scripts/validate manifest is empty")
    return rows


def _check_shell_syntax(command: str, line: str, rules: "Grammar") -> None:
    """Reject a manifest command that is not valid shell.

    VGS-30's rule for this file is that every command must be runnable exactly
    as written, and a syntax error is the one way a command can fail that rule
    without being absent or mis-moded. Left to the runner alone, this check
    would have been the first place the two readers disagreed on whether a row
    is acceptable — so it is here too, by shelling out to the same parser the
    runner uses rather than approximating one.

    A MISSING bash is a failure, not a skip: unable-to-verify must never read as
    verified, which is the standing rule for every check in this repo.
    """
    try:
        parsed = subprocess.run(
            ["bash", "-n", "-c", command], capture_output=True, text=True, check=False
        )
    except OSError as exc:
        # OSError, not FileNotFoundError: a bash that is present but
        # unreadable, non-executable, or unlaunchable for any other reason
        # raises a different subclass, and those escaped as tracebacks —
        # fail-closed in direction, but the diagnostic degraded to noise
        # exactly when someone is debugging. Same shape as the PyYAML import.
        raise ManifestError(
            f"could not run bash to check manifest command syntax, so it was "
            f"NOT checked: {exc}"
        ) from exc
    if parsed.returncode != 0:
        detail = parsed.stderr.strip() or f"bash -n exited {parsed.returncode}"
        error = rules.row_error("row-bad-syntax", line)
        raise ManifestError(f"{error}\n  {detail}")


GRAMMAR_FILE = Path(__file__).resolve().parent / "validation-grammar.conf"

# The flag that asks scripts/validate for the normalized grammar it parsed.
DUMP_FLAG = "--dump-grammar"

# The booleans every dumped `class` line carries, in the order the runner emits
# them. This is the DUMP's contract, not a restatement of the grammar's rules:
# whether a class may omit one, repeat one, or spell it `maybe` is the runner's
# question and is settled before anything reaches here.
CLASS_PROPERTIES = (
    "selects", "standalone", "rowtag", "exclusive", "cli", "universal", "skips",
)
CLASS_COUNTS = ("min", "max")


class Grammar:
    """The grammar as scripts/validate parsed it, decoded from its dump.

    NOT A PARSER OF validation-grammar.conf — deliberately, and this is the
    point of the change that introduced it. One definition removed "the grammar
    exists in two places" but left TWO READERS of it, and they disagreed about
    invalid or ambiguous input three times: the lone-modifier wording, a set()
    de-duplication, and a duplicate class declaration that one reader merged
    key-by-key and the other record-by-record. Same file, two meanings.

    So scripts/validate is the only parser — it must read and validate the
    definition anyway, with nothing on its critical path — and this decodes
    `scripts/validate --dump-grammar`. Divergence is now impossible by
    construction rather than detectable afterwards.

    A conformance corpus was the alternative and was rejected: a corpus
    ENUMERATES malformed shapes, and the lesson of the eight holes in VGS-123 is
    that such enumerations are incomplete. It would have caught neither the
    missing-trailing-newline divergence nor the metadata-pass indexing bug, both
    of which surfaced only while fixing something else.

    WHAT THIS GIVES UP, named rather than discovered later: nothing here can
    catch a bug in the runner's own parse. A runner that mis-reads the
    definition now mis-reports it identically to every consumer. That is covered
    behaviourally instead — scripts/test-validate.sh drives the runner against
    mutated grammars and asserts exit 2 with the definition's own wording, and
    scripts/test-validation-inventory.sh asserts the guard relays exactly what
    the runner said.

    The decode below validates the dump's SHAPE only. It supplies no defaults:
    the runner normalizes every field, so a decoder filling one in is where a
    second reader would start having opinions again.
    """

    def __init__(self, runner: Path) -> None:
        self.runner = runner
        self.classes: dict[str, dict[str, bool]] = {}
        self.counts: dict[str, dict[str, int]] = {}
        self.token_class: dict[str, str] = {}
        self.messages: dict[str, str] = {}
        self.source = GRAMMAR_FILE
        self._decode(self._dump())

    def _dump(self) -> str:
        """Ask the runner for the grammar. Its refusal is the answer, verbatim.

        A grammar the runner rejects must reach the caller as ONE diagnostic
        naming the runner's own wording — never a traceback, and never a silent
        skip that lets the arms below report something other than the real
        problem.
        """
        try:
            dumped = subprocess.run(
                ["bash", str(self.runner), DUMP_FLAG],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as exc:
            raise ManifestError(
                f"could not run {self.runner.name} {DUMP_FLAG}, so the grammar was "
                f"NOT read: {exc}"
            ) from exc
        if dumped.returncode != 0:
            detail = (
                dumped.stderr.strip()
                or dumped.stdout.strip()
                or f"exit {dumped.returncode} with no diagnostic"
            )
            raise ManifestError(
                f"{self.runner.name} refuses its own grammar, so nothing derived from "
                f"it could be checked: {detail}"
            )
        return dumped.stdout

    def _bad_dump(self, why: str) -> ManifestError:
        return ManifestError(
            f"{self.runner.name} {DUMP_FLAG} emitted something this decoder cannot "
            f"read, which is a defect in the runner's dump rather than in the "
            f"grammar: {why}"
        )

    def _decode(self, dump: str) -> None:
        for line in dump.splitlines():
            if not line.strip():
                continue
            kind, _, rest = line.partition(" ")
            if kind == "source":
                self.source = Path(rest)
            elif kind == "class":
                name, *fields = rest.split()
                props: dict[str, bool] = {}
                counts: dict[str, int] = {}
                for field in fields:
                    key, _, value = field.partition("=")
                    if key in CLASS_COUNTS:
                        counts[key] = int(value) if value.isdigit() else -1
                    else:
                        props[key] = value == "yes"
                missing = [p for p in CLASS_PROPERTIES if p not in props]
                if missing:
                    raise self._bad_dump(f"class {name} has no `{missing[0]}`")
                if set(counts) != set(CLASS_COUNTS):
                    raise self._bad_dump(f"class {name} does not carry min and max")
                self.classes[name] = props
                # `max=-` is the runner's spelling of unbounded, decoded to an
                # absent key so callers ask `if high is not None` as before.
                self.counts[name] = {k: v for k, v in counts.items() if v >= 0}
            elif kind == "token":
                name, _, cls = rest.partition(" ")
                if cls not in self.classes:
                    raise self._bad_dump(f"token {name} names undumped class {cls!r}")
                self.token_class[name] = cls
            elif kind == "message":
                key, _, text = rest.partition(" ")
                self.messages[key] = text
            else:
                raise self._bad_dump(f"unknown dump line kind {kind!r}")
        if not self.classes or not self.token_class:
            raise self._bad_dump("no classes or no tokens")

    def say(self, key: str, fallback: str) -> str:
        """A shared diagnostic by key. The fallback keeps a grammar that is
        missing a message readable rather than raising inside a raise."""
        return self.messages.get(key, fallback)

    def row_error(self, key: str, line: str, tags: str | None = None) -> ManifestError:
        """A row diagnostic, worded by the grammar and contextualised here."""
        text = self.say(key, key)
        where = f" `{tags}`" if tags else ""
        return ManifestError(f"scripts/validate: {text}{where}: {line}")

    def _with(self, prop: str) -> set[str]:
        return {t for t, c in self.token_class.items() if self.classes[c].get(prop)}

    @property
    def tokens(self) -> set[str]:
        return set(self.token_class)

    @property
    def arguments(self) -> set[str]:
        """What `scripts/validate X` accepts — asked as a property, not by class
        name: `c in ("area", "argument")` was a rule that named two classes."""
        return self._with("cli")

    @property
    def areas(self) -> set[str]:
        """CLI arguments that are also row tags. Derived, so a class renamed or
        added does not need an edit here."""
        return self._with("cli") & self._with("rowtag")

    @property
    def default_area(self) -> str:
        """The argument that means "every row" — cli, but never a row tag.

        `argument min=1 max=1` is what makes "the one" well defined, and the
        runner derives its default the same way rather than hardcoding `all`.
        """
        candidates = sorted(self._with("cli") - self._with("rowtag"))
        if len(candidates) != 1:
            raise ManifestError(
                f"{self.say('grammar-class-count', 'wrong number of tokens in a class')}"
                f": exactly one cli-only token is the default area, found {candidates}"
            )
        return candidates[0]

    @property
    def universal(self) -> set[str]:
        """Tokens that select every area rather than one named after them."""
        return self._with("universal") & self.row_tags

    @property
    def skipping(self) -> set[str]:
        """Tokens that let a row report exit 77 as a skip."""
        return self._with("skips") & self.row_tags

    @property
    def row_tags(self) -> set[str]:
        return self._with("rowtag")

    @property
    def selectors(self) -> set[str]:
        return self._with("selects") & self.row_tags

    @property
    def standalone(self) -> set[str]:
        return self._with("standalone") & self.row_tags

    @property
    def exclusive(self) -> set[str]:
        return self._with("exclusive") & self.row_tags

    def tag_pattern(self) -> re.Pattern[str]:
        """The accepted language for a tag field, derived from the classes."""
        excl = sorted(self.exclusive)
        comb = sorted(self.row_tags - self.exclusive)
        if not excl or not comb:
            raise ManifestError(
                f"{self.source.name}: the grammar needs both exclusive and combinable "
                f"row tags to form a tag field pattern"
            )
        excl_alt = "|".join(re.escape(t) for t in excl)
        comb_alt = "|".join(re.escape(t) for t in comb)
        return re.compile(rf"^(?:(?:{excl_alt})|(?:{comb_alt})(?:,(?:{comb_alt}))*)$")


def grammar(runner: Path) -> Grammar:
    """The grammar as `runner` parsed it. Takes the RUNNER, not the .conf: the
    runner is the only parser, and asking it is the whole point."""
    return Grammar(runner)


def runner_usage_arguments(runner: Path) -> set[str]:
    """The areas `scripts/validate -h` actually offers.

    Read by RUNNING the runner rather than by matching its text: the runner
    derives its argument list from the grammar, so the question is whether that
    derivation still agrees with the definition — which a text match on an array
    that no longer exists could not answer.
    """
    try:
        shown = subprocess.run(
            ["bash", str(runner), "-h"], capture_output=True, text=True, check=False
        )
    except OSError as exc:
        raise ManifestError(f"could not run {runner.name} -h: {exc}") from exc
    match = re.search(r"\[--list\] \[([^\]]*)\]", shown.stderr + shown.stdout)
    if not match:
        raise ManifestError(
            f"{runner.name} -h printed no `usage: ... [--list] [a|b|c]` line, so the "
            f"arguments it offers cannot be compared against the grammar"
        )
    return set(match.group(1).split("|"))


def token_participates(runner: Path, rules: "Grammar", token: str, workdir: Path):
    """Does the runner ACT on `token` as a tag? Answered by running it.

    Appearance is not participation. Matching whole tokens over the runner's
    text closed the substring hole (`skip` inside `may-skip`) but not the
    INCIDENTAL one: `status` and `run` are exact whole-token matches against the
    runner's own variables, so declaring either as a modifier passed while the
    tag was completely inert. Tag names and identifiers come from the same small
    pool of English words, so that collision will keep happening.

    So the question is behavioural, and it is the one the grammar already
    states: does the token change what a manifest SELECTS, or how a row EXITS?

      exclusive  a row tagged with it is skipped by a named area and taken by all
      selects    a row tagged with it is taken by an area it does not name
      modifier   a row tagged with it may exit 77 as a skip; without it, 77 fails

    Returns (participates, reason).
    """
    repo = workdir / "repo"
    (repo / "scripts" / "lib").mkdir(parents=True, exist_ok=True)
    # Written under the name the RUNNER looks for, not the fixture's own
    # basename: a grammar under test may live anywhere, but the runner resolves
    # its definition relative to itself. Copying it as `reordered.conf` left the
    # fixture runner unable to find any grammar, so every token looked inert.
    # The SOURCE PATH COMES FROM THE DUMP — the runner reports the file it
    # actually read — rather than being re-derived here, which would be this
    # module deciding again where the grammar lives.
    (repo / "scripts" / "lib" / GRAMMAR_FILE.name).write_text(
        rules.source.read_text(encoding="utf-8"), encoding="utf-8"
    )
    for stub, body in (("stub-x", "true"), ("stub-go", "true"), ("stub-skip", "exit 77")):
        target = repo / "scripts" / stub
        target.write_text(f"#!/usr/bin/env bash\n{body}\n", encoding="utf-8")
        target.chmod(0o755)

    def build(manifest: str) -> Path:
        text = runner.read_text(encoding="utf-8")
        text = re.sub(
            r"(<<'MANIFEST_EOF'\n).*?(\nMANIFEST_EOF\n)",
            lambda m: m.group(1) + manifest + m.group(2),
            text,
            flags=re.DOTALL,
        )
        probe = repo / "scripts" / "validate"
        probe.write_text(text, encoding="utf-8")
        probe.chmod(0o755)
        return probe

    def run(manifest: str, *args: str):
        probe = build(manifest)
        return subprocess.run(
            [str(probe), *args], capture_output=True, text=True, check=False
        )

    props = rules.classes[rules.token_class[token]]
    if props.get("exclusive"):
        scoped = run(f"{token}       | scripts/stub-x\ngo        | scripts/stub-go", "--list", "go")
        every = run(f"{token}       | scripts/stub-x\ngo        | scripts/stub-go", "--list", "all")
        if "stub-x" in scoped.stdout:
            return False, f"a row tagged `{token}` is selected by a named area, so it is not exclusive"
        if "stub-x" not in every.stdout:
            return False, f"a row tagged `{token}` is not selected by `all`, so nothing runs it"
        return True, ""
    if props.get("selects"):
        scoped = run(f"{token}       | scripts/stub-x\ngo        | scripts/stub-go", "--list", "go")
        if "stub-x" not in scoped.stdout:
            return False, (
                f"a row tagged `{token}` is not selected by an area it does not name, "
                f"so the tag changes nothing"
            )
        return True, ""
    tagged = run(f"go,{token}    | scripts/stub-skip", "go")
    plain = run("go        | scripts/stub-skip", "go")
    if tagged.returncode == plain.returncode:
        return False, (
            f"a row tagged `{token}` exits {tagged.returncode}, exactly as it does "
            f"untagged, so the tag changes nothing"
        )
    return True, ""


def runner_logic(runner: Path) -> str:
    """The runner's executable shell, with everything that is DATA removed.

    Used to ask whether a tag token is acted upon. Three things are stripped,
    and each one had to be:

      comments          a token named only in the header prose behaves exactly
                        like an undeclared one at run time
      the declarations  TAG_ATTRIBUTES and AREAS list the vocabulary; finding a
                        token in its own declaration proves nothing
      the manifest      the heredoc is data. Every attribute in real use appears
                        in a manifest ROW, so leaving it in made the whole test
                        vacuous: deleting the `may-skip` branch outright still
                        looked wired, because `qml,may-skip | ...` was in scope.

    What remains is shell that runs. That is a NECESSARY condition for a token
    being honoured, not a sufficient one — the behavioral proof that each branch
    does its job lives in scripts/test-validate.sh.
    """
    text = runner.read_text(encoding="utf-8")
    manifest = re.search(r"<<'MANIFEST_EOF'\n.*?\nMANIFEST_EOF\n", text, re.DOTALL)
    if manifest:
        text = text.replace(manifest.group(0), "")
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped.startswith("TAG_ATTRIBUTES=(") or stripped.startswith("AREAS=("):
            continue
        lines.append(line)
    return "\n".join(lines)


def prose_areas(path: Path) -> set[str]:
    """Backticked area names from a prose surface's `areas ...` enumeration.

    ABSENCE IS AN ERROR, never an empty answer. This returned None on a phrasing
    miss and the caller skipped that document, so rewording a lead-in — with a
    real, and possibly wrong, list still on the page — turned the comparison off
    while the suite stayed green. "An empty result treated as a clean result" is
    the standing rule this file's own instructions name.

    The wording coupling is the residual weakness: the parser keys on the word
    `areas` followed by backticked names. A delimited anchor in each document
    would remove it, and is the better long-term shape; making absence fatal is
    what stops the coupling from failing OPEN in the meantime.
    """
    match = re.search(
        r"areas\s+((?:`[a-z-]+`(?:,\s*|\s+and\s+|\s*)?)+)",
        path.read_text(encoding="utf-8"),
    )
    if not match:
        raise ManifestError(
            f"{path.name} no longer states the validate area list where this guard can "
            f"read it (the word `areas` followed by backticked names). Restore that "
            f"phrasing, or drop the enumeration entirely and remove the file from "
            f"AREA_ENUMERATING_DOCS as a recorded decision."
        )
    stated = set(re.findall(r"`([a-z-]+)`", match.group(1)))
    if not stated:
        raise ManifestError(f"{path.name} states an empty validate area list")
    return stated


def ci_run_commands(ci: Path) -> str:
    """Only the shell inside ci.yml's `run:` blocks, never the whole file.

    A raw substring test over ci.yml counts COMMENTS as invocations: deleting a
    check from its `run:` block while leaving the comment above it kept this
    guard green, the exact false green it exists to prevent. It cuts the other
    way too — a comment naming a local-only script would report a failure that
    is not real. A YAML parse is the honest form.
    """
    # IMPORTED HERE, not at module scope. At module scope the failure fires
    # during import — before the caller has installed its ManifestError handler
    # — so a python3 without PyYAML got a traceback out of the guard and a
    # cascade of unrelated fixture failures out of the two shell suites, in
    # place of one clear prerequisite line. Deferring also keeps every other
    # parser in this module usable without PyYAML at all.
    try:
        import yaml
    except ImportError as exc:
        # ImportError, not ModuleNotFoundError: a PyYAML that is INSTALLED but
        # fails to import — a broken build, a partial upgrade, a shadowing
        # module — raises the base class, and that escaped uncaught. Same
        # too-narrow-catch shape as FileNotFoundError vs OSError next door.
        # Fails rather than degrading: without a YAML parse, CI coverage is NOT
        # checked, and a check that silently skips its own subject is the exact
        # false green the importing guard exists to prevent.
        raise ManifestError(
            "PyYAML is not installed, so ci.yml could not be parsed and CI "
            "coverage was NOT checked (pacman -S python-yaml)"
        ) from exc

    workflow = yaml.safe_load(ci.read_text(encoding="utf-8"))
    runs: list[str] = []

    def walk(node) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "run" and isinstance(value, str):
                    runs.append(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(workflow)
    if not runs:
        raise ManifestError("ci.yml has no `run:` blocks at all")
    # Strip shell comments too: a `#` line inside a run block is still prose.
    lines = []
    for block in runs:
        for line in block.splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                lines.append(line)
    return "\n".join(lines)


def documented_table(doc: Path, lead_in: str) -> set[str]:
    """Script basenames named in the first column of the table after `lead_in`."""
    text = doc.read_text(encoding="utf-8")
    start = text.find(lead_in)
    if start == -1:
        raise ManifestError(f"{doc.name} has no table introduced by {lead_in!r}")
    names: set[str] = set()
    seen_rows = False
    for line in text[start + len(lead_in):].splitlines():
        stripped = line.strip()
        if not stripped:
            if seen_rows:
                break
            continue
        if not stripped.startswith("|"):
            break
        cells = stripped.split("|")
        if len(cells) < 2:
            continue
        first = cells[1].strip()
        if set(first) <= {"-", ":", " "}:  # the header underline
            continue
        match = re.search(r"`scripts/([A-Za-z0-9._-]+)`", first)
        if match:
            names.add(match.group(1))
            seen_rows = True
    return names
