#Requires -Version 5.1
<#
.SYNOPSIS
  Thin Windows stub. Flow logic lives in lib/main.py; this just ensures
  python3 is available, performs the self-update + re-exec dance, and
  dispatches.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$dir = $PSScriptRoot

# Self-update + re-exec.
#
# Only safe to hard-reset when the working tree is clean AND we're on the
# branch that tracks origin's default head (typically main). Otherwise the
# user is doing local development on this repo and a reset would eat their
# work — skip the update and let bootstrap proceed against the local tree.
# Set $env:MACHINE_SETUP_SKIP_UPDATE=1 to bypass the update entirely.
if ((Test-Path "$dir\.git") -and -not $env:_BOOTSTRAP_UPDATED -and -not $env:MACHINE_SETUP_SKIP_UPDATE) {
    $dirty   = & { $ErrorActionPreference = "Continue"; git -C $dir status --porcelain 2>$null } | Out-String
    $branch  = & { $ErrorActionPreference = "Continue"; git -C $dir symbolic-ref --short HEAD 2>$null } | Out-String
    $default = & { $ErrorActionPreference = "Continue"; git -C $dir symbolic-ref --short refs/remotes/origin/HEAD 2>$null } | Out-String
    $dirty   = $dirty.Trim()
    $branch  = $branch.Trim()
    $default = $default.Trim() -replace '^origin/', ''
    if (-not $dirty -and $branch -and $default -and ($branch -eq $default)) {
        Write-Host "==> Updating machine-setup..." -ForegroundColor Green
        & { $ErrorActionPreference = "Continue"; git -C $dir fetch origin 2>$null }
        if ($LASTEXITCODE -eq 0) { git -C $dir reset --hard "origin/$default" }
        $env:_BOOTSTRAP_UPDATED = "1"
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$dir\bootstrap.ps1" @args
        exit $LASTEXITCODE
    } else {
        if ($dirty) {
            Write-Host "==> Skipping self-update: working tree has local changes" -ForegroundColor Yellow
        } elseif (-not $branch) {
            Write-Host "==> Skipping self-update: HEAD is detached" -ForegroundColor Yellow
        } elseif ($branch -ne $default) {
            Write-Host "==> Skipping self-update: on branch '$branch' (default is '$default')" -ForegroundColor Yellow
        }
        $env:_BOOTSTRAP_UPDATED = "1"
    }
}

# Find or install python3 (winget). main.py requires 3.11+ for tomllib.
$py = $null
foreach ($cmd in @("py", "python", "python3")) {
    $p = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($p) { $py = $p.Source; break }
}
if (-not $py) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "==> Installing Python 3 via winget..." -ForegroundColor Green
        winget install --id Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("PATH","User")
        foreach ($cmd in @("py", "python", "python3")) {
            $p = Get-Command $cmd -ErrorAction SilentlyContinue
            if ($p) { $py = $p.Source; break }
        }
    }
    if (-not $py) { throw "Python 3.11+ not on PATH (try installing manually from python.org)" }
}

& $py "$dir\lib\main.py" @args
exit $LASTEXITCODE
