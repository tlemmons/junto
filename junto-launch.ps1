#Requires -Version 5.1
<#
.SYNOPSIS
    junto-launch.ps1 -- launch Claude Code with the junto system prompt on Windows.

.DESCRIPTION
    Windows counterpart to junto-launch.sh. Same identity resolution priority:
      1. JUNTO_AGENT / JUNTO_PROJECT env vars (hard override)
      2. .agent-name file in cwd
      3. CLAUDE.md auto-detection ("Your name is: `X`" / <!-- project="X" -->)
      4. Interactive prompt on first launch in a new directory
      5. cwd basename fallback (non-interactive / CI)

.PARAMETER NoPlugin
    Disable junto-inbox channel push (push is on by default).

.PARAMETER ClaudeArgs
    Additional arguments forwarded to claude.

.EXAMPLE
    cd C:\code\my-project
    & "$HOME\.junto\junto-launch.ps1"
    & "$HOME\.junto\junto-launch.ps1" -NoPlugin

.NOTES
    junto is the recommended alias. Add to your PowerShell profile:
      Set-Alias junto "$HOME\.junto\junto-launch.ps1"
#>

[CmdletBinding()]
param(
    [switch]$NoPlugin,
    [Parameter(ValueFromRemainingArguments)][string[]]$ClaudeArgs
)

$ErrorActionPreference = 'Stop'

$JuntoDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath  = Join-Path $JuntoDir 'config'
$TemplatesDir = Join-Path $JuntoDir 'templates'

# -- Load config (does not override env vars already set in the shell) -----------

if (Test-Path $ConfigPath) {
    Get-Content $ConfigPath | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)="([^"]*)"' -and $_ -notmatch '^\s*#') {
            $varName = $Matches[1]; $varValue = $Matches[2]
            if (-not [System.Environment]::GetEnvironmentVariable($varName, 'Process')) {
                [System.Environment]::SetEnvironmentVariable($varName, $varValue, 'Process')
            }
        }
    }
}

# -- Identity resolution ---------------------------------------------------------

$cwd           = (Get-Location).Path
$claudeMdPath  = Join-Path $cwd 'CLAUDE.md'
$agentNameFile = Join-Path $cwd '.agent-name'

function Read-AgentNameFile {
    if ($env:JUNTO_AGENT) { return }
    if (-not (Test-Path $agentNameFile)) { return }
    $a = (Get-Content $agentNameFile -First 1 -ErrorAction SilentlyContinue).Trim()
    if ($a) { $env:JUNTO_AGENT = $a }
}

function Read-ClaudeMd {
    if ($env:JUNTO_AGENT -and $env:JUNTO_PROJECT) { return }
    if (-not (Test-Path $claudeMdPath)) { return }
    $content = Get-Content $claudeMdPath -Raw -ErrorAction SilentlyContinue
    if (-not $env:JUNTO_AGENT) {
        if ($content -match 'Your name is:[ \t]*`([^`]+)`') { $env:JUNTO_AGENT = $Matches[1] }
    }
    if (-not $env:JUNTO_PROJECT) {
        if ($content -match 'project="([^"]+)"') { $env:JUNTO_PROJECT = $Matches[1] }
    }
}

function Initialize-Directory {
    $defaultAgent   = Split-Path -Leaf $cwd
    $defaultProject = ($defaultAgent -replace '[^a-z0-9-]', '').ToLower()
    Write-Host ""
    Write-Host "junto: No CLAUDE.md found in $cwd" -ForegroundColor Yellow
    Write-Host "junto: Enter identity for this directory (permanent -- saved to CLAUDE.md)." -ForegroundColor Yellow
    Write-Host ""
    $inputAgent   = (Read-Host "  Agent name   [$defaultAgent]").Trim()
    $inputProject = (Read-Host "  Project name [$defaultProject]").Trim()
    $env:JUNTO_AGENT   = if ($inputAgent)   { $inputAgent }   else { $defaultAgent }
    $env:JUNTO_PROJECT = if ($inputProject) { $inputProject } else { $defaultProject }
    Set-Content -Path $claudeMdPath -Encoding utf8 -Value @"
# $($env:JUNTO_AGENT)

Your name is: ``$($env:JUNTO_AGENT)``

<!-- project="$($env:JUNTO_PROJECT)" -->
"@
    Write-Host ""
    Write-Host "junto: Created CLAUDE.md -- $($env:JUNTO_AGENT)@$($env:JUNTO_PROJECT)" -ForegroundColor Green
    Write-Host ""
}

