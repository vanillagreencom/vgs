# Safety: block-repo-copy

**Safety: Block recursive copies (cp -r/-R/-a, rsync, local git clone, tar pipes) of a source carrying repository history or a build tree into a temp/scratch destination. Suggests reading the source in place or building a minimal fixture.**
Temp destinations are commonly RAM-backed tmpfs; a multi-gigabyte tree copy fills the filesystem and every process writing there then fails with ENOSPC.
Before executing Bash operations, the agent must verify this constraint is met.
