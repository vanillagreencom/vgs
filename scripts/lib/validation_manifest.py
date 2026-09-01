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
import shlex
import subprocess
from pathlib import Path


class ManifestError(Exception):
    """A surface this module reads does not say what it must say."""


# The manifest heredoc, spelled ONCE for every reader of it. `\r?\n` at both
# delimiters because `_read` opens with `newline=""`: on a CRLF-lined runner a
# pattern requiring a bare `\n` matches nothing, and every reader of this
# delimiter is wrong without it — the inventory is empty, the runner's
# executable shell still carries the manifest's DATA, and the participation
# probe is built from the wrong rows. All three now refuse rather than
# no-opping, so the CRLF spelling of that miss surfaces as a diagnostic naming
# the delimiter instead of as a quietly wrong answer.
_HEREDOC_OPEN = r"<<'MANIFEST_EOF'\r?\n"
_HEREDOC_CLOSE = r"\r?\nMANIFEST_EOF\r?\n"
_MANIFEST_HEREDOC = re.compile(
    rf"({_HEREDOC_OPEN})(.*?)({_HEREDOC_CLOSE})", re.DOTALL
)


def _no_heredoc(consequence: str) -> ManifestError:
    """A runner whose manifest delimiter could not be found, worded once.

    Three readers look for that heredoc and all three are wrong without it, so
    each states the same cause and its own consequence. Two of them used to state
    NOTHING: they no-opped, and shipped no false green only because the third
    refused the same file first.
    """
    return ManifestError(
        f"scripts/validate has no MANIFEST_EOF heredoc — every reader here finds "
        f"the manifest by that delimiter, {consequence}"
    )


def _read(path: Path, what: str) -> str:
    """A surface's text, with an unreadable file as a DIAGNOSTIC not a traceback.

    Every read in this module goes through here. A document that has become
    unreadable — mode, a dangling symlink, a directory where a file was, bytes
    that are not UTF-8 — used to escape as a traceback from inside whichever arm
    happened to touch it first: fail-closed in direction, but the diagnostic
    degraded to noise exactly when someone is debugging. Same class as the
    PyYAML import and the unlaunchable bash next door, by a different mechanism.

    UnicodeDecodeError is caught with OSError because it is the same event from
    the caller's side — this path did not yield text — and it is a ValueError,
    so an OSError-only catch let it through.

    THE LINE BOUNDARY IS THE CALLER'S DECISION, NOT THE READ LAYER'S, which is
    why this opens with `newline=""`. The convenience reader opens in
    universal-newline mode and rewrites a lone \\r — and \\r\\n — to \\n before
    any caller sees it, so a row tagged `qml\\r` arrived here already split in
    two while the runner, whose whitespace set CONTAINS 0d, stripped it and ran
    the row. That is the same divergence `str.splitlines()` produced on \\v and
    \\f, reached one layer lower: the shared set says "strip it" and the read
    said "end the row here". Spelled as `open(newline="")` rather than
    `read_text(newline=...)` because the latter is 3.13+ only.
    """
    try:
        with path.open(encoding="utf-8", newline="") as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise ManifestError(
            f"could not read {what} at {path}, so it was NOT checked: {exc}"
        ) from exc


