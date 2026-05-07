# Stage-0 installer for machine-setup.
# Usage:  irm https://raw.githubusercontent.com/delabrcd/machine-setup/main/install.ps1 | iex
# Env:
#   $env:MACHINE_SETUP_DIR     install location (default: %USERPROFILE%\.local\share\machine-setup)
#   $env:MACHINE_SETUP_REPO    repo URL         (default: https://github.com/delabrcd/machine-setup.git)
#   $env:MACHINE_SETUP_PROFILE pre-pick a profile so the bootstrap doesn't prompt

$ErrorActionPreference = "Stop"

$dest = if ($env:MACHINE_SETUP_DIR)  { $env:MACHINE_SETUP_DIR }  else { Join-Path $env:USERPROFILE ".local\share\machine-setup" }
$repo = if ($env:MACHINE_SETUP_REPO) { $env:MACHINE_SETUP_REPO } else { "https://github.com/delabrcd/machine-setup.git" }

# Install git if missing -- needed before we can clone anything.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "==> Installing Git for Windows via winget..." -ForegroundColor Green
        winget install --id Git.Git --silent --accept-source-agreements --accept-package-agreements
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("PATH","User")
    } else {
        throw "git not installed and winget unavailable. Install git manually from https://git-scm.com/download/win"
    }
}

if (Test-Path "$dest\.git") {
    Write-Host "==> Updating $dest" -ForegroundColor Green
    git -C $dest fetch origin
    git -C $dest reset --hard origin/HEAD
} else {
    Write-Host "==> Cloning $repo -> $dest" -ForegroundColor Green
    $parent = Split-Path $dest -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    git clone $repo $dest
}

& powershell -NoProfile -ExecutionPolicy Bypass -File "$dest\bootstrap.ps1"
