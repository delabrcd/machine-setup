. "$script:MachineSetupDir\lib\WindowsHelpers.ps1"

# Per-identity HTTPS credential helpers on Windows. Same scheme set as Linux:
#   gcm        - Git Credential Manager (bundled with Git for Windows)
#   bitwarden  - Linux only (Windows has GCM available out of the box; if you
#                need BW on Windows, switch to Linux/WSL or extend this script)
#   ssh / none - clear any prior helper for this host

foreach ($app in (Get-IdentityAppliesTo)) {
    if (-not $app.host) { continue }
    $scope  = "credential.https://$($app.host)"
    $helper = $app.credential_helper

    & { $ErrorActionPreference = 'Continue'; git config --global --unset-all "$scope.helper" 2>$null | Out-Null }

    switch ($helper) {
        'gcm' {
            git config --global "$scope.helper" "manager"
            if ($env:IDENT_GIT_NAME) {
                git config --global "$scope.username" $env:IDENT_GIT_NAME
            }
            Write-Log "  $($app.host): GCM"
        }
        'bitwarden' {
            Write-Warn "  $($app.host): bitwarden helper not implemented for Windows host. Use the WSL side, or skip HTTPS auth for this host."
        }
        { $_ -in @('ssh','none','') } {
            Write-Log "  $($app.host): no helper (SSH-only)"
        }
        default {
            Write-Warn "  $($app.host): unknown credential_helper '$helper'"
        }
    }
}
