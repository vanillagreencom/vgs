# Jarvis release and network

Covers: shell/plugins/vgs.jarvis/backend/Policy.js, shell/plugins/vgs.jarvis/backend/net.js, scripts/test-jarvis-release.js, scripts/test-jarvis-net.js, scripts/fixtures/jarvis/policy.js

[D073](../decisions/D073-jarvis-release-and-origin-bound-keys.md) records the outbound boundary. [The plan § Release gate](../plans/v2-jarvis-plan.md#38-release-gate-what-leaves-the-machine) fixes the label rules. The skeleton daemon starts no transport. This interface does not implement an adapter, account store, approval prompt, audit writer or conversation lifecycle.

## Owners

- `Policy.item` snapshots labelled text or bytes. Its source inventory is the same inventory that `Policy.observe` uses. Tool producers use `Tools.refine(...).source`, not a model-supplied label.
- `Policy.summary` retains the union of all contributing labels. The session keeps those labels for the conversation, including across repeated summaries.
- `Policy.recipients` copies and freezes the whole brain and speech set. `Policy.release` judges that set, not just the adapter's destination.
- `net.create` owns transport handles for that immutable set. The session closes it when the conversation ends. The daemon and adapters must use this door rather than create their own sockets.
- J11 owns ending the conversation, clearing context and closing the old transport when provider, account or policy changes. J19 owns user grants. J21 owns recording each release before transfer. Those integrations are not present in the skeleton.
- A harness brain still needs release consent for its cloud provider. Its vendor owns its sockets. The harness integration must enforce that handoff boundary; `net.js` does not intercept another program's networking.

## Recipient and item contract

| Value | Producer and consumer |
|---|---|
| `Policy.item(content, labels)` | Speech, context and tool producers supply a string or byte array and source labels. The summarizer and adapters consume the snapshot. |
| `Policy.summary(content, items)` | The session supplies the summary and every contributing item. The resulting item keeps all source labels. An empty contributor list refuses. |
| `Policy.recipients({conversation, profile, cloudVision, brain, speech})` | The session supplies a non-empty conversation identity, current policy settings, one brain and a non-empty speech list. Local speech is an explicit local entry. |
| Recipient `{kind, provider, account, origin?}` | Account and adapter owners supply provider and account strings. `kind` is `local` or `network`. Only network entries have an origin. They use `net.endpoint(url).origin`, including its non-default port. WebSocket entries use their HTTP handshake origin. |
| Grant `{recipients, labels}` | The approval owner supplies a reference to the exact frozen recipient set and its approved labels. A grant from any other set has no effect, even when its provider names match. |
| `Policy.release(item, recipients, grants?)` | The transport or context assembler supplies the whole current set. `send` contains a copied payload. `ask` and `withhold` contain only a marker. All answers retain every label. `ask.needed` names the labels that require a grant. No original content survives in non-send answers. |

The release judge derives offline state from the full set. Loopback and local recipients need no cloud grant. Provider selection covers only speech and desktop content for remote recipients. The other labels follow the plan's profile rules. Screen content, including OCR text, follows `cloudVision` in every profile.

An adapter receives a marker rather than withheld data. It encodes that marker into its provider's request format. The session retains the contributing labels separately. It must not relabel an original or summary as speech to evade consent. The gate cannot discover missing source labels from arbitrary bytes.

Changing a provider, account or policy creates a new recipient set. Old grants fail against it. This identity rule does not end a session by itself. J11 must close the old owner and remove the old context before it starts the replacement.

## Transport contract

| API | Meaning |
|---|---|
| `net.endpoint(url)` | Parses HTTP, HTTPS, WS or WSS without credentials or fragments. Returns the canonical handshake origin and loopback classification. |
| `net.create(recipients)` | Accepts only a set issued by `Policy.recipients`. Holds the lifetime of HTTP requests and WebSocket channels. |
| `owner.request(item, options, grants?)` | Options are `{url, method?, headers?, key?, signal?}`. It returns a native Response in `{kind:"response", response, close}` or the non-send release answer. The default method is POST. GET and HEAD require empty content. The adapter calls `close` after consuming or cancelling the response. |
| `owner.websocket(item, options, grants?)` | Options are `{url, headers?, key?}`. The item covers connection metadata. This operation sends no application frame. It returns `{kind:"channel", events, readyState, send, close}` or the non-send release answer. |
| `channel.send(item, grants?)` | Judges every application frame against the whole set before writing bytes. An ask or withhold writes nothing. |
| `channel.events` | A separate EventTarget publishes open, message, error and close. Message events contain only received data. Neither event targets nor channel properties expose the native WebSocket. |
| `owner.close()` | Refuses further transfers and aborts owned HTTP streams and WebSocket channels. The session calls it before dropping an old set. |
| Key `{origin, header, prefix, value}` | The secret owner supplies the exact stored canonical origin and the in-memory secret. The adapter supplies the provider's credential header and prefix. Header choices live in `net.js::headers`. Keys require HTTPS outside loopback. |

The door attaches a key only when the stored origin equals the request's origin. A different scheme, host or port refuses before connection. Adapter metadata cannot carry a credential header or change the Host header. `net.js::headers` owns the accepted metadata names.

The door refuses every HTTP redirect. Node's WebSocket handshake also refuses redirects. No redirected request forwards credentials or content. An adapter must select an endpoint rather than depend on a redirect.

Only selected network origins can receive a connection. Thus a fully offline set has no route to a non-loopback socket. Numeric loopback addresses need no DNS lookup. The door normalizes `localhost` to the IPv4 loopback address before selection or key storage. A key stored for the text origin `localhost` refuses rather than crossing to that numeric origin. The account owner uses the endpoint judge when storing the origin. A name that merely starts with a loopback address is not loopback.

Response parsing, provider errors, stream limits, deadlines and audio queue bounds belong to adapters and their session. Transport errors name their operation without including a URL, header or secret. The door opens no key store and passes no key to a child.

## Node contract

The [Node URL reference](https://github.com/nodejs/node/blob/v22.20.0/doc/api/url.md) defines canonical origins. The [bundled WebSocket interface](https://github.com/nodejs/node/blob/v22.0.0/deps/undici/src/types/websocket.d.ts) declares `WebSocketInit.headers`. Its [handshake implementation](https://github.com/nodejs/node/blob/v22.0.0/deps/undici/src/lib/web/websocket/connection.js) uses HTTP or HTTPS origins and `redirect: "error"`. The [WebSocket API](https://github.com/nodejs/node/blob/v22.20.0/deps/undici/src/docs/docs/api/WebSocket.md) documents its options object. This door uses the global Node WebSocket, not an npm SDK or a browser WebSocket.

## Evidence

- `scripts/test-jarvis-release.js` runs the complete label, profile, vision, recipient and grant table. It checks nested summaries, buffer snapshots, markers, immutable recipients and expired grant identities. Its controls remove each independent release rule.
- `scripts/test-jarvis-net.js` uses real HTTP and WebSocket traffic in the [Jarvis test world](validation-jarvis.md). Two origins test key isolation. Redirects test that no second request starts. A socket-creator observer proves that offline refusal occurs before a socket attempt.
- The transport suite tests grants before connection and before frames, safe event targets, localhost pinning, URL refusals, credential metadata, cancellation and owner closure. Its controls mutate disposable code copies, not the installed tree.
- `scripts/validate` selects both suites for their direct and shared inputs. `scripts/test-validate.sh` pins the selection. `packaging/install-tree.manifest` includes the installed network door.

## Omarchy comparison

The read-only Omarchy shell's agents plugin reads usage records from collectors. Its `omarchy-agent-usage-claude` and `omarchy-agent-usage-fireworks` collectors attach credentials to fixed API requests. VGS keeps network work outside QML. It does not copy their credential-file readers or automatic urllib redirects. Jarvis sends conversation content and supports custom providers, so it needs explicit release consent and exact origin-bound keys.
