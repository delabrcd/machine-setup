. "$env:MACHINE_SETUP_DIR\lib\WindowsHelpers.ps1"

$cfg = Get-ComponentConfig
$distro = if ($cfg.distro) { $cfg.distro } else { "Ubuntu" }
# Profile to run inside WSL. Defaults to the host's chosen profile so one
# selection drives both halves of the bootstrap.
$wslProfile = if ($cfg.profile) { $cfg.profile } else { $script:Plan.profile }

# Verify the distro is installed before delegating
$null = & { $ErrorActionPreference = "Continue"; wsl.exe -d $distro -- echo ok 2>$null }
if ($LASTEXITCODE -ne 0) {
    Write-Warn "WSL distro '$distro' not found. Install with: wsl --install -d $distro"
    return
}

# Forward BW credentials so the inner bootstrap can unlock without re-prompting.
# BW_SESSION = unlocked session token; BW_PASSWORD = master password fallback.
# /u suffix in WSLENV = upcase (Windows env var) -> WSL env var.
$env:WSLENV = ($env:WSLENV + ":BW_SESSION/u:BW_PASSWORD/u:MACHINE_SETUP_PROFILE/u").TrimStart(":")
$env:MACHINE_SETUP_PROFILE = $wslProfile

# Convert the Windows machine-setup path to a /mnt/<drive>/... WSL path
$drive = $env:MACHINE_SETUP_DIR[0].ToString().ToLower()
$wslDir = "/mnt/$drive" + ($env:MACHINE_SETUP_DIR.Substring(2) -replace '\\', '/')

Write-Log "Running bootstrap.sh inside WSL $distro with profile '$wslProfile'..."
wsl.exe -d $distro -- bash "$wslDir/bootstrap.sh"

Remove-Item env:MACHINE_SETUP_PROFILE -ErrorAction SilentlyContinue