Read-AgentNameFile
Read-ClaudeMd

if (-not $env:JUNTO_AGENT -or -not $env:JUNTO_PROJECT) {
    # Interactive check: $Host.UI.RawUI available and stdout is a console
    if ($Host.Name -ne 'ConsoleHost' -or [System.Console]::IsOutputRedirected) {
        $env:JUNTO_AGENT   = if ($env:JUNTO_AGENT)   { $env:JUNTO_AGENT }   else { Split-Path -Leaf $cwd }
        $env:JUNTO_PROJECT = if ($env:JUNTO_PROJECT) { $env:JUNTO_PROJECT } else { Split-Path -Leaf $cwd }
        Write-Host "junto-launch: no CLAUDE.md in $cwd, using $($env:JUNTO_AGENT)@$($env:JUNTO_PROJECT)" -ForegroundColor Yellow
    } else {
        Initialize-Directory
    }
}

# -- Apply defaults for anything still unset -------------------------------------

if (-not $env:JUNTO_ROLE)       { $env:JUNTO_ROLE       = 'General work agent' }
if (-not $env:JUNTO_MEMORY_URL) { $env:JUNTO_MEMORY_URL = 'http://your-junto-server:8080/mcp' }

if (-not $env:JUNTO_API_KEY) {
    Write-Error "junto-launch: JUNTO_API_KEY is not set. Add it to $ConfigPath or export it."
    exit 1
}

# Bridge env var name: plugin reads JUNTO_SHARED_MEMORY_URL; config uses JUNTO_MEMORY_URL.
$env:JUNTO_SHARED_MEMORY_URL = $env:JUNTO_MEMORY_URL

# -- Pre-flight: ensure channel settings in remote-settings.json -----------------

if (-not $NoPlugin) {
    $hookScript = Join-Path $HOME '.claude\hooks\ensure-channel-settings.ps1'
    if (Test-Path $hookScript) {
        & powershell.exe -NoProfile -NonInteractive -File $hookScript
    }
}

# -- Render the system prompt ----------------------------------------------------

$promptFile  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "junto-$($env:JUNTO_AGENT)-$($env:JUNTO_PROJECT)-prompt.md")
$renderArgs  = @{
    Agent           = $env:JUNTO_AGENT
    Project         = $env:JUNTO_PROJECT
    Role            = $env:JUNTO_ROLE
    SharedMemoryUrl = $env:JUNTO_MEMORY_URL
    Cwd             = $cwd
    ApiKey          = $env:JUNTO_API_KEY
    PluginPresent   = (-not $NoPlugin.IsPresent)
    Out             = $promptFile
}
if ($env:JUNTO_OVERLAY -and (Test-Path $env:JUNTO_OVERLAY)) {
    $renderArgs['Overlay'] = $env:JUNTO_OVERLAY
}
& (Join-Path $TemplatesDir 'render.ps1') @renderArgs | Out-Null

# -- Opt into Sonnet 1M context window -------------------------------------------
# Same per-token cost as 200K; reduces compaction frequency significantly.

if (-not $env:ANTHROPIC_DEFAULT_SONNET_MODEL) {
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-4-6[1m]'
}

# -- Ensure managed-remote-settings.json is seen before Claude Code's own settings

$managedSettings = Join-Path $HOME '.claude\managed-remote-settings.json'
if (Test-Path $managedSettings -and -not $env:CLAUDE_CODE_REMOTE_SETTINGS_PATH) {
    $env:CLAUDE_CODE_REMOTE_SETTINGS_PATH = $managedSettings
}

# -- Launch ----------------------------------------------------------------------

Write-Host "junto: launching $($env:JUNTO_AGENT)@$($env:JUNTO_PROJECT) -> $($env:JUNTO_MEMORY_URL)" -ForegroundColor Cyan
if (-not $NoPlugin) { Write-Host "junto: push plugin enabled" -ForegroundColor Cyan }

$allClaudeArgs = @('--append-system-prompt-file', $promptFile)
if (-not $NoPlugin) {
    $allClaudeArgs += '--dangerously-load-development-channels'
    $allClaudeArgs += 'plugin:junto-inbox@tlemmons-junto-inbox'
}
if ($ClaudeArgs) { $allClaudeArgs += $ClaudeArgs }

& claude @allClaudeArgs
