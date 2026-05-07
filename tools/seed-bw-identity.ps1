<#
.SYNOPSIS
  PowerShell port of tools/seed-bw-identity.sh.

.DESCRIPTION
  Create or update a Bitwarden item named "Machine Identity: <name>" so the
  bootstrap can discover it as an identity at runtime.

.PARAMETER Mode
  from-toml | new

.PARAMETER Path
  For `from-toml`: path to a local/identities/<name>.toml file.

.PARAMETER Name
  For `new`: the identity name (becomes the suffix of the BW item name).

.PARAMETER SshFrom
  Name of an existing BW item whose private_key/public_key fields should be
  copied into the new identity item (for `from-toml`; defaults from
  the TOML's `bw_ssh_item` field if omitted).

.EXAMPLE
  $env:BW_SESSION = (bw unlock --raw)
  .\tools\seed-bw-identity.ps1 from-toml local\identities\work.toml -SshFrom "Machine SSH Key Work"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position=0)] [ValidateSet("from-toml","new")] [string]$Mode,
    [Parameter(Position=1)] [string]$Path,
    [string]$Name,
    [string]$SshFrom
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command bw -ErrorAction SilentlyContinue)) { throw "bw CLI not on PATH" }
if (-not $env:BW_SESSION) { throw "BW_SESSION not set. Run: `$env:BW_SESSION = (bw unlock --raw)" }

$python = (Get-Command py, python, python3 -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $python) { throw "python3 not on PATH" }

function Get-AllItems {
    $json = & { $ErrorActionPreference = "Continue"; bw list items 2>$null }
    if (-not $json) { return @() }
    return @($json | ConvertFrom-Json)
}

# Extract private_key + public_key fields from a BW item by name, returns
# [pscustomobject]@{ Private = ...; Public = ... } or $null if not found.
function Get-BwSshKey {
    param([string]$ItemName)
    $items = Get-AllItems | Where-Object { $_.name -eq $ItemName }
    foreach ($item in $items) {
        $priv = ($item.fields | Where-Object { $_.name -eq "private_key" } | Select-Object -First 1).value
        $pub  = ($item.fields | Where-Object { $_.name -eq "public_key"  } | Select-Object -First 1).value
        if ($priv -or $pub) {
            return [pscustomobject]@{ Private = $priv; Public = $pub }
        }
    }
    return $null
}

# Upsert a "Machine Identity: <name>" item with all metadata fields.
function Set-BwIdentity {
    param(
        [string]$ItemName,
        [string]$GitName, [string]$GitEmail,
        [string]$SshKeyBasename, [string]$IsDefault,
        [string]$AppliesToJson,
        [string]$PrivateKey, [string]$PublicKey
    )

    $existing = Get-AllItems | Where-Object { $_.name -eq $ItemName } | Select-Object -First 1

    # Field shape: type 0 = text, type 1 = hidden
    $desired = @(
        @{ name = "git_name";         value = $GitName;         type = 0 }
        @{ name = "git_email";        value = $GitEmail;        type = 0 }
        @{ name = "ssh_key_basename"; value = $SshKeyBasename;  type = 0 }
        @{ name = "default";          value = $IsDefault;       type = 0 }
        @{ name = "applies_to_json";  value = $AppliesToJson;   type = 0 }
    )
    if ($PublicKey)  { $desired += @{ name = "public_key";  value = $PublicKey;  type = 0 } }
    if ($PrivateKey) { $desired += @{ name = "private_key"; value = $PrivateKey; type = 1 } }

    if ($existing) {
        Write-Host "Updating $ItemName" -ForegroundColor Green
        # Preserve any extra fields already on the item; merge desired in.
        $byName = @{}
        $currentFields = if ($existing.fields) { @($existing.fields) } else { @() }
        foreach ($f in $currentFields) { $byName[$f.name] = $f }
        foreach ($d in $desired) {
            if ($byName.ContainsKey($d.name)) {
                $byName[$d.name].value = $d.value
                $byName[$d.name].type  = $d.type
            } else {
                $currentFields += [pscustomobject]$d
                $byName[$d.name] = $currentFields[-1]
            }
        }
        $existing.fields = $currentFields
        $payload = $existing | ConvertTo-Json -Depth 10 -Compress
        $payload | & bw encode | & bw edit item $existing.id | Out-Null
    } else {
        Write-Host "Creating $ItemName" -ForegroundColor Green
        $template = & bw get template item | ConvertFrom-Json
        $template.type = 2
        $template.name = $ItemName
        $template.secureNote = [pscustomobject]@{ type = 0 }
        $template.fields = @($desired | ForEach-Object { [pscustomobject]$_ })
        $payload = $template | ConvertTo-Json -Depth 10 -Compress
        $payload | & bw encode | & bw create item | Out-Null
    }
    Write-Host "Done: $ItemName" -ForegroundColor Green
}

# Use Python to parse TOML — robust, handles nested tables/arrays correctly.
function Read-IdentityToml {
    param([string]$Path)
    $script = @"
import sys, json, tomllib
with open(sys.argv[1], 'rb') as fp:
    d = tomllib.load(fp)
name = d.get('name') or sys.argv[2]
out = {
    'name':      name,
    'git_name':  d.get('git_name', ''),
    'git_email': d.get('git_email', ''),
    'ssh_key_basename': d.get('ssh_key_basename') or f'id_ed25519_{name}',
    'default':   'true' if d.get('default') else 'false',
    'applies_to_json': json.dumps(d.get('applies_to', [])),
    'bw_ssh_item': d.get('bw_ssh_item', ''),
}
print(json.dumps(out))
"@
    $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
    $out = & $python -c $script $Path $stem
    return ($out | ConvertFrom-Json)
}

# ── Mode dispatch ────────────────────────────────────────────────────────────
switch ($Mode) {
    "from-toml" {
        if (-not $Path) { throw "usage: from-toml <path-to-identity.toml> [-SshFrom <bw-item>]" }
        if (-not (Test-Path $Path)) { throw "no such file: $Path" }

        $t = Read-IdentityToml -Path $Path
        $itemName = if ($Name) { "Machine Identity: $Name" } else { "Machine Identity: $($t.name)" }

        # Default --ssh-from to the TOML's bw_ssh_item (unless it'd be a self-copy)
        if (-not $SshFrom -and $t.bw_ssh_item -and $t.bw_ssh_item -ne $itemName) {
            $SshFrom = $t.bw_ssh_item
        }

        $priv = ""; $pub = ""
        if ($SshFrom) {
            Write-Host "Pulling SSH key from existing BW item: $SshFrom" -ForegroundColor DarkGray
            $key = Get-BwSshKey -ItemName $SshFrom
            if ($key) {
                $priv = $key.Private; $pub = $key.Public
            } else {
                Write-Warning "  no private_key/public_key fields on '$SshFrom' -- identity will be created without SSH key"
            }
        } else {
            Write-Warning "No SSH source -- identity will be created without SSH key fields"
        }

        Set-BwIdentity `
            -ItemName        $itemName `
            -GitName         $t.git_name `
            -GitEmail        $t.git_email `
            -SshKeyBasename  $t.ssh_key_basename `
            -IsDefault       $t.default `
            -AppliesToJson   $t.applies_to_json `
            -PrivateKey      $priv `
            -PublicKey       $pub
    }
    "new" {
        throw "Interactive 'new' mode not yet ported to PowerShell. Use the bash version (Git Bash) or create the BW item via the web UI, then run from-toml."
    }
}
