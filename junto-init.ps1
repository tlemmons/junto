#Requires -Version 5.1
<#
.SYNOPSIS
    junto-init.ps1 -- initialize or update a project workspace for junto (Windows).

.DESCRIPTION
    Run from any directory in your project tree. Walks up to find any existing
    CLAUDE.md (shows inherited context), then creates or updates a CLAUDE.md in
    the CURRENT directory and creates .claude\settings.local.json if missing.

    After running, junto-launch.ps1 will walk up and find the CLAUDE.md
    automatically from any subdirectory.

    Re-running is safe -- shows current values as defaults.

.EXAMPLE
    cd C:\code\my-project
    & "$HOME\.junto\junto-init.ps1"
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$JuntoDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $JuntoDir 'config'
$cwd        = (Get-Location).Path

# -- Load agent name from config ------------------------------------------------

$configAgent = ''
if (Test-Path $ConfigPath) {
    $line = Get-Content $ConfigPath | Where-Object { $_ -match '^JUNTO_AGENT="([^"]*)"' } | Select-Object -First 1
    if ($line -match '^JUNTO_AGENT="([^"]*)"') { $configAgent = $Matches[1] }
}

# -- Walk up to find nearest existing CLAUDE.md ---------------------------------

$existingClaudeMd   = $null
$inheritedAgent     = ''
$inheritedProject   = ''
$inheritedComponent = ''

$dir = Split-Path -Parent $cwd
while ($dir -ne $HOME -and $dir -ne (Split-Path -Parent $dir)) {
    $candidate = Join-Path $dir 'CLAUDE.md'
    if (Test-Path $candidate) {
        $existingClaudeMd = $candidate
        $content = Get-Content $candidate -Raw -ErrorAction SilentlyContinue
        if ($content -match 'Your name is:[ \t]*`([^`]+)`')  { $inheritedAgent     = $Matches[1] }
        if ($content -match 'project="([^"]+)"')              { $inheritedProject   = $Matches[1] }
        if ($content -match 'component="([^"]+)"')            { $inheritedComponent = $Matches[1] }
        break
    }
    $dir = Split-Path -Parent $dir
}

# -- Display banner -------------------------------------------------------------

Write-Host ""
Write-Host "=== junto-init -- project workspace setup ===" -ForegroundColor Cyan
Write-Host "Directory: $cwd"
Write-Host ""

$targetClaudeMd = Join-Path $cwd 'CLAUDE.md'

if (Test-Path $targetClaudeMd) {
    $content = Get-Content $targetClaudeMd -Raw -ErrorAction SilentlyContinue
    $curAgent = $curProject = $curComponent = ''
    if ($content -match 'Your name is:[ \t]*`([^`]+)`')  { $curAgent     = $Matches[1] }
    if ($content -match 'project="([^"]+)"')              { $curProject   = $Matches[1] }
    if ($content -match 'component="([^"]+)"')            { $curComponent = $Matches[1] }
    Write-Host "Existing CLAUDE.md found -- updating." -ForegroundColor Yellow
    Write-Host "  Agent:     $(if ($curAgent) { $curAgent } else { '(not set)' })"
    Write-Host "  Project:   $(if ($curProject) { $curProject } else { '(not set)' })"
    Write-Host "  Component: $(if ($curComponent) { $curComponent } else { '(none)' })"
    Write-Host ""
    $defaultAgent     = if ($curAgent)     { $curAgent }     else { $configAgent }
    $defaultProject   = $curProject
    $defaultComponent = $curComponent
} elseif ($existingClaudeMd) {
    Write-Host "Found CLAUDE.md in a parent directory: $existingClaudeMd" -ForegroundColor Yellow
    Write-Host "  Inherited agent:     $(if ($inheritedAgent) { $inheritedAgent } else { '(not set)' })"
    Write-Host "  Inherited project:   $(if ($inheritedProject) { $inheritedProject } else { '(not set)' })"
    Write-Host "  Inherited component: $(if ($inheritedComponent) { $inheritedComponent } else { '(none)' })"
    Write-Host ""
    Write-Host "Creating a NEW CLAUDE.md in $cwd."
    Write-Host "You can inherit the same project/component or set a different one."
    Write-Host ""
    $defaultAgent     = if ($inheritedAgent)     { $inheritedAgent }     else { $configAgent }
    $defaultProject   = $inheritedProject
    $defaultComponent = $inheritedComponent
} else {
    Write-Host "No existing CLAUDE.md found in this directory or any parent."
    $defaultAgent     = if ($configAgent) { $configAgent } else { Split-Path -Leaf $cwd }
    $defaultProject   = (Split-Path -Leaf $cwd) -replace '[^a-z0-9-]', '' | ForEach-Object { $_.ToLower() }
    $defaultComponent = ''
}

