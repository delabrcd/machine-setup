# Profile-driven dispatcher for Windows.
# Mirrors lib/driver.sh: shells out to lib/config.py for plan resolution,
# then dot-sources each component's windows.ps1 in dependency order.
#
# Caller (bootstrap.ps1) is expected to have set $script:MachineSetupDir
# (the repo root). All functions write through that.

$Global:FailedSteps = @()

function Write-Log   { Write-Host "==> $args" -ForegroundColor Green }
function Write-Warn  { Write-Host "WARN: $args" -ForegroundColor Yellow }
function Write-Step  { Write-Host "`n--- $args ---" -ForegroundColor Cyan }
function Write-Die   { Write-Host "ERROR: $args" -ForegroundColor Red; exit 1 }

function Get-Python {
    # Prefer py.exe launcher (most reliable on Windows), then python, then python3.
    foreach ($cmd in @("py", "python", "python3")) {
        $exe = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($exe) { return $exe.Source }
    }
    Write-Die "Python 3.11+ is required but not on PATH (try winget install Python.Python.3.13)"
}

function Invoke-Python {
    param([Parameter(ValueFromRemainingArguments)] $Args)
    $py = Get-Python
    & $py @Args
}

function Get-OsTag {
    if ($env:MACHINE_SETUP_OS_TAG) { return $env:MACHINE_SETUP_OS_TAG }
    return (Invoke-Python "$script:MachineSetupDir\lib\config.py" "os-tag").Trim()
}

function Get-Profiles {
    # Returns array of [pscustomobject]@{name; description; source}
    $lines = Invoke-Python "$script:MachineSetupDir\lib\config.py" "list-profiles"
    if (-not $lines) { return @() }
    return @($lines | Where-Object { $_ -match '\S' } | ForEach-Object {
        $_ | ConvertFrom-Json
    })
}

function Resolve-Plan {
    param([string]$ProfileName, [string]$OsTag)
    $args = @("$script:MachineSetupDir\lib\config.py", "resolve", $ProfileName)
    if ($OsTag) { $args += @("--os-tag", $OsTag) }
    $json = & (Get-Python) @args
    if ($LASTEXITCODE -ne 0) { Write-Die "Failed to resolve profile '$ProfileName'" }
    return ($json -join "`n") | ConvertFrom-Json
}

function Get-IdentityEnv {
    param([string]$IdentityName)
    $lines = Invoke-Python "$script:MachineSetupDir\lib\config.py" "identity-env" $IdentityName
    $map = @{}
    foreach ($line in $lines) {
        if ($line -match "^(IDENT_[A-Z_]+)='(.*)'$") {
            # Unescape the single-quote escape used by Python: '\\''  →  '
            $map[$matches[1]] = $matches[2] -replace "'\\''", "'"
        }
    }
    return $map
}

function Set-IdentityEnv {
    param([hashtable]$Env)
    foreach ($k in $Env.Keys) {
        Set-Item "env:$k" $Env[$k]
    }
}

