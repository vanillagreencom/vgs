# Safety: block-bare-cd

**Safety: Block bare cd commands that permanently change the working directory. Suggests using subshells instead.**
Prevents accidental working directory pollution across tool calls.
Before executing Bash operations, the agent must verify this constraint is met.
