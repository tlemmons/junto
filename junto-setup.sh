#!/usr/bin/env bash
# junto-setup.sh — first-time setup wizard for new Junto users.
#
# Usage:
#   ~/.junto/junto-setup.sh
#
# Run once per machine. Prompts for name, API key, server URL, and project
# directory, then writes ~/.junto/config, creates a starter CLAUDE.md in
# the project directory, and launches Claude in first-run onboarding mode.
#
# Re-running is safe — existing config, CLAUDE.md, managed-remote-settings.json,
# and settings.local.json are not overwritten; missing pieces are added.
#
# After setup, use the standard launcher for all future sessions:
#   cd <project-dir> && ~/.junto/junto-launch.sh

set -euo pipefail

JUNTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${JUNTO_DIR}/config"
FIRST_RUN_OVERLAY="${JUNTO_DIR}/templates/overlays/first-run.md"

echo ""
echo "=== Junto First-Run Setup ==="
echo ""

# ── Prerequisites ──────────────────────────────────────────────────────────────

if ! command -v claude &>/dev/null; then
    echo "ERROR: 'claude' CLI not found. Install Claude Code first."
    echo "  https://claude.ai/code"
    exit 1
fi

if ! command -v curl &>/dev/null; then
    echo "ERROR: 'curl' is required but not found."
    exit 1
fi

# ── Collect user info ──────────────────────────────────────────────────────────

# If config already exists, load it as defaults
if [[ -f "$CONFIG" ]]; then
    echo "Existing config found at ${CONFIG} — using it as defaults."
    echo "(Press Enter to keep each value, or type a new one.)"
    echo ""
    # shellcheck disable=SC1090
    source "$CONFIG"
fi

# Name
existing_agent="${JUNTO_AGENT:-}"
read -rp "Your first name (will become junto{Name} agent identity, e.g. juntoSarah)$(
    [[ -n "$existing_agent" ]] && echo " [${existing_agent}]"
): " USER_FIRST
if [[ -z "$USER_FIRST" ]]; then
    if [[ -n "$existing_agent" ]]; then
        # Strip "junto" prefix to get the first name
        USER_FIRST="${existing_agent#junto}"
    else
        echo "ERROR: Name cannot be empty." >&2; exit 1
    fi
fi
# Capitalize first letter (portable — bash 3.2+, macOS-safe)
first_char=$(echo "${USER_FIRST:0:1}" | tr '[:lower:]' '[:upper:]')
USER_FIRST="${first_char}${USER_FIRST:1}"
JUNTO_AGENT="junto${USER_FIRST}"
echo "  Agent identity: ${JUNTO_AGENT}"
echo ""

# API key
existing_key="${JUNTO_API_KEY:-}"
if [[ -n "$existing_key" ]]; then
    read -rp "Junto API key [${existing_key:0:12}...] (press Enter to keep): " new_key
    JUNTO_API_KEY="${new_key:-$existing_key}"
else
    echo "Paste your Junto API key (starts with smk_):"
    read -rp "API key: " JUNTO_API_KEY
fi
if [[ -z "$JUNTO_API_KEY" ]]; then
    echo "ERROR: API key cannot be empty." >&2; exit 1
fi
echo ""

# Server URL
DEFAULT_URL="http://your-junto-server:8080/mcp"
existing_url="${JUNTO_MEMORY_URL:-$DEFAULT_URL}"
read -rp "Server URL [${existing_url}]: " url_input
JUNTO_MEMORY_URL="${url_input:-$existing_url}"
echo ""

JUNTO_ROLE="General agent"

# Project dir
existing_dir="${PROJECT_DIR:-$HOME}"
read -rp "Path to your primary work directory (e.g. ~/code/your-project) [${existing_dir}]: " dir_input
PROJECT_DIR="${dir_input:-$existing_dir}"
PROJECT_DIR="${PROJECT_DIR/#\~/$HOME}"
PROJECT_DIR="$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$PROJECT_DIR")"
mkdir -p "$PROJECT_DIR"
echo "  Project dir: ${PROJECT_DIR}"
echo ""

# Project name — derived from folder, user confirms or changes
dir_basename="$(basename "$PROJECT_DIR")"
# Lowercase and strip non-alphanumeric (portable, bash 3.2 safe)
default_project="$(echo "$dir_basename" | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z0-9-')"
existing_project="${JUNTO_PROJECT:-$default_project}"
echo "Project identifier — this becomes your agent's context tag (e.g. juntoRoy@ispy)."
echo "  Use the exact project name Tom assigned to your API key (lowercase)."
echo "  Common values: awareness, ispy, junto"

