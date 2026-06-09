#Requires -Version 5.1
<#
.SYNOPSIS
    junto-setup.ps1 -- first-time setup wizard for Windows (native, no WSL required).

.DESCRIPTION
    Run once per machine. Prompts for agent name, API key, server URL, and project
    directory, then writes config, registers the MCP server, configures Claude Code
    plugin settings, and launches Claude in first-run onboarding mode.

    Re-running is safe -- existing config, CLAUDE.md, and settings files are not
    overwritten; missing pieces are added.

.EXAMPLE
    & "$HOME\.junto\junto-setup.ps1"
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$JuntoDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath    = Join-Path $JuntoDir 'config'
$FirstRunOverlay = Join-Path $JuntoDir 'templates\overlays\first-run.md'

Write-Host ""
Write-Host "=== Junto First-Run Setup (Windows) ===" -ForegroundColor Cyan
Write-Host ""

# -- Prerequisites ---------------------------------------------------------------

foreach ($cmd in 'claude', 'git', 'curl') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "ERROR: '$cmd' not found on PATH. Install it and re-run."
        exit 1
    }
}
# python3 may be 'python' on Windows
$PyCmd = if (Get-Command python3 -EA SilentlyContinue) { 'python3' } elseif (Get-Command python -EA SilentlyContinue) { 'python' } else { $null }

# -- Load existing config as defaults --------------------------------------------

$cfg = @{}
if (Test-Path $ConfigPath) {
    Write-Host "Existing config found -- using it as defaults." -ForegroundColor Yellow
    Write-Host "(Press Enter to keep each value, or type a new one.)"
    Write-Host ""
    Get-Content $ConfigPath | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)="([^"]*)"' -and $_ -notmatch '^\s*#') {
            $cfg[$Matches[1]] = $Matches[2]
        }
    }
}

# -- Collect user info -----------------------------------------------------------

# Name
$existingAgent = $cfg['JUNTO_AGENT']
$nameSuffix    = if ($existingAgent) { " [$($existingAgent -replace '^junto','')]" } else { '' }
$firstName = (Read-Host "Your first name (agent will be junto{Name}, e.g. juntoSarah)$nameSuffix").Trim()
if ([string]::IsNullOrEmpty($firstName)) {
    if ($existingAgent) { $firstName = $existingAgent -replace '^junto', '' }
    else { Write-Error "Name cannot be empty."; exit 1 }
}
$firstName    = $firstName.Substring(0,1).ToUpper() + $firstName.Substring(1).ToLower()
$JUNTO_AGENT  = "junto$firstName"
Write-Host "  Agent identity: $JUNTO_AGENT" -ForegroundColor Green
Write-Host ""

# API key
$existingKey = $cfg['JUNTO_API_KEY']
if ($existingKey) {
    $preview = $existingKey.Substring(0, [Math]::Min(12, $existingKey.Length))
    $newKey  = (Read-Host "Junto API key [${preview}...] (Enter to keep)").Trim()
    $JUNTO_API_KEY = if ([string]::IsNullOrEmpty($newKey)) { $existingKey } else { $newKey }
} else {
    $JUNTO_API_KEY = (Read-Host "Paste your Junto API key (starts with smk_)").Trim()
}
if ([string]::IsNullOrEmpty($JUNTO_API_KEY)) { Write-Error "API key cannot be empty."; exit 1 }
Write-Host ""

# Server URL
$existingUrl   = if ($cfg['JUNTO_MEMORY_URL']) { $cfg['JUNTO_MEMORY_URL'] } else { 'http://your-junto-server:8080/mcp' }
$urlInput      = (Read-Host "Server URL [$existingUrl]").Trim()
$JUNTO_MEMORY_URL = if ([string]::IsNullOrEmpty($urlInput)) { $existingUrl } else { $urlInput }
Write-Host ""

$JUNTO_ROLE = 'General agent'

# Project directory
$existingDir = if ($cfg['PROJECT_DIR']) { $cfg['PROJECT_DIR'] } else { $HOME }
$dirInput    = (Read-Host "Path to your primary work directory [$existingDir]").Trim()
$rawDir      = if ([string]::IsNullOrEmpty($dirInput)) { $existingDir } else { $dirInput }
$rawDir      = $rawDir.Replace('~', $HOME)
$PROJECT_DIR = [System.IO.Path]::GetFullPath($rawDir)
if (-not (Test-Path $PROJECT_DIR)) { New-Item -ItemType Directory -Path $PROJECT_DIR -Force | Out-Null }
Write-Host "  Project dir: $PROJECT_DIR" -ForegroundColor Green
Write-Host ""

