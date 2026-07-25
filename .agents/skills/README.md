# Agent Skills

Project-local skills for VGS.

| Skill | Description |
|-------|-------------|
| [vshell-dev](vshell-dev/) | Work on VanillaGreen Shell: Quickshell runtime, bundled plugins, theme engine, generated targets, and workstation wiring boundaries. |

Agents that support the Agent Skills layout can discover skills from `.agents/skills/`.
For Claude Code project discovery, symlink if desired:

```bash
mkdir -p .claude/skills
ln -s ../../.agents/skills/vshell-dev .claude/skills/vshell-dev
```
