. "$script:MachineSetupDir\lib\WindowsHelpers.ps1"

Install-Winget -Id "twpayne.chezmoi" -Label "chezmoi"
Sync-PathFromRegistry

$cfg = Get-ComponentConfig
$repo = $cfg.repo
if (-not $repo) {
    Write-Warn "chezmoi: no repo configured in [component_config.chezmoi].repo — skipping apply"
    return
}

$chezmoiSrc = Join-Path $env:USERPROFILE ".local\share\chezmoi"
if (Test-Path "$chezmoiSrc\.git") {
    Write-Log "chezmoi source present — applying ($repo)"
    chezmoi apply --force
} else {
    Write-Log "Initialising chezmoi from $repo"
    chezmoi init --apply --force $repo
}
