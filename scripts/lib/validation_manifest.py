"""Read validation manifests, runner grammar dumps, area lists and CI commands.

Callers supply paths and own comparison policy. Parse failures raise
ManifestError so each caller can add its own diagnostic context.
"""

from __future__ import annotations

import re
import shlex
import subprocess
from pathlib import Path


class ManifestError(Exception):
    """A surface this module reads does not say what it must say."""


# The reader preserves line endings, so heredoc delimiters accept CRLF.
_HEREDOC_OPEN = r"<<'MANIFEST_EOF'\r?\n"
_HEREDOC_CLOSE = r"\r?\nMANIFEST_EOF\r?\n"
_MANIFEST_HEREDOC = re.compile(
    rf"({_HEREDOC_OPEN})(.*?)({_HEREDOC_CLOSE})", re.DOTALL
)


def _no_heredoc(consequence: str) -> ManifestError:
    """Describe an absent manifest heredoc delimiter."""
    return ManifestError(
        f"scripts/validate has no MANIFEST_EOF heredoc — every reader here finds "
        f"the manifest by that delimiter, {consequence}"
    )


def _read(path: Path, what: str) -> str:
    """Read text without newline translation; report file and decoding failures.

    The caller owns line splitting. Translating carriage returns before parsing
    would disagree with the runner whitespace rules.
    """
    try:
        with path.open(encoding="utf-8", newline="") as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise ManifestError(
            f"could not read {what} at {path}, so it was NOT checked: {exc}"
        ) from exc


def manifest_rows(runner: Path) -> list[tuple[str, str]]:
    """Return tag and command pairs from the manifest heredoc.

    This independent row reader can inspect manifests the runner rejects. Grammar
    rules come from the runner dump. Row refusal order follows the runner;
    parser-agreement controls compare their answers. Kept as a second reader on
    purpose: an inventory read from the runner's own dump would not cross-check
    it (docs/decisions/D009-manifest-second-reader.md).
    """
    text = _read(runner, "the manifest runner")
    block = _MANIFEST_HEREDOC.search(text)
    if not block:
        raise _no_heredoc("so moving or renaming it would silently empty the inventory")
    rules = grammar(runner)
    pattern = rules.tag_pattern()
    # Use the runner whitespace set rather than a second local definition.
    spaces = rules.whitespace_pattern()
    rows: list[tuple[str, str]] = []
    # Split only on newline: splitlines also splits vertical tabs and form feeds
    # that the runner treats as removable whitespace within a row.
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
        # Keep duplicates for tag counts; set membership alone loses repeated modifiers.
        row_tag_list = tags.split(",")
        row_tags = set(row_tag_list)
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
    """Reject invalid shell commands using bash syntax checking.

    An unavailable parser raises rather than reporting unchecked syntax as valid.
    """
    try:
        parsed = subprocess.run(
            ["bash", "-n", "-c", command], capture_output=True, text=True, check=False
        )
    except OSError as exc:
        raise ManifestError(
            f"could not run bash to check manifest command syntax, so it was "
            f"NOT checked: {exc}"
        ) from exc
    if parsed.returncode != 0:
        detail = parsed.stderr.strip() or f"bash -n exited {parsed.returncode}"
        error = rules.row_error("row-bad-syntax", line)
        raise ManifestError(f"{error}\n  {detail}")


GRAMMAR_FILE = Path(__file__).resolve().parent / "validation-grammar.conf"

DUMP_FLAG = "--dump-grammar"

# Boolean field order in the normalized grammar dump.
CLASS_PROPERTIES = (
    "selects", "standalone", "rowtag", "exclusive", "cli", "universal", "skips",
)
CLASS_COUNTS = ("min", "max")

# Validate canonical decimal spelling in the dump as well as the definition.
_CANONICAL_INT = re.compile(r"0|[1-9][0-9]*")


