# Jarvis input

Covers: shell/plugins/vgs.jarvis/backend/Input.js, shell/plugins/vgs.jarvis/backend/ComputerHelp.js, shell/plugins/vgs.jarvis/backend/input-check.js, shell/plugins/vgs.jarvis/backend/skills/computer/input.md, shell/plugins/vgs.jarvis/tui/setup-input.sh, scripts/test-jarvis-input.js

The [plan's input family](../plans/v2-jarvis-plan.md#6-computer-use-and-browser-reference-set) uses the existing [Policy](jarvis-policy.md) and [router](jarvis-approval.md). [Core input facts](input-facts.md) owns the target and keymap observations. Input owns only its command children and transport readiness. `ComputerHelp.js` reads installed family files on demand. Its advertised topics come from those files; this item ships only input help.

## Authority

- The router reserves its serial slot while an asynchronous observation runs. It checks Session's current turn and deadline after that observation. Policy then decides the immutable call. Before execution, another observation and Policy decision must succeed. An old turn, held action, failed audit or changed application cannot send input.
- Keys use wtype. Policy judges both the requested native identity and wtype's raw emitted identity under Hyprland's global group-zero map. Hyprland can interpret the raw keycode against its native map, or the virtual keyboard's symbol map. No global input configuration changes.
- Text emits no modifiers. Policy refuses text while an effective own bind has no modifiers. This conservative rule prevents text from activating a rebound approval or control key.
- Pointer actions request compositor cursor movement, then observe the target and exact cursor position again. A changed target, protected target or constrained pointer refuses the click or scroll. wlrctl is the primary transport. ydotool is a fallback only after its debug command proves an already running socket. Setup never starts its daemon.
- The [Policy input rules](jarvis-policy.md#trusted-context) own terminal restrictions, application grants and taint. Trusted terminal text keeps its exact displayed text and physical approval. The executor introduces no second policy table.
- Command completion proves delivery only. A result reads back the target and reports the application's effect as unknown. A failed read after delivery cannot establish that nothing happened. A transport that started but failed also reports unknown because delivery can be partial.

## Readiness

Check input opens the plugin's floating terminal. The same Input owner probes an empty wtype string, a zero-axis wlrctl frame, or ydotool debug. These probes send no key, button, motion or scroll event. Missing tools remain unavailable. The requirements notice installs optional commands. No unit, module, group or configuration changes in this flow.

## Comparison and evidence

Omarchy's shell agents plugin supplies no synthetic-input policy. omarchy-voice supplies wtype and pointer argv, but its input path does not protect every assistant bind or terminal. VGS keeps the typed command interfaces and adds the plan's fresh target and serial approval boundary. The system library resolves key identities; no plugin key parser duplicates the core judge. `packaging/runtime-libraries.json` names required library packages for the shared packaging judge.

`scripts/test-jarvis-input.js` uses stand-in commands inside the private [Jarvis world](validation-jarvis.md). It controls transport, freshness, readiness and serial observation rules. The nested input row proves the core facts and protected VGS targets. TUI execution in the sandbox uses a fixture script.
