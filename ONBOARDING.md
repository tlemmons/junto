# Junto AI Coordination System — Onboarding Guide

---

## PART 1: What Is Junto and Why We Use It

### The Problem It Solves

Each engineer on the team runs their own Claude Code instance as an AI coding assistant. Without coordination, these agents are isolated: they accumulate knowledge that disappears when a session ends, they have no idea what other agents are working on, and there is no way for them to hand off context to each other. Every new session starts cold.

Junto is the team's answer to that problem. It is a shared coordination layer that sits underneath all of our Claude Code instances, giving them a common memory, a messaging channel, and a set of norms for working alongside each other.

### Mental Model

Think of Junto as a combination of three things a human team already has:

1. **A shared wiki** — where anyone can record what they learned, look up how something works, or read a spec written by a teammate. In Junto this is the shared memory server.
2. **A task board** — where work items are tracked, assigned, and handed off between people (or agents). Also in the shared memory server.
3. **A messaging system** — where one agent can send a note to another agent and expect it to arrive in the recipient's next session. This is the inbox plugin.

Every Claude agent on the team connects to all three. A learning recorded by one agent during a late-night debugging session is available to every other agent the next morning before they start work.

### The Three Components

**1. MCP Shared Memory Server**

The server runs on `spg-junto-central` on the LVT tailnet (Tailscale), port 8080. It is the authoritative store for:

- **Learnings** — non-obvious discoveries, gotchas, workarounds, and debugging findings. Agents are expected to record these in real time, not just at session end.
- **Backlog items** — tasks that can be assigned to a specific agent, prioritized, and tracked through to completion.
- **Specs** — versioned contracts and architectural decisions that all agents must respect.
- **Session state** — what each agent is currently doing, what files they have locked, and their handoff notes for the next agent picking up the same work.
- **Messages** — notes from one agent to another, including cross-project messages from coordinator agents.

Every Claude session begins by calling `memory_start_session`. This registers the agent, returns any guidelines set by the project admin, surfaces relevant learnings, and shows handoff notes from the previous session. Every session ends by calling `memory_end_session` with a summary and any handoff notes needed.

**2. junto-inbox Channel Plugin**

This is a Claude Code marketplace plugin (marketplace: `tlemmons-junto-inbox`, from the GitHub repo `tlemmons/junto-inbox`). When installed, it opens a persistent channel inside the running Claude Code session. Other agents can push a message to it using `send_message`, and the message arrives in the recipient's active session immediately — no polling, no delay.

This is the real-time layer on top of the server's async messaging. Without this plugin, messages are only delivered at the start of the next session. With it, a message sent by one agent mid-task arrives in another agent's session within seconds.

**3. Claude Code Configuration**

Both components require configuration wired into Claude Code. The shared memory server is registered as an MCP server in `~/.claude/settings.json`. The inbox plugin requires additional settings entries and, due to an Enterprise policy tier constraint, a local managed-settings file. Per-project `settings.local.json` files grant the specific tool permissions each project needs.

The behavioral contract — the mandate that every agent must call `memory_start_session` before doing anything else, the park checklist, and peer routing rules — is sourced from `~/.junto/templates/junto-system-prompt.md.tmpl` and injected into Claude Code at launch time via `--append-system-prompt-file`. The global `~/.claude/CLAUDE.md` is thin: it contains only identity and machine-level orientation. An agent that is not launched via the junto launcher is operating without these mandates and should not be considered a compliant junto agent.

### Which Option Should You Set Up?

There are three options:

**Option A — Shared Memory Only**

The base layer. Your Claude agent connects to the shared memory server via tailnet. It can read and write learnings, manage backlog, send and receive async messages, and coordinate with other agents. Messages from other agents are delivered at the start of your next session. This is sufficient for most day-to-day work.

Choose Option A if you want to get started quickly and do not need real-time push notifications.

**Option B — Shared Memory + Push Notifications**

Option A plus the junto-inbox plugin. Your agent receives messages from other agents in real time during an active session. This also requires configuring a local `managed-remote-settings.json` to work around a Claude Code Enterprise policy tier issue (described in the setup section). This file also carries the LVT Coralogix telemetry token, which you will need from an admin.

Choose Option B if your workflow involves close coordination with other agents or if you want to be reachable during active sessions.

**Option C — Local VM Peer**

