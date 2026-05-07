#Requires -Version 5.1
<#
.SYNOPSIS
  Profile-driven Windows bootstrap.

.DESCRIPTION
  Mirror of bootstrap.sh -- same profile/identity/component model, but driving
  Windows-side scripts (winget installs, ssh-agent service, PowerShell profile,
  WSL delegation, etc.). The same profile file works on both -- each component
  declares which OSes it supports and the resolver filters automatically.

.PARAMETER Reconfigure
  Re-run both the profile and component pickers even if saved choices exist.

.PARAMETER Quiet
  Skip the component picker on first run; use the profile's component list as-is.
  (Subsequent runs are non-interactive anyway once a selection is saved.)

.NOTES
  Prereqs: git available (or winget can install it).
#>
param(
    [switch]$Reconfigure,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:MachineSetupDir = $PSScriptRoot

# Self-update + re-exec ------------------------------------------------------
if ((Test-Path "$script:MachineSetupDir\.git") -and -not $env:_BOOTSTRAP_UPDATED) {
    Write-Host "==> Updating machine-setup..." -ForegroundColor Green
    & { $ErrorActionPreference = "Continue"; git -C $script:MachineSetupDir fetch origin 2>$null }
    if ($LASTEXITCODE -eq 0) {
        git -C $script:MachineSetupDir reset --hard origin/HEAD
    } else {
        Write-Host "WARN: could not fetch updates - using local copy" -ForegroundColor Yellow
    }
    $env:_BOOTSTRAP_UPDATED = "1"
    $argv = @()
    if ($Reconfigure) { $argv += "-Reconfigure" }
    if ($Quiet)       { $argv += "-Quiet" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:MachineSetupDir\bootstrap.ps1" @argv
    exit $LASTEXITCODE
}

. "$script:MachineSetupDir\lib\Driver.ps1"
. "$script:MachineSetupDir\lib\BwSession.ps1"

# OS tag detection -----------------------------------------------------------
Write-Step "OS detection"
$osTag = Get-OsTag
Write-Log "OS tag: $osTag"

# Profile selection ----------------------------------------------------------
Write-Step "Profile selection"
$profileName = Select-Profile -Force:$Reconfigure
Write-Log "Profile: $profileName"

# Component selection --------------------------------------------------------
Write-Step "Component selection"
$componentsOverride = Select-Components -ProfileName $profileName -OsTag $osTag `
    -Force:$Reconfigure -Quiet:$Quiet

# Resolve plan ---------------------------------------------------------------
Write-Step "Resolve plan"
$script:Plan = Resolve-Plan -ProfileName $profileName -OsTag $osTag -Components $componentsOverride
Write-Log ("Components: " + (($script:Plan.components | ForEach-Object { $_.name }) -join " "))
Write-Log ("Identities: " + (($script:Plan.identities | ForEach-Object { $_.name }) -join " "))

# Bitwarden session ----------------------------------------------------------
Write-Step "Bitwarden session"
if (Test-BwSessionRequired -Plan $script:Plan) {
    if (-not (Unlock-BwSession)) {
        Write-Warn "BW unlock failed -- components requiring it will be skipped"
    }
} else {
    Write-Log "No component in this profile needs Bitwarden -- skipping unlock."
}

# Run components -------------------------------------------------------------
Invoke-Plan -Plan $script:Plan
Write-Summary

# Cleanup --------------------------------------------------------------------
Remove-Item env:BW_PASSWORD -ErrorAction SilentlyContinue
Remove-Item env:_BOOTSTRAP_UPDATED -ErrorAction SilentlyContinue
