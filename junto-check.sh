#!/usr/bin/env bash
# junto-check.sh — verify junto installation and diagnose common issues.
#
# Usage:
#   ~/.junto/junto-check.sh [--fix] [--project-dir DIR] ... [--quiet]
#
# Options:
#   --fix              Auto-apply safe fixes without interactive prompts
#   --project-dir DIR  Project directory to check (repeatable; default: cwd)
#   --quiet            Only print failures and warnings, suppress PASS lines
#
# Examples:
#   junto-check                                         # check cwd
#   junto-check --project-dir ~/code/awareness         # check one project
#   junto-check --fix \
#     --project-dir ~/code/awareness \
#     --project-dir ~/code/ispy                        # fix all projects
#
# Exit code: 0 = all checks pass (or fixed), 1 = one or more failures remain

set -euo pipefail

JUNTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"   # Darwin | Linux

# ── Args ──────────────────────────────────────────────────────────────────────

AUTO_FIX=false
QUIET=false
PROJECT_DIRS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)         AUTO_FIX=true ;;
        --quiet)       QUIET=true ;;
        --project-dir) PROJECT_DIRS+=("$2"); shift ;;
        -h|--help)
            sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

[[ ${#PROJECT_DIRS[@]} -eq 0 ]] && PROJECT_DIRS=("$(pwd)")

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
    if ! ( exec 3</dev/tty ) &>/dev/null 2>&1; then
        _info "Skipping auto-fix (no TTY) — re-run interactively or use --fix"
        return 1
    fi
    printf "    ${YELLOW}Fix?${RESET} %s [y/N] " "$prompt"
    local answer=""
    read -r answer </dev/tty 2>/dev/null || true
    [[ "$answer" =~ ^[Yy]$ ]]
}

# Portable in-place sed: handles both BSD (macOS) and GNU (Linux).
_sed_inplace() {
    local file="$1"; shift
    if [[ "$OS" == "Darwin" ]]; then
        sed -i '' "$@" "$file"
    else
        sed -i "$@" "$file"
    fi
}

# ── Section 1: Prerequisites ──────────────────────────────────────────────────

check_prerequisites() {
    _section "1. Prerequisites"

    if command -v bun &>/dev/null; then
        _pass "bun installed ($(bun --version 2>/dev/null || echo 'version unknown'))"
    else
        _fail "bun not installed — required for junto-inbox channel plugin"
        _info "Install: curl -fsSL https://bun.sh/install | bash"
        _info "Then re-open your shell or run: source ~/.bashrc  (or ~/.zshrc on macOS)"
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

    # Tailscale — may be Windows-native on WSL (not in Linux PATH)
    local tailscale_cmd=""
    if command -v tailscale &>/dev/null; then
        tailscale_cmd="tailscale"
    elif [[ -f "/mnt/c/Program Files/Tailscale/tailscale.exe" ]]; then
        tailscale_cmd="/mnt/c/Program Files/Tailscale/tailscale.exe"
    fi

    if [[ -z "$tailscale_cmd" ]]; then
        _fail "tailscale not found (checked PATH and Windows Program Files)"
        _info "Install at: https://tailscale.com/download"
    else
        _pass "tailscale found ($(basename "$tailscale_cmd"))"
        if ! "$tailscale_cmd" status &>/dev/null 2>&1; then
            _fail "tailscale is not running or not connected to the LVT tailnet"
            _info "Start Tailscale and connect with your LVT credentials"
        else
            _pass "tailscale running"
        fi
    fi

    # Hostname resolution
    local resolved=false
    if getent hosts "${SPG_HOST}" &>/dev/null 2>&1; then
        _pass "spg-junto-central resolves via MagicDNS"
        resolved=true
    elif host "${SPG_HOST}" &>/dev/null 2>&1; then
        _pass "spg-junto-central resolves"
        resolved=true
    elif dscacheutil -q host -a name "${SPG_HOST}" 2>/dev/null | grep -q "ip_address"; then
        _pass "spg-junto-central resolves (macOS DNS cache)"
        resolved=true
    fi

    if [[ "$resolved" == "false" ]]; then
        _fail "spg-junto-central does not resolve — MagicDNS may be off or wrong tailnet"
        if _ask_fix "enable MagicDNS: sudo tailscale set --accept-dns=true"; then
            if [[ -n "$tailscale_cmd" ]] && sudo "$tailscale_cmd" set --accept-dns=true 2>/dev/null; then
                _fixed "MagicDNS enabled"
                resolved=true
            else
                _warn "Could not enable MagicDNS automatically — try manually"
            fi
        fi
        if [[ "$resolved" == "false" ]]; then
            if grep -q "${SPG_HOST}" /etc/hosts 2>/dev/null; then
                _pass "/etc/hosts fallback entry exists"
                resolved=true
            else
                if _ask_fix "add '${SPG_IP} ${SPG_HOST}' to /etc/hosts (requires sudo)"; then
                    if echo "${SPG_IP} ${SPG_HOST}" | sudo tee -a /etc/hosts &>/dev/null; then
                        _fixed "/etc/hosts entry added"
                        resolved=true
                    else
                        _warn "Could not write /etc/hosts — try: echo '${SPG_IP} ${SPG_HOST}' | sudo tee -a /etc/hosts"
                    fi
                fi
            fi
        fi
    fi

    # IP reachability — macOS ping uses -t for timeout, Linux uses -W
    local ping_timeout_flag="-W2"
    [[ "$OS" == "Darwin" ]] && ping_timeout_flag="-t2"
    if ping -c1 "${ping_timeout_flag}" "${SPG_IP}" &>/dev/null 2>&1; then
        _pass "spg-junto-central IP (${SPG_IP}) reachable"
    else
        _warn "spg-junto-central IP (${SPG_IP}) ping failed — may be ICMP-blocked (not always fatal)"
    fi

    # Port 8080 — prefer nc (available on macOS and Linux), fallback to /dev/tcp
    local port_open=false
    if command -v nc &>/dev/null; then
        # macOS nc: -z (scan only), -G (connect timeout); Linux nc: -z -w (wait)
        local nc_timeout_flag="-w2"
        [[ "$OS" == "Darwin" ]] && nc_timeout_flag="-G2"
        if nc -z "${nc_timeout_flag}" "${SPG_HOST}" "${SPG_PORT}" &>/dev/null 2>&1; then
            port_open=true
        fi
    elif ( exec 3<>/dev/tcp/"${SPG_HOST}"/"${SPG_PORT}" ) &>/dev/null 2>&1; then
        port_open=true
    fi

    if [[ "$port_open" == "true" ]]; then
        _pass "port ${SPG_PORT} reachable on spg-junto-central"
    else
        _fail "port ${SPG_PORT} not reachable — check Tailscale ACL"
        _info "Test: nc -z ${SPG_HOST} ${SPG_PORT}"
    fi

    # Health endpoint
    local health_status
    health_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "http://${SPG_HOST}:${SPG_PORT}/health" 2>/dev/null || echo "000")

    case "$health_status" in
        200) _pass "health endpoint returns 200" ;;
        503) _warn "health endpoint returns 503 — server up but a backend is unhealthy" ;;
        000) _fail "health endpoint unreachable (timeout or connection refused)" ;;
        *)   _warn "health endpoint returned HTTP ${health_status} (expected 200)" ;;
    esac
}