Option C is for team members whose connection to `spg-junto-central` (AWS) is unreliable from their home network. A local VM running the junto-memory peer stack provides low-latency local access and continues working during AWS connectivity drops. The peer syncs with `spg-junto-central` when the connection is available. The peer runs in Docker Compose on a local machine (for example, a NUC, home server, or spare laptop on the same LAN).

Choose Option C if you experience frequent tailnet connectivity drops or want sub-millisecond MCP latency from your local machine.

---

## PART 2: Agent Setup Instructions

> **Primary path:** Run `~/.junto/junto-setup.sh`. The wizard prompts for your name, API key, and project directory, then configures everything below automatically — MCP server registration, managed-remote-settings.json, CLAUDE_CODE_REMOTE_SETTINGS_PATH, the ensure-channel-settings hook, and per-project settings.local.json. The sections below document each step for reference and manual recovery only; you do not need to follow them if you used the setup script.

Prerequisites that require human action are marked with `STOP: HUMAN REQUIRED`. All other steps can be executed by the agent without clarification.

---

### Prerequisites

**STOP: HUMAN REQUIRED — Tailnet Access**

Before any setup can proceed, the user's machine must be on the LVT Tailscale tailnet. A tailnet admin must:

1. Add the user to the tailnet at the Tailscale admin console.
2. Have the user install Tailscale on their machine (Windows host or macOS) and sign in.

On Windows: Tailscale runs on the Windows host, not inside WSL2. WSL2 must be configured for mirrored networking so that it can reach tailnet addresses. The agent will handle this configuration in the setup steps below, but Tailscale itself must already be installed and authenticated on the Windows host before proceeding.

On macOS: Tailscale runs as a native macOS app. No additional network bridging is needed.

**STOP: HUMAN REQUIRED — Junto API Key**

The shared memory server requires an API key. Obtain `<JUNTO_API_KEY>` from Tom or another team admin. Do not proceed until this value is in hand.

**STOP: HUMAN REQUIRED — Coralogix Token (Option B only)**

If setting up Option B, obtain `<LVT_CORALOGIX_TOKEN>` from Tom or infosec. This token is placed in `managed-remote-settings.json` and enables OTEL telemetry to the LVT Coralogix instance.

**Clone the junto templates repository**

Clone the `tlemmons/junto` repository to `~/.junto/`. This provides the launcher scripts and system prompt template used in all options.

```bash
gh repo clone tlemmons/junto ~/.junto
# or without gh:
git clone https://github.com/tlemmons/junto.git ~/.junto
```

This provides `~/.junto/templates/render.sh`, `render.ps1`, and `junto-system-prompt.md.tmpl`. These are required before proceeding to any option's setup steps.

---

### Option A Setup: Shared Memory Only

#### Step 1 (Windows only): Verify WSL2 Mirrored Networking

On Windows, check whether `~/.wslconfig` (in the Windows user home, i.e., `C:\Users\<username>\.wslconfig`) already contains mirrored networking configuration. If it does not, a human must add it — the agent cannot write to Windows host paths from inside WSL2.

**STOP: HUMAN REQUIRED (Windows only)**

On the Windows host (not inside WSL2), ensure `C:\Users\<username>\.wslconfig` contains:

```ini
[wsl2]
networkingMode=mirrored
```

If the file does not exist, create it with that content. After saving, run `wsl --shutdown` from a Windows command prompt and restart WSL2. This allows WSL2 to reach Tailscale MagicDNS addresses (including `spg-junto-central`).

#### Step 2: Verify Tailnet Connectivity

From inside WSL2 (Windows) or Terminal (macOS), run:

```bash
curl http://spg-junto-central:8080/health
```

Expected response: HTTP 200 with a JSON body containing a status field (e.g., `{"status":"ok",...}`).

If this fails, Tailscale is not reachable. Check `tailscale status` on the host. As a fallback, try the corp VPN address:

```bash
curl http://172.26.18.219:8080/health
```

If the VPN fallback works but MagicDNS does not, use `http://172.26.18.219:8080/mcp` as the MCP URL in the next step and note this for the user.

Do not proceed to Step 3 until one of these two addresses returns a healthy response.

#### Step 3: Add the MCP Server to `~/.claude/settings.json`

Read the current contents of `~/.claude/settings.json`. If the file does not exist, create it with `{}` as the base content.

Merge the following blocks into the top-level JSON object. If `mcpServers` already exists, add `junto` as a new entry within it. Do not overwrite existing entries.

```json
"mcpServers": {
  "junto": {
    "url": "http://spg-junto-central:8080/mcp",
    "headers": {
      "X-API-Key": "<JUNTO_API_KEY>"
    }
  }
},
"model": "opusplan"
```

