. "$env:MACHINE_SETUP_DIR\lib\WindowsHelpers.ps1"

Install-Winget -Id "twpayne.chezmoi" -Label "chezmoi"
Sync-PathFromRegistry

$cfg = Get-ComponentConfig
$repo = $cfg.repo
if (-not $repo) {
    Write-Warn "chezmoi: no repo configured in [component_config.chezmoi].repo -- skipping apply"
    return
}

# Expose MCP-component selection to chezmoi templates (see linux.sh for rationale)
function _Has-Component($name) {
    if (-not $env:PLAN_JSON) { return "0" }
    try {
        $plan = $env:PLAN_JSON | ConvertFrom-Json
        foreach ($c in $plan.components) {
            if ($c.name -eq $name) { return "1" }
        }
    } catch {}
    return "0"
}
$env:MS_MCP_CONTEXT7  = _Has-Component "mcp-context7"
$env:MS_MCP_BITBUCKET = _Has-Component "mcp-bitbucket"
$env:MS_MCP_JIRA      = _Has-Component "mcp-jira"
Write-Log "MCP flags for chezmoi: context7=$env:MS_MCP_CONTEXT7 bitbucket=$env:MS_MCP_BITBUCKET jira=$env:MS_MCP_JIRA"

$chezmoiSrc = Join-Path $env:USERPROFILE ".local\share\chezmoi"
if (Test-Path "$chezmoiSrc\.git") {
    Write-Log "chezmoi source present -- applying ($repo)"
    chezmoi apply --force
} else {
    Write-Log "Initialising chezmoi from $repo"
    chezmoi init --apply --force $repo
}
