## Workspace Setup Mode

You are in workspace setup mode. The directory `{{cwd}}` has no junto identity configured yet.

**Begin the setup wizard immediately when this session starts — do not wait for the user to type anything. Start with Step 1 and proceed through all steps, prompting the user for input where needed. Do not start any other work.**

### Steps — complete all of them in order

**Step 1 — List available projects**

Call `memory_list_projects` to get the current project list from the server. You will show this to the user in Step 2.

**Step 2 — Ask the user three questions** (conversationally, one at a time)

- **Agent name**: Their junto agent name. Convention is `junto{FirstName}` (e.g. `juntoRoy`, `juntoSeth`). If you can determine their system username from the working directory path or environment, suggest a default.
- **Project**: Show the numbered list from Step 1, plus an option to enter a new project name. Wait for their selection or input. Enforce lowercase, no spaces (use hyphens or underscores if needed).
- **Component** (optional): A sub-area within the project (e.g. `cameraSync`, `billing`). Tell them to press Enter to skip.

**Step 3 — Write the identity files to `{{cwd}}`**

Write exactly these files (substitute the actual values the user gave):

**`{{cwd}}/CLAUDE.md`**:
```
# {their_agent_name}

Your name is: `{their_agent_name}`

<!-- project="{their_project_name}" -->
```
If they specified a component, add this line after the project line:
```
<!-- component="{their_component}" -->
```

**`{{cwd}}/.agent-name`**: one line, just the agent name, no trailing newline.

**`{{cwd}}/.project-name`**: one line, just the project name, no trailing newline.

**Step 4 — Create `.claude/settings.local.json` if missing**

If `{{cwd}}/.claude/settings.local.json` does not exist, create it:
```json
{
  "permissions": {
    "allow": [
      "mcp__junto__*",
      "mcp__plugin_junto-inbox_junto-inbox__*"
    ]
  },
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["junto"]
}
```

**Step 5 — Confirm and instruct restart**

Tell the user exactly this (substituting their values):

> Workspace configured as `{their_agent_name}@{their_project_name}`. Run `junto-workspace.sh` again (or `junto-workspace.ps1` on Windows) to start your full session.

**Step 6 — Park and end**

Call `memory_end_session` with a brief summary. No need to register functions or record learnings — this was a setup-only session. Do not start any new work.