The `model` key sets the default model policy: Opus when in plan mode (`/plan`), Sonnet otherwise. Set it only if `model` is not already present — do not overwrite an existing value. The Sonnet 1M context window is activated automatically by the junto launcher (see Part 3); no additional settings change is needed for that.

Replace `<JUNTO_API_KEY>` with the actual key obtained from the prerequisite step.

If MagicDNS was not reachable in Step 2, use `http://172.26.18.219:8080/mcp` as the `url` value instead.

#### Step 4: Configure `~/.claude/CLAUDE.md`

Check whether `~/.claude/CLAUDE.md` already exists.

- If it exists, verify it does not contain a duplicated `memory_start_session` mandate or park checklist. Those operational rules are now sourced exclusively from `~/.junto/templates/junto-system-prompt.md.tmpl` and injected at launch via `--append-system-prompt-file`. They must not be duplicated in CLAUDE.md.
- If it does not exist, create a minimal file.

The global `~/.claude/CLAUDE.md` should contain only identity and machine-level orientation: the user's email, their default agent name, which projects they work on, and any machine-specific facts (e.g., VPN address overrides). It should not contain the `memory_start_session` mandate, the park checklist, or peer routing rules — those come from the rendered system prompt produced by the launcher.

Include the following line so that future readers know where the operational rules live:

```
Operational rules source: tlemmons/junto/templates/junto-system-prompt.md.tmpl — injected at launch via --append-system-prompt-file
```

**STOP: HUMAN REQUIRED**

If you are creating or substantially rewriting `~/.claude/CLAUDE.md`, ask Tom to confirm the correct agent name and default project for this user before writing the file.

#### Step 5: Configure Per-Project `settings.local.json`

For each project repository where Claude Code will be used with Junto, create or update `<project>/.claude/settings.local.json` with the following minimum content. If the file already exists, merge the `permissions.allow` list and the two boolean keys — do not overwrite existing entries.

```json
{
  "permissions": {
    "allow": [
      "mcp__junto__memory_start_session",
      "mcp__junto__memory_send_message",
      "mcp__junto__memory_end_session",
      "mcp__junto__memory_list_backlog",
      "mcp__junto__memory_get_messages",
      "mcp__junto__memory_query",
      "mcp__junto__memory_record_learning",
      "mcp__junto__memory_get_spec"
    ]
  },
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["junto"]
}
```

#### Step 6: Write the Launcher Script

The launcher script renders the junto system prompt and starts Claude Code with it appended. This is the primary way to start a junto-enabled session — it replaces launching `claude` directly.

The launcher lives at `~/.junto/junto-launch.sh` and is shared across all projects. Create it with the following content:

```bash
#!/usr/bin/env bash
# junto-launch.sh — launch Claude with junto system prompt for this project
set -euo pipefail

JUNTO_DIR="${HOME}/.junto"
AGENT="${JUNTO_AGENT:-workClaude}"           # override: JUNTO_AGENT=myname ./junto-launch.sh
PROJECT="${JUNTO_PROJECT:-junto}"            # override: JUNTO_PROJECT=myproject ./junto-launch.sh
ROLE="${JUNTO_ROLE:-General work agent}"
SHARED_MEMORY_URL="http://spg-junto-central:8080/mcp"
API_KEY="${JUNTO_API_KEY:?JUNTO_API_KEY must be set}"

PROMPT_FILE=$(bash "${JUNTO_DIR}/templates/render.sh" \
    --agent "$AGENT" \
    --project "$PROJECT" \
    --role "$ROLE" \
    --shared-memory-url "$SHARED_MEMORY_URL" \
    --cwd "$(pwd)" \
    --api-key "$API_KEY" \
    --out "/tmp/junto-${AGENT}-${PROJECT}-prompt.md")

exec claude --append-system-prompt-file "$PROMPT_FILE" "$@"
```

Make it executable:

```bash
chmod +x ~/.junto/junto-launch.sh
```

Invoke it with environment variables to configure the agent identity and project:

```bash
JUNTO_AGENT=workClaude JUNTO_PROJECT=junto JUNTO_API_KEY=smk_... ~/.junto/junto-launch.sh
```

#### Step 7: Restart Claude Code and Verify

Use the launcher to start Claude Code rather than launching `claude` directly:

```bash
JUNTO_AGENT=workClaude JUNTO_PROJECT=junto JUNTO_API_KEY=smk_... ~/.junto/junto-launch.sh
```

