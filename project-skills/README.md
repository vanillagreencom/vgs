# Agent Skills

Project-local skills for VGS. These are tracked repo content; the `.agents/`,
`.claude/`, and other harness directories are untracked mirrors and are
symlinked wholesale into every worktree, so a tracked skill cannot live there
(git refuses to write a shadowed path while `git status` still reports clean).

| Skill | Description |
|-------|-------------|
| [vshell-dev](vshell-dev/) | Work on VanillaGreen Shell: Quickshell runtime, bundled plugins, theme engine, generated targets, and workstation wiring boundaries. |

`vstack.toml` sets `project-skills-dir = "project-skills"`, so `vstack refresh`
links each directory here to `.agents/skills/<name>`, where agents discover it
as usual. Do not create that symlink by hand, and do not move a skill back
under `.agents/skills/`. Refresh refuses to replace a real directory with the
link, so if `.agents/skills/<name>` already exists as a directory, delete it
first.
