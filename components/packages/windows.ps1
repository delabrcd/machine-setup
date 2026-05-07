. "$script:MachineSetupDir\lib\WindowsHelpers.ps1"

# Base packages for Windows host. Note: uv (uvx) deliberately NOT installed here
# — corporate AV often scans/blocks the binary. Use the WSL side for uvx-based
# tooling instead.

Install-Winget -Id "Git.Git"               -Label "Git for Windows"
Install-Winget -Id "GitHub.cli"            -Label "gh CLI"
Install-Winget -Id "Python.Python.3.13"    -Label "Python 3"

Sync-PathFromRegistry