# REVISIT(D009): collapse this into a `--dump-manifest` if the runner ever grows
# one for a second consumer, or if the two readers diverge on a row the agreement
# tests did not catch.
def manifest_rows(runner: Path) -> list[tuple[str, str]]:
    """`(tags, command)` pairs from the scripts/validate manifest heredoc.

    Parsed statically, not via `scripts/validate --list`: this check must report
    a manifest the runner cannot even parse.

    THE MANIFEST IS THE ONE THING STILL READ TWICE, and deliberately — weighed
    against collapsing it the way the grammar reader was collapsed, and kept.
    The reason is what this reader is FOR: the importing guard is an INVENTORY
    of the runner's own coverage, and an inventory taken from the audited party's
    own report is not a cross-check. The grammar had no equivalent to lose, which
    is why the same move was right one level up. Recorded as
    docs/decisions/D009-manifest-second-reader.md, with the cost named there.

    The grammar it applies is not a second copy — it comes from the runner's dump
    — but the row loop is a second reader, and scripts/test-validate.sh's
    parser-agreement case plus scripts/test-validation-inventory.sh's
    reader-agreement cases are what hold the two to one answer. Rows are refused
    in the same ORDER the runner refuses
    them (tag field, tag pattern, class rules, command) so one malformed line
    gets one diagnosis, not two readers naming different defects on it.
    """
    text = _read(runner, "the manifest runner")
    block = _MANIFEST_HEREDOC.search(text)
    if not block:
        raise _no_heredoc("so moving or renaming it would silently empty the inventory")
    rules = grammar(runner)
    pattern = rules.tag_pattern()
    # C4's set, AS THE RUNNER SPELLS IT — C4 being the constraint in
    # scripts/validate's manifest-grammar header that whitespace is ASCII and
    # removed before matching. This used to be a regex written here
    # under a comment claiming it changed with the runner's `ASCII_SPACE`;
    # nothing enforced that, so an ASCII character dropped from one side alone
    # would have divided the two readers exactly as a locale-resolved class once
    # did. Read from the dump, the two cannot hold different sets.
    spaces = rules.whitespace_pattern()
    rows: list[tuple[str, str]] = []
    # SPLIT ON `\n`, NEVER `str.splitlines()`, AND FOR THE SAME REASON THE SET
    # ABOVE IS SHARED. splitlines() also breaks on \v and \f — two of the six
    # characters in that very set — so a row tagged `qml\x0b` was ONE line the
    # runner stripped to `qml` and accepted, and TWO lines here, the first of
    # which has no `|` and was refused as a row with no separator. Verified end
    # to end before this was written. Sharing the character set does not settle
    # C4 on its own: the LINE BOUNDARY has to be the runner's too.
    for line in block.group(2).split("\n"):
        if not spaces.sub("", line):
            continue
        if "|" not in line:
            raise rules.row_error("row-no-separator", line)
        tags, command = line.split("|", 1)
        tags = spaces.sub("", tags)
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
        command = spaces.sub(" ", command).strip(" ")
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