In the first response after launching, the agent should identify itself by name and confirm it called `memory_start_session` (the rendered prompt makes this mandatory).

Then verify message retrieval by asking the agent to call:

```
memory_get_messages()
```

Expected result: a messages array (may be empty). Any error here indicates an authentication or connectivity problem.

Option A setup is complete.

---

### Option B Additional Steps: Push Notifications

Complete all Option A steps first (Steps 1–7). Then continue here.

#### Step B-1: Create `~/.claude/managed-remote-settings.json`

Create the file `~/.claude/managed-remote-settings.json` with the following content. Replace `<LVT_CORALOGIX_TOKEN>` with the actual token from the prerequisite step.

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://ingress.us1.coralogix.com",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer <LVT_CORALOGIX_TOKEN>",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_LOG_TOOL_DETAILS": "1",
    "OTEL_LOG_USER_PROMPTS": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_RESOURCE_ATTRIBUTES": "cx.application.name=claude-code,cx.subsystem.name=claude-code-cli,deployment.environment=prod,service.namespace=lvt-infosec"
  },
  "channelsEnabled": true,
  "allowedChannelPlugins": [
    { "marketplace": "tlemmons-junto-inbox", "plugin": "junto-inbox" }
  ]
}
```

This file serves two purposes: it provides the OTEL telemetry configuration that would otherwise come from the org managed settings fetched from Anthropic's backend, and it adds the channel permissions needed for the inbox plugin. Both must be present — omitting the OTEL block breaks telemetry.

**Why this file is necessary:** Claude Code Enterprise periodically fetches org managed settings from Anthropic's backend and caches them in `~/.claude/remote-settings.json`. This cached file is the highest-priority policy tier and overrides all other settings for security-gated features, including channels. The LVT org managed settings contain only OTEL telemetry config — they do not include `channelsEnabled`. Without that key in the policy tier, Claude Code falls back to Anthropic's default plugin ledger, which does not include the private `tlemmons-junto-inbox` marketplace, and channel registration fails. Setting `CLAUDE_CODE_REMOTE_SETTINGS_PATH` (done in the next step) redirects Claude Code to use the local stable file instead of the fetched one.

#### Step B-2: Update `~/.claude/settings.json` for Option B

Read the current `~/.claude/settings.json`. Add or merge the following keys at the top level. Do not overwrite keys that already exist; merge them:

```json
"env": {
  "CLAUDE_CODE_REMOTE_SETTINGS_PATH": "/home/<username>/.claude/managed-remote-settings.json"
},
"extraKnownMarketplaces": {
  "tlemmons-junto-inbox": {
    "source": { "source": "github", "repo": "tlemmons/junto-inbox" }
  }
},
"enabledPlugins": {
  "junto-inbox@tlemmons-junto-inbox": true
},
"channelsEnabled": true,
"allowedChannelPlugins": [
  { "marketplace": "tlemmons-junto-inbox", "plugin": "junto-inbox" }
]
```

Replace `<username>` with the actual Linux/macOS username. On macOS, the path will be `/Users/<username>/.claude/managed-remote-settings.json`.

#### Step B-3: Create the Channel Settings Safety-Net Hook

Create the directory `~/.claude/hooks/` if it does not already exist.

Create the file `~/.claude/hooks/ensure-channel-settings.sh` with the following content:

```bash
#!/bin/bash
# Ensures channelsEnabled + allowedChannelPlugins stay in remote-settings.json as fallback.
REMOTE="$HOME/.claude/remote-settings.json"
python3 - "$REMOTE" <<'EOF'
import sys, json
path = sys.argv[1]
try:
    with open(path, 'r') as f:
        data = json.load(f)
except Exception:
    data = {}
changed = False
if not data.get('channelsEnabled'):
    data['channelsEnabled'] = True
    changed = True
desired_plugins = [{"marketplace": "tlemmons-junto-inbox", "plugin": "junto-inbox"}]
existing = data.get('allowedChannelPlugins', [])
existing_keys = {(e.get('marketplace'), e.get('plugin')) for e in existing}
desired_keys = {(p['marketplace'], p['plugin']) for p in desired_plugins}
if not desired_keys.issubset(existing_keys):
    data['allowedChannelPlugins'] = existing + [p for p in desired_plugins if (p['marketplace'], p['plugin']) not in existing_keys]
    changed = True
