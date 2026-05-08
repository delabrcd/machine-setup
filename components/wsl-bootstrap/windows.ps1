. "$env:MACHINE_SETUP_DIR\lib\WindowsHelpers.ps1"

# Run the full bootstrap inside WSL Ubuntu, propagating the host's identity +
# component selections so the user only picks once across the host + WSL pair.
#
# Mechanism:
#   1. Host's machine.toml is copied into the WSL distro (~/.config/...)
#   2. BW_SESSION + BW_PASSWORD are forwarded via WSLENV so the inner bw doesn't
#      need to re-prompt for the master password
#   3. bootstrap.sh runs with --quiet so it uses the saved state directly
#      (no inner Textual TUI; the host TUI is suspended for the duration)

$cfg = Get-ComponentConfig
$distro = if ($cfg.distro) { $cfg.distro } else { "Ubuntu" }

# Verify the distro is installed before delegating
$null = & { $ErrorActionPreference = "Continue"; wsl.exe -d $distro -- echo ok 2>$null }
if ($LASTEXITCODE -ne 0) {
    Write-Warn "WSL distro '$distro' not found. Install with: wsl --install -d $distro"
    return
}

# Copy host machine.toml -> WSL ~/.config/machine-setup/machine.toml so the
# inner bootstrap inherits identities/components/auth/component_config.
$hostCfg = Join-Path $env:USERPROFILE ".config\machine-setup\machine.toml"
if (Test-Path $hostCfg) {
    Write-Log "Copying machine.toml to WSL distro $distro ..."
    $hostFwd = '/mnt/' + $hostCfg[0].ToString().ToLower() + ($hostCfg.Substring(2) -replace '\\','/')
    wsl.exe -d $distro -- bash -lc "mkdir -p `$HOME/.config/machine-setup && cp '$hostFwd' `$HOME/.config/machine-setup/machine.toml"
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Failed to copy machine.toml into WSL -- inner bootstrap will pick freshly."
    }
}

# Forward BW creds via WSLENV so inner bw doesn't re-prompt
$env:WSLENV = ($env:WSLENV + ":BW_SESSION/u:BW_PASSWORD/u").TrimStart(":")

# Convert the Windows machine-setup path to a /mnt/<drive>/... WSL path so the
# inner bootstrap.sh runs from the same checkout (saves a re-clone).
$drive = $env:MACHINE_SETUP_DIR[0].ToString().ToLower()
$wslDir = "/mnt/$drive" + ($env:MACHINE_SETUP_DIR.Substring(2) -replace '\\','/')

Write-Log "Running bootstrap.sh inside WSL $distro with saved selections..."
wsl.exe -d $distro -- bash "$wslDir/bootstrap.sh" --quiet