# The same canonical form the runner enforces on the definition: no leading
# zero, no sign, no padding. Asserted again on the wire rather than assumed,
# since a dump is the one thing no other check looks at.
_CANONICAL_INT = re.compile(r"0|[1-9][0-9]*")


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
        self.default = ""
        self.whitespace = ""
        self._decode(self._dump())

    def _dump(self) -> str:
        """Ask the runner for the grammar. Its refusal is the answer, verbatim.

        A grammar the runner rejects must reach the caller as ONE diagnostic
        naming the runner's own wording — never a traceback, and never a silent
        skip that lets the arms below report something other than the real
        problem.

        CAPTURED AS BYTES AND DECODED HERE, for the reason `_read` opens with
        `newline=""`: `text=True` is universal-newline mode, so a \\r inside a
        dumped message would arrive at `_decode` already turned into a line
        break the runner never emitted, and the tail would be refused as an
        unknown dump line kind. The decoder below owns the line boundary.
        """
        try:
            dumped = subprocess.run(
                ["bash", str(self.runner), DUMP_FLAG],
                capture_output=True,
                check=False,
            )
        except OSError as exc:
            raise ManifestError(
                f"could not run {self.runner.name} {DUMP_FLAG}, so the grammar was "
                f"NOT read: {exc}"
            ) from exc
        if dumped.returncode != 0:
            # LOSSY ON PURPOSE, and only here: this is a diagnostic being
            # relayed, so undecodable bytes in the runner's refusal must not
            # replace that refusal with a decoding complaint.
            detail = (
                dumped.stderr.decode("utf-8", "replace").strip()
                or dumped.stdout.decode("utf-8", "replace").strip()
                or f"exit {dumped.returncode} with no diagnostic"
            )
            raise ManifestError(
                f"{self.runner.name} refuses its own grammar, so nothing derived from "
                f"it could be checked: {detail}"
            )
        try:
            return dumped.stdout.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise self._bad_dump(f"its output is not valid UTF-8: {exc}") from exc

    def _bad_dump(self, why: str) -> ManifestError:
        return ManifestError(
            f"{self.runner.name} {DUMP_FLAG} emitted something this decoder cannot "
            f"read, which is a defect in the runner's dump rather than in the "
            f"grammar: {why}"
        )

    def _decode(self, dump: str) -> None:
        """Decode the dump, FAIL-CLOSED on anything it does not recognise.

        Strictness matters more here than anywhere else in this module, for a
        reason particular to the single-reader shape: this is the ONLY consumer
        of the dump, so it is the last place a runner dump bug can be caught —
        and a runner bug is precisely the class the single reader can no longer
        catch any other way. It is also the code that states the principle: a
        decoder supplying a default is where a second reader starts having
        opinions again, and coercing `min=banana` to -1 and then dropping it was
        that, in the file the note is written in.

        So every field is VALIDATED, never coerced: an unparseable value, an
        unknown key, a repeated record and a missing required line all raise,
        naming the runner's dump as the defect, because on a validated .conf
        that is the only way any of them can be reached.
        """
        seen_kinds: set[str] = set()
        # `\n` here too: this decodes text the RUNNER emitted, so its line
        # boundary is the runner's. splitlines() would break a message carrying a
        # \v or \f into two dump lines and report the tail as an unknown line
        # kind — a refusal aimed at the wrong thing. Left alone deliberately:
        # ci_run_commands (YAML text, and no reader compares its line set with
        # the runner's) and runner_logic (compares no boundaries at all).
        for line in dump.split("\n"):
            if not line.strip():
                continue
            kind, _, rest = line.partition(" ")
            if kind in ("source", "default", "whitespace"):
                if kind in seen_kinds:
                    raise self._bad_dump(f"more than one `{kind}` line")
                seen_kinds.add(kind)
                if not rest:
                    raise self._bad_dump(f"`{kind}` line is empty")
                if kind == "whitespace":
                    self.whitespace = self._decode_whitespace(rest)
                elif kind == "source":
                    # A PATH, so it takes the rest of the line — the way
                    # `message` takes free text after its key. Requiring one
                    # whitespace-free word broke every checkout under a
                    # directory whose path contains a space: the grammar and the
                    # checkout were both correct and the guard simply refused to
                    # run. The strictness this replaces was added for a real
                    # reason, so the field stays validated (present, non-empty,
                    # dumped once) — it just no longer forbids a value a path
                    # may legitimately take.
                    self.source = Path(rest)
                else:
                    # A TOKEN, which the runner constrains to `[a-z][a-z0-9-]*`
                    # or `-`, so it genuinely cannot contain a space. Checked
                    # here as well because the membership test below would
                    # otherwise report `qml all` as an unknown token rather than
                    # as a malformed line.
                    if rest.split() != [rest]:
                        raise self._bad_dump(f"`default {rest}` is not one token")
                    self.default = rest
            elif kind == "class":
                fields = rest.split()
                if not fields:
                    raise self._bad_dump("a `class` line with no name")
                name, fields = fields[0], fields[1:]
                if name in self.classes:
                    raise self._bad_dump(f"class {name} dumped twice")
                props: dict[str, bool] = {}
                counts: dict[str, int | None] = {}
                for field in fields:
                    key, sep, value = field.partition("=")
                    if not sep:
                        raise self._bad_dump(f"class {name}: `{field}` is not key=value")
                    if key in props or key in counts:
                        raise self._bad_dump(f"class {name} repeats `{key}`")
                    if key in CLASS_COUNTS:
                        # `-` is the runner's spelling of unbounded, and it is
                        # only legal on max. Anything else must be a canonical
                        # decimal — the same form the runner enforces on the
                        # .conf, asserted again on the wire rather than assumed.
                        if value == "-" and key == "max":
                            counts[key] = None
                        elif _CANONICAL_INT.fullmatch(value):
                            counts[key] = int(value)
                        else:
                            raise self._bad_dump(
                                f"class {name}: `{key}={value}` is not a decimal integer"
                                + (" or `-`" if key == "max" else "")
                            )
                    elif key in CLASS_PROPERTIES:
                        if value not in ("yes", "no"):
                            raise self._bad_dump(
                                f"class {name}: `{key}={value}` is not yes or no"
                            )
                        props[key] = value == "yes"
                    else:
                        raise self._bad_dump(f"class {name}: unknown field `{key}`")
                missing = [p for p in CLASS_PROPERTIES if p not in props]
                if missing:
                    raise self._bad_dump(f"class {name} has no `{missing[0]}`")
                if set(counts) != set(CLASS_COUNTS):
                    raise self._bad_dump(f"class {name} does not carry min and max")
                self.classes[name] = props
                # An unbounded max is dropped so callers keep asking
                # `if high is not None`; that is a representation choice on a
                # value the dump stated, not a default supplied for one it did
                # not.
                self.counts[name] = {k: v for k, v in counts.items() if v is not None}
            elif kind == "token":
                fields = rest.split()
                if len(fields) != 2:
                    raise self._bad_dump(f"`token {rest}` is not `token <name> <class>`")
                name, cls = fields
                if name in self.token_class:
                    raise self._bad_dump(f"token {name} dumped twice")
                if cls not in self.classes:
                    raise self._bad_dump(f"token {name} names undumped class {cls!r}")
                self.token_class[name] = cls
            elif kind == "message":
                key, sep, text = rest.partition(" ")
                if not key or not sep or not text:
                    raise self._bad_dump(f"`message {rest}` has no key or no text")
                if key in self.messages:
                    raise self._bad_dump(f"message {key} dumped twice")
                self.messages[key] = text
            else:
                raise self._bad_dump(f"unknown dump line kind {kind!r}")
        for required in ("source", "default", "whitespace"):
            if required not in seen_kinds:
                raise self._bad_dump(f"no `{required}` line")
        if not self.classes or not self.token_class:
            raise self._bad_dump("no classes or no tokens")
        # SHAPE, not rule: the runner decides WHICH token is the default and
        # whether exactly one is eligible. All this asks is that the dump named
        # one and named a token it also dumped, so a lookup below cannot return
        # something that is not in the vocabulary.
        if self.default not in self.token_class:
            raise self._bad_dump(
                f"the default area {self.default!r} is not a dumped token"
            )

    def _decode_whitespace(self, rest: str) -> str:
        """C4's whitespace set, decoded from the dump's hex codepoints.

        VALIDATED, never coerced, like every other field: a codepoint outside
        ASCII is refused here rather than accepted and then relied upon, because
        C4 is exactly the claim that this set is ASCII — a transport can carry a
        wider one, and the decoder is where that stops.
        """
        chars: list[str] = []
        for field in rest.split():
            if not re.fullmatch(r"[0-9a-f]{2}", field):
                raise self._bad_dump(
                    f"`whitespace {rest}`: `{field}` is not a two-digit lowercase "
                    f"hex codepoint"
                )
            code = int(field, 16)
            if code > 0x7F:
                raise self._bad_dump(
                    f"`whitespace {rest}`: U+{code:04X} is not ASCII, and C4 is the "
                    f"claim that this set is"
                )
            char = chr(code)
            if char in chars:
                raise self._bad_dump(f"`whitespace {rest}` repeats `{field}`")
            chars.append(char)
        if not chars:
            raise self._bad_dump("`whitespace` line names no codepoints")
        return "".join(chars)

    def whitespace_pattern(self) -> re.Pattern[str]:
        """A character class over the runner's own whitespace set.

        Built from codepoints rather than from `re.escape`, so the class the
        readers apply is unambiguous even for the characters that carry a
        backslash meaning of their own.
        """
        return re.compile("[" + "".join(rf"\x{ord(c):02x}" for c in self.whitespace) + "]")

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
        """The argument that means "every row", AS THE RUNNER RESOLVED IT.

        A lookup, not a computation. This used to re-derive the default from
        `cli & not rowtag` and raise when that set was not a singleton — which
        made the guard reject a grammar the runner had accepted and run against,
        the exact split the single-reader change exists to close. Re-deriving is
        not a second parser, but it is a second place the rule is written, and
        that turned out to be the same thing.

        The invariant itself — exactly one eligible token across all classes —
        now lives in the runner's pre-flight, so a grammar violating it never
        produces a dump to decode.
        """
        return self.default

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
    # THE STATUS IS PART OF THE ANSWER. `-h` exits 0; anything else means the
    # runner never reached its usage line, and reporting that as "printed no
    # usage line" names the symptom instead of the cause. Same discarded-status
    # class as the runner's process substitutions.
    if shown.returncode != 0:
        detail = (shown.stderr.strip() or shown.stdout.strip()).splitlines()
        raise ManifestError(
            f"{runner.name} -h exited {shown.returncode} instead of printing its usage, "
            f"so the arguments it offers could not be read: "
            f"{detail[0] if detail else 'no output'}"
        )
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
        _read(rules.source, "the grammar the runner dumped"), encoding="utf-8"
    )
    for stub, body in (("stub-x", "true"), ("stub-go", "true"), ("stub-skip", "exit 77")):
        target = repo / "scripts" / stub
        target.write_text(f"#!/usr/bin/env bash\n{body}\n", encoding="utf-8")
        target.chmod(0o755)

    def build(manifest: str) -> Path:
        # SUBSTITUTED OR REFUSED, never quietly zero times. A `sub` that matches
        # nothing returns the text unchanged, so a renamed delimiter would have
        # built a probe carrying the REAL manifest and answered the
        # participation question about the wrong rows — a confident wrong answer
        # in place of a diagnostic.
        text, swapped = _MANIFEST_HEREDOC.subn(
            lambda m: m.group(1) + manifest + m.group(3),
            _read(runner, "the manifest runner"),
        )
        if not swapped:
            raise _no_heredoc(
                f"so the participation probe for `{token}` could not be built"
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

    def listing(manifest: str, *args: str) -> str:
        """A `--list` probe's stdout, with a FAILED probe distinguished.

        The exclusive and selects branches read stdout only, so a probe that
        exited 2 for an unrelated reason produced empty output and was reported
        as "the tag changes nothing" — a discarded status turning into a
        confident wrong diagnosis about the token. Raising keeps the two apart.
        """
        result = run(manifest, *args)
        if result.returncode != 0:
            detail = (result.stderr.strip() or result.stdout.strip()).splitlines()
            raise ManifestError(
                f"the participation probe for `{token}` exited {result.returncode} "
                f"instead of listing, so whether the runner acts on the token was NOT "
                f"determined: {detail[0] if detail else 'no output'}"
            )
        return result.stdout

    props = rules.classes[rules.token_class[token]]
    probe_manifest = f"{token}       | scripts/stub-x\ngo        | scripts/stub-go"
    if props.get("exclusive"):
        scoped = listing(probe_manifest, "--list", "go")
        every = listing(probe_manifest, "--list", "all")
        if "stub-x" in scoped:
            return False, f"a row tagged `{token}` is selected by a named area, so it is not exclusive"
        if "stub-x" not in every:
            return False, f"a row tagged `{token}` is not selected by `all`, so nothing runs it"
        return True, ""
    if props.get("selects"):
        scoped = listing(probe_manifest, "--list", "go")
        if "stub-x" not in scoped:
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
    text = _read(runner, "the manifest runner")
    manifest = _MANIFEST_HEREDOC.search(text)
    # A MISS IS REFUSED, NOT SHRUGGED AT. `if manifest:` with no else left the
    # rows in the returned text on a renamed or removed delimiter — precisely the
    # vacuity described above, since every attribute in real use appears in some
    # row. It shipped no false green only because manifest_rows refuses the same
    # file in a sibling arm, which is an implicit coupling between two readers
    # that nothing asserted.
    if not manifest:
        raise _no_heredoc("so the runner's executable shell could not be isolated")
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


# The markers that delimit a document's validate area list. HTML comments, so
# every one of these surfaces is markdown and renders unchanged.
AREA_ANCHOR_OPEN = "<!-- validate-areas -->"
AREA_ANCHOR_CLOSE = "<!-- /validate-areas -->"

# A FENCE LINE, and its RUN LENGTH, which is what decides pairing below.
#
# ONLY AN UNINDENTED BACKTICK FENCE, and the contract paragraph in
# .github/instructions/validation-scripts.instructions.md says so in those
# words. A fence opened under a list bullet, and a `~~~` fence, are not matched
# here, so markers inside one are read as the real thing — which fails LOUDLY
# (two anchored regions) rather than quietly, and is the direction to keep.
_FENCE_LINE = re.compile(r"(```+)(.*)$")

def _strip_fenced_blocks(path: Path, text: str, spaces: re.Pattern[str]) -> str:
    """`text` with every unindented fenced block removed, PAIRED BY RUN LENGTH.

    A FENCED BLOCK IS NOT A MARKER, it is a picture of one. Without this the
    document that DOCUMENTS the anchor could not show it: a second literal
    `<!-- validate-areas -->` anywhere on the page — even inside a code fence
    demonstrating the contract — trips the exactly-once refusal below, so the
    mechanism was unnameable in the one place it is explained.

    RUN LENGTH IS COMPARED, and this scanner exists because not comparing it was
    a FALSE ACCEPT rather than the false refusal it was assumed to be. Pairing
    each fence line with the next one regardless of length splits a four-backtick
    block around the three-backtick example inside it, leaving the example's
    middle live: the identical illustration that is correctly read as a picture
    one nesting level up was silently honoured as the REAL anchor, so a page
    could pass this guard on the strength of a list nobody maintains. Markdown's
    rule — a fence closes on a run at least as long as the one that opened it —
    is what makes the two levels agree, and a line scanner is enough for it.

    THE TWO ENDS TAKE DIFFERENT REMAINDERS, and the asymmetry is CommonMark's,
    not a convenience: an OPENER may carry an info string but that string may not
    contain a backtick, while a CLOSER may carry no info string at all. Each rule
    is stated again at the arm that enforces it, because reading one and assuming
    the other is how both halves of this were wrong in turn.

    Both halves were the same FALSE ACCEPT, one side each, and both inverted which
    text is live. Closing on run length alone ended a block early, so a complete
    anchored list rendering INSIDE a fence was read as the contract; opening on
    run length alone started a block where a reader sees ordinary text, so a stale
    live list was stripped and the fenced example accepted in its place. Either
    way the page passed against a list nobody maintains.

    `spaces` IS THE RUNNER'S OWN SET, THE SAME ONE THE ROW READER APPLIES, and it
    is a parameter for the reason C4 is: a whitespace list hand-spelled here is a
    SECOND definition, and the first character the two disagreed on cost a real
    answer — the pair `[ \\t]` read the trailing carriage return of a CRLF
    checkout as content, so every genuine closer stopped closing and a balanced
    page was refused as unclosed. Since the set is the runner's, `\\f` and `\\v`
    after a closing run are tolerated where CommonMark would not tolerate them;
    one shared set is worth more here than that margin, because divergence is
    what fails silently and the margin cannot.
    """
    kept: list[str] = []
    open_run = 0
    for line in text.split("\n"):
        match = _FENCE_LINE.match(line)
        run = len(match.group(1)) if match else 0
        rest = match.group(2) if match else ""
        if not open_run:
            # AN OPENER TAKES AN INFO STRING, BUT NOT A BACKTICK INSIDE IT: a
            # backtick fence's info string may not contain one, so such a line is
            # ordinary text and is KEPT. No whitespace question arises here — the
            # info string is free-form — which is why this arm spells no set.
            if run and "`" not in rest:
                open_run = run
            else:
                kept.append(line)
        # A CLOSER TAKES NO INFO STRING AT ALL, only whitespace, and that
        # whitespace is the runner's dumped set rather than a pair written here.
        elif run >= open_run and not spaces.sub("", rest):
            open_run = 0
    if open_run:
        raise ManifestError(
            f"{path.name} opens an unindented ``` code fence that is never closed by "
            f"a line of at least {open_run} backticks and nothing after them but "
            f"whitespace, so a code fence is opened and "
            f"never closed. Which markers are pictures and which are the contract is "
            f"decided by that pairing, so an unclosed fence moves the region this "
            f"guard reads."
        )
    return "\n".join(kept)


def _fenced_marker_error(path: Path, marker: str) -> ManifestError:
    """The one wording for "this marker is present, but only as a picture".

    Written once and taken by both ends: the opener and the closer fail the same
    way, and spelling the diagnosis at one of them is how the wrong-cause report
    survived at the other.
    """
    return ManifestError(
        f"{path.name} carries {marker}, but only inside a code fence, where it is a "
        f"picture of the contract rather than the contract. Move the real anchor "
        f"outside the fence, or drop the enumeration entirely and remove the file "
        f"from AREA_ENUMERATING_DOCS as a recorded decision."
    )


def prose_areas(path: Path, rules: Grammar) -> set[str]:
    """Backticked area names from between a document's validate-areas anchors.

    TAKES THE GRAMMAR ONLY FOR ITS WHITESPACE SET, and takes it rather than
    spelling one because C4 — the runner's set, dumped and read back — is what
    keeps a character from being dropped on one side alone. The cost is real and
    accepted: reading a document now needs a runner whose grammar parses, where
    before it needed only the file. Every caller already holds one, and the
    importing guard reads the grammar first and stops on a bad one, so the
    dependency adds no reachable arm; a future caller that has no runner must
    obtain a grammar rather than be handed a literal.

    ANCHORED, NOT WORDED. This used to key on the word `areas` followed by
    backticked names, which coupled the guard to a phrasing three documents
    happened to share: rewording a lead-in, or separating the names with
    something the pattern could not follow, changed what the guard read. Absence
    being fatal kept that from failing OPEN, but the coupling itself was the
    defect.

    WHAT THE ANCHOR DECOUPLES IS THE PROSE, NOT THE CODE SPANS. Every backticked
    lowercase token between the markers is read as an area name, so a document
    may reword the sentence however it likes but must put nothing else in
    backticks in there — a stray "see `bin`" inside the region is reported as an
    area the runner does not accept. Saying "whatever it likes" overstated the
    contract by exactly that much.

    ABSENCE IS STILL AN ERROR, never an empty answer, and so is a second anchor:
    with two anchored regions the parser would read one and silently ignore the
    other, which is "an empty result treated as a clean result" wearing the next
    disguise.
    """
    raw = _read(path, "an area-enumerating document")
    # AN UNCLOSED FENCE IS REFUSED BY THE STRIP ITSELF, before any marker is
    # counted: one stray opener swallows every line below it, so a live region
    # becomes a picture and the misdirection lands on whichever arm reads next.
    text = _strip_fenced_blocks(path, raw, rules.whitespace_pattern())
    opens = text.count(AREA_ANCHOR_OPEN)
    closes = text.count(AREA_ANCHOR_CLOSE)
    # A MARKER THAT EXISTS BUT IS FENCED IS ITS OWN DIAGNOSIS, AT EITHER END.
    # Reporting it as "no anchor ... restore the anchor" sent the author to re-add
    # something plainly on the page and never named the fence that swallowed it;
    # keying the diagnosis on the opener alone left that identical wrong cause
    # reachable through the closer, which then reported "never closes it" about a
    # document whose closing marker is right there.
    if opens == 0 and AREA_ANCHOR_OPEN in raw:
        raise _fenced_marker_error(path, AREA_ANCHOR_OPEN)
    if opens == 0:
        raise ManifestError(
            f"{path.name} has no {AREA_ANCHOR_OPEN} anchor around its validate area "
            f"list. Restore the anchor, or drop the enumeration entirely and remove "
            f"the file from AREA_ENUMERATING_DOCS as a recorded decision."
        )
    if closes == 0 and AREA_ANCHOR_CLOSE in raw:
        raise _fenced_marker_error(path, AREA_ANCHOR_CLOSE)
    # BOTH MARKERS ARE COUNTED. Counting only the opener left the identical hole
    # through the other end: one opener and two closers reads open..close#1, and
    # anything between close#1 and close#2 is a region no reader looks at — the
    # very thing the open-count check exists to prevent.
    if opens > 1 or closes > 1:
        raise ManifestError(
            f"{path.name} carries {opens} opening and {closes} closing validate area "
            f"markers; the area list must be anchored exactly once, or one region is "
            f"read and the rest are silently ignored."
        )
    start = text.index(AREA_ANCHOR_OPEN) + len(AREA_ANCHOR_OPEN)
    end = text.find(AREA_ANCHOR_CLOSE, start)
    if end == -1:
        # A CLOSER THAT EXISTS BUT PRECEDES THE OPENER IS NOT A MISSING CLOSER.
        # The region is read between the two, so a reversed pair anchors nothing
        # — and telling the author to add a marker the page already carries is
        # the same wrong cause the fenced arms above exist to avoid.
        if closes:
            raise ManifestError(
                f"{path.name} carries {AREA_ANCHOR_CLOSE} BEFORE its "
                f"{AREA_ANCHOR_OPEN}; the area list is read between the two, so a "
                f"reversed pair anchors nothing. Put the closing marker after the "
                f"opening one."
            )
        raise ManifestError(
            f"{path.name} opens the validate area anchor but never closes it with "
            f"{AREA_ANCHOR_CLOSE}"
        )
    stated = set(re.findall(r"`([a-z-]+)`", text[start:end]))
    if not stated:
        raise ManifestError(f"{path.name} anchors an empty validate area list")
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

    workflow = yaml.safe_load(_read(ci, "the CI workflow"))
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


# Command position, for ci_runs below. `VAR=value` is a prefix and not yet the
# command; a shell keyword hands command position to the word after it.
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_KEYWORDS = frozenset({"if", "then", "elif", "else", "while", "until", "do", "!", "time", "{"})
# Operator tokens that END a command, so the next word starts one. Kept apart
# from the redirections below because shlex hands back both as punctuation and
# treating a redirection as a separator is fail-open: `: > <path>` truncates the
# file and runs nothing, while reading `>` as a separator made <path> a command.
_SEPARATORS = frozenset({";", ";;", "&", "&&", "|", "||", "(", ")"})
_REDIRECTIONS = frozenset({"<", "<<", "<<-", "<<<", "<&", "<>", ">", ">>", ">|", ">&"})
# `name()` and `name ()` open a function DEFINITION. The word before it is being
# defined, not called, so a workflow that defines a function named after a lane
# has still stopped running it.
_DEFINITION = frozenset({"()", "("})


def _unquote(token: str) -> str:
    """A token wrapped whole in one quote pair, unwrapped. `"scripts/x"` runs it."""
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "\"'":
        return token[1:-1]
    return token


def _logical_lines(text: str) -> list[str]:
    """Physical lines with backslash continuations joined.

    The word after a continuation is an ARGUMENT of the command above it, not a
    new command, and treating it as a command start is a fail-open.
    """
    lines: list[str] = []
    pending = ""
    for line in text.splitlines():
        if line.endswith("\\"):
            pending += line[:-1]
            continue
        lines.append(pending + line)
        pending = ""
    if pending:
        lines.append(pending)
    return lines


def ci_runs(ci_text: str, path: str) -> bool:
    """Whether ci.yml INVOKES `path`, rather than merely mentioning it.

    `path in ci_text` was the first form of this question, and it answers yes to
    an ARGUMENT and to a trailing comment: `echo scripts/foo.py` and
    `scripts/bar.py  # replaces scripts/foo.py` both contain the path while CI
    runs nothing of the sort. A workflow could stop running a lane and leave
    every lockstep arm green, which is the false green those arms exist to
    prevent. ci_run_commands already drops YAML comments and whole-line shell
    comments; the shapes left over are the trailing comment and the argument.

    TOKENIZED, NOT SPLIT. The first repair split each line on separator
    characters, which is fail-open on a quoted one: `echo "( scripts/foo.py )"`
    made the path the first word of a synthetic segment and read as an
    invocation. shlex with `punctuation_chars` is quote-aware, so a separator
    inside a string stays inside the token it belongs to.

    A path counts only in COMMAND POSITION: the first word of a command, which
    is the start of a logical line or whatever follows an operator token, after
    any `VAR=value` prefixes and shell keywords. Heredoc bodies are skipped to
    their delimiter, since a line there is data and not a command; backslash
    continuations are joined for the same reason.

    A line that cannot be tokenized — an unbalanced quote — is skipped rather
    than guessed at, so it can never be shown to invoke anything. That direction
    reports a problem instead of hiding one, which is the bias a predicate
    written to remove a false green has to take.
    """
    heredoc: str | None = None
    for line in _logical_lines(ci_text):
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        lexer = shlex.shlex(line, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = "#"
        try:
            tokens = list(lexer)
        except ValueError:
            continue
        found = False
        start = True
        operand = False
        for index, token in enumerate(tokens):
            # Recorded even when the invocation is found on this same line: the
            # body still has to be skipped, so the scan finishes the line first.
            if token.startswith("<<") and index + 1 < len(tokens):
                heredoc = _unquote(tokens[index + 1]).lstrip("-")
            if token and all(character in lexer.punctuation_chars for character in token):
                if token in _REDIRECTIONS:
                    operand = True
                elif token in _SEPARATORS:
                    start = True
                    operand = False
                continue
            if operand:
                # A redirection TARGET, which is written to and never executed.
                operand = False
                continue
            if not start:
                continue
            if _ASSIGNMENT.match(token) or token in _KEYWORDS:
                continue
            following = tokens[index + 1 : index + 2]
            defines = bool(following) and following[0] in _DEFINITION
            if _unquote(token) == path and not defines:
                found = True
            start = False
        if found:
            return True
    return False


def documented_table(doc: Path, lead_in: str) -> set[str]:
    """Script basenames named in the first column of the table after `lead_in`."""
    text = _read(doc, "a documented-table surface")
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