while true; do
    read -rp "Project name [${existing_project}]: " project_input
    JUNTO_PROJECT="${project_input:-$existing_project}"

    # Enforce lowercase
    project_lower="$(echo "$JUNTO_PROJECT" | tr '[:upper:]' '[:lower:]' | tr '-' '_' | tr ' ' '_')"
    if [[ "$JUNTO_PROJECT" != "$project_lower" ]]; then
        echo "  → Lowercased to: ${project_lower}"
        JUNTO_PROJECT="$project_lower"
    fi

    # Live validation — skip if server unreachable (don't block setup)
    if command -v python3 &>/dev/null && [[ -f "${JUNTO_DIR}/check-auth.py" ]]; then
        printf "  Validating key + project against server... "
        auth_result=$(python3 "${JUNTO_DIR}/check-auth.py" "$JUNTO_MEMORY_URL" "$JUNTO_API_KEY" "$JUNTO_PROJECT" 2>/dev/null || echo "error")
        case "$auth_result" in
            ok)
                echo "✓"
                break
                ;;
            invalid_key)
                echo "✗"
                echo "  ERROR: API key is invalid or not recognized by the server."
                echo "  Check your key and server URL, then re-run junto-setup.sh."
                exit 1
                ;;
            permission_denied)
                echo "✗"
                echo "  ERROR: Your API key cannot access project '${JUNTO_PROJECT}'."
                echo "  Contact Tom to confirm which project names your key is scoped to."
                existing_project="$JUNTO_PROJECT"
                ;;
            unreachable)
                echo "skipped (server unreachable)"
                echo "  Warning: could not reach ${JUNTO_MEMORY_URL} — check Tailscale."
                echo "  Proceeding anyway; junto-check will re-verify when connected."
                break
                ;;
            *)
                echo "skipped (unexpected result: ${auth_result})"
                break
                ;;
        esac
    else
        break
    fi
done

echo "  Agent context: ${JUNTO_AGENT}@${JUNTO_PROJECT}"
echo ""

# ── Write config ───────────────────────────────────────────────────────────────

cat > "$CONFIG" << EOF
# Junto local configuration — generated by junto-setup.sh
# Edit these values for your machine. Do not commit this file.

# API key for the shared memory server
JUNTO_API_KEY="${JUNTO_API_KEY}"

# Shared memory server URL
JUNTO_MEMORY_URL="${JUNTO_MEMORY_URL}"

# Role description
JUNTO_ROLE="${JUNTO_ROLE}"

# Last setup working directory
PROJECT_DIR="${PROJECT_DIR}"

# Agent name and project are set per-directory in CLAUDE.md (auto-detected by junto-launch.sh).
# junto-launch.sh prompts for these on first launch in any new directory.
# Uncomment below only to hard-override for ALL directories on this machine.
# JUNTO_AGENT=""
# JUNTO_PROJECT=""
EOF
chmod 600 "$CONFIG"
echo "Config written to ${CONFIG}"

# ── Register MCP server in ~/.mcp.json ────────────────────────────────────────

MCP_JSON="${HOME}/.mcp.json"
python3 - "$MCP_JSON" "$JUNTO_MEMORY_URL" "$JUNTO_API_KEY" << 'PYEOF'
import json, sys
path, url, key = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f: data = json.load(f)
except Exception: data = {}
data.setdefault("mcpServers", {})["junto"] = {
    "type": "http",
    "url": url
}
with open(path, "w") as f: json.dump(data, f, indent=2)
print(f"MCP server 'junto' registered in {path}")
PYEOF

# ── Create managed-remote-settings.json ───────────────────────────────────────
# This stable file is pointed to by CLAUDE_CODE_REMOTE_SETTINGS_PATH so that
# Claude Code's periodic org-policy fetches cannot wipe our channelsEnabled
# setting from ~/.claude/remote-settings.json.

MANAGED_SETTINGS="${HOME}/.claude/managed-remote-settings.json"
if [[ ! -f "$MANAGED_SETTINGS" ]]; then
    cat > "$MANAGED_SETTINGS" << 'EOF'
{
  "channelsEnabled": true,
  "allowedChannelPlugins": [
    { "marketplace": "tlemmons-junto-inbox", "plugin": "junto-inbox" }
  ]
}
EOF
    echo "Created ${MANAGED_SETTINGS}"
    echo "  (If your deployment uses OTEL telemetry, ask your admin for the token to add later.)"
else
    # File exists — merge channel keys in case they're missing (safe for files
    # that already have the OTEL block).
    python3 - "$MANAGED_SETTINGS" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f: data = json.load(f)
except Exception: data = {}
changed = False
if not data.get("channelsEnabled"):
    data["channelsEnabled"] = True; changed = True
entry = {"marketplace": "tlemmons-junto-inbox", "plugin": "junto-inbox"}
existing = data.get("allowedChannelPlugins", [])
keys = {(p.get("marketplace"), p.get("plugin")) for p in existing}
if (entry["marketplace"], entry["plugin"]) not in keys:
    existing.append(entry); data["allowedChannelPlugins"] = existing; changed = True
if changed:
    with open(path, "w") as f: json.dump(data, f, indent=2)
    print(f"Merged channel entries into {path}")
else:
    print(f"{path} already has required entries — no changes")
PYEOF
fi

# ── Create ensure-channel-settings.sh hook ────────────────────────────────────
# Belt-and-suspenders: patches remote-settings.json on every Stop/UserPromptSubmit
# in case Claude Code overwrites it with a fresh org policy fetch.