if changed:
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f"[ensure-channel-settings] Restored channel keys to {path}", flush=True)
EOF
exit 0
```

Make the script executable:

```bash
chmod +x ~/.claude/hooks/ensure-channel-settings.sh
```

#### Step B-4: Register the Hook in `~/.claude/settings.json`

Add the hook to both `Stop` and `UserPromptSubmit` hooks in `~/.claude/settings.json`. If a `hooks` key already exists, merge these entries. If `Stop` or `UserPromptSubmit` arrays already exist, append to them.

```json
"hooks": {
  "Stop": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "bash ~/.claude/hooks/ensure-channel-settings.sh"
        }
      ]
    }
  ],
  "UserPromptSubmit": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "bash ~/.claude/hooks/ensure-channel-settings.sh"
        }
      ]
    }
  ]
}
```

#### Step B-5: Update Per-Project `settings.local.json` for Option B

For each project using Option B, add the following entries to the `permissions.allow` array in `<project>/.claude/settings.local.json` (in addition to the Option A entries from Step 5):

```json
"mcp__plugin_junto-inbox_junto-inbox__send_message",
"mcp__plugin_junto-inbox_junto-inbox__get_session_id",
"mcp__plugin_junto-inbox_junto-inbox__junto_journal_list",
"mcp__plugin_junto-inbox_junto-inbox__junto_journal_replay",
"mcp__plugin_junto-inbox_junto-inbox__junto_journal_discard"
```

#### Step B-6: Write the Option B Launcher Script

Replace or update the launcher at `~/.junto/junto-launch.sh` with the Option B variant, which calls `ensure-channel-settings.sh` before launch and passes `--plugin-present true` to the renderer:

```bash
#!/usr/bin/env bash
# junto-launch.sh — launch Claude with junto system prompt + push plugin
set -euo pipefail

JUNTO_DIR="${HOME}/.junto"
AGENT="${JUNTO_AGENT:-workClaude}"
PROJECT="${JUNTO_PROJECT:-junto}"
ROLE="${JUNTO_ROLE:-General work agent}"
SHARED_MEMORY_URL="http://spg-junto-central:8080/mcp"
API_KEY="${JUNTO_API_KEY:?JUNTO_API_KEY must be set}"

# Ensure channel settings are present before launch
bash "${HOME}/.claude/hooks/ensure-channel-settings.sh"

PROMPT_FILE=$(bash "${JUNTO_DIR}/templates/render.sh" \
    --agent "$AGENT" \
    --project "$PROJECT" \
    --role "$ROLE" \
    --shared-memory-url "$SHARED_MEMORY_URL" \
    --cwd "$(pwd)" \
    --plugin-present true \
    --api-key "$API_KEY" \
    --out "/tmp/junto-${AGENT}-${PROJECT}-prompt.md")

exec claude --append-system-prompt-file "$PROMPT_FILE" \
            --channels plugin:junto-inbox@tlemmons-junto-inbox \
            "$@"
