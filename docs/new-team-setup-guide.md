# Junto Setup Guide — New Team

How to stand up junto for a new team that wants their own isolated instance.
Written from the SPG team's live experience, including all the bugs we hit.

Two audiences in this doc:
- **Admin** — the person provisioning the server and API keys (probably Tom or a tech lead)
- **Team member** — each developer who will run a Claude agent

---

## Overview: what you're building

```
[Developer laptop]                     [Server — Linux VM]
  Claude Code CLI                        Docker containers:
  junto-launch.sh         → HTTP →         mcp-rag-arch  (junto-memory MCP server)
  junto-inbox plugin                       mcp-mongodb   (MongoDB 7.0)
  ~/.mcp.json                              mcp-chromadb  (ChromaDB)
```

The server holds shared knowledge. Each developer's `claude` process connects to it over HTTP (via Tailscale, VPN, or LAN — your choice). The `junto-inbox` plugin delivers peer messages live.

---

## PART 1: Admin — Stand up the server

### 1.1 Server requirements

- Linux (Ubuntu 22.04+ recommended)
- 2+ GB RAM, 10+ GB disk (knowledge base grows ~120 KB/day at SPG scale)
- Docker 20.10+ and Docker Compose v2 installed
- Outbound internet during install (pip, apt, Docker Hub)
- Port 8080 open to your team's network

Verify Docker:
```bash
docker --version              # 20.10+
docker compose version        # v2 (with a space, not a hyphen)
docker info >/dev/null && echo "ok"
```

### 1.2 Clone junto-memory

```bash
git clone https://github.com/tlemmons/junto-memory.git
cd junto-memory
```

### 1.3 Configure .env

```bash
cp .env.example .env
```

Edit `.env`. The required fields:

| Variable | What to set |
|---|---|
| `MONGO_USER` | Any string. `mcp_orch` is fine. |
| `MONGO_PASSWORD` | **Strong password.** `openssl rand -base64 24` works. **Do NOT leave as `changeme`.** |
| `MONGO_DB` | `mcp_orchestrator` is fine. |
| `MCP_AUTH_ENABLED` | Set to `true` — your server will be reached from outside localhost. |
| `ORIGIN_SERVER_ID` | Set to something unique for this team, e.g. `yourteam-central`. |

Leave `ANTHROPIC_API_KEY` commented unless you want the librarian enrichment daemon.

### 1.4 Fix the docker-compose.yml volumes section

**IMPORTANT:** The repo's `docker-compose.yml` has volumes declared as `external: true` (because it was written on SPG's existing deployment). A fresh install must remove that so Docker creates them automatically.

Find this section at the bottom of `docker-compose.yml`:
```yaml
volumes:
  chroma-data:
    external: true
    name: chroma-persistent
  mongo-data:
    external: true
    name: mcp-mongo-persistent
```

Change it to:
```yaml
volumes:
  chroma-data:
  mongo-data:
```

### 1.5 Generate the MongoDB keyfile

MongoDB's replica set requires an internal auth keyfile:

```bash
mkdir -p secrets
openssl rand -base64 756 > secrets/mongo-keyfile
chmod 400 secrets/mongo-keyfile
sudo chown 999:999 secrets/mongo-keyfile
```

(UID 999 is the `mongodb` user inside the container.)

### 1.6 Start the services

```bash
docker compose up -d
docker compose logs -f mcp-server
```

Wait for: `Uvicorn running on http://0.0.0.0:8080`. Ctrl-C to stop tailing.

### 1.7 Initialize the MongoDB replica set

**This step is not automatic.** MongoDB starts but does not self-initiate a replica set.
Without it, the server passes its health check but fails silently on every write.

```bash
# Get Mongo container name (probably mcp-mongodb)
docker compose ps

# Run rs.initiate
source .env
docker exec mcp-mongodb mongosh --quiet --norc \
  "mongodb://${MONGO_USER:-mcp_orch}:${MONGO_PASSWORD}@localhost:27017/?directConnection=true&authSource=admin" \
  --eval 'rs.status().ok === 1 ? "already initialized" : rs.initiate({_id:"rs0", members:[{_id:0,host:"mongodb:27017"}]})'
```

