# Jarvis wire brain

Covers: shell/plugins/vgs.jarvis/backend/OpenAIChat.js, shell/plugins/vgs.jarvis/backend/Providers.js, shell/plugins/vgs.jarvis/backend/Sse.js, scripts/test-jarvis-brain-openai.js, scripts/test-jarvis-providers.js, scripts/test-jarvis-sse.js, scripts/test-schema-check.js, scripts/fixtures/schema-check.js, scripts/fixtures/jarvis-brain/

[D079](../decisions/D079-brains-wire-and-harness-adapters.md) records the brain adapter kinds. [The plan § Brain adapters](../plans/v2-jarvis-plan.md#36-brain-adapters) fixes the interface. This page defines the OpenAI-compatible wire driver, its provider table and the event stream reader later wire adapters reuse. The daemon still supplies unavailable session ports: no shipped path creates a driver yet.

## Owners

- `Providers.js` is the one provider table. A row names its driver, base URL, key need, image input, no-store request fields and retention note. `select(id, customBaseUrl)` returns a frozen row; `assertRow` accepts only those rows. The custom row reads the brain settings' `customBaseUrl`; every other row ignores it.
- `Sse.js::reader` parses the [WHATWG event stream format](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation) from bytes. It owns no transport or timer. Its caller chooses the line, event and total byte ceilings.
- `OpenAIChat.js::create` owns one conversation's provider-format history, its looked-up key and its live request. The session owns the [net owner, recipient set and grants](jarvis-release.md#owners). The driver sends only through that net owner.
- The session's turn loop (J33) connects the driver to the [session ports](jarvis-session.md) and owns context bounds and summaries. Account choice and the `brains` and `models` choices status belong to J27. The driver publishes no model list. J19 owns grants and the approval prompt. J50 owns OCR text for a brain without image input.

## Driver contract

| API | Meaning |
|---|---|
| `create({provider, model, net, recipients, key})` | `provider` is a `Providers.select` row. `net` is the session's `net.create` owner for `recipients`. `key` is `null` or `{secrets, reference}`, a `Secrets` store and the account's key reference. A cloud row refuses `null` with `brain=no-key`. A key that requests to the row's base could never carry, by `net.assertKeyTarget`, refuses here before any keyring lookup. |
| `start({instructions, tools})` | Begins a new history. `instructions` is the shipped guidance text, sent as the system message. A tool is `{id, description, parameters}`. A tool id's dots become underscores on the wire, because `FunctionObject.name` allows letters, digits, underscores and dashes only. A name outside that set, or two ids with one wire name, refuse. |
| `send(turn, grants?)` | Renders the whole request at once and returns `{release: {withheld, needed}, events}`. Nothing leaves until the caller iterates `events`. A caller can ask for a grant and call `events.return()` instead. |
| turn | `{kind: "user", items, images?}`, with Policy items and images `{type, item}` of type PNG or JPEG; or `{kind: "tool-results", results: [{id, item}]}`, answering every pending call once. |
| `events` | Yields `{kind: "text", text}` as the stream arrives, then each assembled `{kind: "tool-call", id, tool, arguments}`, then one `{kind: "done", reason}` with reason `stop` or `tool-calls`. Every other ending throws a keyed error. |
| `cancel()` | Aborts the live request. It resolves after the request's stream has ended and the net owner's response is closed. The next read then throws `brain=cancelled`; text queued before the acknowledgement never reaches the caller. An unstarted turn is cancelled without a request. |
| `close()` | Cancels the live request, zeroes the looked-up key and refuses further use. |

A turn and its reply enter history together when the caller reads `done`. A failed or cancelled turn changes no history. A turn stays live until its caller reads `done` or the error, or cancels it. One turn is live at a time; a second `send` or `start` refuses `brain=busy`.

The key is looked up through `Secrets.lookup` at the first request and kept for the conversation. Net receives it as the [origin-bound key](jarvis-release.md#transport-contract) with the bearer scheme the pinned schema names. The header copies JavaScript makes cannot be zeroed; they are unreachable after each request. The key never enters argv, a log, status or an error.

## Release

Every history item passes `Policy.release` against the conversation's recipient set on every request. An asked or withheld item travels as its marker. An image becomes a text part with its marker. `release.needed` and `release.withheld` name the labels the session and approval owners act on.

The request item that reaches net carries only the labels of content the request includes. A reply carries the labels of the content its request sent. Grants only grow within a conversation, so a reply stays sendable; a later request without its grant refuses `brain=history-release`. A request that includes no released content still returns its release report, so the approval owner can ask for the grant. Iterating it refuses `brain=release-empty` without a request.

## Stream

The driver posts `{model, messages, stream: true, tools?}` plus the row's no-store fields to `base + "/chat/completions"`. Text-only user content is one string; content with an image is a list of text and `image_url` parts with a base64 data URL.

- A reply other than 200 fails with the status's key from the operation's documented error statuses, or `http`, and the status code. The driver cancels the body unread, because provider error text can echo content or credentials. A 200 reply must be `text/event-stream`.
- `chunkOf` is the one narrowing door for a data frame. A frame with an `error` field is the documented mid-stream failure. Fields the driver does not read, such as usage, pass unread.
- Tool-call fragments are assembled by index. The first fragment of a call carries its id and name; later fragments extend its arguments. A gap, a nameless start, a conflicting id or name, a repeated id, an unknown name or arguments that are not a JSON object fail the turn. No call is yielded until the stream completes, so a lost chunk never yields a partial call.
- `finish_reason` `stop` ends a turn without calls; `tool_calls`, or `stop` with assembled calls, ends a tool-call turn. Gemini's compatible endpoint ends tool-call turns with `stop`, as [niki914/zafiro#256](https://github.com/niki914/zafiro/issues/256) shows against that endpoint; Google's page does not state the finish reason. Assembly has already refused a lost chunk, so the calls decide the ending for every row. `tool_calls` without a call, `length`, `content_filter` and `function_call` fail with their reason. A choice after the finish, a non-empty refusal, a stream that ends without `data: [DONE]` and `[DONE]` without a finish all fail.

## Bounds

| What | Ceiling | Why |
|---|---|---|
| An event stream line | 1 MiB | One line holds one chunk; a local server sends a whole tool call in one chunk |
| An event's data | 1 MiB | The same chunk, split across data lines |
| One response | 8 MiB | Bounds the reply text history keeps |
| A request body | 20 MiB | The lowest documented request ceiling among the rows: Groq, with an image |
| Tools | 64 | The tool table holds fewer; the bound is the offer list's buffer |
| Tool calls in one reply | 16 | Each index holds an arguments buffer |

## Providers

Each row's base URL, image input and retention come from its vendor's page, fetched 2026-09-30. The bearer scheme is the pinned schema's `ApiKeyAuth`; every row uses it.

| Row | Base URL | Key | Images | No-store fields | Retention source |
|---|---|---|---|---|---|
| `openai` | `https://api.openai.com/v1`, the schema's server | required | [vision guide](https://developers.openai.com/api/docs/guides/images-vision) | `store: false`, the schema's default sent explicitly | [your data](https://developers.openai.com/api/docs/guides/your-data) |
| `openrouter` | [API reference](https://openrouter.ai/docs/api/reference/overview) | required | the same page | `provider.data_collection: "deny"` ([provider selection](https://openrouter.ai/docs/guides/routing/provider-selection)) | [data collection](https://openrouter.ai/docs/guides/privacy/data-collection) |
| `groq` | [OpenAI compatibility](https://console.groq.com/docs/openai) | required | [vision](https://console.groq.com/docs/vision) | none; zero retention is an account setting | [your data](https://console.groq.com/docs/your-data) |
| `cerebras` | [OpenAI compatibility](https://inference-docs.cerebras.ai/resources/openai) | required | the same page: PNG or JPEG data URIs | none | [privacy policy](https://www.cerebras.ai/privacy-policy) |
| `mistral` | [API](https://docs.mistral.ai/api/) | required | [vision](https://docs.mistral.ai/studio/conversations/vision) | none; zero retention is an account setting | [privacy policy](https://legal.mistral.ai/terms/privacy-policy/) |
| `gemini` | [OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai) | required | the same page | none | [terms](https://ai.google.dev/gemini-api/terms) |
| `ollama` | `127.0.0.1:11434/v1` ([compatibility](https://github.com/ollama/ollama/blob/1abe35e6e6e777e858bbfbba283667ee8d516801/docs/api/openai-compatibility.mdx)) | optional | base64 only, the same page | none | loopback |
| `llama-server` | `127.0.0.1:8080/v1` ([server](https://github.com/ggml-org/llama.cpp/blob/0c1e57098bba43ac29e6e3b677cdceebdd22334f/tools/server/README.md)) | optional, `--api-key` | with a projector, the same page | none | loopback |
| `lmstudio` | `127.0.0.1:1234/v1` ([compatibility](https://lmstudio.ai/docs/developer/openai-compat)) | optional ([authentication](https://lmstudio.ai/docs/developer/core/authentication)) | the same page | none | loopback |
| `custom` | the `customBaseUrl` setting | optional | no | none | the server's operator |

- Local servers use the numeric loopback address that `net.endpoint` pins for `localhost`.
- A custom base URL is HTTP or HTTPS without credentials, a query or a fragment. No documentation states a custom server's image input, so its images take J50's OCR route. A key on a plaintext non-loopback base is refused by net.
- xAI marks Chat Completions deprecated ([plan research § 2.4](../plans/v2-jarvis-plan-research.md#24-inference-what-may-run-on-a-subscription)), so it has no row.
- The retention text in each row is what a future Settings page shows. OpenAI's API data is not used for training, and abuse logs stay up to 30 days. OpenRouter stores no prompts unless the account opts in. Groq retains none by default and logs up to 30 days for reliability or abuse. Cerebras retains no inference inputs or outputs. Mistral keeps 30 rolling days for abuse monitoring. Gemini's paid tier logs for a limited period for abuse; its unpaid quota is used to improve products.

## Evidence

- `scripts/test-jarvis-brain-openai.js` runs in the [Jarvis test world](validation-jarvis.md). Loopback servers replay `scripts/fixtures/jarvis-brain/openai-chat-scripts.json`. Each frame is validated against the pinned excerpt before it is sent, and each request body is validated when it arrives. The excerpt names its source commit, file hash and the rules that cut it from OpenAI's published OpenAPI document.
- It covers streamed text, a tool call split across chunks, the tool result round trip, history, images and their refusals, release markers and grants, the fixture key reaching only its origin, every documented error status without its body, a status outside that list, a mid-stream reset, every finish reason, malformed frames, the stream and request bounds, and the local rows on their default ports in the private network.
- Cancellation is read at the loopback server: the server sees the connection close. A harness defect that keeps the real request open while the driver acknowledges must turn that observation red. Stand-in bodies fix orders a socket cannot: a read that resolves in the same turn as cancel, a stream that ends a timer after its abort, and text one read buffered before cancel or close.
- Each bound has an accepted row at the bound and a refused row past it, so raising or lowering a ceiling fails.
- Cloud origins cannot be served on loopback, so their requests reach a recording net stand-in. It pins each documented URL, the bearer key and the no-store fields.
- Its disposable mutants remove each rule, including the plan's control: a dropped tool-call chunk must not yield a call.
- `scripts/test-jarvis-sse.js` runs every row whole and byte by byte, with controls for terminators, the first-line byte order mark, decoding and each bound. `scripts/test-jarvis-providers.js` pins the rows and the custom base URL judge. `scripts/test-schema-check.js` pins the checker's keyword table and refuses a keyword it does not implement.

## Omarchy comparison

The read-only Omarchy shell has no model client; its agents plugin runs vendor programs and reads their usage collectors. omarchy-voice's `planner.py` posts non-streaming Chat Completions to OpenAI only, with a key from an environment file, and puts 400 characters of the provider's error body into its error. Its `vision_provider.py` reads Chat Completions or Responses streams with a total size limit, refuses redirects, fails a finish other than `stop` and keeps provider error bodies out of its errors. VGS takes the redirect refusal, the size limit, the strict finish and the unread error body. It differs: keys come from libsecret through the origin-bound door, one table serves ten providers, tool calls stream and assemble by index, and every context item passes the release gate.
