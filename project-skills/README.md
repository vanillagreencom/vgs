# Agent Skills

Project-local skills for VGS. These are tracked repo content; the `.agents/`,
`.claude/`, and other harness directories are untracked mirrors and are
symlinked wholesale into every worktree, so a tracked skill cannot live there
(git refuses to write a shadowed path while `git status` still reports clean).

| Skill | Description |
|-------|-------------|
| [vgs-release](skills/vgs-release/) | Cut and publish a VGS release across GitHub and every maintained install channel. |
| [vshell-dev](skills/vshell-dev/) | Work on VanillaGreen Shell: Quickshell runtime, bundled plugins, theme engine, generated targets, and workstation wiring boundaries. |

`kendex.toml` declares this directory as the path source `project-skills`
(skills live under `skills/<name>`), and declares each skill from it, so
`kendex refresh` installs them into `.agents/skills/<name>` like any other
package. Do not create those links by hand, and do not move a skill back
under `.agents/skills/`. A new skill here needs a `skills/<name>/SKILL.md`
and a `kendex add --skill <name> project-skills` to declare it.