function Clear-IdentityEnv {
    foreach ($k in @("IDENT_NAME","IDENT_GIT_NAME","IDENT_GIT_EMAIL",
                     "IDENT_BW_SSH_ITEM","IDENT_SSH_KEY_BASENAME",
                     "IDENT_DEFAULT","IDENT_APPLIES_TO_JSON")) {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
}

function Invoke-Component {
    param([Parameter(Mandatory)] $Component, [Parameter(Mandatory)] $Plan)
    $name = $Component.name
    $script = $Component.script

    Write-Step "Component: $name"
    if (-not $script -or -not (Test-Path $script)) {
        Write-Warn "No windows.ps1 for '$name' — skipping"
        return
    }

    # Per-component config available to the script as $env:COMPONENT_CONFIG_JSON
    $env:COMPONENT_CONFIG_JSON = ($Component.config | ConvertTo-Json -Compress)

    if ($Component.per_identity) {
        $count = 0
        foreach ($ident in $Plan.identities) {
            $count++
            Write-Log "↳ identity: $($ident.name)"
            $envMap = Get-IdentityEnv $ident.name
            Set-IdentityEnv $envMap
            try {
                & $script
            } catch {
                Write-Warn "Component '$name [$($ident.name)]' raised: $_"
                $Global:FailedSteps += "$name [$($ident.name)]"
            }
            Clear-IdentityEnv
        }
        if ($count -eq 0) {
            Write-Warn "Component '$name' is per-identity but profile has no identities — skipping"
        }
    } else {
        try {
            & $script
        } catch {
            Write-Warn "Component '$name' raised: $_"
            $Global:FailedSteps += $name
        }
    }
    Remove-Item env:COMPONENT_CONFIG_JSON -ErrorAction SilentlyContinue
}

function Invoke-Plan {
    param([Parameter(Mandatory)] $Plan)
    foreach ($comp in $Plan.components) {
        Invoke-Component -Component $comp -Plan $Plan
    }
}

function Write-Summary {
    Write-Host ""
    Write-Host "==============================" -ForegroundColor Green
    if ($Global:FailedSteps.Count -eq 0) {
        Write-Host "Bootstrap complete!" -ForegroundColor Green
    } else {
        Write-Host "Bootstrap finished with errors." -ForegroundColor Yellow
        Write-Host "Re-run after fixing:" -ForegroundColor Yellow
        foreach ($s in $Global:FailedSteps) { Write-Host "  - $s" }
    }
    Write-Host "==============================" -ForegroundColor Green
}

# ── Profile picker (TUI) ──────────────────────────────────────────────────────

$Global:MachineConfigDir = Join-Path $env:USERPROFILE ".config\machine-setup"
$Global:MachineConfigFile = Join-Path $Global:MachineConfigDir "machine.toml"

function Save-Profile {
    param([string]$Name)
    if (-not (Test-Path $Global:MachineConfigDir)) {
        New-Item -ItemType Directory -Force -Path $Global:MachineConfigDir | Out-Null
    }
    @"
# Auto-generated by machine-setup. Edit to switch profiles, or delete this file
# to be re-prompted on next bootstrap run.
profile = "$Name"
"@ | Set-Content -Path $Global:MachineConfigFile -Encoding utf8
}

function Read-SavedProfile {
    if (-not (Test-Path $Global:MachineConfigFile)) { return $null }
    $content = Get-Content $Global:MachineConfigFile -Raw
    if ($content -match 'profile\s*=\s*"([^"]+)"') { return $matches[1] }
    return $null
}

function Select-Profile {
    param([switch]$Force)
    if ($env:MACHINE_SETUP_PROFILE -and -not $Force) {
        Write-Log "Using profile from MACHINE_SETUP_PROFILE: $($env:MACHINE_SETUP_PROFILE)"
        return $env:MACHINE_SETUP_PROFILE
    }
    if (-not $Force) {
        $saved = Read-SavedProfile
        if ($saved) {
            Write-Log "Using saved profile: $saved  ($Global:MachineConfigFile)"
            return $saved
        }
    }
    $profiles = Get-Profiles
    if (-not $profiles -or $profiles.Count -eq 0) {
        Write-Die "No profiles found. Add one to profiles/ or local/profiles/."
    }

    Write-Host ""
    Write-Host "Pick a profile for this machine:" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $p = $profiles[$i]
        $desc = if ($p.description) { " — $($p.description)" } else { "" }
        Write-Host ("  {0}) {1}{2}  [{3}]" -f ($i + 1), $p.name, $desc, $p.source)
    }
    Write-Host ""
    while ($true) {
        $choice = Read-Host "Enter number (1-$($profiles.Count))"
        if ($choice -match '^\d+$') {
            $n = [int]$choice
            if ($n -ge 1 -and $n -le $profiles.Count) {
                $picked = $profiles[$n - 1].name
                Save-Profile $picked
                Write-Log "Saved selection to $Global:MachineConfigFile"
                return $picked
            }
        }
        Write-Host "Invalid choice." -ForegroundColor Yellow
    }
}