class Grammar:
    """Decode the normalized grammar produced by the runner.

    This validates dump structure and supplies no defaults. It cannot detect an
    incorrect grammar interpretation that the runner reports consistently.
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
        """Return the runner grammar dump or relay its refusal.

        Capture bytes so newline translation cannot alter dump message boundaries.
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
            # Decode diagnostics with replacement so encoding does not hide the runner error.
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
        """Decode required dump fields and reject malformed, unknown or repeated records."""
        seen_kinds: set[str] = set()
        # The runner emits newline-delimited records; other whitespace can be message text.
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
                    # Paths can contain spaces, so this field consumes the remainder of its line.
                    self.source = Path(rest)
                else:
                    # Tokens have a narrower syntax than paths and cannot contain spaces.
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
                        # Only max accepts the unbounded marker; other bounds are canonical decimals.
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
        # Validate the dumped default token; the runner decides which token qualifies.
        if self.default not in self.token_class:
            raise self._bad_dump(
                f"the default area {self.default!r} is not a dumped token"
            )

    def _decode_whitespace(self, rest: str) -> str:
        """Decode the runner whitespace codepoints and reject non-ASCII entries."""
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
        """Return tokens whose classes permit command-line use."""
        return self._with("cli")

    @property
    def areas(self) -> set[str]:
        """CLI arguments that are also row tags. Derived, so a class renamed or
        added does not need an edit here."""
        return self._with("cli") & self._with("rowtag")

    @property
    def default_area(self) -> str:
        """Return the default argument selected by the runner."""
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
    """Read the grammar through the supplied runner."""
    return Grammar(runner)


def runner_usage_arguments(runner: Path) -> set[str]:
    """Return areas listed by the runner help output."""
    try:
        shown = subprocess.run(
            ["bash", str(runner), "-h"], capture_output=True, text=True, check=False
        )
    except OSError as exc:
        raise ManifestError(f"could not run {runner.name} -h: {exc}") from exc
    # A nonzero help status means the runner failed before producing usable help.
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
    """Probe whether a token changes row selection or exit handling.

    Return participation and a diagnostic reason. The probes exercise exclusive
    selection, cross-area selection and permitted skip status as applicable.
    """
    repo = workdir / "repo"
    (repo / "scripts" / "lib").mkdir(parents=True, exist_ok=True)
    # Copy grammar to the relative path the fixture runner expects. The dump names
    # the source definition actually read.
    (repo / "scripts" / "lib" / GRAMMAR_FILE.name).write_text(
        _read(rules.source, "the grammar the runner dumped"), encoding="utf-8"
    )
    for stub, body in (("stub-x", "true"), ("stub-go", "true"), ("stub-skip", "exit 77")):
        target = repo / "scripts" / stub
        target.write_text(f"#!/usr/bin/env bash\n{body}\n", encoding="utf-8")
        target.chmod(0o755)

    def build(manifest: str) -> Path:
        # A missing delimiter must not leave the real manifest inside a synthetic probe.
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
        """Return list-probe output; raise if the probe fails."""
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
    """Remove recognized comments, declarations and manifest data from runner text.

    The result is a limited source view, not proof that a token affects execution.
    """
    text = _read(runner, "the manifest runner")
    manifest = _MANIFEST_HEREDOC.search(text)
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


AREA_ANCHOR_OPEN = "<!-- validate-areas -->"
AREA_ANCHOR_CLOSE = "<!-- /validate-areas -->"

# Only unindented backtick fences hide markers; indented and tilde examples count.
_FENCE_LINE = re.compile(r"(```+)(.*)$")

def _strip_fenced_blocks(path: Path, text: str, spaces: re.Pattern[str]) -> str:
    """Remove unindented backtick fences paired by character run length.

    Openers can carry info strings without backticks; closers permit only the
    supplied whitespace set. This set is the runner vocabulary and can accept
    whitespace beyond CommonMark fence syntax.
    """
    kept: list[str] = []
    open_run = 0
    for line in text.split("\n"):
        match = _FENCE_LINE.match(line)
        run = len(match.group(1)) if match else 0
        rest = match.group(2) if match else ""
        if not open_run:
            # Backtick fence info strings cannot contain a backtick.
            if run and "`" not in rest:
                open_run = run
            else:
                kept.append(line)
        # A closer permits only the runner whitespace set after its fence run.
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
    """Describe a marker that exists only inside a stripped fence."""
    return ManifestError(
        f"{path.name} carries {marker}, but only inside a code fence, where it is a "
        f"picture of the contract rather than the contract. Move the real anchor "
        f"outside the fence, or drop the enumeration entirely and remove the file "
        f"from AREA_ENUMERATING_DOCS as a recorded decision."
    )


