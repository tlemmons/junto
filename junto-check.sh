#!/usr/bin/env bash
# junto-check.sh — verify junto installation and diagnose common issues.
#
# Usage:
#   ~/.junto/junto-check.sh [--fix] [--project-dir DIR] [--quiet]
#
# Options:
#   --fix          Auto-apply safe fixes without interactive prompts
#   --project-dir  Project directory to check (default: current directory)
#   --quiet        Only print failures and warnings, suppress PASS lines
#
# Exit code: 0 = all checks pass (or fixed), 1 = one or more failures remain

set -euo pipefail

JUNTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Args ──────────────────────────────────────────────────────────────────────

AUTO_FIX=false
QUIET=false
PROJECT_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)         AUTO_FIX=true ;;
        --quiet)       QUIET=true ;;
        --project-dir) PROJECT_DIR="$2"; shift ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# //'
            exit 0 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

# ── Colors ────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Counters ──────────────────────────────────────────────────────────────────

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
FIX_COUNT=0

# ── Output helpers ────────────────────────────────────────────────────────────

_pass()  { (( PASS_COUNT++ )) || true; [[ "$QUIET" == "true" ]] || printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
_warn()  { (( WARN_COUNT++ )) || true; printf "  ${YELLOW}⚠${RESET} %s\n" "$1"; }
_fail()  { (( FAIL_COUNT++ )) || true; printf "  ${RED}✗${RESET} %s\n" "$1"; }
_info()  { [[ "$QUIET" == "true" ]] || printf "    ${CYAN}→${RESET} %s\n" "$1"; }
_fixed() { (( FIX_COUNT++ )) || true; (( FAIL_COUNT-- )) || true; printf "  ${GREEN}⚙${RESET} FIXED: %s\n" "$1"; }

_section() {
    echo ""
    printf "${BOLD}%s${RESET}\n" "$1"
}

# Ask user before applying a fix. Returns 0 (apply) or 1 (skip).
_ask_fix() {
    local prompt="$1"
    if [[ "$AUTO_FIX" == "true" ]]; then
        return 0
    fi
    # Skip interactive prompts in non-interactive environments
    if ! ( exec 3</dev/tty ) &>/dev/null 2>&1; then
        _info "Skipping auto-fix (no TTY) — re-run interactively or use --fix"
        return 1
    fi
    printf "    ${YELLOW}Fix?${RESET} %s [y/N] " "$prompt"
    local answer=""
    read -r answer </dev/tty 2>/dev/null || true
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ── Section 1: Prerequisites ──────────────────────────────────────────────────

check_prerequisites() {
    _section "1. Prerequisites"

    if command -v bun &>/dev/null; then
        _pass "bun installed ($(bun --version 2>/dev/null || echo 'version unknown'))"
    else
        _fail "bun not installed — required for junto-inbox channel plugin"
        _info "Install: curl -fsSL https://bun.sh/install | bash"
        _info "Then re-open your shell or run: source ~/.bashrc"
    fi

    if command -v claude &>/dev/null; then
        _pass "claude CLI installed"
    else
        _fail "claude CLI not installed"
        _info "Install at: https://claude.ai/code"
    fi

    if command -v git &>/dev/null; then
        _pass "git installed"
    else
        _fail "git not installed — required for ~/.junto updates"
    fi

    if command -v curl &>/dev/null; then
        _pass "curl installed"
    else
        _fail "curl not installed — required for health checks"
    fi
}

# ── Section 2: Network / Tailscale ────────────────────────────────────────────

SPG_IP="100.83.241.96"
SPG_HOST="spg-junto-central"
SPG_PORT="8080"

check_network() {
    _section "2. Network / Tailscale"

    # Tailscale installed — handle WSL (Windows-native Tailscale, not in Linux PATH)
    local tailscale_cmd=""
    if command -v tailscale &>/dev/null; then
        tailscale_cmd="tailscale"
    elif [[ -f "/mnt/c/Program Files/Tailscale/tailscale.exe" ]]; then
        tailscale_cmd="/mnt/c/Program Files/Tailscale/tailscale.exe"
    fi

    if [[ -z "$tailscale_cmd" ]]; then
        _fail "tailscale not found (checked PATH and /mnt/c/Program Files/Tailscale/)"
        _info "Install at: https://tailscale.com/download"
        # Don't return — still check hostname/health which may work via Windows Tailscale
    else
        _pass "tailscale found (${tailscale_cmd})"

        # Tailscale running
        if ! "$tailscale_cmd" status &>/dev/null 2>&1; then
            _fail "tailscale is not running or not connected"
            _info "Start Tailscale and connect to the LVT tailnet"
        else
            _pass "tailscale running"
        fi
    fi

    # Hostname resolution (MagicDNS)
    local resolved=false
    if getent hosts "${SPG_HOST}" &>/dev/null 2>&1; then
        _pass "spg-junto-central resolves via MagicDNS"
        resolved=true
    elif host "${SPG_HOST}" &>/dev/null 2>&1; then
        _pass "spg-junto-central resolves via DNS"
        resolved=true
    else
        _fail "spg-junto-central does not resolve — MagicDNS may be off"

        # Offer MagicDNS fix
        if _ask_fix "enable MagicDNS: sudo tailscale set --accept-dns=true"; then
            if [[ -n "$tailscale_cmd" ]] && sudo "$tailscale_cmd" set --accept-dns=true 2>/dev/null; then
                _fixed "MagicDNS enabled"
                resolved=true
            else
                _warn "sudo tailscale set failed — try manually"
            fi
        fi

        # Offer /etc/hosts fallback
        if [[ "$resolved" == "false" ]]; then
            if grep -q "${SPG_HOST}" /etc/hosts 2>/dev/null; then
                _pass "/etc/hosts fallback entry exists for spg-junto-central"
                resolved=true
            else
                _info "Fallback: add IP entry to /etc/hosts"
                if _ask_fix "add '${SPG_IP} ${SPG_HOST}' to /etc/hosts (requires sudo)"; then
                    if echo "${SPG_IP} ${SPG_HOST}" | sudo tee -a /etc/hosts &>/dev/null; then
                        _fixed "/etc/hosts entry added for spg-junto-central"
                        resolved=true
                    else
                        _warn "Could not write to /etc/hosts — try: echo '${SPG_IP} ${SPG_HOST}' | sudo tee -a /etc/hosts"
                    fi
                fi
            fi
        fi
    fi

    # IP reachability (ping, quick)
    if ping -c1 -W2 "${SPG_IP}" &>/dev/null 2>&1; then
        _pass "spg-junto-central IP (${SPG_IP}) is reachable"
    else
        _warn "spg-junto-central IP (${SPG_IP}) ping failed — may be blocked by firewall (not always fatal)"
    fi

    # Port 8080 open
    local port_open=false
    if command -v nc &>/dev/null; then
        if nc -zv "${SPG_HOST}" "${SPG_PORT}" &>/dev/null 2>&1; then
            port_open=true
        fi
    elif ( exec 3<>/dev/tcp/"${SPG_HOST}"/"${SPG_PORT}" ) &>/dev/null 2>&1; then
        port_open=true
    fi

    if [[ "$port_open" == "true" ]]; then
        _pass "port ${SPG_PORT} open on spg-junto-central"
    else
        _fail "port ${SPG_PORT} not reachable on spg-junto-central"
        _info "Check Tailscale ACL policy — your node may not have access"
        _info "Test: nc -zv ${SPG_HOST} ${SPG_PORT}"
    fi

    # Health endpoint
    local health_status
    health_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "http://${SPG_HOST}:${SPG_PORT}/health" 2>/dev/null || echo "000")

    if [[ "$health_status" == "200" ]]; then
        _pass "health endpoint returns 200"
    elif [[ "$health_status" == "503" ]]; then
        _warn "health endpoint returns 503 — server up but a backend (Chroma?) is unhealthy"
    elif [[ "$health_status" == "000" ]]; then
        _fail "health endpoint unreachable (timeout or connection refused)"
    else
        _warn "health endpoint returned HTTP ${health_status} (expected 200)"
    fi
}

# ── Section 3: Claude Code Config ─────────────────────────────────────────────

check_claude_code() {
    _section "3. Claude Code Config"

    local claude_dir="${HOME}/.claude"

    # managed-remote-settings.json
    local mremote="${claude_dir}/managed-remote-settings.json"
    if [[ ! -f "$mremote" ]]; then
        _fail "managed-remote-settings.json missing (${mremote})"
        if _ask_fix "create managed-remote-settings.json with channelsEnabled + allowedChannelPlugins"; then
            python3 - "$mremote" <<'PYEOF'
import json, sys
path = sys.argv[1]
content = {
    "channelsEnabled": True,
    "allowedChannelPlugins": [
        {"marketplace": "tlemmons-junto-inbox", "plugin": "junto-inbox"}
    ]
}
with open(path, 'w') as f:
    json.dump(content, f, indent=2)
print(f"  Created {path}")
PYEOF
            _fixed "created managed-remote-settings.json"
        fi
    else
        local has_channels
        has_channels=$(python3 -c "
import json, sys
try:
    d = json.load(open('${mremote}'))
    ok = d.get('channelsEnabled') and any(
        p.get('plugin') == 'junto-inbox'
        for p in d.get('allowedChannelPlugins', [])
        if isinstance(p, dict)
    )
    print('ok' if ok else 'missing')
except: print('error')
" 2>/dev/null || echo "error")

        if [[ "$has_channels" == "ok" ]]; then
            _pass "managed-remote-settings.json has channelsEnabled + junto-inbox plugin"
        else
            _fail "managed-remote-settings.json exists but missing channelsEnabled or allowedChannelPlugins"
            if _ask_fix "patch managed-remote-settings.json"; then
                python3 - "$mremote" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}
data['channelsEnabled'] = True
plugins = data.get('allowedChannelPlugins', [])
desired = {"marketplace": "tlemmons-junto-inbox", "plugin": "junto-inbox"}
if not any(p.get('plugin') == 'junto-inbox' for p in plugins if isinstance(p, dict)):
    plugins.append(desired)
data['allowedChannelPlugins'] = plugins
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
print(f"  Patched {path}")
PYEOF
                _fixed "patched managed-remote-settings.json"
            fi
        fi
    fi

    # ensure-channel-settings.sh hook
    local hook_script="${claude_dir}/hooks/ensure-channel-settings.sh"
    if [[ ! -f "$hook_script" ]]; then
        _fail "ensure-channel-settings.sh hook missing at ${hook_script}"
        _info "This hook keeps channelsEnabled in remote-settings.json — contact Tom to install"
    else
        _pass "ensure-channel-settings.sh hook file exists"

        # Check it's registered in settings.json
        local settings_json="${claude_dir}/settings.json"
        if [[ -f "$settings_json" ]] && grep -q "ensure-channel-settings" "$settings_json" 2>/dev/null; then
            _pass "ensure-channel-settings.sh registered in settings.json"
        else
            _warn "ensure-channel-settings.sh exists but may not be registered as a hook in settings.json"
            _info "Hook should be registered as UserPromptSubmit and Stop hooks"
        fi
    fi

    # ~/.mcp.json has junto server
    local mcp_json="${HOME}/.mcp.json"
    if [[ ! -f "$mcp_json" ]]; then
        _fail "~/.mcp.json not found — junto MCP server not configured"
        _info "Add junto server: { \"mcpServers\": { \"junto\": { \"url\": \"http://spg-junto-central:8080/mcp\" } } }"
    else
        local junto_url
        junto_url=$(python3 -c "
import json, sys
try:
    d = json.load(open('${mcp_json}'))
    servers = d.get('mcpServers', {})
    for name, cfg in servers.items():
        url = cfg.get('url', '')
        if 'spg-junto-central' in url or '8080/mcp' in url:
            print(url); sys.exit(0)
    print('')
except: print('')
" 2>/dev/null || echo "")

        if [[ -n "$junto_url" ]]; then
            _pass "~/.mcp.json has junto server (${junto_url})"
        else
            _fail "~/.mcp.json exists but no junto server entry pointing to spg-junto-central:8080"
            _info "Expected: { \"mcpServers\": { \"junto\": { \"url\": \"http://spg-junto-central:8080/mcp\" } } }"
            _info "Note: API key goes as api_key= in tool calls — NOT in MCP headers (failure mode #5)"
        fi
    fi
}

# ── Section 4: junto Install ──────────────────────────────────────────────────

check_junto_install() {
    _section "4. junto Install"

    # ~/.junto exists and is a git repo
    if [[ ! -d "${JUNTO_DIR}" ]]; then
        _fail "~/.junto not found — junto not installed"
        _info "Clone: git clone https://github.com/tlemmons/junto.git ~/.junto"
        return
    fi
    _pass "~/.junto directory exists"

    if ! git -C "${JUNTO_DIR}" rev-parse --git-dir &>/dev/null 2>&1; then
        _fail "~/.junto is not a git repo — may be an old file copy"
        if _ask_fix "remove and re-clone ~/.junto"; then
            local backup="${JUNTO_DIR}.bak.$$"
            mv "${JUNTO_DIR}" "$backup"
            _info "Old ~/.junto moved to ${backup}"
            git clone https://github.com/tlemmons/junto.git "${JUNTO_DIR}" 2>&1 | sed 's/^/  /'
            _fixed "re-cloned ~/.junto from GitHub"
            _warn "Your config was in ${backup}/config — re-apply your API key and settings"
        fi
    else
        _pass "~/.junto is a git repo"

        # Up to date check
        local behind
        behind=$(git -C "${JUNTO_DIR}" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
        if [[ "$behind" == "0" ]]; then
            _pass "~/.junto is up to date with origin/main"
        elif [[ "$behind" == "?" ]]; then
            _warn "Could not check ~/.junto update status (no network or fetch failed)"
        else
            _warn "~/.junto is ${behind} commit(s) behind origin/main"
            if _ask_fix "git pull ~/.junto"; then
                git -C "${JUNTO_DIR}" pull --ff-only 2>&1 | tail -3 | sed 's/^/  /'
                _fixed "pulled latest ~/.junto"
            fi
        fi
    fi

    # config file
    local config="${JUNTO_DIR}/config"
    if [[ ! -f "$config" ]]; then
        _fail "~/.junto/config missing — run ~/.junto/junto-setup.sh to create it"
        return
    fi
    _pass "~/.junto/config exists"

    # Source config to check keys
    # shellcheck disable=SC1090
    (
        set -a
        source "$config" 2>/dev/null || true
        set +a

        if [[ -z "${JUNTO_API_KEY:-}" ]]; then
            _fail "JUNTO_API_KEY not set in ~/.junto/config — contact Tom to provision a key"
        elif [[ "${JUNTO_API_KEY}" != smk_* ]]; then
            _warn "JUNTO_API_KEY doesn't look like a valid key (expected smk_ prefix)"
        else
            _pass "JUNTO_API_KEY is set (${JUNTO_API_KEY:0:12}...)"
        fi

        if [[ -z "${JUNTO_MEMORY_URL:-}" ]]; then
            _fail "JUNTO_MEMORY_URL not set in ~/.junto/config"
            _info "Add to config: JUNTO_MEMORY_URL=http://spg-junto-central:8080/mcp"
        elif [[ "${JUNTO_MEMORY_URL}" == *"your-junto-server"* ]]; then
            _fail "JUNTO_MEMORY_URL is still the default placeholder — update to real server URL"
            _info "Set to: http://spg-junto-central:8080/mcp"
        else
            _pass "JUNTO_MEMORY_URL is set (${JUNTO_MEMORY_URL})"
        fi
    )

    # junto-launch.sh executable
    if [[ ! -x "${JUNTO_DIR}/junto-launch.sh" ]]; then
        _fail "junto-launch.sh is not executable"
        if _ask_fix "chmod +x ${JUNTO_DIR}/junto-launch.sh"; then
            chmod +x "${JUNTO_DIR}/junto-launch.sh"
            _fixed "junto-launch.sh is now executable"
        fi
    else
        _pass "junto-launch.sh is executable"
    fi

    # `junto` alias/command check — must ultimately call junto-launch.sh
    local alias_ok=false
    local junto_path
    junto_path=$(command -v junto 2>/dev/null || true)

    if [[ -n "$junto_path" ]]; then
        if grep -q "junto-launch.sh" "$junto_path" 2>/dev/null; then
            _pass "\`junto\` command (${junto_path}) → junto-launch.sh"
            alias_ok=true
        else
            # Found junto but it's stale (old wrapper, wrong flags, hardcoded identity)
            _fail "\`junto\` at ${junto_path} does NOT call junto-launch.sh"
            # Check for specific known-bad patterns
            if grep -q "\-\-channels " "$junto_path" 2>/dev/null; then
                _info "Stale: uses deprecated --channels flag (should be --dangerously-load-development-channels)"
            fi
            if grep -qE "JUNTO_AGENT=|JUNTO_PROJECT=" "$junto_path" 2>/dev/null; then
                _info "Stale: hardcodes JUNTO_AGENT/JUNTO_PROJECT — overrides CLAUDE.md identity detection"
            fi
            _info "Fix: replace ${junto_path} with a wrapper that calls ~/.junto/junto-launch.sh"
            if _ask_fix "overwrite ${junto_path} with a clean junto-launch.sh wrapper"; then
                cat > "$junto_path" << 'WRAPPER'
#!/usr/bin/env bash
# junto — wrapper for ~/.junto/junto-launch.sh
exec ~/.junto/junto-launch.sh "$@"
WRAPPER
                chmod +x "$junto_path"
                _fixed "updated ${junto_path} → ~/.junto/junto-launch.sh"
                alias_ok=true
            fi
        fi
    else
        # Not in PATH — check shell rc files for alias definition
        for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.bash_aliases" "${HOME}/.profile"; do
            if [[ -f "$rc" ]] && grep -v "^[[:space:]]*#" "$rc" 2>/dev/null | grep -q "junto-launch.sh"; then
                _pass "\`junto\` alias defined in ${rc} → junto-launch.sh"
                alias_ok=true
                break
            fi
        done
    fi

    if [[ "$alias_ok" == "false" && -z "$junto_path" ]]; then
        # Not found anywhere — suggest creating it
        _fail "\`junto\` not found in PATH — you'd have to call ~/.junto/junto-launch.sh manually"
        _info "Add to ~/.bashrc (or ~/.zshrc):"
        _info "  alias junto='~/.junto/junto-launch.sh'"
        _info "Then run: source ~/.bashrc"
    fi
}

# ── Section 5: Project Directory ──────────────────────────────────────────────

check_project_dir() {
    _section "5. Project Directory (${PROJECT_DIR})"

    if [[ ! -d "$PROJECT_DIR" ]]; then
        _fail "Project directory does not exist: ${PROJECT_DIR}"
        return
    fi

    local claude_md="${PROJECT_DIR}/CLAUDE.md"

    # CLAUDE.md exists
    if [[ ! -f "$claude_md" ]]; then
        _fail "CLAUDE.md not found in ${PROJECT_DIR}"
        _info "Run: cd ${PROJECT_DIR} && ~/.junto/junto-launch.sh  (it will prompt to create one)"
        return
    fi
    _pass "CLAUDE.md exists"

    # "Your name is: `...`" line
    local agent_name
    agent_name=$(grep -m1 'Your name is:.*`' "$claude_md" 2>/dev/null \
        | sed 's/.*`\([^`]*\)`.*/\1/' || true)
    if [[ -z "$agent_name" ]]; then
        _fail "CLAUDE.md missing agent name line (need: Your name is: \`juntoYourName\`)"
    else
        _pass "Agent name: ${agent_name}"
    fi

    # project="..." marker
    local project_name
    project_name=$(grep -m1 'project="[^"]*"' "$claude_md" 2>/dev/null \
        | sed 's/.*project="\([^"]*\)".*/\1/' || true)
    if [[ -z "$project_name" ]]; then
        _fail "CLAUDE.md missing project marker (need: <!-- project=\"yourproject\" -->)"
    else
        # Case check — server normalizes to lowercase
        local project_lower
        project_lower=$(echo "$project_name" | tr '[:upper:]' '[:lower:]' | tr '-' '_' | tr ' ' '_')
        if [[ "$project_name" != "$project_lower" ]]; then
            _fail "Project name '${project_name}' has uppercase — causes live_subscribers=0 (plugin subscribes as '${project_name}', server routes to '${project_lower}')"
            if _ask_fix "lowercase project name in CLAUDE.md: '${project_name}' → '${project_lower}'"; then
                sed -i "s/project=\"${project_name}\"/project=\"${project_lower}\"/" "$claude_md"
                _fixed "project name lowercased to '${project_lower}'"
                project_name="$project_lower"
            fi
        else
            _pass "Project name: ${project_name} (lowercase ✓)"
        fi
    fi

    # .claude/settings.local.json
    local settings_local="${PROJECT_DIR}/.claude/settings.local.json"
    if [[ ! -f "$settings_local" ]]; then
        _fail ".claude/settings.local.json missing — MCP tool calls will prompt for permission every time"
        if _ask_fix "create minimal .claude/settings.local.json with junto tool permissions"; then
            mkdir -p "${PROJECT_DIR}/.claude"
            python3 - "$settings_local" <<'PYEOF'
import json, sys
path = sys.argv[1]
content = {
    "permissions": {
        "allow": [
            "mcp__junto__memory_start_session",
            "mcp__junto__memory_end_session",
            "mcp__junto__memory_query",
            "mcp__junto__memory_store",
            "mcp__junto__memory_record_learning",
            "mcp__junto__memory_get_spec",
            "mcp__junto__memory_define_spec",
            "mcp__junto__memory_guidelines",
            "mcp__junto__memory_list_backlog",
            "mcp__junto__memory_add_backlog_item",
            "mcp__junto__memory_update_backlog_item",
            "mcp__junto__memory_complete_backlog_item",
            "mcp__junto__memory_get_messages",
            "mcp__junto__memory_acknowledge_message",
            "mcp__junto__memory_send_message",
            "mcp__junto__memory_register_function",
            "mcp__junto__memory_find_function",
            "mcp__junto__memory_list_agents",
            "mcp__junto__memory_get_by_id",
            "mcp__junto__memory_change_status",
            "mcp__junto__memory_list_specs",
            "mcp__junto__memory_heartbeat",
            "mcp__junto__memory_get_active_work",
            "mcp__junto__memory_update_work",
            "mcp__junto__memory_lock_files",
            "mcp__junto__memory_unlock_files",
            "mcp__junto__memory_get_locks",
            "mcp__junto__memory_search_global",
            "mcp__junto__memory_batch_backlog",
            "mcp__plugin_junto-inbox_junto-inbox__get_session_id",
            "mcp__plugin_junto-inbox_junto-inbox__send_message",
            "mcp__plugin_junto-inbox_junto-inbox__junto_journal_list"
        ]
    },
    "enableAllProjectMcpServers": True,
    "enabledMcpjsonServers": ["junto"]
}
with open(path, 'w') as f:
    json.dump(content, f, indent=2)
print(f"  Created {path}")
PYEOF
            _fixed "created .claude/settings.local.json"
        fi
    else
        # Check it has junto permissions
        if grep -q "mcp__junto__" "$settings_local" 2>/dev/null; then
            _pass ".claude/settings.local.json exists with junto permissions"
        else
            _warn ".claude/settings.local.json exists but no mcp__junto__ permissions found"
            _info "You may get permission prompts on every tool call — add mcp__junto__* to allow list"
        fi
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}junto-check${RESET} — installation verifier\n"
printf "Project dir: %s\n" "$PROJECT_DIR"
[[ "$AUTO_FIX" == "true" ]] && printf "Mode: ${YELLOW}auto-fix${RESET}\n"

check_prerequisites
check_network
check_claude_code
check_junto_install
check_project_dir

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}Summary${RESET}\n"
printf "  ${GREEN}✓${RESET} %d passed\n" "$PASS_COUNT"
[[ $WARN_COUNT -gt 0 ]] && printf "  ${YELLOW}⚠${RESET} %d warnings\n" "$WARN_COUNT"
[[ $FIX_COUNT  -gt 0 ]] && printf "  ${GREEN}⚙${RESET} %d auto-fixed\n" "$FIX_COUNT"
[[ $FAIL_COUNT -gt 0 ]] && printf "  ${RED}✗${RESET} %d failed\n" "$FAIL_COUNT"

echo ""
if [[ $FAIL_COUNT -eq 0 ]]; then
    printf "${GREEN}${BOLD}All checks passed.${RESET} Run: cd %s && junto\n" "$PROJECT_DIR"
    exit 0
else
    printf "${RED}${BOLD}%d check(s) failed.${RESET} Fix the issues above, then re-run junto-check.\n" "$FAIL_COUNT"
    [[ "$AUTO_FIX" == "false" ]] && printf "Tip: run with ${CYAN}--fix${RESET} to auto-apply safe fixes.\n"
    exit 1
fi