Wait ~10 seconds, then verify:
```bash
docker exec mcp-mongodb mongosh --quiet --norc \
  "mongodb://${MONGO_USER:-mcp_orch}:${MONGO_PASSWORD}@localhost:27017/?directConnection=true&authSource=admin" \
  --eval 'db.hello().isWritablePrimary'
# Should return: true
```

### 1.8 Verify health

```bash
curl -s http://localhost:8080/health
# Expected: {"status":"healthy","chroma":"healthy","active_sessions":0,...}
```

All three containers should show healthy:
```bash
docker compose ps
```

### 1.9 Create the first owner API key

With `MCP_AUTH_ENABLED=true`, the server needs an owner key before it's useful.
Connect to it once without a key (soft-auth fallback) and create the key:

```bash
# Quick Python one-liner to create owner key via MCP
python3 - <<'EOF'
import json, urllib.request

BASE = "http://localhost:8080/mcp"
headers = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}

def post(payload, session_id=None):
    h = dict(headers)
    if session_id: h["mcp-session-id"] = session_id
    req = urllib.request.Request(BASE, data=json.dumps({**payload,"jsonrpc":"2.0","id":1}).encode(), headers=h, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        sid = r.headers.get("mcp-session-id")
        body = r.read().decode()
    msgs = [json.loads(l[6:]) for chunk in body.split("\n\n") for l in chunk.splitlines() if l.startswith("data: ")]
    return sid, msgs

sid, _ = post({"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"setup","version":"1.0"}}})
urllib.request.urlopen(urllib.request.Request(BASE, data=json.dumps({"jsonrpc":"2.0","method":"notifications/initialized","params":{}}).encode(), headers={**headers,"mcp-session-id":sid}, method="POST"), timeout=10).read()

_, msgs = post({"method":"tools/call","params":{"name":"memory_start_session","arguments":{"project":"junto","claude_instance":"setup","role_description":"initial setup"}}}, sid)
mem_sid = json.loads([m["result"]["content"][0]["text"] for m in msgs if "result" in m][0])["session_id"]

_, msgs = post({"method":"tools/call","params":{"name":"memory_admin","arguments":{"session_id":mem_sid,"action":"create_key","name":"admin-owner","role":"owner"}}}, sid)
result = json.loads([m["result"]["content"][0]["text"] for m in msgs if "result" in m][0])
print("OWNER KEY:", json.dumps(result, indent=2))
EOF
```

**The key is shown ONCE. Copy it to a password manager immediately.**

It will look like: `smk_XXXX...`

### 1.10 Provision team project and user keys

For each developer, you need to create an API key scoped to their project.
Use the owner key you just created. Add `"headers": {"Authorization": "Bearer smk_..."}` to your `~/.mcp.json` quando making these calls, then use any junto session to run:

```
memory_admin(action="create_key", name="junto{Name}-agent", role="agent", projects=["your-project-name"])
```

Example for a team member named Sarah on project `acme`:
```
memory_admin(action="create_key", name="juntoSarah-agent", role="agent", projects=["acme"])
```

**Again: key is shown ONCE. Copy it before moving on.**

Send each developer:
1. Their `smk_...` API key (via secure channel — Slack DM, 1Password share, etc.)
2. The server URL: `http://<your-server-hostname-or-ip>:8080/mcp`
3. Their project name (e.g. `acme`)
4. Link to the team member setup section below

### 1.11 Set up backups

**Do this before anyone starts putting real data in.**

```bash
# Review the scripts first
ls contrib/backup/
# backup-chroma.sh  backup-mongo.sh

# Set up daily cron (edit paths to match your install location)
crontab -e
# Add:
# 0 3 * * * /home/ubuntu/junto-memory/contrib/backup/backup-chroma.sh
# 15 3 * * * /home/ubuntu/junto-memory/contrib/backup/backup-mongo.sh
```

After 24 hours, verify: `ls -la ~/chroma-backups/ ~/mongo-backups/`