# -- Prompts --------------------------------------------------------------------

$agentSuffix   = if ($defaultAgent)     { " [$defaultAgent]" }   else { '' }
$projSuffix    = if ($defaultProject)   { " [$defaultProject]" } else { '' }
$compSuffix    = if ($defaultComponent) { " [$defaultComponent] (Enter=keep, 'none'=clear)" } else { ' (optional, Enter to skip)' }

$inputAgent     = (Read-Host "Agent name$agentSuffix").Trim()
$inputProject   = (Read-Host "Project name$projSuffix").Trim()
$inputComponent = (Read-Host "Component/subproject$compSuffix").Trim()

$newAgent   = if ($inputAgent)   { $inputAgent }   else { $defaultAgent }
$newProject = if ($inputProject) { ($inputProject.ToLower() -replace '[^a-z0-9_-]', '_') } else { $defaultProject }

if ([string]::IsNullOrEmpty($newAgent))   { Write-Error "Agent name cannot be empty.";   exit 1 }
if ([string]::IsNullOrEmpty($newProject)) { Write-Error "Project name cannot be empty."; exit 1 }

if ($inputComponent -eq 'none') {
    $newComponent = ''
} elseif ([string]::IsNullOrEmpty($inputComponent)) {
    $newComponent = $defaultComponent
} else {
    $newComponent = $inputComponent.ToLower() -replace '[^a-z0-9_-]', '_'
}

# -- Confirm --------------------------------------------------------------------

Write-Host ""
Write-Host "Will write to: $targetClaudeMd"
Write-Host "  Agent:     $newAgent"
Write-Host "  Project:   $newProject"
Write-Host "  Component: $(if ($newComponent) { $newComponent } else { '(none)' })"
Write-Host ""
$confirm = (Read-Host "Confirm? [Y/n]").Trim()
if ($confirm -and $confirm -notmatch '^[Yy]') { Write-Host "Aborted."; exit 0 }

# -- Write CLAUDE.md ------------------------------------------------------------

$lines = @(
    "# $newAgent",
    "",
    "Your name is: ``$newAgent``",
    "",
    "<!-- project=`"$newProject`" -->"
)
if ($newComponent) { $lines += "<!-- component=`"$newComponent`" -->" }
Set-Content -Path $targetClaudeMd -Value ($lines -join "`n") -Encoding utf8

$ctx = "$newAgent@$newProject"
if ($newComponent) { $ctx += ":$newComponent" }
Write-Host "CLAUDE.md written -- $ctx" -ForegroundColor Green

# -- Create .claude\settings.local.json if missing ------------------------------

$projectClaudeDir  = Join-Path $cwd '.claude'
$localSettings     = Join-Path $projectClaudeDir 'settings.local.json'
if (-not (Test-Path $projectClaudeDir)) { New-Item -ItemType Directory -Path $projectClaudeDir -Force | Out-Null }

if (-not (Test-Path $localSettings)) {
    [PSCustomObject]@{
        permissions               = [PSCustomObject]@{ allow = @('mcp__junto__*', 'mcp__plugin_junto-inbox_junto-inbox__*') }
        enableAllProjectMcpServers = $true
        enabledMcpjsonServers     = @('junto')
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $localSettings -Encoding utf8
    Write-Host "Created .claude\settings.local.json (junto tools pre-approved)"
} else {
    Write-Host ".claude\settings.local.json already exists -- skipping"
}

Write-Host ""
Write-Host "Done. Run 'junto' from this directory (or any subdirectory) to start your agent." -ForegroundColor Green
