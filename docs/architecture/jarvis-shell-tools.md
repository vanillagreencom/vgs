# Jarvis shell tools

Covers: shell/plugins/vgs.jarvis/backend/Shell.js, shell/plugins/vgs.jarvis/backend/skills/computer/, scripts/test-jarvis-shell.js

The [router](jarvis-approval.md) owns admission, approval, audit and command-labelled results. `Shell.js` translates its immutable shell call into the [kernel owner's](jarvis-sandbox.md) request. [D074](../decisions/D074-jarvis-kernel-sandbox.md) owns confinement. The daemon still has no conversation engine, so no brain calls these tools yet.

## Owners

- `Shell.roots` reuses `Accounts.candidates` for metadata-only account directories. It runs no vendor authentication command. Policy and Sandbox consume the same trusted producer. Each call rebuilds the protected snapshot, including hand-added and newly discovered account roots. A failed discovery provides no path authority.
- `Shell.install` publishes checking, then registers the sandbox executor only after protected-root construction and the real kernel probe succeed. A missing command, unsupported kernel setup or failed protected-root discovery leaves both shell offers absent. `ToolRouter.route` refuses an unregistered executor. No unsandboxed fallback exists.
- `Shell.close` aborts readiness and the active serial call. Late readiness cannot register tools or publish status. The kernel owner ends the namespace, including detached descendants. The adapter holds no second child or command timer.
- `Sandbox.BOUNDS` supplies the router's action deadline. The kernel owner also holds the combined output ceiling. These are allocation and recovery bounds, not measured latency budgets. The [plan's bounds](../plans/v2-jarvis-plan.md#311-bounds) and kernel declarations own the values.
- A shell line becomes the fixed `/bin/sh -c` argv with the exact original text. Its working directory and network choice stay bound to the approved snapshot. The tool table owns read-only classification. The sandbox's fixed system PATH resolves those commands, never the caller's PATH.
- The adapter matches every kernel result kind. Only an exited command with code zero completes. Nonzero exits, refusals, unavailable setup and errors fail. Cancellation, timeout and output overflow remain unknown outcomes. The result begins with its JSON status before stdout and stderr, so router clipping keeps the outcome and cause.

## Status and reference

`shell-status` carries the kernel availability to the service through the judged wire. The service publishes the manifest's Shell tools state and clears it when the daemon ends. Only a missing Bubblewrap binary offers the core's Install Bubblewrap action. The requirement declaration owns its package mappings. A namespace or path failure remains unavailable and names its cause.

`help(shell)` reads the installed computer reference through `Guidance.help`. The tool table owns topic names. The guidance owner bounds asset reads and reports absent, empty, malformed or oversized files. Help remains registered when confinement is unavailable. Missing tool families fail explicitly. The installer preserves computer guidance as runtime data, including in read-only installations.

## Evidence

`scripts/test-jarvis-shell.js` runs the real adapter, router, reducer, policy, audit and Bubblewrap in [the private Jarvis world](validation-jarvis.md). The shared forbidden list reaches the actual router in every policy profile. Its protected-file cases then reach the kernel through the actual shell tool. The suite reads the kernel privilege bit and absent desktop, audio and input access without invoking authentication or a real device. It checks read-only argv, exact shell text, account masks, command labels, exit codes, timeout, combined output bounds, router clipping, cancellation and detached-descendant cleanup. A failed kernel probe reports exit 77, not a pass.

Disposable controls remove registration, unavailable refusal, line translation, outcome mapping, cancellation, lease teardown and kernel timeout or output enforcement. Each must break its owning behavioral assertion. The protocol suite removes each availability-wire rule. The nested Jarvis row reads readiness through the real service and removes its publication as a control. Installation controls retain the runtime reference in their manifest and consumer checks.

## Omarchy comparison

Omarchy's shell agents plugin keeps display separate from argv-based workers. Its panel launches user agent programs and has no model shell executor. VGS uses the same separation. Model commands additionally need the existing D074 kernel boundary because those commands can start descendants. The [kernel comparison](jarvis-sandbox.md) records the controls taken from omarchy-voice.

The adapter's cancellation uses the [Node AbortController interface](https://github.com/nodejs/node/blob/v22.20.0/doc/api/globals.md#class-abortcontroller). The service reads explicit account-root environment values through [Quickshell.env](https://quickshell.org/docs/v0.3.1/types/Quickshell/Quickshell/#function.env).
