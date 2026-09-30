# Jarvis accounts

Covers: shell/plugins/vgs.jarvis/AccountProviders.js, shell/plugins/vgs.jarvis/Accounts.qml, shell/plugins/vgs.jarvis/backend/Accounts.js, shell/plugins/vgs.jarvis/backend/accounts.js, shell/plugins/vgs.jarvis/tui/accounts.sh, scripts/test-jarvis-accounts.js, scripts/test-jarvis-accounts-tui.js, scripts/fixtures/jarvis/accounts-world.js, scripts/fixtures/jarvis/accounts-tui.py

The [Jarvis plan's account section](../plans/v2-jarvis-plan.md#39-secrets-and-accounts) owns discovery and explicit verification. `backend/Accounts.js::Accounts` is the one account judge. `AccountProviders.js::PROVIDERS` is the shared provider declaration. QML reads that declaration to pass key-variable presence as booleans, never key values, into the helper.

## Discovery

Accounts checks each candidate with its vendor's documented login-status command before it tests the marker. The [Claude CLI reference](https://code.claude.com/docs/en/cli-reference) defines authentication-status JSON and its exit status. The [Codex login implementation](https://github.com/openai/codex/blob/main/codex-rs/cli/src/login.rs) defines status on stderr. Accounts keeps only recognized login state, plan and email. It clears output buffers and publishes no masked key suffix or raw helper diagnosis.

Candidate roots come from the provider declaration, the explicit vendor environment variables, HOME and the XDG config and data homes. The scan visits the plan's bounded depth and entry count. It deduplicates overlapping roots. It skips directory links. Explicit and hand-added paths also reject links in every component. The Linux descriptor walk anchors parents while it opens and enumerates them, using `O_NOFOLLOW`. The marker check uses the held directory descriptor and `lstat`, never a content reader. A missing default is normal. An unreadable directory, linked explicit root, incomplete scan or exceeded bound fails discovery instead of reporting an empty result.

User-added directories live in `accounts.json` under the Jarvis state directory. Each row stores only provider, directory and label. The file is bounded, private and replaced whole. No discovered identity or verification result is persisted. A malformed or unreadable file fails rather than discarding user additions. An existing directory can receive a new label without adding another account.

Local-server discovery reads listening-port metadata through `ss`. It makes no connection and no model-list or inference request. A listening port means Found, not Verified. Missing or failed port inspection produces Unavailable. Key-variable rows report presence only. The service supplies those booleans from its own environment. The terminal scrubs its environment before launching any child and does not transfer environment-held keys.

## Key references

[Jarvis secrets](jarvis-secrets.md) owns metadata, presence and deferred key lookup. The Accounts picker calls `Secrets::items` for public labels and attributes. It uses SearchItems and Item properties without activation, interaction, unlock or secret retrieval. Accounts excludes vendor-login and OAuth items before offering them. The user selects an eligible item by label and selects its intended provider. `Accounts::remember` rechecks the selected path and passes attributes to `Secrets::remember`. The provider declaration supplies the origin. No login token is copied.

Remembered references use the same `Secrets::presence` result as the key status reader. A locked item produces Locked. Missing and failed presence checks produce Unavailable. Discovery does not call lookup or `secret-tool search`.

## Account state and verification

Each account holds one tagged state. Vendor login status can produce Signed in but never Verified. The model also keeps identity metadata outside that state so a Verify failure does not erase the identity hint. A reported email different from a non-default directory label produces Identity mismatch.

`Accounts::verify` requires the user initiator and a selected current account id. It refuses a locked item and a concurrent Verify. While a request runs, the account holds its operation id. Refresh invalidates the discovery epoch. A late result cannot verify a replacement snapshot. Only a nonempty inference result can produce Verified; login status and model-list results cannot.

The production request port is unavailable. The terminal reports that refusal and sends no inference request. The [outbound owner](jarvis-policy.md#owners) must supply the real request through the origin-bound network door before Verify can become usable. Tests inject an inference result at that port. They do not implement a second network path.

## Settings and terminal

The manifest declares the Brain account setting, its `brains` choices and `accounts` presence status. Account ids bind provider and source metadata, not menu position. Discovery failure clears the offer list and publishes Unavailable. The core retains a configured id that is no longer offered; discovery never selects a replacement.

The manifest also lists Accounts as a [core-hosted floating TUI](tui-capability.md). The terminal adds a directory, chooses an existing keyring item, displays account metadata or asks for explicit Verify consent. The core presentation library owns its controls and colors.

`Accounts.qml` owns one metadata reader. It refreshes at service creation and after Accounts or Add key ends through `shell.tui.state`. Overlapping refreshes collapse into a pending refresh. `Keys.qml` also refreshes after Accounts stores a reference. Helpers receive explicit environments. No credential value enters helper argv, logs or status.

## Evidence

- `scripts/test-jarvis-accounts.js` runs the actual judge and CLI in the [isolated Jarvis world](validation-jarvis.md). It covers nested and hand-added roots, explicit roots, depth and count bounds, links, mode-000 markers, login hints, mismatch, key variables, local-port metadata, keyring references and safe failures.
- Marker instrumentation counts actual content-reader calls during discovery. Its production mutant adds a marker read. Permission bits alone are insufficient inside a user namespace because that namespace can grant permission-bypass capabilities.
- The same suite checks explicit Verify, unavailable production requests, inference-only proof, busy and locked refusals, stale completion and refresh discarding Verified. It mutates production guards on disposable copies. Removing a stand-in breaks its positive assertion and never reaches a host account tool.
- `scripts/test-jarvis-accounts-tui.js` runs the actual script on a private terminal. Its stand-in presentation tool selects directory and key-reference actions. The suite checks persisted metadata, explicit consent, refusal without a request port and scrubbed child environments. Mutants change the directory passed to the judge and remove the user initiator.
- `scripts/smoke/rows/jarvis.sh` adds account metadata readback, a no-auth terminal-argv fixture, TUI-end refresh and failed-discovery clearing. Controls keep stale account rows or remove the Accounts and Keys end refresh. Those nested rows require the final smoke run for execution evidence.

## Omarchy comparison

The current Omarchy default branch's agents display delegates extraction to its account collectors. VGS also keeps extraction outside QML. Omarchy's Claude collector reads `.credentials.json` for usage access; its Codex collector reads session files and uses app-server RPC. VGS instead uses vendor login-status commands and bounded metadata discovery. It opens no marker or credential content and requires explicit inference verification. The plan forbids importing those collector credential reads.
