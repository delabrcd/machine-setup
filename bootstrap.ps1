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

# Self-update + re-exec
if ((Test-Path "$dir\.git") -and -not $env:_BOOTSTRAP_UPDATED) {
    Write-Host "==> Updating machine-setup..." -ForegroundColor Green
    & { $ErrorActionPreference = "Continue"; git -C $dir fetch origin 2>$null }
    if ($LASTEXITCODE -eq 0) { git -C $dir reset --hard origin/HEAD }
    $env:_BOOTSTRAP_UPDATED = "1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$dir\bootstrap.ps1" @args
    exit $LASTEXITCODE
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
