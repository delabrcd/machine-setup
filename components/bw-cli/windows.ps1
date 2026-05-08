. "$env:MACHINE_SETUP_DIR\lib\WindowsHelpers.ps1"

Install-Winget -Id "Bitwarden.CLI" -Label "Bitwarden CLI"
Sync-PathFromRegistry
