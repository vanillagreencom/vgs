# D074: Jarvis commands require kernel confinement

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: [Jarvis plan § Policy](../plans/v2-jarvis-plan.md#37-policy-authority-effects-approval-audit), [Omarchy comparison](../plans/v2-jarvis-plan-research.md#25-omarchy-voice-v030-mit)
**Refines**: [D070](D070-jarvis-action-policy.md)

**Context**: A command can start another program. Argument classification and a shell-token scanner cannot mediate those later operations.

**Decision**: `Sandbox.js` owns one bubblewrap lifetime. A real kernel probe must succeed before the shell adapter offers tools. There is no unsandboxed fallback. The working directory is the only writable host tree. The sandbox consumes `Denied.masks`, including physical aliases and absent paths. Its status descriptor, not command output, establishes a valid launch.

**Rationale**:
- omarchy-voice's `task_worker.py::sandbox_command` uses bubblewrap namespaces, a new session, private devices, selected runtime mounts, a cleared environment and a writable workspace. VGS takes those controls.
- VGS differs by exposing read-only HOME with Denied masks. Its file and shell tools use the same trusted user paths. Rebuilding protected mount branches makes absent masks possible without writing into HOME.
- VGS preserves symlinks instead of binding their targets at another path. A read-only credential bind at an unprotected alias would still expose its contents.
- VGS supplies no host GPU devices, desktop endpoints or real authentication. Its shell consumer needs commands, not model execution or a desktop session.
- A seccomp filter denies Unix sockets even when external networking is authorized. A pathname mask cannot hide an abstract bus socket. VGS refuses unsupported syscall architectures rather than run without that filter.
- Omarchy's agents plugin keeps display separate from worker extraction. VGS likewise keeps the service separate from this command owner.
- User-namespace or bootstrap failure removes the tools. Continuing outside confinement would invalidate D070.

**Alternatives considered**:
- Shell-token refusal cannot confine a program's descendants.
- Binding HOME wholesale cannot add absent masks on a read-only parent.
- Copying a credential inventory into Sandbox would let Policy and the kernel protect different paths.
- Mounting host `/dev`, runtime or `/etc` wholesale would expose devices, service endpoints or authentication configuration.

**Boundaries**: J19 owns policy and approval. J21 owns audit. J22 owns release. J27 supplies account roots. J49 translates shell calls and matches all Sandbox result kinds. This change registers no executor. A host program that copies a secret into an ordinary file remains outside this boundary.

**Revisit When**: A command needs another host mount, endpoint or privilege. Add a typed control and its real-kernel test, or use a user-authorized handoff.

**Verification**: `scripts/test-jarvis-sandbox.js` through `scripts/validate`. It runs real bubblewrap in scratch HOME with the shared forbidden list and disposable controls. The `no_new_privs` probe reads the kernel bit; it never starts PAM, sudo, polkit, su, run0 or doas.

**References**: [Sandbox contract](../architecture/jarvis-sandbox.md), [test world](../architecture/validation-jarvis.md), [D035](D035-manifest-requirements.md)