```

Make it executable:

```bash
chmod +x ~/.junto/junto-launch.sh
```

#### Step B-7: Restart Claude Code and Verify Push Notifications

Launch using the launcher script:

```bash
JUNTO_AGENT=workClaude JUNTO_PROJECT=junto JUNTO_API_KEY=smk_... ~/.junto/junto-launch.sh
```

On startup, Claude Code should print a line similar to:

```
Listening for channel messages from: plugin:junto-inbox@tlemmons-junto-inbox
```

If that line does not appear, see the Troubleshooting section.

---

### Option C Additional Steps: Local VM Peer

Complete Option A steps first (Steps 1–7). Option C replaces the remote `spg-junto-central` URL with a local peer that syncs to it. You do not need Option B to use Option C, but you can combine them.

**STOP: HUMAN REQUIRED — Register the peer machine**

Before setting up the peer, Tom must add the peer machine to the LVT tailnet and assign it a hostname (e.g., `spg-<yourname>`). Provide Tom with the machine's Tailscale node key or have the machine join the tailnet first. Do not proceed until Tom confirms the hostname.

#### Prerequisites for Option C

- A Linux machine on the local LAN (VM, NUC, spare server, or spare laptop) that can run Docker Compose.
- Docker and Docker Compose installed on that machine.
- Tailscale installed and joined to the LVT tailnet on that machine.

#### Step C-1: Clone junto-memory on the peer machine

On the peer machine:

```bash
git clone https://github.com/tlemmons/junto-memory.git
```

#### Step C-2: Start the peer stack

Use the peer compose file, not the standalone primary compose file. The `junto-stack` repository on GitHub (commit fc9f565) does not include peer mode — use `junto-memory` directly.

```bash
docker-compose -f docker-compose.peer.yml up -d
```

#### Step C-3: Run the bootstrap script

```bash
bash contrib/test/bootstrap-peer.sh
```

#### Step C-4: Update the launcher to point at the peer

In `~/.junto/junto-launch.sh`, change the `SHARED_MEMORY_URL` line to use the peer's LAN IP or tailnet hostname:

```bash
SHARED_MEMORY_URL="http://<peer-hostname>:8080/mcp"
```

The peer will sync to `spg-junto-central` automatically when the tailnet connection is available.

#### Step C-5: Verify peer health

```bash
curl http://<peer-hostname>:8080/health
```

Expected response: `{"status":"healthy",...}` (HTTP 200).

---

### Verification Procedure

Run all of these checks in order after completing any option's setup.

**Check 1 — Tailnet health**

```bash
curl http://spg-junto-central:8080/health
```

Expected: HTTP 200, JSON body with `"status": "ok"` or similar.

**Check 2 — Session start**

Launch Claude using the launcher script:

```bash
JUNTO_AGENT=workClaude JUNTO_PROJECT=junto JUNTO_API_KEY=smk_... ~/.junto/junto-launch.sh
```

In the first response after launching, the agent should identify itself by name and confirm it called `memory_start_session` (the rendered prompt makes this mandatory).

**Check 3 — Message retrieval**

```
memory_get_messages()
```

Expected: no error; returns a messages array (may be empty on a fresh setup).

**Check 4 — Push channel registration (Option B only)**

On Claude Code startup output, confirm the presence of:

```
Listening for channel messages from: plugin:junto-inbox@tlemmons-junto-inbox
```

---

### Troubleshooting

**`curl http://spg-junto-central:8080/health` — connection refused or timeout**

- Windows: Confirm Tailscale is running on the Windows host (not WSL2). Run `tailscale status` on the Windows side. Confirm `~/.wslconfig` has `networkingMode=mirrored` and that WSL2 was restarted after that change.
- macOS: Confirm the Tailscale app is running and connected. Check the Tailscale menu bar icon.
- Both: Confirm the user has been added to the LVT tailnet by an admin. The machine will show in the Tailscale admin console if it is properly enrolled.
- Fallback: Try `curl http://172.26.18.219:8080/health`. If this works, the corp VPN is reachable but MagicDNS is not. Use the IP address in the MCP URL as a temporary workaround and report the MagicDNS issue to a tailnet admin.

**`memory_start_session` returns an authentication error**

- Verify the API key in `~/.claude/settings.json` is correct and has not been rotated.
- Confirm there are no extra spaces or newline characters in the key value.
- Confirm the `mcpServers` block is valid JSON (use `python3 -m json.tool ~/.claude/settings.json` to validate).

**`memory_start_session` is not available as a tool in Claude Code**

- Confirm `enableAllProjectMcpServers: true` is set in the project's `settings.local.json`.
- Confirm `enabledMcpjsonServers` includes `"junto"`.
- Confirm the `mcpServers` key in `~/.claude/settings.json` is named `"junto"` (not `"shared-memory"`).
- Restart Claude Code fully after settings changes.

**Option B: Push channel line does not appear on startup**

The most common causes, in order:

1. `CLAUDE_CODE_REMOTE_SETTINGS_PATH` is not set, or the path is wrong. Verify the value in `~/.claude/settings.json` `env` block matches the actual path to `managed-remote-settings.json`.
2. `managed-remote-settings.json` does not contain `"channelsEnabled": true` and the `allowedChannelPlugins` entry. Read the file and verify.
3. `~/.claude/remote-settings.json` was overwritten by a fresh org policy fetch after setup. The safety-net hook (Steps B-3 and B-4) should prevent this, but if the hook has not run yet, manually verify `remote-settings.json` contains `channelsEnabled` and the plugin entry, or run the hook script manually: `bash ~/.claude/hooks/ensure-channel-settings.sh`.
4. The plugin is not enabled. Confirm `settings.json` contains `"enabledPlugins": { "junto-inbox@tlemmons-junto-inbox": true }`.
5. The `tlemmons-junto-inbox` marketplace is not registered. Confirm `extraKnownMarketplaces` is present in `settings.json` with the correct `github`/`tlemmons/junto-inbox` source.

**Option B: Coralogix telemetry stops working after setup**

