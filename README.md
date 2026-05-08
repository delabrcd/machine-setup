# machine-setup

Identity-first, modular bootstrap for any Linux distro, Windows host, or
WSL combo. Pick which **identities** to install on this machine, configure
their **per-host auth**, and the bootstrap derives the required components
+ lets you toggle optional ones.

Identities (SSH keys + git config + per-host auth) live in **Bitwarden**.
The public repo carries no personal data; configuration syncs across
machines via your vault.

## Anatomy

```
components/<name>/                    # the building blocks
    manifest.toml                     # supported OSes, deps, per_identity flag
    linux.sh                          # Linux/WSL implementation (optional)
    windows.ps1                       # Windows implementation (optional)
local/                                # gitignored — per-machine private bindings
    identities/<name>.toml            # OPTIONAL — TOML fallback if you don't use BW
    components/<name>/                # OPTIONAL — per-host component overrides

Bitwarden                             # canonical cross-machine config
    "Machine Identity: <name>"        # SSH key + git_name/email/applies_to fields

~/.config/machine-setup/machine.toml  # the only persisted state per machine:
                                      #   identities (which to install)
                                      #   extra_components (optional toggles)
                                      #   identity_overrides (per-host helper)
                                      #   component_config (chezmoi.repo etc.)
```

**Identities are Bitwarden Secure Notes** named `Machine Identity: <name>`:

| Field              | Type   | What it is                                              |
| ------------------ | ------ | ------------------------------------------------------- |
| `git_name`         | text   | git `user.name`                                         |
| `git_email`        | text   | git `user.email`                                        |
| `ssh_key_basename` | text   | optional, defaults to `id_ed25519_<name>`               |
| `default`          | text   | `"true"` for the global default identity                |
| `applies_to_json`  | text   | JSON: `[{"host":"...","git_url_patterns":[...],"credential_helper":"ssh|gcm|bitwarden|none"}]` |
| `public_key`       | text   | OpenSSH `ssh-ed25519 AAAA...`                           |
| `private_key`      | hidden | OpenSSH private key                                     |

## One-liners (fresh machine)

### Linux / WSL

```sh
curl -fsSL https://raw.githubusercontent.com/delabrcd/machine-setup/main/install.sh | bash
```

