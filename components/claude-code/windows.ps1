. "$script:MachineSetupDir\lib\WindowsHelpers.ps1"

# Anthropic publishes a native PowerShell installer at install.claude.ai/install.ps1
# (mirrors the Linux/macOS install.sh). It writes claude.exe to a per-user
# location and adds it to the user's PATH.

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Log "Claude Code already installed: $(claude --version 2>$null)"
    return
}

Write-Log "Installing Claude Code (native Windows installer)..."
try {
    Invoke-RestMethod -Uri "https://claude.ai/install.ps1" | Invoke-Expression
} catch {
    Write-Warn "Claude Code installer failed: $_"
    return
}

Sync-PathFromRegistry
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Log "Claude Code: $(claude --version 2>$null)"
} else {
    Write-Warn "Claude Code installed but 'claude' not on PATH yet -- open a new shell."
}