The `OTEL_EXPORTER_OTLP_HEADERS` value in `managed-remote-settings.json` contains a Coralogix bearer token. If infosec rotates this token, each user with Option B must update that header manually. Obtain the new token from Tom or infosec and update the `Authorization=Bearer <token>` value in `~/.claude/managed-remote-settings.json`.

**Agent does not follow guidelines / session-start behavior seems wrong**

- Verify the agent was launched via `~/.junto/junto-launch.sh`, not `claude` directly. The mandatory session-start behavior is injected by the rendered system prompt; it is not duplicated in `~/.claude/CLAUDE.md`.
- If the launcher was used but the agent still skips `memory_start_session`, re-render the prompt by running the launcher again — the template may have stale output in `/tmp`.
- If the agent calls `memory_start_session` but ignores the guidelines rules block, the most likely cause is a very full context window. Park the session early and start a fresh one.
- Confirm the guidelines returned by `memory_start_session` are being acknowledged. If the call succeeds but the agent ignores the rules block, escalate to Tom.

**Messages sent to this agent are not arriving**

- Async messages (Option A): Messages are delivered by `memory_get_messages()` at session start. If a message was sent after your session started, call `memory_get_messages()` again manually.
- Push messages (Option B): If the push channel line is absent on startup, messages will not arrive in real time but will be queued for async delivery. Fix the channel registration issue first.

---

### Maintenance Notes

**Coralogix token rotation (Option B)**

The `OTEL_EXPORTER_OTLP_HEADERS` value in `~/.claude/managed-remote-settings.json` contains a Coralogix bearer token. If infosec rotates this token, each user with Option B must update that header manually. Obtain the new token from Tom or infosec and update the `Authorization=Bearer <token>` value in that file.

**Template updates**

The operational rules injected by the launcher come from `~/.junto/templates/junto-system-prompt.md.tmpl`. When Tom updates that template (new guidelines, peer routing rules, park checklist changes), you will not pick them up until you pull the latest `tlemmons/junto` and re-render.

Periodically run:

```bash
git -C ~/.junto pull
```

Then re-launch via `~/.junto/junto-launch.sh` to pick up the updated prompt. No changes to `~/.claude/settings.json` or project files are needed for template-only updates.

**Tool prefix changes**

The `permissions.allow` entries in `settings.local.json` use the prefix `mcp__junto__` because the MCP server is registered under the key `"junto"` in `~/.claude/settings.json`. If that key is ever renamed, both places must be updated together:

1. Rename the key in `mcpServers` in `~/.claude/settings.json`.
2. Update all `permissions.allow` entries in every project's `settings.local.json` to use the new prefix (`mcp__<newkey>__`).

Failure to update both will cause all memory tools to be unavailable or to require re-approval on every call.

---

## PART 3: Day-to-Day Usage

This section is written for the user — not the agent. Read it once after your first session.

---

### The Session Rhythm

Every junto session follows the same three-step pattern: **launch → work → park**.

**1. Launch** — open a terminal, go to your project folder, and run the launcher:

```bash
cd ~/lvt_code/iSpy
~/.junto/junto-launch.sh
```

Claude Code starts and your agent automatically calls `memory_start_session`. This registers you on the shared network, loads any messages waiting from teammates' agents, and retrieves your backlog and any learnings relevant to your work. This happens before your agent says anything.

**2. Work** — once Claude is running, type:

```
go
```

This is the junto convention for "I'm here, start the session." Your agent will greet you, report what it found at startup (messages, backlog items, handoff notes from your last session), and ask what you want to work on. You don't have to type "go" — any message works — but it's the standard way to kick things off and keeps sessions consistent.

**3. Park** — when you're done, type:

```
park
```

Your agent runs the park checklist: records what it learned during the session, saves its next steps and current state to shared memory so the next session picks up cleanly, and ends the session. **Park before you close the window.** Closing without parking does not lose your code, but your agent won't have saved its learnings or left a handoff, and the next session starts cold.

---

### How Projects and Folders Work

Your agent identity has two parts: a **name** and a **project**.

- **Name** — always `junto<YourFirstName>` (e.g., `juntoRoy`). Set once during setup. Never changes.
- **Project** — determined by the folder you launch from. Changes when you change folders.

The folder's `CLAUDE.md` file tells junto which project you're connecting to. When you run `~/.junto/junto-launch.sh` from a folder, junto reads that folder's `CLAUDE.md` and registers you as `<your-name>@<project>`. If there is no `CLAUDE.md`, it falls back to the name in `~/.junto/config`.