### Windows

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/delabrcd/machine-setup/main/install.ps1 | iex
```

Both installers ensure `git` is present, clone this repo to
`~/.local/share/machine-setup`, and hand off to `bootstrap.sh` /
`bootstrap.ps1`.

## Re-runs

```sh
bash ~/.local/share/machine-setup/bootstrap.sh                # uses saved selections
bash ~/.local/share/machine-setup/bootstrap.sh --reconfigure  # re-prompt every picker
bash ~/.local/share/machine-setup/bootstrap.sh --quiet        # skip pickers; use saved
MACHINE_SETUP_IDENTITIES=personal,work bash bootstrap.sh       # env-pin identities
MACHINE_SETUP_COMPONENTS=claude-code,uv bash bootstrap.sh      # env-pin extras
```

## First-run flow

1. **Bitwarden unlock + identity discovery** — vault unlocked early; every
   `Machine Identity: *` item + the `Claude Code MCP Secrets` item are
   discovered.
2. **First-time setup auto-detect** — if the vault has zero identity
   items AND zero MCP secrets, the BW config manager pushes itself
   automatically so you can populate the vault before the picker.
3. **Identity picker** — pick which identities to install. The first two
   entries are:
   - `[~] Manage Bitwarden config...` — opens the manager any time
   - `[+] Create new identity in Bitwarden...` — fast path to a single
     identity creation form (same form the manager uses)
4. **Per-identity auth picker** — for each chosen identity-host pair,
   confirm or override the credential helper (`ssh` / `gcm` / `bitwarden` /
   `none`). Override is per-machine, so the same identity can use SSH at
   home and GCM on a work box.
5. **Component picker** — required components are derived from your
   identity choices (`packages`, `git-base`, `git-identity`, `bw-cli`,
   `ssh-key`, `credential-helpers`) and shown as info. Optional components
   are toggleable: `claude-code`, `chezmoi`, `uv`, `mcp-context7`,
   `mcp-bitbucket`, `mcp-jira`, `wsl-bootstrap`, `bw-unlock-shell`, etc.
6. **Component configuration** — for any selected optional component
   that needs it (today only `wsl-bootstrap.distro`), prompts for the
   value if not already saved.
7. **Sudo** — captures sudo password into the cache via `sudo -S -v` so
   component installs don't prompt mid-run.
8. **Run** — components execute in dependency order, output streamed
   into a RichLog; per-identity components loop over each selected
   identity.

All decisions persist to `~/.config/machine-setup/machine.toml`. Re-pick
with `--reconfigure`, edit the file directly, or delete it to start fresh.

## Available components

| Name                 | What it does                                            | Per-identity |
| -------------------- | ------------------------------------------------------- | ------------ |
| `packages`           | Base system packages (apt/dnf/pacman/winget)            | no           |
| `nvm`                | nvm + Node LTS                                          | no           |
| `bw-cli`             | Bitwarden CLI                                           | no           |
| `uv`                 | uv (Astral) Python runner                               | no           |
| `claude-code`        | Anthropic Claude Code CLI (native installer on each OS) | no           |
| `chezmoi`            | Apply the in-repo `chezmoi-source/` dotfiles            | no           |
| `git-base`           | Identity-agnostic git config + ssh-agent service        | no           |
| `git-identity`       | user.name/email/signing-key (with `includeIf` for non-defaults) | yes  |
| `ssh-key`            | Restore-from-BW or generate-and-store SSH keypair       | yes          |
| `credential-helpers` | HTTPS helpers per identity (`gcm`, `bitwarden`, `ssh`)  | yes          |
| `bw-unlock-shell`    | Per-session `bw-unlock` function in shell rc / PS profile | no         |
| `wsl-interop`        | Re-register WSLInterop binfmt (WSL only)                | no           |
| `wsl-bootstrap`      | From Windows host: invoke bootstrap inside WSL          | no           |
| `mcp-context7`       | Enable the context7 MCP (signal — chezmoi registers it) | no           |
| `mcp-bitbucket`      | Enable the Bitbucket MCP (aashari, signal-only)         | no           |
| `mcp-jira`           | Enable the Jira MCP (sooperset/mcp-atlassian, signal)   | no           |

Add your own component as a directory under `components/<name>/` with a
`manifest.toml`. Components without a script for the current OS are
skipped silently.

## Bitwarden config (identities + MCP secrets)

The bootstrap ships with an in-TUI **BW config manager** so you don't
have to edit your vault by hand. It's accessible two ways:

### First-time setup (empty vault)

The bootstrap detects a fresh vault — no `Machine Identity:` items and
no `Claude Code MCP Secrets` item — and pushes the manager automatically
right after BW unlock. Walk through:

1. **Create new identity** — name, git_name, git_email, host, credential
   helper. Then for the SSH key, choose:
   - *Generate new ed25519* — fresh keypair, stored in the BW item
   - *Import key files* — point at existing `~/.ssh/id_ed25519` + `.pub`
     paths, contents are uploaded into the BW item
   - *Paste key text* — paste OpenSSH-format private + public blocks
2. Repeat for each identity you want (personal, work, etc.).
3. **Manage MCP secrets** — single form for `context7_api_key`,
   `bitbucket_email` / `bitbucket_api_token` / `bitbucket_workspace`,
   `jira_url` / `jira_pat`. Hidden fields stored as `type: 1`.
4. **Done** — back to the identity picker.

### Editing later

The identity picker's first entry is
`[~] Manage Bitwarden config (identities + MCP secrets)...`. Toggle it
on, Ctrl+S → manager screen → pick `Edit: <name>` for any identity, or
`Manage MCP secrets` to update keys. Saves go straight to BW; the
picker re-renders with the latest list when you return.

### Field reference

**Machine Identity item** (BW item name: `Machine Identity: <name>`):

| Field              | Type   | Purpose                                                |
| ------------------ | ------ | ------------------------------------------------------ |
| `git_name`         | text   | git `user.name`                                        |
| `git_email`        | text   | git `user.email`                                       |
| `ssh_key_basename` | text   | optional, defaults to `id_ed25519_<name>`              |
| `default`          | text   | `"true"` for the global default identity               |
| `applies_to_json`  | text   | per-host config (see below)                            |
| `public_key`       | text   | OpenSSH public                                         |
| `private_key`      | hidden | OpenSSH private                                        |

`applies_to_json` example:

```json
[{"host":"github.com","git_url_patterns":["git@github.com:*/*","https://github.com/*/*"],"credential_helper":"ssh"}]
```

**Claude Code MCP Secrets item** (one BW item, all field names exactly
as below; field types in parentheses):

| Field                  | Type   | Used by         |
| ---------------------- | ------ | --------------- |
| `context7_api_key`     | hidden | context7 MCP    |
| `bitbucket_email`      | text   | bitbucket MCP   |
| `bitbucket_api_token`  | hidden | bitbucket MCP   |
| `bitbucket_workspace`  | text   | bitbucket MCP (default workspace) |
| `jira_url`             | text   | jira MCP        |
| `jira_pat`             | hidden | jira MCP        |

The chezmoi `run_onchange_register-mcp-servers` template reads these at
chezmoi-apply time (runtime `bw get item`, never inlined into rendered
files) and emits `claude mcp add` calls — gated on which `mcp-*`
components you picked in the bootstrap.

### Power-user CLI alternative

If you'd rather script it:

```sh
export BW_SESSION="$(bw unlock --raw)"
./tools/seed-bw-identity.sh new personal               # interactive identity create
./tools/seed-bw-identity.sh from-toml local/identities/work.toml \
    --ssh-from "Machine SSH Key Work"                  # one-shot migration
