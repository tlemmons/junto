#!/usr/bin/env bash
# junto-launch.sh — launch Claude Code with the junto system prompt.
#
# Usage:
#   ~/.junto/junto-launch.sh [--no-plugin] [claude args...]
#
# Options:
#   --no-plugin   Disable junto-inbox channel push (push is on by default).
#
# Environment overrides (also settable in ~/.junto/config):
#   JUNTO_AGENT       Agent name          (default: workClaude)
#   JUNTO_PROJECT     Project name        (default: junto)
#   JUNTO_ROLE        One-line role       (default: General work agent)
#   JUNTO_MEMORY_URL  MCP server URL      (default: http://localhost:8080/mcp)
#   JUNTO_API_KEY     MCP API key         (required)
#   JUNTO_OVERLAY     Path to overlay .md (optional)
#
# Agent/project auto-detection from CLAUDE.md:
#   If the current directory contains a CLAUDE.md with a "Your name is: `X`"
#   line, JUNTO_AGENT is set from it. If it contains project="X" in a
#   memory_start_session call, JUNTO_PROJECT is set from it.
#   Explicit env vars always win over auto-detection.

set -euo pipefail

JUNTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${JUNTO_DIR}/config"
TEMPLATES="${JUNTO_DIR}/templates"

# Load config file defaults (does not override env vars already set)
if [[ -f "$CONFIG" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG"
    set +a
fi

# Parse --no-plugin flag and pass remaining args to claude
PLUGIN=true
CLAUDE_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--no-plugin" ]]; then
        PLUGIN=false
    else
        CLAUDE_ARGS+=("$arg")
    fi
done

# Auto-detect agent/project from CLAUDE.md in cwd (env vars win if already set)
CLAUDE_MD="$(pwd)/CLAUDE.md"
AGENT_DETECTED=false
PROJECT_DETECTED=false

if [[ -f "$CLAUDE_MD" ]]; then
    if [[ -n "${JUNTO_AGENT:-}" ]]; then
        AGENT_DETECTED=true
    else
        detected=$(grep -m1 'Your name is:.*`' "$CLAUDE_MD" 2>/dev/null \
            | sed 's/.*Your name is:[^`]*`\([^`]*\)`.*/\1/' || true)
        if [[ -n "$detected" ]]; then
            JUNTO_AGENT="$detected"
            AGENT_DETECTED=true
        fi
    fi
    if [[ -n "${JUNTO_PROJECT:-}" ]]; then
        PROJECT_DETECTED=true
    else
        detected=$(grep -m1 'project="[^"]*"' "$CLAUDE_MD" 2>/dev/null \
            | sed 's/.*project="\([^"]*\)".*/\1/' || true)
        if [[ -n "$detected" ]]; then
            JUNTO_PROJECT="$detected"
            PROJECT_DETECTED=true
        fi
    fi
fi

# Apply defaults
JUNTO_AGENT="${JUNTO_AGENT:-workClaude}"
JUNTO_PROJECT="${JUNTO_PROJECT:-junto}"
JUNTO_ROLE="${JUNTO_ROLE:-General work agent}"
JUNTO_MEMORY_URL="${JUNTO_MEMORY_URL:-http://localhost:8080/mcp}"

# Export so the junto-inbox plugin subprocess inherits the correct identity.
# Without this, the plugin defaults to whatever JUNTO_AGENT was in the parent
# shell, causing live_subscribers to register under the wrong name.
export JUNTO_AGENT JUNTO_PROJECT JUNTO_ROLE JUNTO_MEMORY_URL JUNTO_CHANNEL_DELAY

if [[ -z "${JUNTO_API_KEY:-}" ]]; then
    echo "junto-launch: JUNTO_API_KEY is not set. Add it to ~/.junto/config or export it." >&2
    exit 1
fi

# Identity sanity check — warn before launch if we couldn't read identity from CLAUDE.md
if [[ ! -f "$CLAUDE_MD" ]]; then
    echo "" >&2
    echo "junto-launch: WARNING — no CLAUDE.md found in $(pwd)" >&2
    echo "  Falling back to defaults: ${JUNTO_AGENT}@${JUNTO_PROJECT}" >&2
    echo "  To configure this directory: ~/.junto/junto-setup.sh" >&2
    echo "" >&2
elif [[ "$AGENT_DETECTED" == "false" || "$PROJECT_DETECTED" == "false" ]]; then
    echo "" >&2
    echo "junto-launch: WARNING — CLAUDE.md found but identity markers are missing or unreadable" >&2
    [[ "$AGENT_DETECTED" == "false" ]] && \
        echo "  Agent : ${JUNTO_AGENT} (default — 'Your name is: \`X\`' not found in CLAUDE.md)" >&2
    [[ "$PROJECT_DETECTED" == "false" ]] && \
        echo "  Project: ${JUNTO_PROJECT} (default — '<!-- project=\"X\" -->' not found in CLAUDE.md)" >&2
    echo "  To fix: re-run ~/.junto/junto-setup.sh in $(pwd)" >&2
    echo "" >&2
fi

# Pre-flight: ensure channel settings are in remote-settings.json if using plugin
if [[ "$PLUGIN" == "true" ]] && [[ -f "${HOME}/.claude/hooks/ensure-channel-settings.sh" ]]; then
    bash "${HOME}/.claude/hooks/ensure-channel-settings.sh"
fi

# Render the system prompt
RENDER_ARGS=(
    --agent "$JUNTO_AGENT"
    --project "$JUNTO_PROJECT"
    --role "$JUNTO_ROLE"
    --shared-memory-url "$JUNTO_MEMORY_URL"
    --cwd "$(pwd)"
    --api-key "$JUNTO_API_KEY"
    --out "/tmp/junto-${JUNTO_AGENT}-${JUNTO_PROJECT}-prompt.md"
)

[[ "$PLUGIN" == "true" ]] && RENDER_ARGS+=(--plugin-present true)
[[ -n "${JUNTO_OVERLAY:-}" ]] && RENDER_ARGS+=(--overlay "$JUNTO_OVERLAY")

PROMPT_FILE=$(bash "${TEMPLATES}/render.sh" "${RENDER_ARGS[@]}")

# Opt into Sonnet 1M context window — same per-token cost as 200K, 5x working context.
# Reduces compaction frequency significantly. Override by exporting this var before launch.
export ANTHROPIC_DEFAULT_SONNET_MODEL="${ANTHROPIC_DEFAULT_SONNET_MODEL:-claude-sonnet-4-6[1m]}"

# Export remote-settings path so Claude Code sees it before its own settings.json
# env-block is processed. This ensures managed-remote-settings.json (which contains
# channelsEnabled + allowedChannelPlugins) is loaded before the plugin MCP handshake,
# eliminating the ~10s "channels not approved by org" window at startup.
export CLAUDE_CODE_REMOTE_SETTINGS_PATH="${HOME}/.claude/managed-remote-settings.json"

echo "junto: launching ${JUNTO_AGENT}@${JUNTO_PROJECT} → ${JUNTO_MEMORY_URL}" >&2
[[ "$PLUGIN" == "true" ]] && echo "junto: push plugin enabled" >&2

# Launch Claude
if [[ "$PLUGIN" == "true" ]]; then
    exec claude \
        --append-system-prompt-file "$PROMPT_FILE" \
        --dangerously-load-development-channels "plugin:junto-inbox@tlemmons-junto-inbox" \
        ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
else
    exec claude \
        --append-system-prompt-file "$PROMPT_FILE" \
        ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
fi
