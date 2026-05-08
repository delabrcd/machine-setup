# Helpers shared by component windows.ps1 scripts. Dot-sourced into each.

# Logging helpers — components rely on these. Used to live in lib/Driver.ps1
# which we removed during the Python consolidation; they belong here now since
# components are the only callers.
function Write-Log  { Write-Host "==> $args" -ForegroundColor Green }
function Write-Warn { Write-Host "WARN: $args" -ForegroundColor Yellow }
function Write-Step { Write-Host "`n--- $args ---" -ForegroundColor Cyan }
function Write-Die  { Write-Host "ERROR: $args" -ForegroundColor Red; exit 1 }

function Install-Winget {
    param([string]$Id, [string]$Label)
    $installed = & { $ErrorActionPreference = "Continue"; winget list --id $Id --exact --accept-source-agreements 2>$null }
    if ($installed -match [regex]::Escape($Id)) {
        Write-Log "$Label already installed"
        return
    }
    Write-Log "Installing $Label ($Id)..."
    winget install --id $Id --silent --accept-source-agreements --accept-package-agreements
}

function Sync-PathFromRegistry {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

function Write-LfFile {
    param([string]$Path, [string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $normalized = ($Content -replace "`r`n", "`n").TrimEnd("`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
}

function Set-MarkedRegion {
    param(
        [string]$Path,
        [string]$Block,
        [string]$BeginMarker = "# BEGIN machine-setup",
        [string]$EndMarker   = "# END machine-setup"
    )
    $existing = if (Test-Path $Path) { Get-Content $Path -Raw } else { "" }
    $pattern = "(?ms)" + [regex]::Escape($BeginMarker) + ".*?" + [regex]::Escape($EndMarker) + "\r?\n?"
    $existing = [regex]::Replace($existing, $pattern, "")
    $existing = $existing.TrimEnd("`r","`n")
    $newContent = if ($existing) { "$existing`n`n$Block" } else { $Block }
    Write-LfFile -Path $Path -Content $newContent
}

# Exact-name BW lookup -- `bw get item NAME` matches by substring, so it returns
# multiple items when one name is a prefix of another.
function Get-BwItemExact {
    param([string]$Name)
    $json = & { $ErrorActionPreference = "Continue"; bw list items --search $Name 2>$null }
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $items = @($json | ConvertFrom-Json)
    $exact = @($items | Where-Object { $_.name -eq $Name })
    if ($exact.Count -eq 0) { return $null }
    foreach ($item in $exact) {
        if ($item.fields | Where-Object { $_.name -eq "private_key" }) { return $item }
    }
    return $exact[0]
}

function Get-BwField {
    param($Item, [string]$Name)
    ($Item.fields | Where-Object { $_.name -eq $Name } | Select-Object -First 1).value
}

# Forward-slash form of $HOME, used in git/ssh config files.
function Get-HomeForward { ($env:USERPROFILE -replace '\\', '/') }

# Read $env:COMPONENT_CONFIG_JSON into a hashtable
function Get-ComponentConfig {
    if (-not $env:COMPONENT_CONFIG_JSON) { return @{} }
    return ($env:COMPONENT_CONFIG_JSON | ConvertFrom-Json -AsHashtable)
}

# Read $env:IDENT_APPLIES_TO_JSON into an array of objects
function Get-IdentityAppliesTo {
    if (-not $env:IDENT_APPLIES_TO_JSON) { return @() }
    return @($env:IDENT_APPLIES_TO_JSON | ConvertFrom-Json)
}