**Example:**

```
~/lvt_code/iSpy/CLAUDE.md contains:  <!-- project="ispy" -->
  → launching from there registers you as: juntoRoy@ispy

~/lvt_code/awareness/CLAUDE.md contains:  <!-- project="awareness" -->
  → launching from there registers you as: juntoRoy@awareness
```

You can work on multiple projects — just launch from the right folder. Your agent name stays the same; only the project tag changes.

---

### Setting Up a New Project Folder

When you start using junto in a new repo or project directory, create a `CLAUDE.md` there. One file, placed in the project root, is all junto needs.

**Template** (replace `juntoRoy` with your agent name, `ispy` with your project name):

```markdown
# Junto agent — juntoRoy

Your name is: `juntoRoy`

This CLAUDE.md tells junto who you are and what project you're working on.
Launch Claude from this directory to connect as juntoRoy@ispy.
For a different project, create a CLAUDE.md in that folder with the right project tag.

<!-- junto identity markers — used by junto-launch.sh for auto-detection -->
<!-- project="ispy" -->
```

Save it as `<project-root>/CLAUDE.md`. That's it — no other changes needed. The next time you run `~/.junto/junto-launch.sh` from that folder, you'll connect as `juntoRoy@ispy`.

**You do not need a `settings.local.json` in every project** — the one created by `junto-setup.sh` covers the junto tools. If your project has its own `settings.local.json` already, add the junto tool permissions to it (see Part 2, Step 5).

---

### Quick Reference

| You want to… | Do this |
|---|---|
| Start a session | `cd <project-dir> && ~/.junto/junto-launch.sh`, then type `go` |
| End a session cleanly | Type `park` |
| Check your messages | Ask: "check my messages" (agent calls `memory_get_messages`) |
| Check your backlog | Ask: "what's on my backlog" |
| See who else is on the team | Ask: "list agents" |
| Send a message to a teammate | Ask: "send a message to juntoRoy@ispy saying …" |
| Add a task to your backlog | Ask: "add a backlog item: …" |
| Set up a new project folder | Create a `CLAUDE.md` with `<!-- project="<name>" -->` in the root |
| Update junto scripts | `git -C ~/.junto pull`, then relaunch |

---

### Model Setup: opusplan and Sonnet 1M

Junto configures two model defaults that are set up automatically during installation.

**opusplan — Opus in plan mode, Sonnet otherwise**

The `"model": "opusplan"` setting in `~/.claude/settings.json` tells Claude Code to use Opus when you enter plan mode and Sonnet for everything else. You do not need to switch models manually.

- **Plan mode** — type `/plan` (or use the opusplan skill) to enter plan mode. Use it when you want Claude to think through a non-trivial design decision or implementation approach before writing any code. In this mode Claude uses Opus, which is slower but reasons more carefully.
- **Normal mode** — all regular work runs on Sonnet. The status bar shows which model is active.

You can check the current model at any time with `/model`.

**Sonnet 1M — extended context window**

The junto launcher sets `ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6[1m]`, which opts Sonnet sessions into the 1M-token context window at the same per-token cost as the standard 200K window. This means Claude can hold roughly 5× more context before compressing earlier conversation turns — useful for long sessions working across many files.

This is set automatically by `~/.junto/junto-launch.sh`. Sessions launched directly via `claude` (without the launcher) will not have this set — another reason to always use the launcher.

---

### Things That May Surprise You

**Your agent remembers across sessions.** When you park and come back days later, your agent has its previous next steps, the learnings it recorded, and any messages that arrived while you were away. You do not need to re-explain what you were working on — ask your agent to brief you and it will.

**"go" is optional but encouraged.** Without it, Claude will respond to whatever you type first. "go" is just a convention that signals "read my backlog and incoming messages and get oriented" — it keeps sessions consistent across the team.

**Each person's agent is independent.** Roy's agent (juntoRoy@ispy) and Tom's agent (juntoTom@junto) are separate. They share the same memory server and can message each other, but they run in separate Claude Code instances on separate machines.

**Do not run `claude` directly.** Always launch via `~/.junto/junto-launch.sh`. Running `claude` directly skips the system prompt that injects the junto mandates — your agent will not call `memory_start_session` and will not follow the park checklist. If you accidentally launch directly, close it and use the launcher.

**Closing the terminal without parking is OK in an emergency** — no work is lost. But your agent will not have saved its session state. The next session will start without handoff notes or a recorded learning from that session.
