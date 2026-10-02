# Jarvis voice text

Covers: shell/plugins/vgs.jarvis/backend/Guidance.js, shell/plugins/vgs.jarvis/backend/Speakable.js, shell/plugins/vgs.jarvis/backend/SpeechLanguage.js, shell/plugins/vgs.jarvis/backend/skills/voice/, scripts/test-jarvis-guidance.js, scripts/test-jarvis-speakable.js, scripts/test-jarvis-speech-language.js, scripts/fixtures/jarvis-voice/

The [voice contract](../plans/v2-jarvis-plan.md#5-voice-agent-skill) assigns guidance layers to model classes. These Node modules are the engines' text boundary. The [chained engine](jarvis-engine.md) consumes both. They open no provider, device, account or process. They add no runtime dependency.

## Guidance

`Guidance.js::compose(engine, brainClass, language)` is the only layer selector. Its header defines the accepted consumer names. It returns `instructions`, an ordered `layers` array, and `afterToolResult`. It reads assets beside the module, including from a published plugin snapshot or a read-only install. `ComputerHelp` owns the bounded reads of [computer-tool references](jarvis-shell-tools.md#status-and-reference).

- The duplex voice model gets the short core, speech, turns and persona. Its delegated brain gets core, speech and actions, even when that brain is local. Delegation does not add the chained turn rules.
- The chained frontier brain gets core through actions and the language layer. The chained local brain also gets worked examples.
- A chained local engine must append `afterToolResult` as instructions after each tool result. The returned text reuses the core and local step layers, including the one-tool rule, not a separately maintained rule. Other consumers receive null.
- Consumers send `instructions` through their adapter's instruction channel. They do not treat tool results as instructions. They supply the session timing and heard-prefix context separately.
- The guidance describes authority but grants none. The router, policy, release and task owners still enforce their contracts.

The selector offers English (`en`) and Spanish (`es`). Empty language selects English. An unsupported language fails, rather than silently changing the user's choice. The language/voice selection engine belongs to the [multilingual row](../plans/v2-jarvis-plan.md#12-issue-breakdown).

## Speakable

`Speakable.js::create(language)` owns one text stream per generated turn or commentary append. `push(chunk)` returns completed sentences. `finish()` closes the stream and returns its last fragment. Callers send only these returned strings to text-to-speech. They discard the stream on cancellation. They do not reuse it for another turn.

- The lexer keeps valid fragmented tags and addresses pending. Impossible tag prefixes return to prose immediately. It removes markdown markers, images, complete HTML tags, comments and absolute paths. It discards code without retaining the body. An unfinished valid tag returns to prose at EOF.
- A markdown link keeps its visible label, not its target. A scheme URL, `www.` address or `mailto:` address becomes a spoken hostname label without `www.` or the final DNS label. This is not a domain-ownership check. A malformed address disappears.
- Numbers and ordinals share locale grouping. The language owner expands decimals, units, rates, currency, dates and times. Quantities with labels keep their fractions. Identifiers keep digit runs and spoken decimal separators. Spanish agreement has one owner for units and scales. Ambiguous dates and unknown units are not guessed.
- A non-alphanumeric boundary starts a path, including punctuation, quotes and removed HTML separators. Slashes inside rates, availability notation and words do not discard the remainder. Spanish question and exclamation marks remain punctuation, not measured violations.
- Sentence cuts wait for punctuation followed by whitespace, or the end of the stream. Decimal points and supported abbreviations do not cause an early cut. This delivers completed text before brain EOF without a timer.
- Machine sanitation does not prove that a statement is true, an action completed, or a model followed the turn rules. Guidance is not a deterministic model-behavior guarantee.

`Speakable.js::violations(text, language)` returns counts by machine-detectable kind over a final transcript window. Streaming consumers can use `counts()` on the text owner instead. Counts include numeric notation that needs spoken expansion. They contain no transcript or audio. A caller counts each final, non-overlapping window once, not each revised partial transcript.

The duplex engine sanitizes delegated commentary before append. It measures its own output transcript separately. It never holds duplex audio for transcript approval. The [review disposition](../plans/v2-jarvis-plan-review.md#13-review-dispositions) states why that delay is rejected. Provider behavior and a violation rate remain hand-check work, not evidence from these pure tests.

## Bounds

These are allocation limits, not measured latency budgets. The declarations in `Guidance.js` and `Speakable.js::limits` own their values. The owning suites exercise their boundary inputs.

| Store | Limit | Overflow |
|---|---|---|
| One guidance asset | 8192 UTF-8 bytes | Keyed error; no composition returned |
| Composed instructions | 32768 UTF-8 bytes | Keyed error; no composition returned |
| One input chunk or final transcript window | 16384 UTF-16 code units | Keyed error; stream fails |
| Pending token; uncut sentence | 4096 UTF-16 code units each | Keyed error; retained text cleared |
| Returned text per call | 65536 UTF-16 code units | Keyed error; no array returned |

Violation counters refuse a safe-integer overflow. There is no session cache, transcript store or unbounded output queue. A failed or closed stream rejects further input. An engine must report an overflow and stop that text output, not fall back to the raw brain text. The release judge still runs before text leaves the machine.

## Evidence

- `scripts/test-jarvis-guidance.js` uses class fixtures for voice, delegated frontier, delegated local, chained frontier and chained local consumers. It checks the selected files and the repeated rule against the runtime assets. This checks composition, not an AI model's obedience.
- `scripts/test-jarvis-speakable.js` tests whole chunks, individual UTF-16 units and every pair of fragments. Early-delivery cases assert push results before finish, including bounded sentences whose total exceeds the token limit. It also checks final fragments, bounds, code discard and counts.
- `scripts/test-jarvis-speech-language.js` tests the language judge and number, unit, date and time expansions.
- The suites plant defects in disposable production copies. The kept-URL control still reaches the lexer but sends the address into the spoken text. Its expected sentence turns red.
- `scripts/test-install-tree.sh` and the nested read-only prefix row run `scripts/fixtures/jarvis-voice/installed.js` against installed modules and assets with an empty environment. Each resolves the real Node executable before clearing that environment. The installer control drops the runtime markdown and fails both the manifest and consumer assertions.
- `scripts/validate` selects these suites from their direct and shared inputs. The new behavior tests run in process. No process integration exists until the engine rows land.

## Omarchy comparison

Omarchy's shell agents keep display separate from collectors. VGS keeps voice text under the daemon, not the QML service. The read-only omarchy-voice reference's `src/omarchy_voice/persona.py` uses short, action-first narration and reports returned outcomes. VGS adopts that approach.

VGS does not adopt speech as general action permission, free tool chaining, host-terminal commands or policy bypass. Its local brain takes one tool per step. A held action stops the model and the router. The existing plan and policy contracts, not the persona, own that authority.
