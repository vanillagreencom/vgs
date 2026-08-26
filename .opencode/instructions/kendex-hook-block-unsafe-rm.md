# Safety: block-unsafe-rm

**Safety: Block a recursive rm whose path starts with a variable that may expand empty. Names the rewrite the harness accepts without a prompt.**
The harness stops the whole session on that shape with a "Dangerous rm operation on possibly-empty variable path" prompt; refusing it here lets the agent rewrite and continue.
Before executing Bash operations, the agent must verify this constraint is met.
