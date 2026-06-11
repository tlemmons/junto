#!/usr/bin/env bash
# junto-init.sh — initialize or update a project workspace for junto.
#
# Usage:
#   cd ~/code/my-project        # or any subdirectory of it
#   ~/.junto/junto-init.sh
#
# What it does:
#   - Walks up from cwd to find any existing CLAUDE.md (shows inherited context)
#   - Prompts for project name and optional component/subproject
#   - Writes CLAUDE.md in the CURRENT directory
#   - Creates .claude/settings.local.json if missing
#
# Run this once per project or component root directory. After that,
# junto-launch.sh will walk up and find it automatically from any subdirectory.
#
# Re-running is safe — shows current values as defaults.

set -euo pipefail

JUNTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${JUNTO_DIR}/config"
CWD="$(pwd)"

# ── Load agent name from config ────────────────────────────────────────────────

JUNTO_AGENT=""
if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    _tmp_agent=$(grep -m1 '^JUNTO_AGENT=' "$CONFIG" 2>/dev/null \
        | sed 's/^JUNTO_AGENT="\?\([^"]*\)"\?/\1/' || true)
    [[ -n "$_tmp_agent" ]] && JUNTO_AGENT="$_tmp_agent"
fi

# ── Walk up to find nearest existing CLAUDE.md ────────────────────────────────

EXISTING_CLAUDE_MD=""
INHERITED_AGENT=""
INHERITED_PROJECT=""
INHERITED_COMPONENT=""

