# Jarvis Anthropic Messages

Covers: shell/plugins/vgs.jarvis/backend/AnthropicMessages.js, scripts/test-jarvis-brain-anthropic.js, scripts/fixtures/jarvis-brain/anthropic-messages*

[D079](../decisions/D079-brains-wire-and-harness-adapters.md) assigns this wire driver. It implements the [shared brain contract](jarvis-brain.md#driver-contract). Account choice, the tool bridge, session integration and image capture remain separate plan rows. No shipped daemon path creates a brain yet.

## Owners

- `Providers.js` owns the `anthropic` row. It selects `anthropic-messages` at `https://api.anthropic.com/v1`. No custom endpoint or account setting is added.
- `WireBrain.js` owns labelled history, release reports, tool-name mapping, key lookup and the request lifetime for both wire drivers. `AnthropicMessages.js` owns Messages encoding and its event judge. `Sse.js` remains the only byte stream reader.
- The driver uses the documented HTTP API rather than an SDK. No npm dependency or credential-file reader is added.

## Requests

The driver posts to `/v1/messages`. Authentication uses the origin-bound `x-api-key` record through `net.js`. The request sets `anthropic-version: 2023-06-01`. Instructions use the top-level `system` field, not a message role.

Tools use `{name, description, input_schema}`. Assistant history preserves the ordered text and `tool_use` blocks. Tool results use a following user message with `tool_result` blocks and their `tool_use_id`. The shared owner requires every pending call to receive exactly one result before a new user turn.

Images use base64 `image` blocks with `source: {type, media_type, data}`. The shared contract admits PNG and JPEG from the screen producer. It does not use image URLs, upload files or capture images. An unreleased image becomes its text marker. Every text item, image, result and history reply passes the shared release owner.

The required `max_tokens` field uses a fixed allowance of 4096. This is an output limit, not a model context-window claim. Context budgets stay with the session. A response that reaches the allowance fails rather than completing a partial tool call. Request and stream byte limits stay at the [shared bounds](jarvis-brain.md#bounds).

## Events

- `eventOf` narrows consumed fields once. Event names must match the JSON `type`. Error events fail with `brain=stream-error` without reading provider error text. Usage extensions pass unread. Ping and future event types do not change message state, as the vendor versioning policy requires.
- A message starts with empty assistant content and no stop reason. Sequential content blocks start, receive matching deltas and stop at their contiguous indices. Text deltas extend only text blocks. JSON deltas extend only `tool_use` blocks.
- Tool JSON is parsed once the block stops. A non-object input, conflicting initial input, repeated id or unoffered name fails. A block stop emits no call. Only a complete message can emit calls.
- Message deltas follow all closed blocks. A stop reason is accepted once. Cumulative usage-only deltas can follow it. `message_stop` is the explicit terminal event. EOF without it fails, including EOF after valid tool JSON.
- `end_turn` and `stop_sequence` complete a text turn. `tool_use` completes a turn with calls. A missing reason, a mismatched call count, truncation, refusal, a paused server-tool turn or an unknown reason fails. The failure key never includes an arbitrary vendor reason.
- Thinking and server-tool content are not offered by this driver. Receiving such a block fails explicitly rather than discarding content that assistant history would need.

Cancellation uses the shared request owner. The acknowledgement follows stream teardown and response closure. The next read refuses queued text and calls. Failed and cancelled turns enter no history.

## Vendor sources

The official pages below were read on 2026-10-01. The fixture excerpt records the vendor wire type commit and file hash.

| Contract | Source |
|---|---|
| Endpoint, system prompt, tools, tool results, images and output allowance | [Messages API](https://platform.claude.com/docs/en/api/messages) |
| Event ordering, partial JSON, ping, future events and terminal event | [Streaming messages](https://platform.claude.com/docs/en/build-with-claude/streaming) |
| Credential header and version | The same page's direct HTTP example |
| HTTP failure statuses and unread error bodies | [API errors](https://platform.claude.com/docs/en/api/errors) |
| Retention | [Organization data retention](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data) |

Messages has no request no-store switch. The row keeps `noStore: null`. Standard API inputs and outputs are deleted within 30 days. The vendor lists policy, legal and agreed-retention exceptions. It also lists additional review requirements for covered models. Zero retention requires an agreement, not a request field.

## Evidence

`scripts/test-jarvis-brain-anthropic.js` runs in the [Jarvis test world](validation-jarvis.md). Its loopback listener validates each request and each schema-shaped event against `anthropic-messages.schema.json`. Malformed cases explicitly bypass fixture validation, so they reach the real driver judge. The excerpt transcribes the official vendor wire interfaces to the existing schema-checker's keyword set and names every omission.

The suite checks text history, tool fragments, result continuation, output headers, image types, grants, withheld markers and retained labels. It refuses lost events, malformed JSON, event-order defects, unsupported content, failure stop reasons and HTTP failures. A missing terminal event produces no call or done. Disposable controls remove independent driver rules and must turn these assertions red.

Real loopback cancellation observes the server socket close. A leaking relay proves that observation fails if the underlying request remains open. Stand-in streams fix races a socket cannot: buffered text, a terminal read completed beside cancellation and an abort that ends later. The shared [OpenAI suite](jarvis-brain.md#evidence) also runs the moved history, release, key, bounds and lifecycle controls against `WireBrain.js`.

## Omarchy comparison

The read-only Omarchy shell's agents plugin displays usage records from vendor programs. It has no Messages client. omarchy-voice's planner sends non-streaming OpenAI requests. Its vision provider implements OpenAI-compatible streaming with byte limits, refused redirects and unread error bodies. VGS keeps those limits and refusals through the existing shared owners. Messages needs different request blocks and an explicit ordered event judge, so it has its own driver. The origin-bound libsecret key and per-item release remain VGS requirements.
