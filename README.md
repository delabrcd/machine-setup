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
   `Machine Identity: *` item is listed.
2. **Identity picker** — pick which identities to install. Includes a
   `[+] Create a new identity in Bitwarden...` entry that drops into a
   wizard (name, email, host, helper, generates ed25519, stores in BW).
3. **Per-identity auth picker** — for each chosen identity-host pair,
   confirm or override the credential helper (`ssh` / `gcm` / `bitwarden` /
   `none`). Override is per-machine, so the same identity can use SSH at
   home and GCM on a work box.
4. **Component picker** — required components are derived from your
   identity choices (`packages`, `git-base`, `git-identity`, `bw-cli`,
   `ssh-key`, `credential-helpers`) and shown as info. Optional components
   are toggleable: `claude-code`, `chezmoi`, `uv`, `dev-utilities`,
   `bitbucket-mcp`, `wsl-bootstrap`, `bw-unlock-shell`, etc.
5. **Component configuration** — for any selected optional component that
   needs it (`chezmoi.repo`, `dev-utilities.repo`, etc.), prompts for the
   value if not already saved.
6. **Run** — components execute in dependency order; per-identity
   components loop over each selected identity.

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
| `chezmoi`            | Apply a configured dotfiles repo                        | no           |
| `git-base`           | Identity-agnostic git config + ssh-agent service        | no           |
| `git-identity`       | user.name/email/signing-key (with `includeIf` for non-defaults) | yes  |
| `ssh-key`            | Restore-from-BW or generate-and-store SSH keypair       | yes          |
| `credential-helpers` | HTTPS helpers per identity (`gcm`, `bitwarden`, `ssh`)  | yes          |
| `bw-unlock-shell`    | Per-session `bw-unlock` function in shell rc / PS profile | no         |
| `wsl-interop`        | Re-register WSLInterop binfmt (WSL only)                | no           |
| `wsl-bootstrap`      | From Windows host: invoke bootstrap.sh inside WSL       | no           |
| `dev-utilities`      | Clone/reset an arbitrary git repo at a configured path  | no           |
| `bitbucket-mcp`      | `npm install && npm run build` in a configured dir      | no           |

Add your own component as a directory under `components/<name>/` with a
`manifest.toml`. Components without a script for the current OS are
skipped silently.

## Adding a new identity

### Option 1: from the bootstrap picker

The identity picker has a `[+] Create a new identity in Bitwarden...`
entry. Pick it and answer the prompts; the wizard generates the SSH key
and stores everything in BW.

### Option 2: from the CLI

```sh
export BW_SESSION="$(bw unlock --raw)"

# Interactive — prompts for name/email/host/helper:
./tools/seed-bw-identity.sh new personal

# Migrate an existing local TOML + existing standalone BW SSH-key item:
./tools/seed-bw-identity.sh from-toml local/identities/work.toml \
    --ssh-from "Machine SSH Key Work"
```

PowerShell equivalents at `tools\seed-bw-identity.ps1`.

### Option 3: directly in the Bitwarden web UI

Create a Secure Note named `Machine Identity: <yourname>` with the
fields listed above. `applies_to_json` example:

```json
[{"host":"github.com","git_url_patterns":["git@github.com:*/*","https://github.com/*/*"],"credential_helper":"ssh"}]
```

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
