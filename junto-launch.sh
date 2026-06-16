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
#   JUNTO_AGENT       Agent name          (default: junto-user)
#   JUNTO_PROJECT     Project name        (default: junto)
#   JUNTO_ROLE        One-line role       (default: General work agent)
#   JUNTO_MEMORY_URL  MCP server URL      (default: http://your-junto-server:8080/mcp)
#   JUNTO_API_KEY     MCP API key         (required)
#   JUNTO_OVERLAY     Path to overlay .md (optional)
#
# Agent identity resolution (in priority order):
#   1. Explicit env vars (JUNTO_AGENT / JUNTO_PROJECT) always win.
#   2. .agent-name file in cwd: one-line file containing the agent name.
#      Written by Claude Code on first startup; preferred over CLAUDE.md parsing.
#   3. CLAUDE.md auto-detection: "Your name is: `X`" line for agent,
#      project="X" comment for project.
#   4. Fallback: basename of cwd (non-interactive) or interactive prompt.

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

# Identity resolution — .agent-name is preferred; CLAUDE.md is fallback.
# Env vars (from config or shell) win if already set — hard override.
CLAUDE_MD="$(pwd)/CLAUDE.md"
AGENT_NAME_FILE="$(pwd)/.agent-name"

# Walk up from cwd toward $HOME to find the nearest CLAUDE.md.
# Stops at $HOME (does not read ~/.claude/CLAUDE.md or above).
# Sets CLAUDE_MD to the found path; leaves it as cwd default if nothing found.
_junto_find_claude_md() {
    [[ -f "$CLAUDE_MD" ]] && return 0   # already in cwd — no walk needed
    local dir
    dir="$(pwd)"
    while [[ "$dir" != "$HOME" && "$dir" != "/" ]]; do
        dir="$(dirname "$dir")"
        if [[ -f "$dir/CLAUDE.md" ]]; then
            CLAUDE_MD="$dir/CLAUDE.md"
            return 0
        fi
    done
    return 0  # no CLAUDE.md found — caller checks CLAUDE_MD variable, not return code
}

