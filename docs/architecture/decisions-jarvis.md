# Jarvis decisions

Covers: docs/decisions/D064-*, docs/decisions/D066-*, docs/decisions/D070-*, docs/decisions/D072-*, docs/decisions/D074-*, docs/decisions/D079-*, docs/decisions/D082-*, docs/decisions/D087-*, docs/decisions/D089-*, docs/decisions/D093-*

The assistant's decision records. [Decisions](decisions.md) holds the other architecture records. [INDEX.md](../decisions/INDEX.md) holds the full log with dates, rationale and status.

- [D064](../decisions/D064-jarvis-child-lease.md): Jarvis owns a child leased by stdin and one wire judge; bounded recovery reports a problem without a systemd unit.
- [D066](../decisions/D066-pinned-local-speech-and-bounded-inputs.md): local speech uses pinned exports, bounded Moonshine inputs and CPU streaming captions, measured with actual local artifacts and synthetic audio.
- [D070](../decisions/D070-jarvis-action-policy.md): Jarvis actions use one typed policy gate and protected real paths; routing, approval and kernel confinement keep separate owners.
- [D072](../decisions/D072-coding-task-records-and-four-fact-state.md): coding-task records preserve process, turn, wait and outcome facts; the copied event producer and disk replay stay separate from process control. Refines D033 and D052.
- [D074](../decisions/D074-jarvis-kernel-sandbox.md): Jarvis commands require a real kernel sandbox probe, protected masks and private endpoints.
- [D079](../decisions/D079-brains-wire-and-harness-adapters.md): Jarvis brains are wire adapters through the origin-bound network door or harness adapters that start the vendor's own program with its own tools off and the tool bridge as its only server; one provider table and one bounded event stream reader serve them, with no npm dependency. Refines D009 and D046.
- [D082](../decisions/D082-jarvis-approval-bound-to-the-action.md): Jarvis routes serial immutable actions; Session judges confirmation identity and time, Policy rejudges fresh facts and Audit gates starts. Refines D070.
- [D087](../decisions/D087-jarvis-task-control.md): a launcher records a coding task's process-group identity before the agent execs; stops verify it before every signal and write `stopped` only after the group reads empty; tmux or the floating TUI only display the task. Refines D072 and D033.
- [D089](../decisions/D089-jarvis-chained-engine-and-heard-prefix.md): the chained speech engine owns one conversation's resources, routes the brain's calls and tells the brain the prefix Audio reports as heard after a barge-in; the speech table ships empty.
- [D093](../decisions/D093-jarvis-screenshots.md): Jarvis captures the screen only for the user's live turn, reads Hyprland before and after, paints private windows out before the image leaves the executor and releases it by `cloudVision`; masking is limited protection. Refines D070 and D082.