```

PowerShell equivalent at `tools\seed-bw-identity.ps1`. The TUI manager
covers everything these tools do plus MCP-secrets editing and SSH-key
import-from-file/paste, so you'll rarely need them.

## Per-machine identity overrides

When the same identity needs different auth on different machines (your
personal identity uses SSH at home but GCM on the work box), the per-
identity auth picker handles it on first run. The override lives in
this machine's `machine.toml`:

```toml
[identity_overrides.personal."github.com"]
credential_helper = "gcm"
```

Re-run `bootstrap.sh --reconfigure` to re-pick auth methods.

## Private keys never on disk

On Linux/WSL the `ssh-key` component pipes the private key directly
from BW into `ssh-add -` — it never touches disk. On Windows the private
key is written to a temp file with restricted ACL, loaded into the
ssh-agent service (which persists keys across reboots in DPAPI-encrypted
storage), and the temp file is immediately deleted.

The `ssh-key` component also auto-generates a fresh ed25519 key the
first time it can't find a BW item for an identity, then stores it back
in BW.

## Bitwarden credential helper (HTTPS auth)

For hosts that auth via username/api-token (corporate Bitbucket etc.),
declare on the identity's `applies_to` entry (in `applies_to_json`):

```json
{
  "host": "bitbucket.org",
  "credential_helper": "bitwarden",
  "bw_credential_item": "Some BW Item",
  "bw_username_field": "username",
  "bw_password_field": "api_token"
}
```

Currently Linux/WSL only.

## Bootstrap a remote machine

`tools/install-remote.sh <host>` (and `.ps1`) handles a remote setup in
one command: installs git, clones the public repo, tar-pipes your
`local/` overlay over SSH, runs the bootstrap interactively (BW prompt,
key registration pause, etc. all flow through the SSH TTY).

```sh
./tools/install-remote.sh desktop
```

```powershell
.\tools\install-remote.ps1 desktop
```
