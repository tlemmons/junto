#requires -version 5
<#
.SYNOPSIS
    Render junto-system-prompt.md.tmpl with variable substitution.

.DESCRIPTION
    PowerShell counterpart to render.sh. Same variable surface, same safety
    check: fails loud on unresolved `{{...}}` tokens.

    PowerShell 5.1 quirk: -Encoding utf8 is explicit on every file read/write
    to preserve UTF-8 content (em-dashes, etc.). Without it, BOM-less UTF-8
    files are read using the system ANSI codepage on stock Windows.

.PARAMETER Agent
    Agent name (e.g., "memory", "inbox", "coordinator").

.PARAMETER Project
    Project name (e.g., "junto", "nimbus").

.PARAMETER Role
    One-line role description.

.PARAMETER SharedMemoryUrl
    MCP shared-memory server URL.

.PARAMETER Cwd
    Working directory. Defaults to current location. Most launchers should
    pass this explicitly — the renderer's pwd is rarely what you want.

.PARAMETER PluginPresent
    Whether junto-inbox plugin is loaded. Defaults to $false.

.PARAMETER ApiKey
    Optional MCP server API key. If supplied, an auth-instruction block is
    injected into the prompt. Required for servers with MCP_AUTH_ENABLED=true.

.PARAMETER Overlay
    Optional path to a project overlay file.

.PARAMETER Extras
    Optional path to a per-agent extras file (applied after overlay).

.PARAMETER Out
    Output path. If omitted, writes to stdout.

.EXAMPLE
    .\render.ps1 -Agent inbox -Project junto -Role "channel plugin" `
        -SharedMemoryUrl http://localhost:8080/mcp `
        -Out $env:TEMP\junto-prompt.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Agent,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$Role,
    [Parameter(Mandatory)][string]$SharedMemoryUrl,
    [string]$Cwd = (Get-Location).Path,
    [bool]$PluginPresent = $false,
    [string]$ApiKey = "",
    [string]$Overlay = "",
    [string]$Extras = "",
    [string]$Out = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$base = Join-Path $scriptDir "junto-system-prompt.md.tmpl"

if (-not (Test-Path $base)) {
    Write-Error "render.ps1: base template not found: $base"
    exit 1
}

$pluginStr = if ($PluginPresent) { "true" } else { "false" }

if ($ApiKey) {
    $keyPrefix = $ApiKey.Substring(0, [Math]::Min(12, $ApiKey.Length))
    $authBlock = "- **Auth:** API key is configured via ``Authorization: Bearer`` HTTP header in ``~/.mcp.json``. Do NOT pass ``api_key`` as a tool argument -- the server reads the header automatically. (Key prefix: ``${keyPrefix}...``)"
} else {
    $authBlock = "- **Auth:** No API key configured. Server is in open-auth mode (``MCP_AUTH_ENABLED=false``) or this agent runs under default-tier access."
}

if ($PluginPresent) {
    $pluginSessionBlock = @"
## Plugin session vs agent session

Your launcher loaded the junto-inbox plugin. The plugin binds with its own session id (returned by ``get_session_id``). To avoid duplicate sessions, use the plugin's session id when it is ready -- call ``get_session_id()`` BEFORE ``memory_start_session``:

- If ``status: ready``: use the returned ``session_id`` for ALL ``mcp__junto__memory_*`` calls. Do NOT call ``memory_start_session`` -- it would open a duplicate session. Call ``memory_guidelines`` instead to get server-managed rules for this session.
- If ``status: not_ready``: fall back to ``memory_start_session`` as normal.
"@
} else {
    $pluginSessionBlock = ""
}

$content = Get-Content -Raw -Encoding utf8 -Path $base
if ($Overlay) {
    if (-not (Test-Path $Overlay)) { Write-Error "render.ps1: overlay missing: $Overlay"; exit 1 }
    $content += "`n`n## Project overlay`n`n" + (Get-Content -Raw -Encoding utf8 -Path $Overlay)
}
if ($Extras) {
    if (-not (Test-Path $Extras))  { Write-Error "render.ps1: extras missing: $Extras"; exit 1 }
    $content += "`n`n## Per-agent extras`n`n" + (Get-Content -Raw -Encoding utf8 -Path $Extras)
}

$content = $content.Replace('{{agent}}',                $Agent)
$content = $content.Replace('{{project}}',              $Project)
$content = $content.Replace('{{role}}',                 $Role)
$content = $content.Replace('{{shared_memory_url}}',    $SharedMemoryUrl)
$content = $content.Replace('{{cwd}}',                  $Cwd)
$content = $content.Replace('{{plugin_present}}',       $pluginStr)
$content = $content.Replace('{{auth_block}}',           $authBlock)
$content = $content.Replace('{{plugin_session_block}}', $pluginSessionBlock)

# Safety: fail loud on unresolved tokens.
$remaining = [regex]::Matches($content, '\{\{[^}]+\}\}')
if ($remaining.Count -gt 0) {
    Write-Error "render.ps1: unresolved tokens remain — refusing to ship:"
    $remaining | ForEach-Object { Write-Error "  $($_.Value)" }
    exit 3
}

if ($Out) {
    $outDir = Split-Path -Parent $Out
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    Set-Content -Path $Out -Value $content -NoNewline -Encoding utf8
    Write-Output $Out
} else {
    Write-Output $content
}