# Project name
$dirBasename     = (Split-Path -Leaf $PROJECT_DIR) -replace '[^a-z0-9-]', '' | ForEach-Object { $_.ToLower() }
$existingProject = if ($cfg['JUNTO_PROJECT']) { $cfg['JUNTO_PROJECT'] } else { $dirBasename }
Write-Host "Project identifier -- use the exact project name your admin assigned to your API key (lowercase)."

$JUNTO_PROJECT = ''
do {
    $projInput     = (Read-Host "Project name [$existingProject]").Trim()
    $JUNTO_PROJECT = if ([string]::IsNullOrEmpty($projInput)) { $existingProject } else { $projInput.ToLower() -replace '[^a-z0-9_-]', '_' }

    # Live auth validation (skip if python unavailable or server unreachable)
    $checkScript = Join-Path $JuntoDir 'check-auth.py'
    if ($PyCmd -and (Test-Path $checkScript)) {
        Write-Host -NoNewline "  Validating key + project against server... "
        try {
            $authResult = & $PyCmd $checkScript $JUNTO_MEMORY_URL $JUNTO_API_KEY $JUNTO_PROJECT 2>$null
        } catch { $authResult = 'error' }
        switch ($authResult.Trim()) {
            'ok'                {
                Write-Host "OK" -ForegroundColor Green
                break
            }
            'invalid_key'       {
                Write-Host "FAILED" -ForegroundColor Red
                Write-Error "API key is invalid. Check your key and server URL, then re-run."
                exit 1
            }
            'permission_denied' {
                Write-Host "DENIED (key cannot access '$JUNTO_PROJECT')" -ForegroundColor Red
                $JUNTO_PROJECT  = ''
                $existingProject = $projInput
            }
            'unreachable'       {
                Write-Host "skipped (server unreachable -- check network/Tailscale)" -ForegroundColor Yellow
                break
            }
            default             {
                Write-Host "skipped (unexpected: $authResult)" -ForegroundColor Yellow
                break
            }
        }
    }
} while ([string]::IsNullOrEmpty($JUNTO_PROJECT))

Write-Host "  Agent context: ${JUNTO_AGENT}@${JUNTO_PROJECT}" -ForegroundColor Green
Write-Host ""

# -- Write config ----------------------------------------------------------------

Set-Content -Path $ConfigPath -Encoding utf8 -Value @"
# Junto local configuration -- generated by junto-setup.ps1
# Edit these values for your machine. Do not commit this file.

# API key for the shared memory server
JUNTO_API_KEY="$JUNTO_API_KEY"

# Shared memory server URL
JUNTO_MEMORY_URL="$JUNTO_MEMORY_URL"

# Role description
JUNTO_ROLE="$JUNTO_ROLE"

# Last setup working directory
PROJECT_DIR="$PROJECT_DIR"

# Agent name and project are set per-directory in CLAUDE.md (auto-detected by junto-launch.ps1).
# junto-launch.ps1 prompts for these on first launch in any new directory.
# Uncomment below only to hard-override for ALL directories on this machine.
# JUNTO_AGENT=""
# JUNTO_PROJECT=""
"@
Write-Host "Config written to $ConfigPath"

# -- Register MCP server in ~/.mcp.json ------------------------------------------

$mcpPath = Join-Path $HOME '.mcp.json'
try   { $mcpData = Get-Content -Raw $mcpPath -ErrorAction Stop | ConvertFrom-Json }
catch { $mcpData = [PSCustomObject]@{} }
if (-not $mcpData.PSObject.Properties['mcpServers']) {
    $mcpData | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([PSCustomObject]@{}) -Force
}
$mcpData.mcpServers | Add-Member -NotePropertyName 'junto' -NotePropertyValue ([PSCustomObject]@{
    type    = 'http'
    url     = $JUNTO_MEMORY_URL
    headers = [PSCustomObject]@{ Authorization = "Bearer $JUNTO_API_KEY" }
}) -Force
$mcpData | ConvertTo-Json -Depth 10 | Set-Content -Path $mcpPath -Encoding utf8
Write-Host "MCP server 'junto' registered in $mcpPath"

# -- Create managed-remote-settings.json -----------------------------------------

$claudeDir   = Join-Path $HOME '.claude'
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
$managedPath = Join-Path $claudeDir 'managed-remote-settings.json'
$desiredEntry = [PSCustomObject]@{ marketplace = 'tlemmons-junto-inbox'; plugin = 'junto-inbox' }

