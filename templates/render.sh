#!/usr/bin/env bash
# render.sh — render junto-system-prompt.md.tmpl with variable substitution.
#
# Usage:
#   render.sh \
#     --agent NAME --project NAME --role "ROLE STRING" \
#     --shared-memory-url URL \
#     [--cwd PATH] [--plugin-present true|false] [--api-key KEY] \
#     [--overlay PATH] [--extras PATH] [--out PATH]
#
# Writes rendered prompt to --out (or stdout if omitted) and prints the path.
# Exits non-zero with diagnostics if any `{{...}}` token remains unresolved
# OR if base template is missing.
#
# Portable: avoids bash-4-only features (no `${var,,}`); avoids `sed -i`
# (GNU/BSD divergence); escapes sed replacement metachars (`&`, `\`, `!`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${SCRIPT_DIR}/junto-system-prompt.md.tmpl"

AGENT="" PROJECT="" ROLE="" SHARED_MEMORY_URL=""
CWD="$(pwd)" PLUGIN_PRESENT="false" API_KEY=""
OVERLAY="" EXTRAS="" OUT=""

usage() { sed -n '2,15p' "$0"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)              AGENT="$2"; shift 2 ;;
        --project)            PROJECT="$2"; shift 2 ;;
        --role)               ROLE="$2"; shift 2 ;;
        --shared-memory-url)  SHARED_MEMORY_URL="$2"; shift 2 ;;
        --cwd)                CWD="$2"; shift 2 ;;
        --plugin-present)     PLUGIN_PRESENT="$2"; shift 2 ;;
        --api-key)            API_KEY="$2"; shift 2 ;;
        --overlay)            OVERLAY="$2"; shift 2 ;;
        --extras)             EXTRAS="$2"; shift 2 ;;
        --out)                OUT="$2"; shift 2 ;;
        -h|--help)            usage; exit 0 ;;
        *)  echo "render.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Validate required args (hardcoded; avoids bash-4 ${var,,}).
[[ -n "$AGENT"             ]] || { echo "render.sh: missing required --agent"             >&2; exit 2; }
[[ -n "$PROJECT"           ]] || { echo "render.sh: missing required --project"           >&2; exit 2; }
[[ -n "$ROLE"              ]] || { echo "render.sh: missing required --role"              >&2; exit 2; }
[[ -n "$SHARED_MEMORY_URL" ]] || { echo "render.sh: missing required --shared-memory-url" >&2; exit 2; }

# Normalize --plugin-present.
case "$PLUGIN_PRESENT" in
    true|True|TRUE|1|yes)   PLUGIN_PRESENT="true"  ;;
    false|False|FALSE|0|no) PLUGIN_PRESENT="false" ;;
    *) echo "render.sh: --plugin-present must be true|false (got: $PLUGIN_PRESENT)" >&2; exit 2 ;;
esac

[[ -f "$BASE" ]] || { echo "render.sh: base template not found: $BASE" >&2; exit 1; }

# Escape sed replacement metacharacters: backslash, ampersand, and the chosen
# delimiter `!`. Newlines in inputs are not supported (single-line values only).
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&!]/\\&/g'; }

# Conditional auth block: included only if --api-key supplied.
if [[ -n "$API_KEY" ]]; then
    AUTH_BLOCK="- **Auth:** API key is configured via \`Authorization: Bearer\` HTTP header in \`~/.mcp.json\`. Do NOT pass \`api_key\` as a tool argument — the server reads the header automatically. (Key prefix: \`${API_KEY:0:12}...\`)"
else
    AUTH_BLOCK="- **Auth:** No API key configured. Server is in open-auth mode (\`MCP_AUTH_ENABLED=false\`) or this agent runs under default-tier access."
fi

# Conditional plugin/agent session clarifier: shown when plugin is loaded.
if [[ "$PLUGIN_PRESENT" == "true" ]]; then
    PLUGIN_SESSION_BLOCK=$'## Plugin session vs agent session\n\nYour launcher loaded the junto-inbox plugin, which binds its own shared-memory session at startup. Call `attach_session()` FIRST — it attaches you to that session AND returns the server guidelines in one call (no duplicate session, no separate `memory_guidelines` step):\n\n- If `status: ready`: use the returned `session_id` for ALL `mcp__junto__memory_*` calls, and read and obey the returned `guidelines`. Do NOT call `memory_start_session` — it would open a duplicate session.\n- If `status: not_ready`: retry once, then fall back to `memory_start_session` as normal.\n- If `attach_session` is not a known tool (older plugin): call `get_session_id()` instead, then `memory_guidelines` for the rules.\n'
else
    PLUGIN_SESSION_BLOCK=""
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp" "${tmp}.out" 2>/dev/null || true' EXIT

cat "$BASE" > "$tmp"
if [[ -n "$OVERLAY" ]]; then
    [[ -f "$OVERLAY" ]] || { echo "render.sh: overlay missing: $OVERLAY" >&2; exit 1; }
    printf '\n\n## Project overlay\n\n' >> "$tmp"
    cat "$OVERLAY" >> "$tmp"
fi
if [[ -n "$EXTRAS" ]]; then
    [[ -f "$EXTRAS" ]] || { echo "render.sh: extras missing: $EXTRAS" >&2; exit 1; }
    printf '\n\n## Per-agent extras\n\n' >> "$tmp"
    cat "$EXTRAS" >> "$tmp"
fi

# Step 1: substitute single-line values via sed. Replacements are sed-escaped
# to neutralize `&` / `\` / `!`.
sed \
    -e "s!{{agent}}!$(sed_escape "$AGENT")!g" \
    -e "s!{{project}}!$(sed_escape "$PROJECT")!g" \
    -e "s!{{role}}!$(sed_escape "$ROLE")!g" \
    -e "s!{{shared_memory_url}}!$(sed_escape "$SHARED_MEMORY_URL")!g" \
    -e "s!{{cwd}}!$(sed_escape "$CWD")!g" \
    -e "s!{{plugin_present}}!$(sed_escape "$PLUGIN_PRESENT")!g" \
    "$tmp" > "${tmp}.s1"

# Step 2: line-by-line replacement for multi-line blocks. Each block
# placeholder MUST occupy its own line in the template — this is a documented
# template-authoring constraint, validated by reading the template source.
# An empty conditional block (e.g. plugin not present) produces zero lines.
while IFS= read -r line; do
    case "$line" in
        '{{auth_block}}')
            printf '%s\n' "$AUTH_BLOCK"
            ;;
        '{{plugin_session_block}}')
            [[ -n "$PLUGIN_SESSION_BLOCK" ]] && printf '%s\n' "$PLUGIN_SESSION_BLOCK"
            ;;
        *)
            printf '%s\n' "$line"
            ;;
    esac
done < "${tmp}.s1" > "$tmp"
rm -f "${tmp}.s1"

# Safety: fail loud on unresolved tokens.
if remaining=$(grep -En '{{[^}]+}}' "$tmp" || true); [[ -n "$remaining" ]]; then
    echo "render.sh: unresolved tokens remain — refusing to ship:" >&2
    echo "$remaining" >&2
    exit 3
fi

if [[ -n "$OUT" ]]; then
    out_dir=$(dirname "$OUT")
    [[ -d "$out_dir" ]] || mkdir -p "$out_dir"
    mv "$tmp" "$OUT"
    trap - EXIT
    echo "$OUT"
else
    cat "$tmp"
fi
