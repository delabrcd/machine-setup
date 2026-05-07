<#
.SYNOPSIS
  Push/pull/list machine-setup profiles in Bitwarden.

.DESCRIPTION
  Profiles stored in BW as Secure Notes named "Machine Profile: <name>" with
  the TOML content as the note body. Bootstrap discovers them on any machine,
  so you can sync private profiles cross-machine via the same vault that
  already holds your SSH keys + identities.

.EXAMPLE
  tools\seed-bw-profile.ps1 push local\profiles\work-desktop.toml
  tools\seed-bw-profile.ps1 list
  tools\seed-bw-profile.ps1 pull work-desktop

.NOTES
  Requires `bw` CLI on PATH and an unlocked session: $env:BW_SESSION = (bw unlock --raw)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position=0)] [ValidateSet("push","list","pull")] [string]$Mode,
    [Parameter(Position=1)] [string]$Arg,
    [string]$Name
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command bw -ErrorAction SilentlyContinue)) {
    throw "bw CLI not on PATH"
}
if (-not $env:BW_SESSION) {
    throw "BW_SESSION not set. Run: `$env:BW_SESSION = (bw unlock --raw)"
}

function Get-AllItems {
    $json = & { $ErrorActionPreference = "Continue"; bw list items 2>$null }
    if (-not $json) { return @() }
    return @($json | ConvertFrom-Json)
}

switch ($Mode) {
    "push" {
        if (-not $Arg) { throw "usage: push <path> [-Name <override>]" }
        if (-not (Test-Path $Arg)) { throw "no such file: $Arg" }
        $itemName = if ($Name) { "Machine Profile: $Name" } else {
            $base = [IO.Path]::GetFileNameWithoutExtension($Arg)
            "Machine Profile: $base"
        }
        $body = Get-Content $Arg -Raw

        $existing = Get-AllItems | Where-Object { $_.name -eq $itemName } | Select-Object -First 1
        if ($existing) {
            Write-Host "Updating $itemName (id $($existing.id))" -ForegroundColor Green
            $existing.notes = $body
            $payload = $existing | ConvertTo-Json -Depth 10 -Compress
            $payload | & bw encode | & bw edit item $existing.id | Out-Null
        } else {
            Write-Host "Creating $itemName" -ForegroundColor Green
            $template = & bw get template item | ConvertFrom-Json
            $template.type = 2
            $template.name = $itemName
            $template.secureNote = [pscustomobject]@{ type = 0 }
            $template.notes = $body
            $payload = $template | ConvertTo-Json -Depth 10 -Compress
            $payload | & bw encode | & bw create item | Out-Null
        }
        Write-Host "Done: $itemName" -ForegroundColor Green
    }
    "list" {
        $prefix = "Machine Profile: "
        Get-AllItems | Where-Object { $_.name -and $_.name.StartsWith($prefix) } | ForEach-Object {
            $name = $_.name.Substring($prefix.Length)
            $body = ($_.notes -as [string])
            $firstLine = if ($body) { ($body -split "`n", 2)[0].Trim() } else { "(empty)" }
            "{0,-25}  {1}" -f $name, $firstLine.Substring(0, [Math]::Min(60, $firstLine.Length))
        }
    }
    "pull" {
        if (-not $Arg) { throw "usage: pull <profile-name>" }
        $itemName = "Machine Profile: $Arg"
        $item = Get-AllItems | Where-Object { $_.name -eq $itemName } | Select-Object -First 1
        if (-not $item) { throw "profile '$Arg' not found in BW" }
        Write-Output ($item.notes -as [string])
    }
}
