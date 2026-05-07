<#
.SYNOPSIS
  One-shot migration: push everything currently in local/ to Bitwarden.

.DESCRIPTION
  Walks local/profiles/*.toml and local/identities/*.toml, creating BW items:
    - "Machine Profile: <name>"   (Secure Note, body = file content)
    - "Machine Identity: <name>"  (Secure Note, fields from TOML; SSH key
                                   fields copied from the existing BW item
                                   named in the TOML's `bw_ssh_item` field)
  Idempotent — re-running updates in place.

.PARAMETER DryRun
  Print what would be pushed without making changes.

.PARAMETER SkipProfiles
  Migrate identities only.

.PARAMETER SkipIdentities
  Migrate profiles only.

.EXAMPLE
  $env:BW_SESSION = (bw unlock --raw)
  .\tools\migrate-to-bw.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipProfiles,
    [switch]$SkipIdentities
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command bw -ErrorAction SilentlyContinue)) { throw "bw CLI not on PATH" }
if (-not $env:BW_SESSION) { throw "BW_SESSION not set. Run: `$env:BW_SESSION = (bw unlock --raw)" }

$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Step {
    param([string]$Description, [scriptblock]$Action)
    Write-Host "==> $Description" -ForegroundColor Green
    if ($DryRun) {
        Write-Host "  [dry-run]" -ForegroundColor Yellow
        return
    }
    & $Action
}

# Resolve a python interpreter once
$python = (Get-Command py, python, python3 -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $python) { throw "python3 not on PATH" }

# ── Profiles ────────────────────────────────────────────────────────────────
if (-not $SkipProfiles) {
    Write-Host "`n--- Profiles ---" -ForegroundColor Cyan
    $profiles = Get-ChildItem -Path (Join-Path $repoRoot "local\profiles") -Filter "*.toml" -ErrorAction SilentlyContinue
    if (-not $profiles) {
        Write-Host "  (no local/profiles/*.toml)" -ForegroundColor DarkGray
    }
    foreach ($f in $profiles) {
        $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        Invoke-Step "$($f.FullName) -> Machine Profile: $name" {
            & "$repoRoot\tools\seed-bw-profile.ps1" push $f.FullName
        }
    }
}

# ── Identities ─────────────────────────────────────────────────────────────
if (-not $SkipIdentities) {
    Write-Host "`n--- Identities ---" -ForegroundColor Cyan
    $identities = Get-ChildItem -Path (Join-Path $repoRoot "local\identities") -Filter "*.toml" -ErrorAction SilentlyContinue
    if (-not $identities) {
        Write-Host "  (no local/identities/*.toml)" -ForegroundColor DarkGray
    }
    foreach ($f in $identities) {
        $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        # Read bw_ssh_item from the TOML
        $sshFrom = & $python -c @"
import sys, tomllib
with open(sys.argv[1], 'rb') as fp:
    d = tomllib.load(fp)
print(d.get('bw_ssh_item', '') or '')
"@ $f.FullName

        $sshFrom = $sshFrom.Trim()
        $targetName = "Machine Identity: $name"

        $seed = Join-Path $repoRoot "tools\seed-bw-identity.ps1"
        if ($sshFrom -and $sshFrom -ne $targetName) {
            Invoke-Step "$($f.FullName) -> $targetName  (SSH from '$sshFrom')" {
                & $seed from-toml $f.FullName -SshFrom $sshFrom
            }
        } elseif ($sshFrom -eq $targetName) {
            Invoke-Step "$($f.FullName) -> $targetName  (SSH already in place)" {
                & $seed from-toml $f.FullName
            }
        } else {
            Write-Warning "  $($f.FullName) has no bw_ssh_item field -- pushing without SSH key"
            Invoke-Step "$($f.FullName) -> $targetName" {
                & $seed from-toml $f.FullName
            }
        }
    }
}

if ($DryRun) {
    Write-Host "`nDry run complete. Re-run without -DryRun to apply." -ForegroundColor Green
} else {
    Write-Host "`nMigration complete. Once verified, you can delete local/profiles/* and local/identities/* -- the bootstrap will discover them from BW." -ForegroundColor Green
}
