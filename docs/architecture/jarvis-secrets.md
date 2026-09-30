# Jarvis keys

Covers: shell/plugins/vgs.jarvis/backend/Secrets.js, shell/plugins/vgs.jarvis/backend/keys.js, shell/plugins/vgs.jarvis/tui/add-key.sh, shell/plugins/vgs.jarvis/Keys.qml, scripts/test-jarvis-secrets.js, scripts/fixtures/jarvis/keys-world.js, scripts/fixtures/jarvis/key-tui.py

The [Jarvis plan's secrets section](../plans/v2-jarvis-plan.md#39-secrets-and-accounts) owns this scope. [D035](../decisions/D035-manifest-requirements.md) owns the install notice. [D037](../decisions/D037-plugin-status.md) owns presence status. [D033](../decisions/D033-floating-tuis-are-core.md) owns the terminal presentation.

## Add key

Settings lists Add key from the manifest's TUI declaration. The core opens the floating terminal and supplies the presentation library. The script asks for provider, account label and origin. Only that metadata reaches argv. `Secrets::addKey` runs `secret-tool store` with terminal stdin and private output pipes. Libsecret's `getpass` prompt reads the key with terminal echo off. Jarvis never receives the key during storage.

`backend/keys.js` normalizes a newly entered endpoint through `net.endpoint` before constructing its reference. Storage attributes therefore match the [transport origin](jarvis-release.md#transport-contract), including numeric localhost pinning. Existing references keep their exact origins.

The [secret-tool manual](https://man.archlinux.org/man/secret-tool.1.en) defines terminal storage and attributes. Its [source](https://github.com/GNOME/libsecret/blob/master/tool/secret-tool.c), `read_password_tty`, uses `getpass`; its prompt uses the controlling terminal. A non-terminal invocation fails before storage. Add key and `remember` share one reference-update judge. Add key checks the metadata and bounds before the key prompt, then checks again when it writes. Failed storage changes no reference. If the reference write fails after storage, the keyed failure reports the write cause; the key remains in libsecret and the user can repeat Add key.

The manifest names each external command and its package. Settings can install missing requirements with the core's Install button. No setup command or plugin installer is needed.

## Reference API

`backend/Secrets.js` is the only reference and storage owner. State lives in `keys.json` under the Jarvis state directory. The file holds metadata, never secret values. Writes replace the whole file with private permissions. A missing file means no references. An unreadable, linked, oversized or malformed file fails with a safe key; it never means no accounts.

| API | Consumer and result |
|---|---|
| `ownReference(provider, account, origin)` | Add key: returns `{ provider, account, origin, attributes }`, with attributes `service vgs-jarvis`, `provider`, `account`, `origin`. |
| `reference(value)` | Every caller: judges the exact metadata shape and returns a copy. Unknown fields fail. Origin is a canonical HTTP or HTTPS origin, not a path, login URL or query. This is storage syntax, not permission to send. |
| `new Secrets(directory, env)` | The daemon's future adapters and the CLI: one explicit state root and scrubbed child environment. No inherited credential variable reaches a helper. |
| `references()` | J27's accounts picker and future adapters: returns the stored references. It opens no vendor CLI credential file and reads no key. |
| `remember(reference)` | J27's accounts picker: persists the attributes of an existing Secret Service item the user selected. It looks up no secret and copies no token. Provider, account and origin identify the row. |
| `lookup(reference)` | Future in-process wire/speech adapters: reads `secret-tool lookup` only at first need and returns a Buffer directly. There is no lookup CLI verb or secret wire message. The caller clears the Buffer after use. |
| `rows()` | The service's `Keys.qml`: returns labels, presence and safe failure keys only. |

J27 owns item discovery and its accounts TUI. An existing item's attributes can differ from Jarvis's own storage attributes. The reference still records its intended origin. J22's network door must enforce that origin before it attaches a key. A retrieved key must never enter a child, argv, file, log, status or shell wire. No provider request or origin enforcement is implemented here.

Bounds live in `Secrets.js`: references follow the core's presence-list ceiling; files, helper replies and lookup buffers are bounded. Attribute names cannot become helper flags. Helper failures report a fixed keyed cause, never raw stdout or stderr.

## Presence

`Keys.qml` owns one probe at service start and after the core reports an ended Add key run. Overlapping refreshes collapse into one pending refresh. It publishes the manifest's `keys` presence list through `shell.status.set`. A failed process or invalid result publishes Unavailable with a safe keyed diagnosis. It never forwards helper stderr.

Presence calls [Secret Service `SearchItems`](https://specifications.freedesktop.org/secret-service/0.2/org.freedesktop.Secret.Service.html) through [busctl](https://www.freedesktop.org/software/systemd/man/latest/busctl.html). Only item paths return: unlocked matches mean Present, locked matches mean Locked, no match means Absent. A missing helper, failed service or malformed reply means Unavailable. The probe disables activation and interactive authorization. It never calls Unlock, GetSecrets, `secret-tool search` or lookup.

The [Quickshell Process reference](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/Process/) defines explicit environments and completion from `runningChanged`. The [StdioCollector reference](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/StdioCollector/) defines the completed output reader.

## Evidence

- `scripts/test-jarvis-secrets.js` runs the actual module, CLI and Add key script in the [Jarvis test world](validation-jarvis.md). Every secret, bus and presentation helper is a stand-in. A private terminal fixture waits for the masked prompt before it supplies synthetic key bytes.
- [Release validation](jarvis-release-validation.md) runs that same producer against a loopback transport and removes producer normalization in its integration control.
- The suite checks attributes, origin storage, external references, deferred lookup, presence states, malformed replies, missing helpers, failed storage, metadata-only files and scrubbed environments. Invalid or full metadata must fail before any secret-tool call. It checks generated state, HOME and runtime files for the synthetic key. Lookup returns directly to the test's in-process consumer.
- Controls remove reference rules, secret-free diagnosis, the correct lookup/probe operation and the storage-output suppression. The owning assertions must fail.
- `scripts/smoke/rows/jarvis.sh` reads the real service's presence through a J09 probe. It opens only a disposable no-auth Add key script and checks recorded terminal argv. A failed whole probe must replace present rows with Unavailable. Controls retain stale rows or remove TUI-end refresh and must break those assertions. No real keyring, account or unlock is used.

## Omarchy comparison

The read-only Omarchy shell reference's notifications service has no keyring storage or secret helper. Its agents plugin keeps extraction outside QML. VGS keeps that separation. Unlike the notifications' existing `secret-tool search` probe, Jarvis uses SearchItems because search retrieves secrets even without an unlock request. The Jarvis plan requires a probe that never reads a key.
