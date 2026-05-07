. "$script:MachineSetupDir\lib\WindowsHelpers.ps1"

if (-not $env:IDENT_BW_SSH_ITEM) {
    Write-Log "ssh-key ($($env:IDENT_NAME)): no bw_ssh_item — skipping"
    return
}

$item = Get-BwItemExact $env:IDENT_BW_SSH_ITEM
if (-not $item) {
    Write-Warn "ssh-key ($($env:IDENT_NAME)): BW item '$($env:IDENT_BW_SSH_ITEM)' not found — skipping"
    return
}

$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }
$pubPath = Join-Path $sshDir "$($env:IDENT_SSH_KEY_BASENAME).pub"

# Public key on disk (no private key — agent only)
$pub = Get-BwField $item "public_key"
if ($pub) {
    Write-LfFile -Path $pubPath -Content $pub
    Write-Log "Wrote $(Split-Path -Leaf $pubPath)"
}

# Load private key into agent if not already present
$priv = Get-BwField $item "private_key"
$svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
if ($priv -and $svc -and $svc.Status -eq "Running") {
    $agentPubs = & { $ErrorActionPreference = "Continue"; ssh-add -L 2>$null }
    $blob = if ($pub) { ($pub.Trim() -split '\s+')[1] } else { $null }
    if ($blob -and ($agentPubs | Where-Object { $_ -match [regex]::Escape($blob) })) {
        Write-Log "$($env:IDENT_NAME) already in agent"
    } else {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($tmp, $priv, $utf8NoBom)
            $acl = Get-Acl $tmp
            $acl.SetAccessRuleProtection($true, $false)
            $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, "Read,Write", "Allow")))
            Set-Acl -Path $tmp -AclObject $acl
            & { $ErrorActionPreference = 'Continue'; ssh-add $tmp 2>&1 | Out-Null }
            if ($LASTEXITCODE -eq 0) { Write-Log "Loaded $($env:IDENT_NAME) into agent" }
            else                     { Write-Warn "ssh-add failed for $($env:IDENT_NAME)" }
        } finally {
            Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        }
    }
}

# ~/.ssh/config — one Host block per applies_to entry, marked with this identity
$homeFwd = Get-HomeForward
$marker = "# BEGIN machine-setup:$($env:IDENT_NAME)"
$endMark = "# END machine-setup:$($env:IDENT_NAME)"
$blockLines = @()
foreach ($app in (Get-IdentityAppliesTo)) {
    if (-not $app.host) { continue }
    $blockLines += "Host $($app.host)"
    $blockLines += "    IdentityFile $homeFwd/.ssh/$($env:IDENT_SSH_KEY_BASENAME)"
    $blockLines += "    IdentitiesOnly yes"
    $blockLines += ""
}
if ($blockLines.Count -gt 0) {
    $block = $marker + "`n" + (($blockLines -join "`n").TrimEnd()) + "`n" + $endMark
    Set-MarkedRegion -Path "$sshDir\config" -Block $block -BeginMarker $marker -EndMarker $endMark
    Write-Log "Updated ~/.ssh/config for $($env:IDENT_NAME)"
}
