# v2 architecture

A Quickshell shell for Hyprland. The core owns the process, the compositor connection, the plugin loader and the validation harness. Everything else is a plugin.

## The one idea

A plugin is the unit of change. A plugin has one directory, one manifest, one owner for each watcher or poller it starts, and one validation row that runs it in the nested sandbox against its latency and memory budget. The core exposes a small API and changes rarely. A feature that needs a core change first lands the core change with its own row, then the plugin.

## Vocabulary

- Core: the runner, the instance lock, the Hyprland connection, the theme tokens, the plugin loader and the validation harness.
- Plugin: a directory under the plugin root with a manifest the loader reads.
- Surface: a Wayland surface the core creates for a window or layer. A plugin draws inside one; it never creates one.
- Service: a plugin with no surface that owns a watcher, a poller or a subprocess.
- Budget: the latency and memory ceilings a plugin's validation row asserts.

## Boundaries

- Core: depends on Quickshell, Qt and the Hyprland socket. Contains no plugin code and no knowledge of any plugin's name.
- Plugin: depends on the core API and its own files. Contains no direct compositor call and no reference to another plugin.
- Validation: depends on the nested compositor sandbox. Never touches the live session.

No check enforces the boundaries yet. The first plugin PR adds the check with its first plugin.

## Invariants

1. One shell process per session. A second instance blanks the desktop. The runner holds the lock and the shell refuses to draw for any other parent. Check: not yet written; the runner PR adds it.
2. Every Wayland object the shell creates is dispatched or destroyed. An undispatched event queue grows without bound. Check: the memory budget row, once it exists.
3. Every figure in a document was measured in the PR that wrote it, and the document names how.

## Decisions

- Hyprland only. Niri support in the previous shell doubled the compositor code paths and the review surface.
- Quickshell 0.3.1 is the baseline. Every recipe with a version slot requires at least it.
- Everything is a plugin. The core stays small so that an agent can hold the whole core in context and a plugin change cannot break another plugin.
- Each change carries its own validation row. Stability and performance are checked per change, not per release.
- The allocator is Quickshell's jemalloc. The shell sets no allocator tuning.

No decision record exists yet. The first structural PR writes them with the decider skill.

## Topics

- [runtime.md](runtime.md): read before touching anything that starts, stops, measures or talks to the shell.
