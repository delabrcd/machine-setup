# Bitwarden session helpers for Windows. Mirrors lib/bw-session.sh.
#
# Caller must have $script:Plan set (output of Resolve-Plan) so we can decide
# whether any component in the plan needs Bitwarden.

function Test-BwSessionRequired {
    param([Parameter(Mandatory)] $Plan)
    foreach ($ident in $Plan.identities) {
        if ($ident.bw_ssh_item) { return $true }
        foreach ($app in $ident.applies_to) {
            if ($app.credential_helper -eq 'bitwarden') { return $true }
        }
    }
    return $false
}

function Test-BwUnlocked {
    if (-not $env:BW_SESSION) { return $false }
    if (-not (Get-Command bw -ErrorAction SilentlyContinue)) { return $false }
    $status = & {
        $ErrorActionPreference = 'Continue'
        bw status 2>$null
    }
    if (-not $status) { return $false }
    try {
        return ($status | ConvertFrom-Json).status -eq 'unlocked'
    } catch {
        return $false
    }
}

function Unlock-BwSession {
    if (-not (Get-Command bw -ErrorAction SilentlyContinue)) {
        Write-Warn "bw CLI not installed; skipping vault unlock"
        return $false
    }

    if (Test-BwUnlocked) {
        Write-Log "Bitwarden session already active."
        & { $ErrorActionPreference = 'Continue'; bw sync 2>$null | Out-Null }
        return $true
    }

    if (-not $env:BW_PASSWORD) {
        $sec = Read-Host -AsSecureString "Bitwarden master password"
        $env:BW_PASSWORD = [System.Net.NetworkCredential]::new("", $sec).Password
    }

    Write-Log "Unlocking Bitwarden vault..."
    $env:BW_SESSION = (bw unlock --passwordenv BW_PASSWORD --raw)
    if (-not $env:BW_SESSION) {
        Write-Warn "Bitwarden unlock failed"
        return $false
    }
    Write-Log "Syncing Bitwarden vault..."
    & { $ErrorActionPreference = 'Continue'; bw sync 2>$null | Out-Null }
    return $true
}
