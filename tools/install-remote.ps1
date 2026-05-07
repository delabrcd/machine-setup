<#
.SYNOPSIS
  Bootstrap a remote Linux/WSL machine over SSH from Windows, including any
  per-host overlay from this checkout's local/ directory.

.PARAMETER Host
  SSH host (alias from ~/.ssh/config, or user@host)

.PARAMETER Profile
  Profile name to bootstrap with (must exist in profiles/ or local/profiles/)

.PARAMETER BootstrapArgs
  Extra args passed through to bootstrap.sh on the remote (e.g. --reconfigure)

.EXAMPLE
  tools\install-remote.ps1 desktop work-desktop

.EXAMPLE
  tools\install-remote.ps1 desktop work-desktop -BootstrapArgs --reconfigure

.NOTES
  Requirements on this Windows box:
    - ssh.exe + tar.exe   (Windows 10+ ships both in C:\Windows\System32)
    - python3             (used to validate the profile name locally)
    - git Bash / WSL      NOT required

  Requirements on the remote:
    - ssh access already working (`ssh <Host> echo ok` succeeds)
    - sudo (only if git isn't installed)
    - Bitwarden master password (for the bootstrap's vault unlock)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position=0)] [string]$RemoteHost,
    [Parameter(Mandatory, Position=1)] [string]$ProfileName,
    [Parameter(ValueFromRemainingArguments)] [string[]]$BootstrapArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$repoUrl  = if ($env:MACHINE_SETUP_REPO) { $env:MACHINE_SETUP_REPO } else { "https://github.com/delabrcd/machine-setup.git" }
$remoteDestLiteral = '$HOME/.local/share/machine-setup'   # expanded on the remote

# ── Validate profile exists locally before we go through the remote dance ───
$pythonCmd = Get-Command py, python, python3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pythonCmd) { throw "python3 not on PATH (try winget install Python.Python.3.13)" }

$profileLines = & $pythonCmd "$repoRoot\lib\config.py" list-profiles
$profileNames = @()
foreach ($line in $profileLines) {
    if ($line -match '\S') {
        $profileNames += ($line | ConvertFrom-Json).name
    }
}
if ($ProfileName -notin $profileNames) {
    Write-Host "ERROR: profile '$ProfileName' not found in profiles/ or local/profiles/." -ForegroundColor Red
    Write-Host "       Available:"
    foreach ($line in $profileLines) {
        if ($line -match '\S') {
            $p = $line | ConvertFrom-Json
            Write-Host ("         - {0}  [{1}]" -f $p.name, $p.source)
        }
    }
    exit 1
}

# ── Step 1: install git on remote + clone repo ──────────────────────────────
Write-Host "==> [$RemoteHost] Installing git + cloning machine-setup..." -ForegroundColor Cyan

# Bash here-doc piped over ssh stdin. The outer @' '@ is a literal here-string
# in PowerShell so $variables aren't expanded — bash sees them raw.
$remoteScript = @'
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y git
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y git
  elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm git
  else echo "ERROR: no apt/dnf/pacman; install git manually first." >&2; exit 1
  fi
fi

DEST="$HOME/.local/share/machine-setup"
mkdir -p "$(dirname "$DEST")"
if [ -d "$DEST/.git" ]; then
  echo "    Updating $DEST"
  git -C "$DEST" fetch origin
  git -C "$DEST" reset --hard origin/HEAD
else
  echo "    Cloning REPO_URL_PLACEHOLDER -> $DEST"
  git clone REPO_URL_PLACEHOLDER "$DEST"
fi
mkdir -p "$DEST/local/identities" "$DEST/local/profiles" "$DEST/local/components"
'@
$remoteScript = $remoteScript.Replace("REPO_URL_PLACEHOLDER", $repoUrl)
$remoteScript | & ssh $RemoteHost "bash -s"
if ($LASTEXITCODE -ne 0) { throw "Remote clone step failed (exit $LASTEXITCODE)" }

# ── Step 2: tar-pipe local/ overlay to remote ───────────────────────────────
$localDir = Join-Path $repoRoot "local"
if (Test-Path $localDir) {
    Write-Host "==> [$RemoteHost] Copying local/ overlay..." -ForegroundColor Cyan

    # tar | ssh "tar -xf -"  — bsdtar (System32\tar.exe) handles -cf -.
    # Run tar from the repo root so paths are stored as `local/...` and untar
    # against $remoteDestLiteral lands them under that repo's local/.
    $tarCmd = "tar -cf - --exclude=local/README.md --exclude=local/.gitkeep local"
    Push-Location $repoRoot
    try {
        # PowerShell native pipe between processes (cmd /c so the pipe is bash-style)
        cmd /c "tar -cf - --exclude=local/README.md --exclude=local/.gitkeep local | ssh $RemoteHost ""tar -xf - -C $remoteDestLiteral && echo '    overlay applied'"""
        if ($LASTEXITCODE -ne 0) { throw "tar/ssh pipe failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "    (no local/ on this machine — skipping overlay sync)" -ForegroundColor DarkGray
}

# ── Step 3: run bootstrap.sh on remote with profile pre-set ─────────────────
Write-Host "==> [$RemoteHost] Running bootstrap with profile=$ProfileName" -ForegroundColor Cyan

$extraArgs = if ($BootstrapArgs) { ($BootstrapArgs -join ' ') } else { "" }
# -t allocates a TTY so the BW password prompt + SSH key registration pause work.
& ssh -t $RemoteHost "MACHINE_SETUP_PROFILE=$ProfileName bash $remoteDestLiteral/bootstrap.sh $extraArgs"
exit $LASTEXITCODE
