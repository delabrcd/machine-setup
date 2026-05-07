. "$script:MachineSetupDir\lib\WindowsHelpers.ps1"

git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global gpg.format ssh
$homeFwd = Get-HomeForward
git config --global gpg.ssh.allowedSignersFile "$homeFwd/.ssh/allowed_signers"
git config --global commit.gpgsign true
git config --global tag.gpgsign true

# Pin git's ssh + ssh-keygen to Windows OpenSSH so they share the agent socket
# that ssh-add uses (Git for Windows ships its own MSYS2 ssh which uses a
# different agent socket — signing would fail with "No private key found"
# even though the key is loaded in the Windows agent).
$winSsh    = "C:\Windows\System32\OpenSSH\ssh.exe"
$winKeygen = "C:\Windows\System32\OpenSSH\ssh-keygen.exe"
if (Test-Path $winSsh)    { git config --global core.sshCommand    ($winSsh    -replace '\\','/') }
if (Test-Path $winKeygen) { git config --global gpg.ssh.program    ($winKeygen -replace '\\','/') }

$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }
$signers = Join-Path $sshDir "allowed_signers"
if (-not (Test-Path $signers)) { New-Item -ItemType File -Force -Path $signers | Out-Null }

# ssh-agent service: Automatic + Running
$svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.StartType -ne "Automatic" -or $svc.Status -ne "Running") {
        Write-Log "Setting ssh-agent to Automatic + Running (may prompt for elevation)..."
        try {
            Set-Service -Name ssh-agent -StartupType Automatic -ErrorAction Stop
            Start-Service -Name ssh-agent -ErrorAction Stop
        } catch {
            Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                "Set-Service -Name ssh-agent -StartupType Automatic; Start-Service -Name ssh-agent"
            ) | Out-Null
        }
    }
    $svc = Get-Service -Name ssh-agent
    Write-Log "ssh-agent: Status=$($svc.Status), StartType=$($svc.StartType)"
} else {
    Write-Warn "ssh-agent service not found (Windows OpenSSH may not be installed)"
}

Write-Log "Wrote base git config + ssh-agent service."
