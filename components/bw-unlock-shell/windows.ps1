. "$script:MachineSetupDir\lib\WindowsHelpers.ps1"

# Install bw-unlock function into the user's PowerShell profile(s). Loads
# every BW SSH item declared by the active profile's identities.

# Pull BW item names from the resolved plan
$items = @()
foreach ($ident in $script:Plan.identities) {
    if ($ident.bw_ssh_item) { $items += $ident.bw_ssh_item }
}
if ($items.Count -eq 0) {
    Write-Log "bw-unlock-shell: no BW SSH items in plan -- installing a no-op stub"
}

# Build the PS array literal of item names (single-quoted, with ' escaped as '')
$itemArray = "@(" + (
    ($items | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ", "
) + ")"

$bwUnlockBlock = @"
# BEGIN machine-setup
# bw-unlock: unlock Bitwarden vault and load every machine-setup-managed SSH key
# into Windows ssh-agent. Private keys live only in BW + agent memory.
function bw-unlock {
    `$env:BW_SESSION = bw unlock --raw
    if (-not `$env:BW_SESSION) { Write-Warning 'Bitwarden unlock failed'; return }

    `$svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if (-not `$svc -or `$svc.Status -ne 'Running') {
        try { Start-Service ssh-agent -ErrorAction Stop }
        catch { Write-Warning 'ssh-agent not running and could not be started'; return }
    }

    foreach (`$item in $itemArray) {
        `$json = & { `$ErrorActionPreference='Continue'; bw list items --search `$item 2>`$null }
        if (-not `$json) { Write-Host "Skipped (not found): `$item"; continue }
        `$entry = @(`$json | ConvertFrom-Json) | Where-Object { `$_.name -eq `$item } | Select-Object -First 1
        if (-not `$entry) { Write-Host "Skipped (not found): `$item"; continue }
        `$priv = (`$entry.fields | Where-Object { `$_.name -eq 'private_key' } | Select-Object -First 1).value
        if (-not `$priv) { Write-Host "Skipped (no private_key): `$item"; continue }
        `$tmp = [System.IO.Path]::GetTempFileName()
        try {
            `$utf8NoBom = New-Object System.Text.UTF8Encoding `$false
            [System.IO.File]::WriteAllText(`$tmp, `$priv, `$utf8NoBom)
            `$acl = Get-Acl `$tmp
            `$acl.SetAccessRuleProtection(`$true, `$false)
            `$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'Read,Write', 'Allow')))
            Set-Acl -Path `$tmp -AclObject `$acl
            & ssh-add `$tmp 2>&1 | Out-Null
            if (`$LASTEXITCODE -eq 0) { Write-Host "Loaded: `$item" }
            else                      { Write-Warning "ssh-add failed for `$item" }
        } finally { Remove-Item -Force `$tmp -ErrorAction SilentlyContinue }
    }

    `$count = (& { `$ErrorActionPreference='Continue'; ssh-add -l 2>`$null } | Measure-Object).Count
    Write-Host "ssh-agent has `$count key(s)."
}
# END machine-setup
"@

# Ensure the profile we're about to write isn't blocked by a hardened
# ExecutionPolicy. Same logic as before -- only intervene when needed.
$effective = Get-ExecutionPolicy
if ($effective -notin @("RemoteSigned", "Unrestricted", "Bypass")) {
    Write-Log "Setting CurrentUser ExecutionPolicy to RemoteSigned (effective: $effective)"
    & {
        $ErrorActionPreference = 'Continue'
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force 2>&1 | Out-Null
    }
}

$profilePaths = @(
    (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "WindowsPowerShell\profile.ps1"),
    (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "PowerShell\profile.ps1")
) | Select-Object -Unique

foreach ($p in $profilePaths) {
    $dir = Split-Path $p -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-MarkedRegion -Path $p -Block $bwUnlockBlock
    Write-Log "Installed bw-unlock to $p"
}
