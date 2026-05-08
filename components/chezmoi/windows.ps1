. "$env:MACHINE_SETUP_DIR\lib\WindowsHelpers.ps1"

Install-Winget -Id "twpayne.chezmoi" -Label "chezmoi"
Sync-PathFromRegistry

$cfg = Get-ComponentConfig
$source = if ($cfg.source) { $cfg.source } else { Join-Path $env:MACHINE_SETUP_DIR "chezmoi-source" }
if (-not (Test-Path $source)) {
    Write-Warn "chezmoi: source dir '$source' does not exist -- skipping apply"
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

Write-Log "Applying chezmoi from local source: $source"
chezmoi apply --source $source --force
