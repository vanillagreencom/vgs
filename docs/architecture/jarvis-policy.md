# Jarvis action policy

Covers: shell/plugins/vgs.jarvis/backend/Policy.js, shell/plugins/vgs.jarvis/backend/Tools.js, shell/plugins/vgs.jarvis/backend/Denied.js, scripts/test-jarvis-policy.js, scripts/test-jarvis-tools.js, scripts/test-jarvis-denied.js, scripts/fixtures/jarvis/policy.js

[Input facts](input-facts.md) defines the fresh core target and key observations. [Jarvis input](jarvis-input.md) defines their policy and transport consumer.

[D070](../decisions/D070-jarvis-action-policy.md) records the action boundary. The [Jarvis plan § Policy](../plans/v2-jarvis-plan.md#37-policy-authority-effects-approval-audit) defines its authority. This code judges calls but executes none. The daemon registers the [desktop executors](jarvis-desktop-tools.md) and setup-verified [browser executor](jarvis-browser.md), and no brain calls them yet. It exposes no account, capture or network connection.

## Owners

- `Policy.js::decide` is the one action judge. `Tools.js::refine` narrows model calls. `Denied.js::create` owns filesystem protection.
- [The router](jarvis-approval.md) owns the immutable call snapshot, conversation grants, serial execution and approval binding. It offers only registered, command-ready tools. Executor owners must prove confinement before registration. `Tools.TABLE` is a reserved contract, not an offer list.
- Session owns turn lifetime. The router calls `Policy.observe` after content reaches that turn, not when a read starts or fails. A new turn starts clean. Existing taint never becomes clean.
- [The audit writer](jarvis-audit.md) owns redaction and persistence before execution. The router consumes its fail-closed boundary. A policy answer alone does not satisfy that requirement.
- `Policy.release` owns outbound consent separately from the action decision. [Jarvis release](jarvis-release.md) defines its immutable recipient set and the network door. An `external` action still needs both decisions.
- [Kernel confinement](jarvis-sandbox.md) consumes the protected snapshot. A shell line is a program, not a string the policy can prove safe. Shell argv wrappers remain `exec`. Direct elevation argv is refused, but that check cannot confine a program that starts another program.
- J27 supplies all discovered and hand-added account roots. The filesystem judge protects those roots in addition to its built-in credential roots. It opens no credential, marker or profile content.

## Call contract

`Tools.refine({ id, args })` returns `{ kind: "call", call, effect, executor, command, paths, input, source }` or `{ kind: "refuse", reason }`. `call` is a copied snapshot. Extra or missing required keys and invalid argument types refuse. Optional task account and agent selections do not grant authority.

`Tools.TABLE` holds closed JSON Schema object descriptors, typed sentence templates, effects, executor ids and required commands. `Tools.BROWSER` holds the browser subcommands. They are frozen data. Refined call snapshots are frozen too. The table supports the schema types it declares, not an arbitrary schema supplied by a model. The [tool bridge](jarvis-bridge.md#calls-and-results) offers these same descriptors as each tool's `inputSchema` instead of writing a second schema.

Browser arguments are named fields, not vendor argv. Unknown commands and extra flags refuse. Action references use snapshot element ids, not flags or arbitrary selectors. URLs admit HTTP and HTTPS without userinfo. This prevents a caller from selecting a host browser profile or passing browser security overrides. [The browser owner](jarvis-browser.md) supplies the private session and vendor action policy.

The exact read-only argv table belongs to `Tools.js`. Extra options, an absolute executable path, wrappers and shell lines do not inherit that classification. Requested command networking makes the effect `external`. J49 must use fixed system implementations, never a caller-controlled PATH substitute, for those read-only argv. J23 must confine even a read-only command.

## Trusted context

`Policy.decide(call, context)` returns `{ kind: "allow", effect }`, `{ kind: "confirm", effect, physical, scope? }` or `{ kind: "refuse", reason }`. J19 matches `kind`. An unknown kind is an internal failure, never permission.

| Context field | Producer and meaning |
|---|---|
| `profile` | Service settings, validated by their owner. The profile table lives in `Policy.js`. An unknown profile refuses. |
| `locked` | Current service observation of the core session capability. Only literal `false` permits a decision. Missing state refuses. |
| `taint` | Router's value keyed to Session's turn: `{ kind: "clean" }` or `{ kind: "tainted" }`. Missing or invalid taint refuses. |
| `denied` | Current `Denied.create` result. Every path-bearing call requires it. |
| `input.target` | J47 or J51's send-time observation: `{ kind, id, password? }`. Kinds are application, terminal, site, VGS, lock and polkit. The code uses lower-case ids for these kinds. Unknown targets or empty identities refuse. |
| `input.key` | J47's `{ request, chord, effective, emitted, emittedEffective }`. `request` must equal the call's chord. Native identities use the active device map. Emitted code and effective bind identities use the independent global group-zero translation map. Each is `{ modifiers, keycode }`; Policy alone matches and refuses own chords. Unknown physical modifiers can add to the requested mask, so a possible matching superset also refuses. |
| `input.text` | J47's `{ effective }` joins native and global identities. Each includes `{ modifiers, keycode, codepoint }`. Policy matches wtype's generated raw codes and Unicode characters against possible held-modifier combinations. Any chord with no modifiers also refuses text. |
| `grants` | J19's conversation-local list of application or site scope ids. It is required when the standard input rule needs a grant. A missing list refuses. |

The model produces only the call. It cannot supply this context. Key parsing remains with the core key judge. J47 must then resolve both keysyms and keycodes to the same physical identity. An unresolved key or effective binding refuses. Jarvis declares [Talk, Mute and Stop](jarvis-controls.md) through the existing core shortcut capability. The policy adds no key parser or input executor; J47 owns them.

A grant scope is `application:<id>` or `site:<id>`. Standard input without a matching grant returns that scope for J19's user prompt. Another application or site does not inherit it. Cautious input confirms each call. Tainted input requires confirmation even with a grant. A terminal has no grant scope.

VGS, lock and polkit targets refuse in every profile before the profile table applies. Browser input also requires a known non-password target. A key that can equal an effective Jarvis chord refuses, independent of modifier order or key spelling. A physical modifier already held can complete that chord. Text uses the distinct Unicode characters in the actual UTF-8 transport, including newline's Return mapping. It refuses any generated raw code or character that can activate an own bind.

Terminal keys, clicks and scrolling refuse as `terminal-input` in every profile, including with taint or a supplied grant. They can enter or paste a command without showing its text. Terminal text refuses in cautious and standard. Trusted terminal text becomes a physical, destructive hold. J19 must show the exact typed text. Taint cannot turn that hold into voice approval.

## Real paths

`Denied.create({ home, config, data, state, runtime, install, accountRoots })` takes absolute trusted roots. HOME must exist as a directory. `accountRoots` must be a list, including an empty list before account discovery exists. Failed root resolution fails construction.

Its `inspect(path, role)` returns `{ kind: "path", path, exists, execution }` or `{ kind: "refuse", reason, error? }`. The tool table owns path roles. Callers do not select them. Resolution uses filesystem metadata only.

Its frozen `masks` list contains the configured and resolved protected roots. J23 consumes that list for its filesystem masks, including roots that do not yet exist. It must not maintain another credential inventory.

- Existing links resolve before an absent write suffix is appended. A dangling link, loop, unreadable component or non-directory parent refuses as `path-resolution`. Only `ENOENT` means absence.
- Resolution processes `..` after the preceding link. It refuses `..` after an absent component rather than guessing what a future directory means.
- Containment checks path components, not string prefixes. A sibling whose name starts with a protected root's name is not that root.
- Credential, browser, VGS and supplied account roots protect both their configured paths and their resolved aliases. Reads and writes inside them refuse as `protected-path`.
- A move, removal, writable workspace or recursive search that contains a protected root also refuses. A one-level directory list may return names. J48 must judge each child before opening it and must not turn a list into an unchecked recursive read.
- Other file paths must remain inside the physical HOME. Link escapes refuse as `outside-home`.
- Writes, moves, removals and writable workspaces that intersect an execution root are destructive. Reads alone are not. The execution-root declaration lives in `Denied.js`.
- A file write or move destination that already exists is destructive. An absent ordinary write stays persistent. A move to an absent ordinary destination stays persistent.

The answer describes a filesystem snapshot. It is not a file descriptor or race-proof permission. J19 and the executor must rejudge paths and targets immediately before execution. J48 must enforce containment while opening children. J23 must mask the same protected roots inside its kernel sandbox.

## Taint

`Policy.observe(taint, source)` returns the next tagged taint value. Unknown sources refuse with a keyed error. Tool output source labels come from the tool table, not model prose. File, web, screen and agent content taint the turn.

Taint raises persistent, exec, input and external actions to confirmation. It leaves read and reversible decisions unchanged. Physical destructive holds apply before that upgrade. Taint never weakens them.

## Evidence

- `scripts/test-jarvis-tools.js` exercises every declared call and browser subcommand. It pins independent input-routing contracts and checks schema refusals, exact argv refinement and networking. Mutations break tool effects, input routing and independent schema rules.
- `scripts/test-jarvis-denied.js` uses real scratch paths, links, absent targets and account aliases. It removes each protected-root and execution-root entry separately. It also breaks resolution, component containment and ancestor protection.
- `scripts/test-jarvis-policy.js` checks the complete profile matrix, matching and nonmatching grants, protected targets, own chords, terminal input and taint. Browser click, fill and submit cases refuse protected and password targets in every profile. Routing-removal mutants retain each call's schema and effect but skip those refusals. Each profile cell and independent guard has a planted behavior defect.
- The suites run inside the [J09 world](validation-jarvis.md). No real credential, authentication, desktop, audio device or network enters them. `scripts/validate` owns their input selection.