Optionally add offsite: `contrib/backup/sync-to-storm.sh` (SSH to a remote host).

### 1.12 Docker auto-restart on host reboot

Docker's `restart: unless-stopped` handles container restarts but not host reboots.
Enable Docker's own autostart:

```bash
sudo systemctl enable docker
```

### 1.13 Network access for your team

Choose one:

**Option A — Tailscale (recommended for remote teams)**
1. Install Tailscale on the server: `curl -fsSL https://tailscale.com/install.sh | sh`
2. `sudo tailscale up`
3. The server's Tailscale hostname becomes the URL your team uses
4. Each team member installs Tailscale on their machine and joins the same tailnet
5. Team members use: `http://<tailscale-hostname>:8080/mcp`

**Option B — LAN only**
Use the server's LAN IP. Works if all developers are on the same network.
`http://<lan-ip>:8080/mcp`

**Option C — Existing VPN**
If your team already has a VPN, put the server behind it. Same pattern as LAN.

---

## PART 2: Team member — Set up your agent

Do this once per machine. You'll need the admin to give you an API key and server URL first.

### 2.1 Prerequisites

```bash
claude --version    # Claude Code CLI
git --version
curl --version
python3 --version   # 3.8+
```

Install Claude Code if missing: https://claude.ai/code

### 2.2 Platform-specific notes — choose your path

**Windows users: pick one of these two paths. Do not mix them.**

| | Windows-native (PowerShell) | WSL2 |
|---|---|---|
| Shell | PowerShell 5.1+ | bash |
| Setup script | `junto-setup.ps1` | `junto-setup.sh` |
| Launcher | `junto-launch.ps1` | `junto-launch.sh` |
| Alias | PowerShell profile | `.bashrc` / `.zshrc` |
| Recommended if | You primarily use Windows tools | You already work in WSL2 |

**Windows-native (PowerShell)** — skip to section 2.3W below.

**WSL2** — continue with section 2.3L.

**macOS / Linux native** — continue with section 2.3L.

---

### 2.3W Windows-native setup (PowerShell, no WSL required)

**Prerequisites (Windows):**
- Claude Code CLI for Windows — download from https://claude.ai/code
- Git for Windows — https://git-scm.com/download/win
- Python 3 — https://python.org/downloads (check "Add to PATH" during install)
- curl — included in Windows 10 1803+; verify: `curl --version` in PowerShell
- Tailscale for Windows (if using Tailscale) — https://tailscale.com/download

**Install Tailscale and verify server reachability:**
```powershell
# After installing Tailscale and joining your team's tailnet:
curl http://<server-hostname>:8080/health
# Expected: {"status":"healthy",...}
```

**Clone the junto launcher:**
```powershell
git clone https://github.com/tlemmons/junto.git "$HOME\.junto"
```

**Run setup:**
```powershell
& "$HOME\.junto\junto-setup.ps1"
```
Answer the same prompts as the bash version (name, API key, server URL, project dir, project name).

**Add the `junto` alias to your PowerShell profile:**
```powershell
# Check if you have a profile file:
Test-Path $PROFILE
# If false, create it:
New-Item -Path $PROFILE -ItemType File -Force

# Add the alias:
Add-Content $PROFILE "`nSet-Alias junto `"$HOME\.junto\junto-launch.ps1`""

# Reload:
. $PROFILE
```

**First launch:**
```powershell
cd C:\code\my-project
junto
```

**Note: junto-check.sh does not run natively on Windows.** For diagnostics, manually verify:
1. `curl http://<server>:8080/health` returns 200
2. `cat "$HOME\.mcp.json"` shows a `junto` entry with `type: http` and a `headers.Authorization` field
3. Claude Code lists `junto` in its MCP servers

---

### 2.3L macOS / Linux / WSL2 setup

**WSL2 extra step:** Add to `~/.wslconfig` (on the Windows side — `C:\Users\YourName\.wslconfig`):
```ini
[wsl2]
networkingMode=mirrored
```
Then restart WSL: `wsl --shutdown` from a Windows PowerShell, reopen WSL.
Without this, WSL2 cannot reach Tailscale routes on the Windows host.

