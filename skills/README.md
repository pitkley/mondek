# Mondek agent skills

These skills guide an agent through the same workflows as the human documentation. Each folder is a standalone skill with a SKILL.md entry point:

| Skill | Use it for |
| --- | --- |
| [mondek-server-setup](mondek-server-setup/SKILL.md) | Start an empty server, plan a hosted deployment or upgrade an existing installation |
| [mondek-runner-setup](mondek-runner-setup/SKILL.md) | Create/install a monitoring project and connect a runner with persistent state |
| [mondek-check-authoring](mondek-check-authoring/SKILL.md) | Add or modify Python checks, datasource access and deliberately delegated settings |

To use a skill without installation, give your agent the Mondek checkout path and the chosen SKILL.md path. For example: “Use /path/to/mondek/skills/mondek-runner-setup/SKILL.md to connect a new monitoring project to my local Mondek server.” An agent that can read files can follow these instructions even without automatic skill discovery.

If your agent supports installing skills, copy or symlink the selected skill directories into its configured skill directory using that agent's normal installation mechanism. The repository's skills/ directory is not universally auto-discovered. Installation is optional, and Mondek does not modify global agent configuration. Installed copies still need access to the selected Mondek source checkout: the skills deliberately use its current guides and APIs instead of duplicating them. Update copied skills when updating Mondek.

Provide the intended server, project and deployment scope. A local evaluation, a new runner and changes to existing monitoring are distinct tasks. Existing authorization applies to the task it covers; a skill does not grant access to unrelated hosts, credentials or notification recipients. For one-off assistance, the [copyable prompts](../docs/AGENT-WORKFLOWS.md) remain available.
