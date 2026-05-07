. "$script:MachineSetupDir\lib\WindowsHelpers.ps1"

if (-not $env:IDENT_NAME)      { Write-Warn "git-identity: IDENT_NAME not set"; return }
if (-not $env:IDENT_GIT_NAME)  { Write-Warn "git-identity ($($env:IDENT_NAME)): no git_name"; return }
if (-not $env:IDENT_GIT_EMAIL) { Write-Warn "git-identity ($($env:IDENT_NAME)): no git_email"; return }

$homeFwd = Get-HomeForward
$pubPath = "$homeFwd/.ssh/$($env:IDENT_SSH_KEY_BASENAME).pub"
$pubFile = "$env:USERPROFILE\.ssh\$($env:IDENT_SSH_KEY_BASENAME).pub"

if ($env:IDENT_DEFAULT -eq "1") {
    Write-Log "Default identity: $($env:IDENT_NAME) ($($env:IDENT_GIT_EMAIL))"
    git config --global user.name  $env:IDENT_GIT_NAME
    git config --global user.email $env:IDENT_GIT_EMAIL
    if (Test-Path $pubFile) {
        git config --global user.signingKey $pubPath
    }
} else {
    Write-Log "Non-default identity: $($env:IDENT_NAME) — writing .gitconfig-$($env:IDENT_NAME)"
    $confLocal = "$env:USERPROFILE\.gitconfig-$($env:IDENT_NAME)"
    $confFwd   = "$homeFwd/.gitconfig-$($env:IDENT_NAME)"
    $signing = if (Test-Path $pubFile) { "    signingKey = $pubPath`n" } else { "" }
    Write-LfFile -Path $confLocal -Content @"
[user]
    name = $($env:IDENT_GIT_NAME)
    email = $($env:IDENT_GIT_EMAIL)
$signing
"@

    # Clear any prior includeIf rules that point to this identity's config
    $prior = & { $ErrorActionPreference = 'Continue'; git config --global --get-regexp '^includeIf\.' 2>$null }
    if ($prior) {
        $priorLines = if ($prior -is [string]) { @($prior) } else { @($prior) }
        foreach ($line in $priorLines) {
            $key = ($line -split '\s+', 2)[0]
            $val = & { $ErrorActionPreference = 'Continue'; git config --global $key 2>$null }
            if ($val -eq $confFwd) {
                & { $ErrorActionPreference = 'Continue'; git config --global --unset-all $key 2>$null | Out-Null }
            }
        }
    }

    foreach ($app in (Get-IdentityAppliesTo)) {
        foreach ($pat in @($app.git_url_patterns)) {
            if (-not $pat) { continue }
            git config --global "includeIf.hasconfig:remote.*.url:$pat.path" $confFwd
            Write-Log "  includeIf: $pat → .gitconfig-$($env:IDENT_NAME)"
        }
    }
}

# Add this identity's public key to allowed_signers
if (Test-Path $pubFile) {
    $signers = "$env:USERPROFILE\.ssh\allowed_signers"
    $existing = if (Test-Path $signers) { Get-Content $signers -Raw } else { "" }
    $pubKey = (Get-Content $pubFile -Raw).Trim()
    if ($existing -notmatch [regex]::Escape($pubKey)) {
        $line = "$($env:IDENT_GIT_EMAIL) $pubKey"
        $new = ($existing.TrimEnd("`r","`n") + "`n" + $line).TrimStart("`n")
        Write-LfFile -Path $signers -Content $new
        Write-Log "Added $($env:IDENT_NAME) to allowed_signers"
    }
}