mkdir -p "${HOME}/.claude/hooks"
HOOK_SCRIPT="${HOME}/.claude/hooks/ensure-channel-settings.sh"
cat > "$HOOK_SCRIPT" << 'BASH_EOF'
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
BASH_EOF
chmod +x "$HOOK_SCRIPT"
echo "Hook created at ${HOOK_SCRIPT}"

# ── Register plugin, env path, and hook in ~/.claude/settings.json ────────────

CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
python3 - "$CLAUDE_SETTINGS" "$MANAGED_SETTINGS" << 'PYEOF'
import json, sys
settings_path, managed_path = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f: data = json.load(f)
except Exception: data = {}

# Plugin marketplace + permissions
data.setdefault("extraKnownMarketplaces", {})["tlemmons-junto-inbox"] = {
    "source": {"source": "github", "repo": "tlemmons/junto-inbox"}
}
data.setdefault("enabledPlugins", {})["junto-inbox@tlemmons-junto-inbox"] = True
plugins = data.setdefault("allowedChannelPlugins", [])
entry = {"marketplace": "tlemmons-junto-inbox", "plugin": "junto-inbox"}
if entry not in plugins:
    plugins.append(entry)
data["channelsEnabled"] = True

# Model: Opus in plan mode (/plan), Sonnet otherwise.
# Sonnet 1M context window is set at launch time via ANTHROPIC_DEFAULT_SONNET_MODEL in junto-launch.sh.
if "model" not in data:
    data["model"] = "opusplan"

# Redirect Claude Code's org-policy cache to our stable file
data.setdefault("env", {})["CLAUDE_CODE_REMOTE_SETTINGS_PATH"] = managed_path

# Register ensure-channel-settings hook (idempotent)
hook_cmd = "bash ~/.claude/hooks/ensure-channel-settings.sh"
hook_entry = {"type": "command", "command": hook_cmd}
hooks = data.setdefault("hooks", {})
for event in ["Stop", "UserPromptSubmit"]:
    event_hooks = hooks.setdefault(event, [])
    already = any(
        any(h.get("command") == hook_cmd for h in w.get("hooks", []))
        for w in event_hooks
    )
    if not already:
        event_hooks.append({"hooks": [hook_entry]})

with open(settings_path, "w") as f: json.dump(data, f, indent=2)
print(f"Settings updated in {settings_path}")
PYEOF

# ── Write CLAUDE.md ────────────────────────────────────────────────────────────

CLAUDE_MD="${PROJECT_DIR}/CLAUDE.md"
if [[ ! -f "$CLAUDE_MD" ]]; then
    cat > "$CLAUDE_MD" << EOF
# ${JUNTO_AGENT}

Your name is: \`${JUNTO_AGENT}\`

<!-- project="${JUNTO_PROJECT}" -->
EOF
    echo "CLAUDE.md created at ${CLAUDE_MD}"
else
    echo "CLAUDE.md already exists at ${CLAUDE_MD} — skipping creation"
    echo "  Make sure it contains: Your name is: \`${JUNTO_AGENT}\`"
fi
echo ""

# ── Create per-project settings.local.json ────────────────────────────────────
# Grants the memory tools auto-approval so Claude doesn't prompt on every call.

PROJECT_CLAUDE_DIR="${PROJECT_DIR}/.claude"
PROJECT_LOCAL_SETTINGS="${PROJECT_CLAUDE_DIR}/settings.local.json"
mkdir -p "$PROJECT_CLAUDE_DIR"

if [[ ! -f "$PROJECT_LOCAL_SETTINGS" ]]; then
    cat > "$PROJECT_LOCAL_SETTINGS" << 'EOF'
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
EOF
    echo "Project settings created at ${PROJECT_LOCAL_SETTINGS}"
else
    echo "settings.local.json already exists at ${PROJECT_LOCAL_SETTINGS} — skipping"
fi
echo ""

# ── Connectivity check ─────────────────────────────────────────────────────────

# Strip trailing /mcp to get the base URL for the health endpoint
BASE_URL="${JUNTO_MEMORY_URL%/mcp}"
echo -n "Testing server connectivity at ${BASE_URL}/health ... "
if curl -sf "${BASE_URL}/health" &>/dev/null; then
    echo "OK"
else
    echo "UNREACHABLE"
    echo ""
    echo "  Warning: the server is not reachable right now."
    echo "  If the server is on a Tailscale/VPN-routed host, confirm you're on the right network."
    echo "  On WSL2: check that ~/.wslconfig has [wsl2] networkingMode=mirrored"
    echo "  You can proceed — the agent will report the issue when it starts."
fi
echo ""

# ── Launch in first-run onboarding mode ───────────────────────────────────────

echo "Launching ${JUNTO_AGENT}@${JUNTO_PROJECT} in first-run onboarding mode..."
echo "(Your agent will walk you through the rest of the setup.)"
echo ""

cd "$PROJECT_DIR"
export JUNTO_OVERLAY="${FIRST_RUN_OVERLAY}"
exec bash "${JUNTO_DIR}/junto-launch.sh"