**macOS / Linux native:** No platform-specific setup needed.

### 2.3 Install Tailscale (if using Tailscale for server access)

Follow instructions at https://tailscale.com/download for your OS.
Join your team's tailnet. Verify the server is reachable:
```bash
curl -s http://<server-hostname>:8080/health
# Expected: {"status":"healthy",...}
```

### 2.4 Clone the junto launcher

```bash
git clone https://github.com/tlemmons/junto.git ~/.junto
```

### 2.5 Run setup

```bash
~/.junto/junto-setup.sh
```

The wizard prompts for:
- **Your first name** → becomes `junto{Name}` (e.g. `juntoSarah`)
- **API key** → paste the `smk_...` key the admin gave you
- **Server URL** → `http://<server>:8080/mcp`
- **Project directory** → path to the codebase you'll work on (e.g. `~/code/my-project`)
- **Project name** → the project identifier the admin assigned (e.g. `acme`, lowercase)

Setup automatically:
- Writes `~/.junto/config`
- Registers the MCP server in `~/.mcp.json`
- Configures the junto-inbox plugin in `~/.claude/settings.json`
- Creates a `CLAUDE.md` in your project directory
- Creates `.claude/settings.local.json` with pre-approved tool permissions

### 2.6 Add the `junto` alias

**bash / zsh (macOS, Linux, WSL2):**
```bash
echo 'alias junto="~/.junto/junto-launch.sh"' >> ~/.bashrc
# or ~/.zshrc on macOS / zsh installs
source ~/.bashrc
```

**PowerShell (Windows-native):** — already covered in section 2.3W above.

### 2.7 Run the health check

```bash
~/.junto/junto-check.sh
```

This checks all 15 known failure modes and reports what's broken. Run with `--fix` to auto-repair most issues:

```bash
~/.junto/junto-check.sh --fix
```

Common issues it catches:
- Missing `"type": "http"` in `~/.mcp.json` (required by current Claude Code)
- Missing `channelsEnabled` in settings
- Stale `JUNTO_AGENT`/`JUNTO_PROJECT` hardcoded in config (old setup bug — auto-fixed)
- Server unreachable (Tailscale not connected)

### 2.8 First launch

```bash
cd ~/code/my-project   # your project directory
junto
```

Your terminal should show:
```
junto: launching juntoSarah@acme → http://<server>:8080/mcp
junto: push plugin enabled
```

Then in Claude, type:
```
go
```

Claude will check in with the server, load context, and propose a plan. You'll see it call `memory_start_session` — that's the handshake.

---

## PART 3: Agent — what Claude Code does

This section is for understanding what the agent does at startup and shutdown.
You don't need to configure this — it's driven by the junto system prompt injected at launch.

### 3.1 `go` — start of session

Type `go` at the beginning of every session. The agent:
1. Loads its state from last session (what it was working on)
2. Checks for messages from other agents
3. Queries the shared knowledge base for relevant context
4. Presents a briefing + proposed plan
5. **Waits for your approval before doing anything**

### 3.2 `park` — end of session

Type `park` before closing the window. The agent:
1. Records anything it learned (learnings, gotchas, function registry entries)
2. Saves its state and next steps
3. Ends the session cleanly

**If you close without parking**, the next session starts blind.

### 3.3 Daily workflow

```
cd ~/code/my-project
junto
[agent starts, calls memory_start_session]
go
[agent loads context, proposes plan]
[approve or redirect]
[do work]
park
[agent saves state, ends session]
/clear   (optional — fresh context for next session)
```

---

## PART 4: Known issues and gotchas

Everything on this list was discovered the hard way during SPG team onboarding.

### Server restarts require reconnect

When the junto-memory server restarts (after an update, reboot, etc.), each Claude Code tab must reconnect:
```
/mcp reconnect junto
```
One tab = one `/mcp reconnect`. There is no automatic recovery on the MCP tool path.

Symptoms: `memory_start_session` returns "Tool execution failed" with no body. That's a transport error, not a server error.

### MongoDB healthcheck is a lie

