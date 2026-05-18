. "$env:MACHINE_SETUP_DIR\lib\WindowsHelpers.ps1"

# Install bw-unlock function into the user's PowerShell profile(s). Loads
# every BW SSH item declared by the active profile's identities.

# Pull BW item names from the resolved plan (passed in via $env:PLAN_JSON)
$items = @()
if ($env:PLAN_JSON) {
    $plan = $env:PLAN_JSON | ConvertFrom-Json
    foreach ($ident in $plan.identities) {
        if ($ident.bw_ssh_item) { $items += $ident.bw_ssh_item }
    }
}
if ($items.Count -eq 0) {
    Write-Log "bw-unlock-shell: no BW SSH items in plan -- installing a no-op stub"
}

# Build the PS array literal of item names (single-quoted, with ' escaped as '')
$itemArray = "@(" + (
    ($items | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ", "
) + ")"

# Probe item baked into the snippet at install time. We probe the *first*
# configured identity to verify the bw session can actually decrypt
# items (bw 2026.x sometimes hands back sessions that cannot --
# bitwarden/clients#18455).
$probeLiteral = if ($items.Count -gt 0) {
    "'" + ($items[0] -replace "'", "''") + "'"
} else { "''" }

$bwUnlockBlock = @"
# BEGIN machine-setup
# bw-unlock: unlock Bitwarden vault and load every machine-setup-managed SSH key
# into Windows ssh-agent. Private keys live only in BW + agent memory.
#
# Resilience notes (bitwarden/clients#18455 + #6705):
#   * Some bw CLI builds return a session from ``bw unlock`` that cannot
#     decrypt vault items. We probe by fetching a known item; on probe
#     failure we automatically fall back to ``bw logout`` + ``bw login``,
#     which produces a session that works. The single password prompt
#     captured at the top covers both attempts (passed via --passwordenv).
#   * ``bw status`` lies about lock state on these builds, so we never use
#     it as a verification mechanism.
function bw-unlock {
    `$probeItem = $probeLiteral
    `$items     = $itemArray

    # Capture current login email before any state changes so the fallback
    # can re-login non-interactively.
    `$email = ''
    try {
        `$st = & { `$ErrorActionPreference='Continue'; bw status 2>`$null } | ConvertFrom-Json
        if (`$st) { `$email = `$st.userEmail }
    } catch {}

    # Single secure password prompt -- reused for the fast path AND fallback.
    `$securePw = Read-Host -AsSecureString -Prompt 'Master password'
    `$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(`$securePw)
    try {
        `$plainPw = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(`$bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR(`$bstr)
    }

    `$sess = `$null

    # --- Fast path: bw lock + bw unlock (uses local cached vault) ---
    try {
        `$env:BW_PASSWORD = `$plainPw
        & { `$ErrorActionPreference='Continue'; bw lock 2>`$null | Out-Null }
        `$sess = & { `$ErrorActionPreference='Continue'
                     bw unlock --passwordenv BW_PASSWORD --raw 2>`$null }
    } finally {
        Remove-Item Env:\BW_PASSWORD -ErrorAction SilentlyContinue
    }

    # --- Probe: does the session actually decrypt items? ---
    `$fastPathWorked = `$false
    if (`$sess -and `$probeItem) {
        `$env:BW_SESSION = `$sess
        try {
            & { `$ErrorActionPreference='Continue'
                bw --nointeraction get item `$probeItem 2>`$null | Out-Null }
            if (`$LASTEXITCODE -eq 0) { `$fastPathWorked = `$true }
        } finally {
            Remove-Item Env:\BW_SESSION -ErrorAction SilentlyContinue
        }
    }

    # --- Fallback: bw logout + bw login (produces a session that works) ---
    if (-not `$fastPathWorked) {
        Write-Host 'bw unlock session is broken (bw#18455). Falling back to bw login...' -ForegroundColor Yellow
        if (-not `$email) {
            Write-Warning "Cannot determine login email for fallback. Run 'bw login' manually."
            `$plainPw = `$null
            return
        }
        try {
            `$env:BW_PASSWORD = `$plainPw
            & { `$ErrorActionPreference='Continue'; bw logout 2>`$null | Out-Null }
            `$sess = & { `$ErrorActionPreference='Continue'
                         bw login --passwordenv BW_PASSWORD --raw `$email 2>`$null }
        } finally {
            Remove-Item Env:\BW_PASSWORD -ErrorAction SilentlyContinue
        }
    }

    `$plainPw = `$null

    if (-not `$sess) {
        Write-Warning 'Could not obtain a bw session -- wrong password?'
        return
    }
    `$env:BW_SESSION = `$sess

    # Ensure ssh-agent service is running.
    `$svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if (-not `$svc -or `$svc.Status -ne 'Running') {
        try { Start-Service ssh-agent -ErrorAction Stop }
        catch { Write-Warning 'ssh-agent not running and could not be started'; return }
    }

    # Per-item ``bw get item`` uses the local cached vault and (unlike
    # ``bw list items``) does not force a full server sync, which is what
    # tends to hang on bw 2026.x. --nointeraction makes bw fail loudly.
    foreach (`$item in `$items) {
        Write-Host "Fetching: `$item"
        `$json = & { `$ErrorActionPreference='Continue'
                     bw --nointeraction get item `$item 2>`$null }
        if (-not `$json -or `$LASTEXITCODE -ne 0) {
            Write-Host "Skipped (bw get item failed): `$item"
            continue
        }
        `$entry = `$json | ConvertFrom-Json
        `$priv  = (`$entry.fields | Where-Object { `$_.name -eq 'private_key' } | Select-Object -First 1).value
        if (-not `$priv) { Write-Host "Skipped (no private_key): `$item"; continue }
        # SSH keys must end with a newline or ssh-add rejects them.
        if (-not `$priv.EndsWith("`n")) { `$priv = `$priv + "`n" }
        `$tmp = [System.IO.Path]::GetTempFileName()
        try {
            `$utf8NoBom = New-Object System.Text.UTF8Encoding `$false
            [System.IO.File]::WriteAllText(`$tmp, `$priv, `$utf8NoBom)
            `$acl = Get-Acl `$tmp
            `$acl.SetAccessRuleProtection(`$true, `$false)
            `$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'Read,Write', 'Allow')))
            Set-Acl -Path `$tmp -AclObject `$acl
            `$sshErr = & ssh-add `$tmp 2>&1
            if (`$LASTEXITCODE -eq 0) { Write-Host "Loaded: `$item" }
            else {
                Write-Warning "ssh-add failed for `$item"
                `$sshErr | Select-Object -First 5 | ForEach-Object { Write-Host "  `$_" }
            }
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
