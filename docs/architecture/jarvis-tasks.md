# Jarvis coding-task records

Covers: shell/plugins/vgs.jarvis/backend/Tasks.js, shell/plugins/vgs.jarvis/backend/task-event, shell/plugins/vgs.jarvis/backend/jarvisd.js, scripts/test-jarvis-tasks.js, scripts/test-task-event.js

[D072](../decisions/D072-coding-task-records-and-four-fact-state.md) records the four-fact choice. The [Jarvis plan § Coding-task delegation](../plans/v2-jarvis-plan.md#7-coding-task-delegation) owns task delegation and its later control, profile and voice work.

## Ownership

| Owner | Produces or consumes |
|---|---|
| `Tasks.js::Store` | Owns task metadata, event validation, disk replay, dropped-event evidence and ended-task retention |
| `task-event` | Writes one normalized event under `flock`; emits a machine-readable acceptance result and a keyed failure |
| `jarvisd.js` | Publishes the data engine and validates existing records before answering hello; a store failure withholds ready |
| J53 task runner | Creates a task before launch; supplies started identity, process observations and process exit |
| J54/J55 profiles | Translate documented vendor hooks into turn and wait facts; return vendor prompt responses outside the record producer |
| Agent's final goal step | Supplies the explicit reported outcome through the copied producer |
| J56 voice and J58 task display | Consume `Store.read` or `Store.list`; use the returned facts and derived state, not vendor logs |

No record method probes, starts, signals or answers a coding agent. A `started` event records identity, not evidence that its group still exists. J53 must check identity and group liveness before using its control authority. Neither daemon startup nor a recorded alive fact is a new liveness observation.

`Store.read` returns `identity` from the latest started event independently of later alive or exited observations. It holds `pid`, `pgid` and `startTime`. J53 supplies `startTime` as the Linux process start-tick string, not wall-clock time. The task record's `createdAt` and event `at` are wall-clock milliseconds. The command does not read `/proc` to obtain or validate either identity.

## Producer API

The daemon calls `Tasks.publish(data, backendDirectory)` using the service's judged hello directories. The return value is the absolute copied `task-event` path. A task records that path at creation. J53 and the agent use it through Node:

```text
node DATA_ENGINE/task-event --state ABSOLUTE_JARVIS_STATE TASK_ID create
node DATA_ENGINE/task-event --state ABSOLUTE_JARVIS_STATE TASK_ID EVENT_KIND
node DATA_ENGINE/task-event --state ABSOLUTE_JARVIS_STATE --prune
```

Each invocation reads one JSON object from stdin. Empty input means an empty object. `Tasks.js::eventData` is the sole kind and payload judge. `Tasks.js::metadata` fixes the task record. The command header fixes stdout and exit status. Its internal `--locked` mode belongs only to its lock-held child, not to producers.

Creation takes the goal, absolute working directory, agent name and account reference. The non-empty goal string can contain line breaks and tabs. The record preserves them as JSON text, not shell code. An empty account means no selected account. It stores no credential. The goal's release and handoff approval belong to J53's policy path before creation. Writing a record does not grant either approval.

Profiles report a question or permission as a wait event. Stop reports only a turn end. Resuming reports wait none and a working turn separately. Failure reports its cause kind. The agent reports an outcome explicitly. The record command does not interpret vendor hook input, supply a hook answer or hold a permission request.

## Facts and replay

`Tasks.js::derive` reads the ordered events into separate tagged process, turn, wait and outcome facts. `Tasks.js::stateOf` derives the display state. Neither result is stored. Failure, lost process and nonzero exit cannot derive reported success. A turn end and a zero exit with no outcome remain distinct from reported success.

A turn end does not erase a failed turn. A subsequent working event starts a new turn. Wait and outcome remain independent until their own producer changes them. A question therefore survives Stop and process exit as recorded evidence.

Startup runs the same lock-held producer's prune command. It reads the metadata, events and noisy marker from disk. This closes an interrupted write that committed an exit before pruning its oldest ended task. It uses no previous daemon memory. Consumers must reread when they need current records. There is no unused watcher or poller in the skeleton. I/O, malformed JSON, invalid UTF-8, missing committed files and refused record shapes throw keyed errors. The daemon surfaces them through stderr and its existing problem/recovery path.

## Storage and limits

The state directory holds `tasks.lock` and `tasks/<id>/`. Each task holds `task.json`, numbered files under `events/`, and an optional `noisy.json`. Only the writer's private temporary names are uncommitted. Readers ignore them after an interrupted publication.

`Store.append` enforces the [plan's bounds table](../plans/v2-jarvis-plan.md#311-bounds). A dropped event leaves the retained facts unchanged, increments the noisy marker and returns an explicit overflow refusal. Consumers must expose `noisy` and `dropped`; lost evidence cannot certify a task outcome. The derived display state is noisy until the task's record is removed.

`Store.prune` removes the oldest tasks whose process is exited or lost, by the recorded end time. It does not prune a task just because a turn or outcome ended. Active records stay. Task creation and event writes run pruning under the same writer lock.

Records are whole-file writes followed by rename. Directories use private mode 0700 and records use 0600. The helper itself has mode 0600 because producers invoke it through Node. `flock` is a declared requirement with packages for the manifest's supported managers.

The data engine uses a hash of both shipped producer files. Directory rename publishes them together. Existing copies must match their content and private modes. Runtime writes never target the plugin directory. Copies remain available for tasks that outlive a rescan or shell restart. J53 must keep the recorded engine path rather than replace it with the new daemon's path.

## Evidence

- `scripts/test-jarvis-tasks.js` tests four-fact combinations, restart replay, the full event and record boundaries, private modes, rename failure and ended-task pruning. Its mutants cover state and record gates.
- `scripts/test-task-event.js` tests the copied producer after snapshot removal, concurrent hook writes, malformed input, overflow, lock contention and visible I/O failures. Its mutants cover the producer's command gates.
- Both run inside the [J09 test world](validation-jarvis.md). They start no real coding agent or TUI. Their synthetic v1 records name their source and date in the suite header.
- `scripts/test-jarvis-daemon.js` proves that a corrupt committed task record prevents ready. The read-only-prefix smoke row writes task events through the installed producer's data copy and compares the installed tree unchanged.