# ── Section 3: Claude Code Config ─────────────────────────────────────────────

check_claude_code() {
    _section "3. Claude Code Config"

    local claude_dir="${HOME}/.claude"

    # managed-remote-settings.json
    local mremote="${claude_dir}/managed-remote-settings.json"
    if [[ ! -f "$mremote" ]]; then
        _fail "managed-remote-settings.json missing"
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
PYEOF
            _fixed "created managed-remote-settings.json"
        fi
    else
        local has_channels
        has_channels=$(python3 -c "
import json
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
            _pass "managed-remote-settings.json configured correctly"
        else
            _fail "managed-remote-settings.json missing channelsEnabled or allowedChannelPlugins"
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
PYEOF
                _fixed "patched managed-remote-settings.json"
            fi
        fi
    fi

    # ensure-channel-settings.sh hook
    local hook_script="${claude_dir}/hooks/ensure-channel-settings.sh"
    if [[ ! -f "$hook_script" ]]; then
        _fail "ensure-channel-settings.sh hook missing — contact Tom to install"
    else
        _pass "ensure-channel-settings.sh hook file exists"
        local settings_json="${claude_dir}/settings.json"
        if [[ -f "$settings_json" ]] && grep -q "ensure-channel-settings" "$settings_json" 2>/dev/null; then
            _pass "ensure-channel-settings.sh registered in settings.json"
        else
            _warn "ensure-channel-settings.sh exists but may not be registered as a hook"
            _info "Should be a UserPromptSubmit and Stop hook in ~/.claude/settings.json"
        fi
    fi

    # ~/.mcp.json has junto server
    local mcp_json="${HOME}/.mcp.json"
    if [[ ! -f "$mcp_json" ]]; then
        _fail "~/.mcp.json not found — junto MCP server not configured"
        _info "Add: { \"mcpServers\": { \"junto\": { \"url\": \"http://spg-junto-central:8080/mcp\" } } }"
    else
        local junto_url junto_type
        read -r junto_url junto_type <<< "$(python3 -c "
import json
try:
    d = json.load(open('${mcp_json}'))
    for name, cfg in d.get('mcpServers', {}).items():
        url = cfg.get('url', '')
        if 'spg-junto-central' in url or '8080/mcp' in url:
            print(url, cfg.get('type', ''))
            exit(0)
    print('', '')
except: print('', '')
" 2>/dev/null || echo "")"
        if [[ -z "$junto_url" ]]; then
            _fail "~/.mcp.json missing junto server entry for spg-junto-central:8080"
            _info "Expected: { \"mcpServers\": { \"junto\": { \"type\": \"http\", \"url\": \"http://spg-junto-central:8080/mcp\" } } }"
            _info "API key goes as api_key= in tool calls, NOT in HTTP headers"
        else
            _pass "~/.mcp.json has junto server (${junto_url})"
            # Current CC versions require explicit "type": "http"
            if [[ "$junto_type" != "http" ]]; then
                _fail "~/.mcp.json junto entry missing \"type\": \"http\" — required by current Claude Code"
                if _ask_fix "add \\\"type\\\": \\\"http\\\" to junto server entry in ~/.mcp.json"; then
                    python3 - "${mcp_json}" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
for name, cfg in data.get('mcpServers', {}).items():
    url = cfg.get('url', '')
    if 'spg-junto-central' in url or '8080/mcp' in url:
        cfg['type'] = 'http'
        break
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
                    _fixed "added \"type\": \"http\" to junto entry in ~/.mcp.json"
                fi
            else
                _pass "~/.mcp.json junto entry has \"type\": \"http\""
            fi
        fi
    fi
}

# ── Section 4: junto Install ──────────────────────────────────────────────────

check_junto_install() {
    _section "4. junto Install"

    if [[ ! -d "${JUNTO_DIR}" ]]; then
        _fail "~/.junto not found"
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
            _fixed "re-cloned ~/.junto"
            _warn "Config was in ${backup}/config — re-apply your API key"
        fi
    else
        _pass "~/.junto is a git repo"

        # Fetch silently to check for updates
        git -C "${JUNTO_DIR}" fetch origin main --quiet 2>/dev/null || true
        local behind
        behind=$(git -C "${JUNTO_DIR}" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
        if [[ "$behind" == "0" ]]; then
            _pass "~/.junto is up to date"
        elif [[ "$behind" == "?" ]]; then
            _warn "Could not check ~/.junto update status"
        else
            _warn "~/.junto is ${behind} commit(s) behind origin/main"
            if _ask_fix "git pull ~/.junto"; then
                git -C "${JUNTO_DIR}" pull --ff-only 2>&1 | tail -3 | sed 's/^/  /'
                _fixed "pulled latest ~/.junto"
            fi
        fi
    fi

    # config
    local config="${JUNTO_DIR}/config"
    if [[ ! -f "$config" ]]; then
        _fail "~/.junto/config missing — run ~/.junto/junto-setup.sh"
        return
    fi
    _pass "~/.junto/config exists"

    (
        set -a
        # shellcheck disable=SC1090
        source "$config" 2>/dev/null || true
        set +a

        if [[ -z "${JUNTO_API_KEY:-}" ]]; then
            _fail "JUNTO_API_KEY not set — contact Tom to provision a key"
        elif [[ "${JUNTO_API_KEY}" != smk_* ]]; then
            _warn "JUNTO_API_KEY has unexpected format (expected smk_ prefix)"
        else
            _pass "JUNTO_API_KEY set (${JUNTO_API_KEY:0:12}...)"
        fi

        if [[ -z "${JUNTO_MEMORY_URL:-}" ]]; then
            _fail "JUNTO_MEMORY_URL not set in ~/.junto/config"
            _info "Add: JUNTO_MEMORY_URL=http://spg-junto-central:8080/mcp"
        elif [[ "${JUNTO_MEMORY_URL}" == *"your-junto-server"* ]]; then
            _fail "JUNTO_MEMORY_URL is still the placeholder — update to http://spg-junto-central:8080/mcp"
        else
            _pass "JUNTO_MEMORY_URL set (${JUNTO_MEMORY_URL})"
        fi
    )

    # Live API key + project validation
    if command -v python3 &>/dev/null && [[ -f "${JUNTO_DIR}/check-auth.py" ]]; then
        (
            set -a
            # shellcheck disable=SC1090
            source "${JUNTO_DIR}/config" 2>/dev/null || true
            set +a
            if [[ -n "${JUNTO_API_KEY:-}" && -n "${JUNTO_MEMORY_URL:-}" && -n "${JUNTO_PROJECT:-}" ]]; then
                local auth_result
                auth_result=$(python3 "${JUNTO_DIR}/check-auth.py" \
                    "$JUNTO_MEMORY_URL" "$JUNTO_API_KEY" "$JUNTO_PROJECT" 2>/dev/null || echo "error")
                case "$auth_result" in
                    ok)
                        _pass "API key valid for project '${JUNTO_PROJECT}'"
                        ;;
                    invalid_key)
                        _fail "API key is invalid or not recognized by the server"
                        _info "Check JUNTO_API_KEY in ~/.junto/config"
                        ;;
                    permission_denied)
                        _fail "API key cannot access project '${JUNTO_PROJECT}' — wrong project name"
                        _info "Your key is scoped to specific projects — contact Tom to confirm the right name"
                        _info "Fix: update project marker in CLAUDE.md and JUNTO_PROJECT in ~/.junto/config"
                        ;;
                    unreachable)
                        _warn "Server unreachable — skipping live auth check (check Tailscale)"
                        ;;
                    *)
                        _warn "Auth check returned unexpected result: ${auth_result}"
                        ;;
                esac
            fi
        )
    fi

    if [[ ! -x "${JUNTO_DIR}/junto-launch.sh" ]]; then
        _fail "junto-launch.sh is not executable"
        if _ask_fix "chmod +x ${JUNTO_DIR}/junto-launch.sh"; then
            chmod +x "${JUNTO_DIR}/junto-launch.sh"
            _fixed "junto-launch.sh is now executable"
        fi
    else
        _pass "junto-launch.sh is executable"
    fi

    # `junto` command — must ultimately call junto-launch.sh
    local alias_ok=false
    local junto_path
    junto_path=$(command -v junto 2>/dev/null || true)

    if [[ -n "$junto_path" ]]; then
        if grep -q "junto-launch.sh" "$junto_path" 2>/dev/null; then
            _pass "\`junto\` (${junto_path}) → junto-launch.sh ✓"
            alias_ok=true
        else
            _fail "\`junto\` at ${junto_path} does NOT call junto-launch.sh"
            if grep -q "\-\-channels " "$junto_path" 2>/dev/null; then
                _info "Stale: uses deprecated --channels flag"
            fi
            if grep -qE "JUNTO_AGENT=|JUNTO_PROJECT=" "$junto_path" 2>/dev/null; then
                _info "Stale: hardcodes identity — overrides CLAUDE.md detection"
            fi
            if _ask_fix "replace ${junto_path} with a clean junto-launch.sh shim"; then
                cat > "$junto_path" << 'WRAPPER'
