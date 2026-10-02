# Consumer text

Covers: shell/plugins/**

Consumer text follows ASD-STE100 Simplified Technical English. This rule applies to plugin descriptions, Settings rows, windows, panels, tooltips, messages and setup screens.

## Rules

- Write short sentences. Put one idea in each sentence. Use active voice and common words.
- Use the same word for the same thing.
- Say what the feature does for the user or what the user must do.
- Give a plugin description one or two short sentences. Include no command or feature list.
- Use plain words for labels and status values. Name the result of a check, not its internal operation.
- Give a hint one short sentence. Remove it when the label already gives the information. Put longer help in an info dialog.
- Remove filler, sales language, hedging and stacked clauses.
- Keep diagnostic keys, internal reason codes and command errors in logs. Show a plain sentence that explains the result or the action. A field made to show a technical value may name that value.
- Apply [D061](../decisions/D061-no-manual-commands.md) to setup instructions and command disclosure.
- Apply [D075](../decisions/D075-consumer-features-need-no-developer-setup.md) to unsupported extras.

## Boundary

Developer logs, code comments, developer documentation and machine-readable output keep their technical terms. Component previews may name the component, property or state they show.

Keep user commands, their output and child command streams unchanged. Map plugin-owned messages before the plugin shows them to the user.
