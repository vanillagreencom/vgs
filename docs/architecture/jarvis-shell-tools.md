# Jarvis shell tools

Covers: shell/plugins/vgs.jarvis/backend/Shell.js, shell/plugins/vgs.jarvis/backend/skills/computer/, scripts/test-jarvis-shell.js

The [router](jarvis-approval.md) owns admission, approval, audit and command-labelled results. `Shell.js` translates its immutable shell call into the [kernel owner's](jarvis-sandbox.md) request. [D074](../decisions/D074-jarvis-kernel-sandbox.md) owns confinement. The [chained engine](jarvis-engine.md) routes calls through this same owner.

## Owners

- The daemon's `trustedRoots` supplies the same facts to its `denied()` judge and Shell. `Accounts.accountRoots` supplies explicit and hand-added account directories without vendor authentication. Denied owns rule-named account folders. Each call rebuilds its protected snapshot. A failed discovery provides no path authority.
- `Shell.install` publishes checking, then registers the sandbox executor once after protected-root construction and the real kernel probe succeed. `Shell.refresh` aborts the prior probe, rebuilds protected roots and repeats the kernel probe. Checking and unavailable states withdraw both shell offers. The router checks current readiness at offer, route and start, including after a held approval. A missing command, unsupported kernel setup or failed protected-root discovery cannot start a shell action. No unsandboxed fallback exists.
- `Shell.close` aborts readiness and the active serial call. Late readiness cannot register tools or publish status. The kernel owner ends the namespace, including detached descendants. The adapter holds no second child or command timer.
- `Sandbox.BOUNDS` supplies the router's action deadline. The kernel owner also holds the combined output ceiling. These are allocation and recovery bounds, not measured latency budgets. The [plan's bounds](../plans/v2-jarvis-plan.md#311-bounds) and kernel declarations own the values.
- A shell line becomes the fixed `/bin/sh -c` argv with the exact original text. Its working directory and network choice stay bound to the approved snapshot. The tool table owns read-only classification. The sandbox's fixed system PATH resolves those commands, never the caller's PATH.
- The adapter matches every kernel result kind. Only an exited command with code zero completes. Nonzero exits, refusals, unavailable setup and errors fail. Cancellation, timeout and output overflow remain unknown outcomes. The result begins with its JSON status before stdout and stderr, so router clipping keeps the outcome and cause.

## Status and reference

`shell-status` carries the kernel availability to the service through the judged wire. The service publishes the manifest's Shell tools state and clears it when the daemon ends. It observes the core's `requirements.revision` and sends a judged `requirements-scan` frame to the same readiness owner. A completed installation can therefore recover readiness without a source change or service restart. The daemon ignores duplicate and older scan counters. Superseded probes cannot publish late results. Only a missing Bubblewrap binary offers the core's Install Bubblewrap action. The requirement declaration owns its package mappings. A namespace or path failure remains unavailable and names its cause.

`help(shell)` reads the installed computer reference through `ComputerHelp`. The tool table owns topic names. The guidance owner bounds asset reads and reports absent, empty, malformed or oversized files. Help remains registered when confinement is unavailable. Missing tool families fail explicitly. The installer preserves computer guidance as runtime data, including in read-only installations.

## Evidence

`scripts/test-jarvis-shell.js` runs the real adapter, router, reducer, policy, audit and Bubblewrap in [the private Jarvis world](validation-jarvis.md). The shared forbidden list reaches the actual router in every policy profile. Its protected-file cases then reach the kernel through the actual shell tool. The suite reads the kernel privilege bit and absent desktop, audio and input access without invoking authentication or a real device. It checks read-only argv, exact shell text, account masks, command labels, exit codes, timeout, combined output bounds, router clipping, cancellation and detached-descendant cleanup. A failed kernel probe reports exit 77, not a pass.

Disposable controls remove registration, unavailable refusal, line translation, outcome mapping, cancellation, lease teardown and kernel timeout or output enforcement. Each must break its owning behavioral assertion. The protocol suite removes each availability-wire rule. The deferred-probe cases check fresh protected roots, repeat registration, readiness loss and stale completion suppression. The daemon suite exercises rescan delivery with a control. The nested Jarvis row reads readiness and actual router offers through the real service, holds the source revision and daemon process unchanged, and removes requirement-scan delivery as a recovery control. Its synthetic dependency state runs no installer. Installation controls retain the runtime reference in their manifest and consumer checks.

## Omarchy comparison

Omarchy's shell agents plugin keeps display separate from argv-based workers. Its panel launches user agent programs and has no model shell executor. VGS uses the same separation. Model commands additionally need the existing D074 kernel boundary because those commands can start descendants. The [kernel comparison](jarvis-sandbox.md) records the controls taken from omarchy-voice.

The adapter's cancellation uses the [Node AbortController interface](https://github.com/nodejs/node/blob/v22.20.0/doc/api/globals.md#class-abortcontroller). The service reads explicit account-root environment values through [Quickshell.env](https://quickshell.org/docs/v0.3.1/types/Quickshell/Quickshell/#function.env).