if (-not (Test-Path $managedPath)) {
    [PSCustomObject]@{
        channelsEnabled       = $true
        allowedChannelPlugins = @($desiredEntry)
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $managedPath -Encoding utf8
    Write-Host "Created $managedPath"
} else {
    try { $ms = Get-Content -Raw $managedPath | ConvertFrom-Json } catch { $ms = [PSCustomObject]@{} }
    $changed = $false
    if (-not $ms.channelsEnabled) {
        $ms | Add-Member -NotePropertyName 'channelsEnabled' -NotePropertyValue $true -Force; $changed = $true
    }
    $existing = @($ms.allowedChannelPlugins)
    if (-not ($existing | Where-Object { $_.marketplace -eq 'tlemmons-junto-inbox' -and $_.plugin -eq 'junto-inbox' })) {
        $ms | Add-Member -NotePropertyName 'allowedChannelPlugins' -NotePropertyValue ($existing + $desiredEntry) -Force; $changed = $true
    }
    if ($changed) {
        $ms | ConvertTo-Json -Depth 5 | Set-Content -Path $managedPath -Encoding utf8
        Write-Host "Merged channel entries into $managedPath"
    } else {
        Write-Host "$managedPath already has required entries -- no changes"
    }
}

# -- Create ensure-channel-settings.ps1 hook -------------------------------------

$hooksDir   = Join-Path $claudeDir 'hooks'
if (-not (Test-Path $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }
$hookScript = Join-Path $hooksDir 'ensure-channel-settings.ps1'
Set-Content -Path $hookScript -Encoding utf8 -Value @'
# Ensures channelsEnabled + allowedChannelPlugins stay in remote-settings.json.
# Called by the Stop and UserPromptSubmit hooks to survive MDM/org-policy overwrites.
$remote = Join-Path $HOME ".claude\remote-settings.json"
try { $data = Get-Content -Raw $remote -ErrorAction Stop | ConvertFrom-Json }
catch { $data = [PSCustomObject]@{} }
$changed = $false
if (-not $data.PSObject.Properties['channelsEnabled'] -or -not $data.channelsEnabled) {
    $data | Add-Member -NotePropertyName 'channelsEnabled' -NotePropertyValue $true -Force
    $changed = $true
}
$entry    = [PSCustomObject]@{ marketplace = 'tlemmons-junto-inbox'; plugin = 'junto-inbox' }
$existing = @($data.allowedChannelPlugins)
if (-not ($existing | Where-Object { $_.marketplace -eq 'tlemmons-junto-inbox' -and $_.plugin -eq 'junto-inbox' })) {
    $data | Add-Member -NotePropertyName 'allowedChannelPlugins' -NotePropertyValue ($existing + $entry) -Force
    $changed = $true
}
if ($changed) {
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $remote -Encoding utf8
    Write-Host "[ensure-channel-settings] Restored channel keys to $remote"
}
'@
Write-Host "Hook created at $hookScript"

# -- Update ~/.claude/settings.json ----------------------------------------------

$settingsPath = Join-Path $claudeDir 'settings.json'
try   { $settings = Get-Content -Raw $settingsPath -ErrorAction Stop | ConvertFrom-Json }
catch { $settings = [PSCustomObject]@{} }

# Plugin marketplace + channel permissions
if (-not $settings.PSObject.Properties['extraKnownMarketplaces']) {
    $settings | Add-Member -NotePropertyName 'extraKnownMarketplaces' -NotePropertyValue ([PSCustomObject]@{}) -Force
}
$settings.extraKnownMarketplaces | Add-Member -NotePropertyName 'tlemmons-junto-inbox' -NotePropertyValue (
    [PSCustomObject]@{ source = [PSCustomObject]@{ source = 'github'; repo = 'tlemmons/junto-inbox' } }
) -Force
if (-not $settings.PSObject.Properties['enabledPlugins']) {
    $settings | Add-Member -NotePropertyName 'enabledPlugins' -NotePropertyValue ([PSCustomObject]@{}) -Force
}
$settings.enabledPlugins | Add-Member -NotePropertyName 'junto-inbox@tlemmons-junto-inbox' -NotePropertyValue $true -Force
$settings | Add-Member -NotePropertyName 'channelsEnabled' -NotePropertyValue $true -Force
if (-not $settings.PSObject.Properties['allowedChannelPlugins']) {
    $settings | Add-Member -NotePropertyName 'allowedChannelPlugins' -NotePropertyValue @() -Force
}
$existing = @($settings.allowedChannelPlugins)
if (-not ($existing | Where-Object { $_.marketplace -eq 'tlemmons-junto-inbox' })) {
    $settings | Add-Member -NotePropertyName 'allowedChannelPlugins' -NotePropertyValue (
        $existing + [PSCustomObject]@{ marketplace = 'tlemmons-junto-inbox'; plugin = 'junto-inbox' }
    ) -Force
}

# Point Claude Code's org-policy cache at our stable file
if (-not $settings.PSObject.Properties['env']) {
    $settings | Add-Member -NotePropertyName 'env' -NotePropertyValue ([PSCustomObject]@{}) -Force
}
$settings.env | Add-Member -NotePropertyName 'CLAUDE_CODE_REMOTE_SETTINGS_PATH' -NotePropertyValue $managedPath -Force

# Register hook (idempotent)
$hookCmd   = "powershell.exe -NoProfile -NonInteractive -File `"$hookScript`""
$hookEntry = [PSCustomObject]@{ type = 'command'; command = $hookCmd }
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force
}
foreach ($event in 'Stop', 'UserPromptSubmit') {
    if (-not $settings.hooks.PSObject.Properties[$event]) {
        $settings.hooks | Add-Member -NotePropertyName $event -NotePropertyValue @() -Force
    }
    $eventHooks = @($settings.hooks.$event)
    $alreadyWired = $eventHooks | Where-Object { ($_.hooks | Where-Object { $_.command -eq $hookCmd }) }
    if (-not $alreadyWired) {
        $settings.hooks.$event = $eventHooks + [PSCustomObject]@{ hooks = @($hookEntry) }
    }
}
$settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding utf8
Write-Host "Settings updated in $settingsPath"

# -- Write CLAUDE.md -------------------------------------------------------------

$claudeMd = Join-Path $PROJECT_DIR 'CLAUDE.md'
if (-not (Test-Path $claudeMd)) {
    # Backticks in the here-string are PS escape chars; `` produces a literal backtick.
    Set-Content -Path $claudeMd -Encoding utf8 -Value @"
# $JUNTO_AGENT

Your name is: ``$JUNTO_AGENT``

<!-- project="$JUNTO_PROJECT" -->
"@
    Write-Host "CLAUDE.md created at $claudeMd"
} else {
    Write-Host "CLAUDE.md already exists at $claudeMd -- skipping creation"
    Write-Host "  Make sure it contains: Your name is: ``$JUNTO_AGENT``"
}

# -- Create per-project settings.local.json --------------------------------------

$projectClaudeDir = Join-Path $PROJECT_DIR '.claude'
if (-not (Test-Path $projectClaudeDir)) { New-Item -ItemType Directory -Path $projectClaudeDir -Force | Out-Null }
$localSettings = Join-Path $projectClaudeDir 'settings.local.json'
if (-not (Test-Path $localSettings)) {
    [PSCustomObject]@{
        permissions               = [PSCustomObject]@{ allow = @('mcp__junto__*', 'mcp__plugin_junto-inbox_junto-inbox__*') }
        enableAllProjectMcpServers = $true
        enabledMcpjsonServers     = @('junto')
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $localSettings -Encoding utf8
    Write-Host "Project settings created at $localSettings"
} else {
    Write-Host "settings.local.json already exists at $localSettings -- skipping"
}
Write-Host ""

# -- Connectivity check ----------------------------------------------------------

$baseUrl = $JUNTO_MEMORY_URL -replace '/mcp$', ''
Write-Host -NoNewline "Testing server connectivity at $baseUrl/health ... "
try {
    $resp = Invoke-WebRequest -Uri "$baseUrl/health" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    if ($resp.StatusCode -eq 200) { Write-Host "OK" -ForegroundColor Green }
    else { Write-Host "HTTP $($resp.StatusCode)" -ForegroundColor Yellow }
} catch {
    Write-Host "UNREACHABLE" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Warning: server not reachable. If using Tailscale, run 'tailscale status'." -ForegroundColor Yellow
    Write-Host "  You can proceed -- the agent will report the issue when it starts." -ForegroundColor Yellow
}
Write-Host ""

# -- Launch in first-run mode ----------------------------------------------------

Write-Host "Launching ${JUNTO_AGENT}@${JUNTO_PROJECT} in first-run onboarding mode..."
Write-Host "(Your agent will walk you through the rest of the setup.)"
Write-Host ""

Set-Location $PROJECT_DIR
$env:JUNTO_OVERLAY = $FirstRunOverlay
& (Join-Path $JuntoDir 'junto-launch.ps1')
