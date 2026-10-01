# Jarvis kernel sandbox

Covers: shell/plugins/vgs.jarvis/backend/Sandbox.js, scripts/test-jarvis-sandbox.js, scripts/fixtures/jarvis/forbidden.js, scripts/fixtures/jarvis/sandbox-child.py, scripts/fixtures/jarvis/sandbox-datagram.py

[D074](../decisions/D074-jarvis-kernel-sandbox.md) refines [the action policy](jarvis-policy.md). The service still offers no tool. J49 supplies the shell adapter. [The router](jarvis-approval.md) owns approval and consumes [the pre-action audit](jarvis-audit.md).

## Kernel boundary

- `Sandbox.js` starts bubblewrap from fixed system paths. It creates user, PID, mount, IPC, network and UTS namespaces and a new terminal session. Bubblewrap sets `no_new_privs` before setup. VGS drops capabilities and passes no stdin or host descriptor.
- The sandbox mounts selected system runtime paths read-only. It supplies private devices, temporary files and runtime directories. No host GPU, audio or input device enters it. No desktop, audio, bus or keyring endpoint enters its environment.
- `publicRuntime` resolves the declared public system sources before binding them at their expected paths. A resolver link into hidden `/run` becomes a read-only file, not a mount of the runtime directory. Public CA and alternatives data also enter through this owner. Private SSL and PKI directories stay out.
- An aliased public directory needs a projected tree. Each member resolves against the physical source, so relative certificate links keep their meaning. Dangling links, cycles and special-file sources fail construction. `available()` reports those failures as unavailable. `run()` also rejects protected-source overlap as a filesystem error. HOME and ordinary runtime links still use `mount` and remain symlinks.
- HOME is read-only except the physically resolved working directory. `Denied.create` rejects a working directory that contains a protected root. The sandbox also refuses overlap with the trusted runtime directory.
- `Denied.masks` owns the protected inventory. The sandbox rebuilds only mount branches with protected descendants. Empty, unreadable, read-only mounts cover both present and absent roots. It preserves symlinks rather than bind-mounting their targets at an unprotected alias. Roots outside mounted trees are already inaccessible.
- The complete trusted runtime root also stays hidden if a user puts it inside HOME. A working directory cannot restore it as a writable mount.
- Networking stays private unless the immutable request sets `network: true`. `Tools.refine` classifies that request as `external`. The router must bind approval and release to that same snapshot.
- A seccomp filter denies AF_UNIX through both `socket` and `socketpair`, and denies io_uring even for external requests. A socketpair endpoint can reconnect to a pathname or abstract datagram listener. Abstract bus sockets have no path a mount can hide. io_uring can create sockets without either constructor. The filter permits only the native x86-64 or AArch64 syscall ABI. Other architectures are unavailable, not an unfiltered launch.
- Kernel mounts protect paths, not copies of content. A host program can copy sensitive content to an ordinary file. This boundary does not stop that host program or replace the release judge.

## Shell adapter contract

| API | Consumer contract |
|---|---|
| `available()` | J49 probes before offering tools. Only `{ kind: "available" }` permits an offer. Missing bubblewrap, unsupported setup or unavailable namespaces returns `unavailable`. |
| `run({ argv, cwd, network }, roots, { signal?, clock? })` | J49 supplies validated argv and service-owned roots from `Denied.create`'s contract. Runtime must exist. A shell line becomes `/bin/sh -c`; token scanning grants no authority. The router must rejudge lock, policy, approval and audit first. |
| `exited` | `code`, `stdout`, `stderr`. A nonzero command status is not success. Command exit 77 remains a command result, not an unavailable sandbox. |
| `refused` | Invalid request or refused working directory, with `reason`. |
| `unavailable` | No bootstrap command. There is no unsandboxed fallback. |
| `error` | Filesystem, spawn or launch protocol failure. `stderr` or `error` names its cause. |
| `stopped` | Cancellation, timeout, output limit or status limit. J49 reports this result and clipping, never success. |

The owner acquires the child, reads output and tears down its namespace. The [plan § Bounds](../plans/v2-jarvis-plan.md#311-bounds) sets its deadline and shared output ceiling. Output counts UTF-8 text bytes after replacement of invalid bytes. The injected clock tests the deadline without waiting for it. J49 uses these bounds instead of creating another lifetime owner.

Only bubblewrap's separate JSON status descriptor proves that exec completed. Stdout, stderr and a command's exit status cannot establish a valid launch. Bubblewrap closes that descriptor in the sandbox child.

## Evidence

`scripts/test-jarvis-sandbox.js` runs real bubblewrap inside the [J09 world](validation-jarvis.md). Its shared forbidden list exercises reserved calls through Policy, not invented executors. Kernel cases cover every supplied mask, file-valued protection, symlink aliases, absent targets, HOME writes, session separation, kernel `no_new_privs`, private devices, runtime endpoints, network isolation and bounded teardown.

Controls alter disposable Sandbox copies. They remove masks, alias preservation, mask permissions, mask read-only mounts, HOME read-only binds, cwd inspection, session separation, private devices, runtime isolation, network isolation, Unix socket and io_uring refusal, output bounds, timeout and launch-status checks. The x86-64 cases exercise compatibility and x32 syscall refusal. The PID control leaves a scratch lock holder alive; J09 ends it when the world closes. No control exposes a real credential or authentication service. Bubblewrap owns `no_new_privs`; the test reads its kernel bit and starts no authentication command.

The socketpair control removes only that constructor's refusal. Both scratch listeners receive the synthetic payload in the control. The pathname case uses default networking. The abstract case uses explicit external networking inside J09's private network. Public-runtime cases use disposable source-lookup substitutions and scratch resolver, CA and alternatives layouts. They read files and execute the allow-listed true program, not DNS, TLS, authentication or an external connection. Separate controls restore dangling system links, omit public data, flatten a relocated directory without fixing member links, permit writes or remove each construction refusal.

## Requirements

The optional manifest requirement follows [D035](../decisions/D035-manifest-requirements.md). Its package is `bubblewrap` on [Arch](https://archlinux.org/packages/extra/x86_64/bubblewrap/), [Debian](https://packages.debian.org/trixie/bubblewrap) and [Fedora](https://packages.fedoraproject.org/pkgs/bubblewrap/bubblewrap/). A command-presence probe alone does not establish kernel availability.

The [bubblewrap interface](https://github.com/containers/bubblewrap/blob/v0.13.0/bubblewrap.c) supplies namespace, mount, session and status controls. VGS uses that interface directly, not a shell wrapper or a parsed diagnostic.

The filter follows Linux [seccomp(2)](https://man7.org/linux/man-pages/man2/seccomp.2.html). Its architecture values, syscall numbers and instruction layout are Linux UAPI constants. A filter error is a launch error, never an unfiltered retry.
