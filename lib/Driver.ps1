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
    param([string]$ProfileName, [string]$OsTag, [string]$Components)
    $args = @("$script:MachineSetupDir\lib\config.py", "resolve", $ProfileName)
    if ($OsTag)      { $args += @("--os-tag", $OsTag) }
    if ($Components) { $args += @("--components", $Components) }
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
            # Unescape the single-quote escape used by Python: '\\''  ->  '
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
        Write-Warn "No windows.ps1 for '$name' -- skipping"
        return
    }

    # Per-component config available to the script as $env:COMPONENT_CONFIG_JSON
    $env:COMPONENT_CONFIG_JSON = ($Component.config | ConvertTo-Json -Compress)

    if ($Component.per_identity) {
        $count = 0
        foreach ($ident in $Plan.identities) {
            $count++
            Write-Log "-> identity: $($ident.name)"
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
            Write-Warn "Component '$name' is per-identity but profile has no identities -- skipping"
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

# -- machine.toml -------------------------------------------------------------

$Global:MachineConfigDir  = Join-Path $env:USERPROFILE ".config\machine-setup"
$Global:MachineConfigFile = Join-Path $Global:MachineConfigDir "machine.toml"

# Read a single key from machine.toml. Returns string for scalar, array for
# list values, $null if the key is absent.
function Get-MachineConfig {
    param([string]$Key)
    if (-not (Test-Path $Global:MachineConfigFile)) { return $null }
    $content = Get-Content $Global:MachineConfigFile -Raw
    # array form: components = ["a", "b", "c"]
    $arrPattern = '(?m)^' + [regex]::Escape($Key) + '\s*=\s*\[(.*?)\]'
    if ($content -match $arrPattern) {
        $inner = $matches[1]
        $items = [regex]::Matches($inner, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
        return @($items)
    }
    # scalar form: profile = "..."
    $scalarPattern = '(?m)^' + [regex]::Escape($Key) + '\s*=\s*"([^"]*)"'
    if ($content -match $scalarPattern) { return $matches[1] }
    return $null
}

# Write the entire machine.toml from a hashtable. Preserves key order.
function Set-MachineConfigFile {
    param([hashtable]$Data)
    if (-not (Test-Path $Global:MachineConfigDir)) {
        New-Item -ItemType Directory -Force -Path $Global:MachineConfigDir | Out-Null
    }
    $lines = @(
        "# Auto-generated by machine-setup. Edit to switch settings, or delete",
        "# this file to be re-prompted on next bootstrap run.",
        ""
    )
    foreach ($k in $Data.Keys) {
        $v = $Data[$k]
        if ($v -is [array]) {
            $items = ($v | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ", "
            $lines += "$k = [$items]"
        } else {
            $lines += "$k = `"$v`""
        }
    }
    ($lines -join "`n") + "`n" | Set-Content -Path $Global:MachineConfigFile -Encoding utf8
}

# Update one key in machine.toml without losing the others.
function Set-MachineConfig {
    param([string]$Key, $Value)
    $data = [ordered]@{}
    if (Test-Path $Global:MachineConfigFile) {
        # Read all existing keys back. Cheaper than a full TOML parser since
        # we only emit very simple shapes.
        $content = Get-Content $Global:MachineConfigFile -Raw
        foreach ($m in [regex]::Matches($content, '(?m)^([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(.+)$')) {
            $existingKey = $m.Groups[1].Value
            if ($existingKey -eq $Key) { continue }   # we're about to overwrite it
            $rhs = $m.Groups[2].Value.Trim()
            if ($rhs.StartsWith("[")) {
                $items = [regex]::Matches($rhs, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
                $data[$existingKey] = @($items)
            } elseif ($rhs.StartsWith('"')) {
                $data[$existingKey] = ($rhs -replace '^"|"$', '')
            }
        }
    }
    $data[$Key] = $Value
    Set-MachineConfigFile -Data ([hashtable]$data)
}

function Remove-MachineConfigKey {
    param([string]$Key)
    if (-not (Test-Path $Global:MachineConfigFile)) { return }
    $data = [ordered]@{}
    $content = Get-Content $Global:MachineConfigFile -Raw
    foreach ($m in [regex]::Matches($content, '(?m)^([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(.+)$')) {
        $existingKey = $m.Groups[1].Value
        if ($existingKey -eq $Key) { continue }
        $rhs = $m.Groups[2].Value.Trim()
        if ($rhs.StartsWith("[")) {
            $items = [regex]::Matches($rhs, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
            $data[$existingKey] = @($items)
        } elseif ($rhs.StartsWith('"')) {
            $data[$existingKey] = ($rhs -replace '^"|"$', '')
        }
    }
    Set-MachineConfigFile -Data ([hashtable]$data)
}

# -- Profile picker ----------------------------------------------------------

function Select-Profile {
    param([switch]$Force)
    if ($env:MACHINE_SETUP_PROFILE -and -not $Force) {
        Write-Log "Using profile from MACHINE_SETUP_PROFILE: $($env:MACHINE_SETUP_PROFILE)"
        return $env:MACHINE_SETUP_PROFILE
    }
    if (-not $Force) {
        $saved = Get-MachineConfig profile
        if ($saved) {
            Write-Log "Using saved profile: $saved  ($Global:MachineConfigFile)"
            return $saved
        }
    } else {
        # Force re-pick: clear both saved profile and saved component override
        if (Test-Path $Global:MachineConfigFile) { Remove-Item $Global:MachineConfigFile -Force }
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
        $desc = if ($p.description) { " -- $($p.description)" } else { "" }
        Write-Host ("  {0}) {1}{2}  [{3}]" -f ($i + 1), $p.name, $desc, $p.source)
    }
    Write-Host ""
    while ($true) {
        $choice = Read-Host "Enter number (1-$($profiles.Count))"
        if ($choice -match '^\d+$') {
            $n = [int]$choice
            if ($n -ge 1 -and $n -le $profiles.Count) {
                $picked = $profiles[$n - 1].name
                Set-MachineConfig profile $picked
                Write-Log "Saved profile to $Global:MachineConfigFile"
                return $picked
            }
        }
        Write-Host "Invalid choice." -ForegroundColor Yellow
    }
}

# -- Component picker --------------------------------------------------------

function Get-AvailableComponents {
    param([string]$ProfileName, [string]$OsTag)
    $args = @("$script:MachineSetupDir\lib\config.py", "list-components", "--profile", $ProfileName)
    if ($OsTag) { $args += @("--os-tag", $OsTag) }
    $lines = & (Get-Python) @args
    $out = @()
    foreach ($line in $lines) {
        if ($line -match '\S') { $out += ($line | ConvertFrom-Json) }
    }
    return $out
}

# Returns a comma-separated string of selected component names, or $null if
# the user wants to use the profile's defaults (e.g. quiet mode).
function Select-Components {
    param(
        [Parameter(Mandatory)] [string]$ProfileName,
        [Parameter(Mandatory)] [string]$OsTag,
        [switch]$Force,
        [switch]$Quiet
    )
    if ($env:MACHINE_SETUP_COMPONENTS) {
        Write-Log "Using components from MACHINE_SETUP_COMPONENTS"
        return $env:MACHINE_SETUP_COMPONENTS
    }
    if (-not $Force) {
        $saved = Get-MachineConfig components
        if ($saved -is [array] -and $saved.Count -gt 0) {
            Write-Log "Using saved component selection ($Global:MachineConfigFile)"
            return ($saved -join ",")
        }
    } else {
        Remove-MachineConfigKey components
    }
    if ($Quiet) {
        Write-Log "Quiet mode: using profile's component list as-is."
        return $null
    }

    $components = Get-AvailableComponents -ProfileName $ProfileName -OsTag $OsTag
    if (-not $components -or $components.Count -eq 0) {
        Write-Warn "No components found for OS tag '$OsTag' -- using profile defaults"
        return $null
    }

    # selection state, indexed alongside $components
    $selected = New-Object 'System.Collections.Generic.List[bool]'
    foreach ($c in $components) { $selected.Add([bool]$c.in_profile) }

    while ($true) {
        Write-Host ""
        Write-Host "Components for profile '$ProfileName' -- toggle by number, ENTER to confirm:" -ForegroundColor Cyan
        Write-Host ""
        for ($i = 0; $i -lt $components.Count; $i++) {
            $mark = if ($selected[$i]) { "[x]" } else { "[ ]" }
            $desc = $components[$i].description
            if ($desc.Length -gt 55) { $desc = $desc.Substring(0, 52) + "..." }
            $line = "  {0,2}) {1} {2,-22} {3}" -f ($i + 1), $mark, $components[$i].name, $desc
            if ($selected[$i]) {
                Write-Host $line -ForegroundColor Green
            } else {
                Write-Host $line -ForegroundColor DarkGray
            }
        }
        Write-Host ""
        Write-Host "Tip: deps are auto-pulled in by the resolver, so toggling a single component is fine." -ForegroundColor DarkGray
        $input = Read-Host "Enter numbers to toggle, or ENTER to confirm"
        if (-not $input -or $input.Trim() -eq "") { break }
        foreach ($tok in ($input -split '\s+')) {
            if ($tok -match '^\d+$') {
                $n = [int]$tok
                if ($n -ge 1 -and $n -le $components.Count) {
                    $selected[$n - 1] = -not $selected[$n - 1]
                } else {
                    Write-Host "  ignored: $tok (out of range)" -ForegroundColor Yellow
                }
            } elseif ($tok) {
                Write-Host "  ignored: $tok" -ForegroundColor Yellow
            }
        }
    }

    $picked = @()
    for ($i = 0; $i -lt $components.Count; $i++) {
        if ($selected[$i]) { $picked += $components[$i].name }
    }
    Set-MachineConfig components $picked
    Write-Log "Saved component selection to $Global:MachineConfigFile"
    return ($picked -join ",")
}