#!/usr/bin/env bash
# junto — launcher shim for ~/.junto/junto-launch.sh
exec ~/.junto/junto-launch.sh "$@"
WRAPPER
                chmod +x "$junto_path"
                _fixed "updated ${junto_path} → junto-launch.sh"
                alias_ok=true
            fi
        fi
    else
        for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.bash_aliases" "${HOME}/.profile"; do
            if [[ -f "$rc" ]] && grep -v "^[[:space:]]*#" "$rc" 2>/dev/null | grep -q "junto-launch.sh"; then
                _pass "\`junto\` alias in ${rc} → junto-launch.sh ✓"
                alias_ok=true
                break
            fi
        done

        if [[ "$alias_ok" == "false" ]]; then
            _fail "\`junto\` not found in PATH or shell rc files"
            _info "Add to ~/.zshrc (macOS) or ~/.bashrc (Linux):"
            _info "  alias junto='~/.junto/junto-launch.sh'"
            _info "Then: source ~/.zshrc  (or ~/.bashrc)"
        fi
    fi
}

# ── Section 5: Project Directory ──────────────────────────────────────────────

check_project_dir() {
    local dir="$1"
    _section "5. Project Directory (${dir})"

    if [[ ! -d "$dir" ]]; then
        _fail "Directory does not exist: ${dir}"
        return
    fi

    local claude_md="${dir}/CLAUDE.md"

    if [[ ! -f "$claude_md" ]]; then
        _fail "CLAUDE.md not found"
        _info "Run: cd ${dir} && junto  (it will prompt to create one)"
        return
    fi
    _pass "CLAUDE.md exists"

    # Agent name
    local agent_name
    agent_name=$(grep -m1 'Your name is:.*`' "$claude_md" 2>/dev/null \
        | sed 's/.*`\([^`]*\)`.*/\1/' || true)
    if [[ -z "$agent_name" ]]; then
        _fail "Missing agent name line (need: Your name is: \`juntoYourName\`)"
    else
        _pass "Agent name: ${agent_name}"
    fi

    # Project marker + case check
    local project_name
    project_name=$(grep -m1 'project="[^"]*"' "$claude_md" 2>/dev/null \
        | sed 's/.*project="\([^"]*\)".*/\1/' || true)
    if [[ -z "$project_name" ]]; then
        _fail "Missing project marker (need: <!-- project=\"yourproject\" -->)"
    else
        local project_lower
        project_lower=$(echo "$project_name" | tr '[:upper:]' '[:lower:]' | tr '-' '_' | tr ' ' '_')
        if [[ "$project_name" != "$project_lower" ]]; then
            _fail "Project name '${project_name}' has uppercase — will cause live_subscribers=0"
            _info "Plugin subscribes as '${project_name}', server routes to '${project_lower}'"
            if _ask_fix "fix project name: '${project_name}' → '${project_lower}'"; then
                _sed_inplace "$claude_md" "s/project=\"${project_name}\"/project=\"${project_lower}\"/"
                _fixed "project name lowercased to '${project_lower}'"
                project_name="$project_lower"
            fi
        else
            _pass "Project name: ${project_name} (lowercase ✓)"
        fi
    fi

    # .claude/settings.local.json
    local settings_local="${dir}/.claude/settings.local.json"
    if [[ ! -f "$settings_local" ]]; then
        _fail ".claude/settings.local.json missing — will prompt for permission on every tool call"
        if _ask_fix "create .claude/settings.local.json with junto tool permissions"; then
            mkdir -p "${dir}/.claude"
            python3 - "$settings_local" <<'PYEOF'
import json, sys
path = sys.argv[1]
content = {
    "permissions": {
        "allow": [
            "mcp__junto__*",
            "mcp__plugin_junto-inbox_junto-inbox__*"
        ]
    },
    "enableAllProjectMcpServers": True,
    "enabledMcpjsonServers": ["junto"]
}
with open(path, 'w') as f:
    json.dump(content, f, indent=2)
PYEOF
            _fixed "created .claude/settings.local.json"
        fi
    else
        if grep -q "mcp__junto__" "$settings_local" 2>/dev/null; then
            _pass ".claude/settings.local.json has junto permissions"
        else
            _warn ".claude/settings.local.json exists but no mcp__junto__ permissions found"
            _info "Add mcp__junto__* entries to the allow list to suppress permission prompts"
        fi
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}junto-check${RESET} — installation verifier\n"
if [[ ${#PROJECT_DIRS[@]} -eq 1 ]]; then
    printf "Project dir: %s\n" "${PROJECT_DIRS[0]}"
else
    printf "Project dirs: %d directories\n" "${#PROJECT_DIRS[@]}"
    for d in "${PROJECT_DIRS[@]}"; do printf "  • %s\n" "$d"; done
fi
[[ "$AUTO_FIX" == "true" ]] && printf "Mode: ${YELLOW}auto-fix${RESET}\n"

check_prerequisites
check_network
check_claude_code
check_junto_install

for dir in "${PROJECT_DIRS[@]}"; do
    check_project_dir "$dir"
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}Summary${RESET}\n"
printf "  ${GREEN}✓${RESET} %d passed\n" "$PASS_COUNT"
[[ $WARN_COUNT -gt 0 ]] && printf "  ${YELLOW}⚠${RESET} %d warnings\n" "$WARN_COUNT"
[[ $FIX_COUNT  -gt 0 ]] && printf "  ${GREEN}⚙${RESET} %d auto-fixed\n" "$FIX_COUNT"
[[ $FAIL_COUNT -gt 0 ]] && printf "  ${RED}✗${RESET} %d failed\n" "$FAIL_COUNT"

echo ""
if [[ $FAIL_COUNT -eq 0 ]]; then
    printf "${GREEN}${BOLD}All checks passed.${RESET}\n"
    if [[ ${#PROJECT_DIRS[@]} -eq 1 ]]; then
        printf "Run: cd %s && junto\n" "${PROJECT_DIRS[0]}"
    else
        printf "Run \`junto\` from any of your project directories.\n"
    fi
    exit 0
else
    printf "${RED}${BOLD}%d check(s) failed.${RESET} Fix the issues above, then re-run junto-check.\n" "$FAIL_COUNT"
    [[ "$AUTO_FIX" == "false" ]] && printf "Tip: run with ${CYAN}--fix${RESET} to auto-apply safe fixes.\n"
    exit 1
fi