The MongoDB container reports `healthy` even before `rs.initiate()` has run.
If every mongo-backed call fails with `RuntimeError: MongoDB not available`,
the replica set isn't initialized. Re-run step 1.7.

### Chroma volume mount matters

The Chroma data volume MUST be mounted at `/data` inside the container.
An old bug mounted it at `/chroma/chroma` which Chroma silently ignored,
causing a data-loss incident when the container was recreated.
Do not change the volume mount path in `docker-compose.yml`.

### Chroma version: don't downgrade

If the running server is on Chroma 1.4.x (check via `docker exec mcp-chromadb ls /data/`),
do NOT downgrade to 1.2.x — incompatible SQLite schema, data invisible after downgrade.
If upgrading, test on a volume copy first.

### First push batch may be dropped

The junto-inbox plugin may drop the first batch of pushed messages after startup
if Claude Code hasn't finished its channel approval handshake yet.
If you notice missing messages on first launch, add to `~/.junto/config`:
```bash
JUNTO_CHANNEL_DELAY=15000
```
This delays the plugin's first push delivery by 15s to let CC finish.

### Corporate Claude Code / MDM deployments

If your company's MDM framework periodically rewrites `/etc/claude-code/managed-settings.json`,
it can silently strip `channelsEnabled` and break the junto-inbox plugin.
The junto setup script already handles this by pointing `CLAUDE_CODE_REMOTE_SETTINGS_PATH`
at a file the MDM doesn't know about (`~/.claude/managed-remote-settings.json`).
If channel push stops working for no apparent reason, run `junto-check.sh`.

### junto-inbox is not on Anthropic's official plugin allowlist

The launcher uses `--dangerously-load-development-channels` to load the plugin.
This is not a bug — it's the only path for plugins not on Anthropic's allowlist.
You'll see it in the launch command; it's intentional.

### Agent identity: CLAUDE.md is the authority

Your agent's name and project come from `CLAUDE.md` in the directory you launch from.
The `~/.junto/config` file holds your API key and server URL only — it does NOT hold your name.
If you launch from the wrong directory, your agent will either prompt you for a name
or use the directory's basename as a fallback.

### API key provisioning: key shown once

When Tom (or your admin) runs `memory_admin(action="create_key", ...)`, the `smk_...`
value is returned exactly once in that response. If it isn't stored immediately, it's gone
(you can delete the key and create a new one, but you lose the old key).

### `"type": "http"` required in `~/.mcp.json`

Current Claude Code requires the junto MCP entry to include `"type": "http"`.
`junto-setup.sh` writes it correctly, but if you're setting up manually:

```json
{
  "mcpServers": {
    "junto": {
      "type": "http",
      "url": "http://your-server:8080/mcp",
      "headers": { "Authorization": "Bearer smk_..." }
    }
  }
}
```

---

## PART 5: Admin operations reference

### Provisioning a new team member

```
memory_admin(action="create_key", name="junto{Name}-agent", role="agent", projects=["your-project"])
```

Store the returned key and send securely. Key is shown once.

### Checking who is connected

```
memory_list_agents(project="your-project")
```

### Restarting the server (after an update)

```bash
cd ~/junto-memory
git pull
docker compose up -d --build mcp-server
```

Then broadcast a warning so agents can park gracefully (optional but polite):
```
memory_admin(action="broadcast_restart_warning")
```

After restart, each agent tab needs: `/mcp reconnect junto`

### Health check

```bash
curl -s http://localhost:8080/health
# {"status":"healthy","chroma":"healthy","active_sessions":N,...}
```

### Viewing server logs

```bash
docker compose logs -f mcp-server    # live
docker compose logs --tail 100 mcp-server
```

### Verifying backups

```bash
ls -la ~/chroma-backups/
ls -la ~/mongo-backups/
```

---

## PART 6: What to send each new team member

Give each developer:

1. **Their API key**: `smk_...` (via 1Password share or equivalent — not Slack unless DM)
2. **Server URL**: `http://<hostname-or-ip>:8080/mcp`
3. **Project name**: e.g. `acme` (lowercase, matches what the key is scoped to)
4. **This guide** (or at least Part 2 + Part 4)