_junto_read_agent_name_file() {
    [[ -n "${JUNTO_AGENT:-}" ]] && return 0  # already set by env/config override
    [[ ! -f "$AGENT_NAME_FILE" ]] && return 0
    local a
    a=$(head -1 "$AGENT_NAME_FILE" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$a" ]] && JUNTO_AGENT="$a"
    return 0
}

_junto_read_claude_md() {
    if [[ -n "${JUNTO_AGENT:-}" && -n "${JUNTO_PROJECT:-}" ]]; then
        return  # both already set by env/config override
    fi
    if [[ ! -f "$CLAUDE_MD" ]]; then
        return
    fi
    if [[ -z "${JUNTO_AGENT:-}" ]]; then
        local a
        a=$(grep -m1 'Your name is:.*`' "$CLAUDE_MD" 2>/dev/null \
            | sed 's/.*`\([^`]*\)`.*/\1/' || true)
        [[ -n "$a" ]] && JUNTO_AGENT="$a"
    fi
    if [[ -z "${JUNTO_PROJECT:-}" ]]; then
        local p
        p=$(grep -m1 'project="[^"]*"' "$CLAUDE_MD" 2>/dev/null \
            | sed 's/.*project="\([^"]*\)".*/\1/' || true)
        [[ -n "$p" ]] && JUNTO_PROJECT="$p"
    fi
    if [[ -z "${JUNTO_COMPONENT:-}" ]]; then
        local c
        c=$(grep -m1 'component="[^"]*"' "$CLAUDE_MD" 2>/dev/null \
            | sed 's/.*component="\([^"]*\)".*/\1/' || true)
        [[ -n "$c" ]] && JUNTO_COMPONENT="$c"
    fi
    return 0
}

_junto_init_directory() {
    local default_agent default_project input_agent input_project input_component
    default_agent="$(basename "$(pwd)")"
    default_project="$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z0-9-')"

    echo "" >&2
    echo "junto: No CLAUDE.md found in $(pwd) or any parent directory." >&2
    echo "junto: Enter identity for this directory (permanent — saved to CLAUDE.md)." >&2
    echo "" >&2
    printf "  Agent name        [%s]: " "$default_agent" >/dev/tty
    read -r input_agent </dev/tty
    printf "  Project name      [%s]: " "$default_project" >/dev/tty
    read -r input_project </dev/tty
    printf "  Component/subproject (optional, press Enter to skip): " >/dev/tty
    read -r input_component </dev/tty

    JUNTO_AGENT="${input_agent:-$default_agent}"
    JUNTO_PROJECT="${input_project:-$default_project}"
    JUNTO_COMPONENT="${input_component:-}"

    {
        echo "# ${JUNTO_AGENT}"
        echo ""
        echo "Your name is: \`${JUNTO_AGENT}\`"
        echo ""
        echo "<!-- project=\"${JUNTO_PROJECT}\" -->"
        [[ -n "${JUNTO_COMPONENT}" ]] && echo "<!-- component=\"${JUNTO_COMPONENT}\" -->"
    } > "$CLAUDE_MD"

    echo "" >&2
    local ctx="${JUNTO_AGENT}@${JUNTO_PROJECT}"
    [[ -n "${JUNTO_COMPONENT}" ]] && ctx="${ctx}:${JUNTO_COMPONENT}"
    echo "junto: Created CLAUDE.md — ${ctx}" >&2
    echo "" >&2
}

_junto_find_claude_md
_junto_read_agent_name_file
_junto_read_claude_md

if [[ -z "${JUNTO_AGENT:-}" || -z "${JUNTO_PROJECT:-}" ]]; then
    if [[ -t 0 && -t 1 ]]; then
        _junto_init_directory
    else
        # Non-interactive fallback — use folder name, don't hang
        JUNTO_AGENT="${JUNTO_AGENT:-$(basename "$(pwd)")}"
        JUNTO_PROJECT="${JUNTO_PROJECT:-$(basename "$(pwd)")}"
        echo "junto-launch: no CLAUDE.md in $(pwd), using ${JUNTO_AGENT}@${JUNTO_PROJECT}" >&2
        echo "  Launch interactively to set up identity for this directory." >&2
    fi
elif [[ -f "$CLAUDE_MD" ]]; then
    # CLAUDE.md exists but markers were unreadable — warn, don't re-prompt
    local_agent="${JUNTO_AGENT:-}"
    local_project="${JUNTO_PROJECT:-}"
    if [[ -z "$local_agent" || -z "$local_project" ]]; then
        echo "" >&2
        echo "junto-launch: WARNING — CLAUDE.md found but identity markers are missing" >&2
        [[ -z "${JUNTO_AGENT:-}" ]] && \
            echo "  Agent  : not found (need: Your name is: \`name\`)" >&2
        [[ -z "${JUNTO_PROJECT:-}" ]] && \
            echo "  Project: not found (need: <!-- project=\"name\" -->)" >&2
        echo "  Delete CLAUDE.md and relaunch to re-initialize." >&2
        echo "" >&2
    fi
fi

# Apply defaults for anything still unset
JUNTO_ROLE="${JUNTO_ROLE:-General work agent}"
JUNTO_MEMORY_URL="${JUNTO_MEMORY_URL:-http://your-junto-server:8080/mcp}"

if [[ -z "${JUNTO_API_KEY:-}" ]]; then
    echo "junto-launch: JUNTO_API_KEY is not set. Add it to ~/.junto/config or export it." >&2
    exit 1
fi

# Export so the junto-inbox plugin subprocess inherits the correct identity.
# Without this, the plugin defaults to whatever JUNTO_AGENT was in the parent
# shell, causing live_subscribers to register under the wrong name.
# The plugin reads JUNTO_SHARED_MEMORY_URL (via envVar('SHARED_MEMORY_URL')),
# but the config file uses JUNTO_MEMORY_URL — bridge them here.
JUNTO_SHARED_MEMORY_URL="${JUNTO_MEMORY_URL}"
export JUNTO_AGENT JUNTO_PROJECT JUNTO_ROLE JUNTO_MEMORY_URL JUNTO_SHARED_MEMORY_URL JUNTO_CHANNEL_DELAY JUNTO_COMPONENT

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

_ctx="${JUNTO_AGENT}@${JUNTO_PROJECT}"
[[ -n "${JUNTO_COMPONENT:-}" ]] && _ctx="${_ctx}:${JUNTO_COMPONENT}"
echo "junto: launching ${_ctx} → ${JUNTO_MEMORY_URL}" >&2
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