_walk_up() {
    local dir="$CWD"
    while [[ "$dir" != "$HOME" && "$dir" != "/" ]]; do
        if [[ -f "$dir/CLAUDE.md" ]]; then
            EXISTING_CLAUDE_MD="$dir/CLAUDE.md"
            INHERITED_AGENT=$(grep -m1 'Your name is:.*`' "$dir/CLAUDE.md" 2>/dev/null \
                | sed 's/.*`\([^`]*\)`.*/\1/' || true)
            INHERITED_PROJECT=$(grep -m1 'project="[^"]*"' "$dir/CLAUDE.md" 2>/dev/null \
                | sed 's/.*project="\([^"]*\)".*/\1/' || true)
            INHERITED_COMPONENT=$(grep -m1 'component="[^"]*"' "$dir/CLAUDE.md" 2>/dev/null \
                | sed 's/.*component="\([^"]*\)".*/\1/' || true)
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

_walk_up || true

# ── Display banner ─────────────────────────────────────────────────────────────

echo ""
echo "=== junto-init — project workspace setup ==="
echo "Directory: $CWD"
echo ""

TARGET_CLAUDE_MD="${CWD}/CLAUDE.md"

if [[ -f "$TARGET_CLAUDE_MD" ]]; then
    # Reading existing values as defaults
    current_agent=$(grep -m1 'Your name is:.*`' "$TARGET_CLAUDE_MD" 2>/dev/null \
        | sed 's/.*`\([^`]*\)`.*/\1/' || true)
    current_project=$(grep -m1 'project="[^"]*"' "$TARGET_CLAUDE_MD" 2>/dev/null \
        | sed 's/.*project="\([^"]*\)".*/\1/' || true)
    current_component=$(grep -m1 'component="[^"]*"' "$TARGET_CLAUDE_MD" 2>/dev/null \
        | sed 's/.*component="\([^"]*\)".*/\1/' || true)
    echo "Existing CLAUDE.md found in this directory — updating."
    echo "  Agent:     ${current_agent:-"(not set)"}"
    echo "  Project:   ${current_project:-"(not set)"}"
    echo "  Component: ${current_component:-"(none)"}"
    echo ""
    DEFAULT_AGENT="${current_agent:-$JUNTO_AGENT}"
    DEFAULT_PROJECT="${current_project:-}"
    DEFAULT_COMPONENT="${current_component:-}"
elif [[ -n "$EXISTING_CLAUDE_MD" ]]; then
    echo "Found CLAUDE.md in a parent directory: $EXISTING_CLAUDE_MD"
    echo "  Inherited agent:     ${INHERITED_AGENT:-"(not set)"}"
    echo "  Inherited project:   ${INHERITED_PROJECT:-"(not set)"}"
    echo "  Inherited component: ${INHERITED_COMPONENT:-"(none)"}"
    echo ""
    echo "Creating a NEW CLAUDE.md in $CWD."
    echo "You can inherit the same project/component or set a different one."
    echo ""
    DEFAULT_AGENT="${INHERITED_AGENT:-$JUNTO_AGENT}"
    DEFAULT_PROJECT="${INHERITED_PROJECT:-}"
    DEFAULT_COMPONENT="${INHERITED_COMPONENT:-}"
else
    echo "No existing CLAUDE.md found in this directory or any parent."
    DEFAULT_AGENT="${JUNTO_AGENT:-$(basename "$CWD")}"
    DEFAULT_PROJECT="$(basename "$CWD" | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z0-9-')"
    DEFAULT_COMPONENT=""
fi

# ── Prompts ────────────────────────────────────────────────────────────────────

# Agent name — default from config (~/.junto/config JUNTO_AGENT) or inherit
agent_prompt="Agent name"
[[ -n "$DEFAULT_AGENT" ]] && agent_prompt="${agent_prompt} [${DEFAULT_AGENT}]"
agent_prompt="${agent_prompt}: "
read -rp "$agent_prompt" input_agent
NEW_AGENT="${input_agent:-$DEFAULT_AGENT}"
if [[ -z "$NEW_AGENT" ]]; then
    echo "ERROR: agent name cannot be empty." >&2; exit 1
fi

# Project name
proj_prompt="Project name"
[[ -n "$DEFAULT_PROJECT" ]] && proj_prompt="${proj_prompt} [${DEFAULT_PROJECT}]"
proj_prompt="${proj_prompt}: "
read -rp "$proj_prompt" input_project
NEW_PROJECT="${input_project:-$DEFAULT_PROJECT}"
NEW_PROJECT="$(echo "$NEW_PROJECT" | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z0-9_-')"
if [[ -z "$NEW_PROJECT" ]]; then
    echo "ERROR: project name cannot be empty." >&2; exit 1
fi

# Component (optional)
comp_prompt="Component/subproject"
if [[ -n "$DEFAULT_COMPONENT" ]]; then
    comp_prompt="${comp_prompt} [${DEFAULT_COMPONENT}] (Enter to keep, 'none' to clear)"
else
    comp_prompt="${comp_prompt} (optional — press Enter to skip)"
fi
comp_prompt="${comp_prompt}: "
read -rp "$comp_prompt" input_component

if [[ "$input_component" == "none" ]]; then
    NEW_COMPONENT=""
elif [[ -z "$input_component" ]]; then
    NEW_COMPONENT="$DEFAULT_COMPONENT"
else
    NEW_COMPONENT="$(echo "$input_component" | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z0-9_-')"
fi

# ── Confirm ────────────────────────────────────────────────────────────────────

echo ""
echo "Will write to: $TARGET_CLAUDE_MD"
echo "  Agent:     $NEW_AGENT"
echo "  Project:   $NEW_PROJECT"
if [[ -n "$NEW_COMPONENT" ]]; then
    echo "  Component: $NEW_COMPONENT"
else
    echo "  Component: (none)"
fi
echo ""
read -rp "Confirm? [Y/n]: " confirm
confirm="${confirm:-y}"
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
fi

# ── Write CLAUDE.md ────────────────────────────────────────────────────────────

{
    echo "# ${NEW_AGENT}"
    echo ""
    echo "Your name is: \`${NEW_AGENT}\`"
    echo ""
    echo "<!-- project=\"${NEW_PROJECT}\" -->"
    [[ -n "$NEW_COMPONENT" ]] && echo "<!-- component=\"${NEW_COMPONENT}\" -->"
} > "$TARGET_CLAUDE_MD"

ctx="${NEW_AGENT}@${NEW_PROJECT}"
[[ -n "$NEW_COMPONENT" ]] && ctx="${ctx}:${NEW_COMPONENT}"
echo "CLAUDE.md written — ${ctx}"

# ── Create .claude/settings.local.json if missing ─────────────────────────────

PROJECT_CLAUDE_DIR="${CWD}/.claude"
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
    echo "Created .claude/settings.local.json (junto tools pre-approved)"
else
    echo ".claude/settings.local.json already exists — skipping"
fi

echo ""
echo "Done. Run 'junto' from this directory (or any subdirectory) to start your agent."