If they hit issues:

- **macOS / Linux / WSL2:** `~/.junto/junto-check.sh` covers 15 failure modes and has a `--fix` auto-repair mode.
- **Windows-native:** `junto-check.sh` doesn't run natively. Manual triage: `curl http://<server>:8080/health` first (server up or not?), then check `$HOME\.mcp.json` has a `junto` entry with `type`, `url`, and `headers.Authorization`.

`curl -s http://<server>:8080/health` returning 200 vs connection-refused is the fastest triage in either case.

---

---

## PART 7: Getting help and escalation

### The support model

Junto deployments are designed to be self-sufficient after initial setup. The
guide you're reading captures everything we learned the hard way at SPG. Most
issues — server won't start, agent can't connect, plugin not delivering messages
— are covered in Part 4. Run `junto-check.sh` first; it catches the majority of
common problems automatically.

When you hit something the guide doesn't cover, use this escalation path:

```
Your team's agent / your own investigation
        ↓  (not resolved)
GitHub issue on LVT's junto fork  →  Tom + juntoTom triage
        ↓  (code change needed or novel infrastructure issue)
tlemmons/junto public repo or sage
```

Open an issue on `lvt/junto` (your fork), not on `tlemmons/junto` directly.
Tom reviews LVT issues and decides what gets escalated upstream. This keeps
LVT-specific context in LVT's repo and ensures security visibility on anything
that comes back in as a fix.

**What belongs in an issue:**
- What you were trying to do
- The exact error or symptom
- Output of `junto-check.sh` if applicable
- Your platform (Windows/WSL2/macOS/Linux) and Claude Code version

### Initial setup: pair session

For your first deployment, plan a session where your team's admin and Tom work
through the setup together — ideally with one of your developers present too.
The guide covers the known gotchas, but every environment has surprises. A few
hours of paired setup is worth more than days of async back-and-forth.

During that session, Tom can connect directly to your junto server to verify it
from the inside — querying your memory server, checking that agents are checking
in correctly, confirming push delivery is working. This uses a temporary API key
you provision for the session and revoke when done. Your admin stays in control
of access the entire time.

What you need ready for that session:
- Server up and health check passing (`curl http://<server>:8080/health`)
- A temporary owner-tier key created for Tom:
  ```
  memory_admin(action="create_key", name="tom-setup-assist", role="owner")
  ```
  (Revoke it when the session ends: `memory_admin(action="revoke_key", name="tom-setup-assist")`)
- Your server URL accessible from Tom's machine (via Tailscale, VPN, or temporary exposure)
- At least one developer who will be running agents present for the session

### Each deployment improves the next

Every novel issue a new team hits and resolves goes back into this guide and the
`lvt/junto` issue tracker. By the third or fourth team deployment, the guide
handles nearly everything and setup sessions are much shorter. You're not just
setting up your team — you're making it easier for every team after you.

---

## Repos

| Repo | Purpose |
|---|---|
| `tlemmons/junto` | Launcher, setup scripts (bash + PowerShell), templates, this guide |
| `tlemmons/junto-memory` | The MCP server (Docker, Python, MongoDB, ChromaDB) |
| `tlemmons/junto-inbox` | The Claude Code channel plugin |
| `tlemmons/junto-control` | (Optional) Web dashboard for monitoring agents |

## Key files in `tlemmons/junto`

| File | Platform | Purpose |
|---|---|---|
| `junto-setup.sh` | Linux / macOS / WSL2 | First-time setup wizard |
| `junto-setup.ps1` | Windows native | First-time setup wizard |
| `junto-launch.sh` | Linux / macOS / WSL2 | Session launcher |
| `junto-launch.ps1` | Windows native | Session launcher |
| `junto-check.sh` | Linux / macOS / WSL2 | Health check + auto-repair |
| `junto-update.sh` | Linux / macOS / WSL2 | Pull latest launcher updates |
| `templates/render.sh` | Linux / macOS / WSL2 | Render system prompt template |
| `templates/render.ps1` | Windows native | Render system prompt template |
