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
#   JUNTO_MEMORY_URL  MCP server URL      (default: http://spg-junto-central:8080/mcp)
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
if [[ -f "$CLAUDE_MD" ]]; then
    if [[ -z "${JUNTO_AGENT:-}" ]]; then
        detected=$(grep -m1 'Your name is:.*`' "$CLAUDE_MD" 2>/dev/null \
            | sed 's/.*`\([^`]*\)`.*/\1/' || true)
        [[ -n "$detected" ]] && JUNTO_AGENT="$detected"
    fi
    if [[ -z "${JUNTO_PROJECT:-}" ]]; then
        detected=$(grep -m1 'project="[^"]*"' "$CLAUDE_MD" 2>/dev/null \
            | sed 's/.*project="\([^"]*\)".*/\1/' || true)
        [[ -n "$detected" ]] && JUNTO_PROJECT="$detected"
    fi
fi

# Apply defaults
JUNTO_AGENT="${JUNTO_AGENT:-workClaude}"
JUNTO_PROJECT="${JUNTO_PROJECT:-junto}"
JUNTO_ROLE="${JUNTO_ROLE:-General work agent}"
JUNTO_MEMORY_URL="${JUNTO_MEMORY_URL:-http://spg-junto-central:8080/mcp}"

if [[ -z "${JUNTO_API_KEY:-}" ]]; then
    echo "junto-launch: JUNTO_API_KEY is not set. Add it to ~/.junto/config or export it." >&2
    exit 1
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

echo "junto: launching ${JUNTO_AGENT}@${JUNTO_PROJECT} → ${JUNTO_MEMORY_URL}" >&2
[[ "$PLUGIN" == "true" ]] && echo "junto: push plugin enabled" >&2

# Launch Claude
if [[ "$PLUGIN" == "true" ]]; then
    exec claude \
        --append-system-prompt-file "$PROMPT_FILE" \
        --channels "plugin:junto-inbox@tlemmons-junto-inbox" \
        ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
else
    exec claude \
        --append-system-prompt-file "$PROMPT_FILE" \
        ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
fi