def prose_areas(path: Path, rules: Grammar) -> set[str]:
    """Read backticked area names inside a unique ordered marker pair.

    Other backticked lowercase tokens inside the pair also count as area names.
    The supplied grammar defines whitespace for fence closing.
    """
    raw = _read(path, "an area-enumerating document")
    # An unclosed fence hides the remaining text and must be reported.
    text = _strip_fenced_blocks(path, raw, rules.whitespace_pattern())
    opens = text.count(AREA_ANCHOR_OPEN)
    closes = text.count(AREA_ANCHOR_CLOSE)
    # Distinguish fenced markers from absent markers at both ends.
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
    # Count both delimiters so an extra closer cannot leave a region unchecked.
    if opens > 1 or closes > 1:
        raise ManifestError(
            f"{path.name} carries {opens} opening and {closes} closing validate area "
            f"markers; the area list must be anchored exactly once, or one region is "
            f"read and the rest are silently ignored."
        )
    start = text.index(AREA_ANCHOR_OPEN) + len(AREA_ANCHOR_OPEN)
    end = text.find(AREA_ANCHOR_CLOSE, start)
    if end == -1:
        # A reversed pair is present but cannot enclose a region.
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
    """Return shell text from YAML run blocks, excluding whole-line comments."""
    # Import YAML only when CI parsing is needed, inside the caller error boundary.
    try:
        import yaml
    except ImportError as exc:
        # Installed but broken YAML modules can raise ImportError as well.
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


_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_KEYWORDS = frozenset({"if", "then", "elif", "else", "while", "until", "do", "!", "time", "{"})
# Redirection operands are file targets, not command starts.
_SEPARATORS = frozenset({";", ";;", "&", "&&", "|", "||", "(", ")"})
_REDIRECTIONS = frozenset({"<", "<<", "<<-", "<<<", "<&", "<>", ">", ">>", ">|", ">&"})
# A function declaration names a definition, not an invocation.
_DEFINITION = frozenset({"()", "("})
# Conditional bodies can skip commands. An if condition itself is scanned,
# while its then body is suppressed.
_BODY_OPEN = frozenset({"then", "do", "case"})
_BODY_CLOSE = frozenset({"fi", "done", "esac"})


def _heredoc_delimiter(operand: str) -> tuple[str, bool]:
    """The delimiter a `<<` operand names, and whether `<<-` tab stripping applies.

    shlex hands back `<<` and `-EOF` for `<<-EOF`, so the dash arrives on the
    operand. Quoting the delimiter changes expansion inside the body, never how
    the terminator is matched, so it is unwrapped here and nowhere else.
    """
    tabs = operand.startswith("-")
    return _unquote(operand[1:] if tabs else operand), tabs


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
    """Return whether supported CI shell forms invoke the supplied path.

    Count command positions after recognized prefixes and separators. Exclude
    arguments, comments, redirection targets, heredoc bodies, array values,
    function declarations and recognized conditional bodies.

    This approximates shell execution. AND-OR recovery can count a skipped path.
    Runtime expansion, substitutions, eval, aliases, sourced code and workflow
    step conditions are not modeled. A match does not prove that CI ran the lane.
    """
    heredoc: str | None = None
    heredoc_tabs = False
    # Track block state across lines so conditional bodies remain suppressed.
    conditional = 0
    for line in _logical_lines(ci_text):
        if heredoc is not None:
            # Only <<- strips leading tabs; ordinary heredocs require exact terminators.
            terminator = line.lstrip("\t") if heredoc_tabs else line
            if terminator == heredoc:
                heredoc = None
            continue
        # The right side of || is conditional. AND-OR recovery is not modeled, so
        # a path after && can count even when a later || recovers a skipped command.
        short_circuit = False
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
        # Array elements are data even when they look like command paths.
        array = 0
        assigned = False
        for index, token in enumerate(tokens):
            # Record heredocs even on a matched command line; later bodies must stay skipped.
            # A herestring operand is a word and opens no body.
            if token == "<<" and index + 1 < len(tokens):
                heredoc, heredoc_tabs = _heredoc_delimiter(tokens[index + 1])
            if token and all(character in lexer.punctuation_chars for character in token):
                if token == "(" and (assigned or array):
                    array += 1
                    continue
                if token == ")" and array:
                    array -= 1
                    continue
                if token == "||":
                    short_circuit = True
                if token in _REDIRECTIONS:
                    operand = True
                elif token in _SEPARATORS:
                    start = True
                    operand = False
                assigned = False
                continue
            if token in _BODY_OPEN:
                conditional += 1
                start = True
                continue
            if token in _BODY_CLOSE:
                conditional = max(0, conditional - 1)
                start = True
                continue
            if token == "elif":
                conditional = max(0, conditional - 1)
                start = True
                continue
            if operand:
                operand = False
                continue
            if array:
                continue
            # Assignments can be arguments, as in declare -a, after command position is gone.
            if _ASSIGNMENT.match(token):
                assigned = True
                continue
            if not start:
                continue
            if token in _KEYWORDS:
                continue
            if conditional or short_circuit:
                start = False
                continue
            assigned = False
            following = tokens[index + 1 : index + 2]
            defines = bool(following) and following[0] in _DEFINITION
            if _unquote(token) == path and not defines:
                found = True
            start = False
        if found:
            return True
    return False
