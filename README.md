# machine-setup

Profile-driven, modular bootstrap for any Linux distro, Windows host, or
WSL combo. Pick a profile (or define your own), and the bootstrap walks a
dependency-ordered list of components — installing packages, restoring
SSH keys from Bitwarden, configuring git identities, applying dotfiles, etc.

The same profile works on multiple OSes: each component declares which
OS tags it supports (`linux-ubuntu`, `linux-fedora`, `linux-arch`, `wsl`,
`windows`), and the resolver filters automatically.

## Anatomy

```
profiles/<name>.toml             # generic templates (components, no identities)
components/<name>/
    manifest.toml                # name, supported OSes, deps, per_identity flag
    linux.sh                     # Linux/WSL implementation (optional)
    windows.ps1                  # Windows implementation (optional)
local/                           # gitignored overlay — your private bindings
    profiles/<name>.toml         # repo URLs, chezmoi.repo, pinned identities
    identities/<name>.toml       # OPTIONAL — TOML fallback if you don't use BW
```

**Identities live in Bitwarden.** Each identity is a BW item named
`Machine Identity: <name>` with these fields:

| Field              | Type   | What it is                                              |
| ------------------ | ------ | ------------------------------------------------------- |
| `git_name`         | text   | git `user.name`                                         |
| `git_email`        | text   | git `user.email`                                        |
| `ssh_key_basename` | text   | optional, defaults to `id_ed25519_<name>`               |
| `default`          | text   | `"true"` for the global default identity (one per host) |
| `applies_to_json`  | text   | JSON: `[{"host":"...","git_url_patterns":[...],"credential_helper":"ssh|gcm|bitwarden|none"}]` |
| `public_key`       | text   | OpenSSH `ssh-ed25519 AAAA...`                           |
| `private_key`      | hidden | OpenSSH private key                                     |

The bootstrap discovers these at runtime, shows a picker pre-checked
according to the active profile, and saves your selection to
`~/.config/machine-setup/machine.toml`. The public repo carries no
identity data.

`local/` always wins for profiles. Drop work-only profile bindings
(chezmoi repo URL, dev-utilities repo URL, etc.) there and the public
repo stays generic. See [`local/README.md`](local/README.md) for a
worked example.

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

Both installers do the minimum to get `git` available, clone this repo to
`~/.local/share/machine-setup`, and hand off to `bootstrap.sh` /
`bootstrap.ps1`. Set `MACHINE_SETUP_PROFILE` first to pre-pick a profile
and skip the TUI — handy for VM/CI setups.

## Re-runs

```sh
bash ~/.local/share/machine-setup/bootstrap.sh                # uses saved profile + components
bash ~/.local/share/machine-setup/bootstrap.sh --reconfigure  # re-pick both
bash ~/.local/share/machine-setup/bootstrap.sh --quiet        # use profile defaults, skip component picker
MACHINE_SETUP_PROFILE=personal-server bash bootstrap.sh        # scripted profile
MACHINE_SETUP_COMPONENTS=packages,nvm,claude-code bash bootstrap.sh  # scripted component subset
```

```powershell
& "$env:USERPROFILE\.local\share\machine-setup\bootstrap.ps1"             # uses saved choices
& "$env:USERPROFILE\.local\share\machine-setup\bootstrap.ps1" -Reconfigure
& "$env:USERPROFILE\.local\share\machine-setup\bootstrap.ps1" -Quiet
$env:MACHINE_SETUP_PROFILE = "windows-desktop"
& "$env:USERPROFILE\.local\share\machine-setup\bootstrap.ps1"
```

## First-run flow

1. **Profile picker** — pick one of `profiles/*.toml` (or `local/profiles/*.toml`).
2. **Component picker** — every component supported by the current OS is shown,
   pre-checked according to the chosen profile. Toggle individual ones on/off.
   The resolver pulls transitive deps in automatically — selecting just
   `claude-code` will quietly pull in `packages`.
3. **Bitwarden unlock** — fired if either (a) the plan has a BW-using
   component, or (b) we want to discover identities from BW (default).
4. **Identity picker** — every BW item named `Machine Identity: *` (plus any
   `local/identities/<name>.toml`) shows up. Pre-checked according to the
   profile. Toggle which identities should be installed on this machine.
5. **Run** — components execute in dependency order; per-identity components
   loop over the chosen identities.

`--quiet` (Linux: `-q`) skips the component + identity pickers and uses the
profile's lists as-is. All three choices (profile / components / identities)
persist to `~/.config/machine-setup/machine.toml` (or
`%USERPROFILE%\.config\...` on Windows). Re-pick with `--reconfigure`.

## Built-in profiles

All in-repo profiles ship with `identities = []` — pick which BW
identities to install at runtime via the picker.

| Profile          | OS targets        | What it sets up                                  |
| ---------------- | ----------------- | ------------------------------------------------ |
| `minimal`        | Linux/WSL         | Just packages + Claude Code (no identity work)   |
| `linux-server`   | Linux/WSL         | + BW SSH key, git config, credential helpers     |
| `linux-desktop`  | Linux/WSL         | + uv + chezmoi (configure repo via local/)       |
| `windows-host`   | Windows + WSL     | Windows-side ident, then delegates to WSL bootstrap |

Define your own in `profiles/<name>.toml` (or `local/profiles/<name>.toml`).

## Available components

| Name                  | What it does                                            | Per-identity |
| --------------------- | ------------------------------------------------------- | ------------ |
| `packages`            | Base system packages (apt/dnf/pacman/winget)            | no           |
| `nvm`                 | nvm + Node LTS                                          | no           |
| `bw-cli`              | Bitwarden CLI                                           | no           |
| `uv`                  | uv (Astral) Python runner                               | no           |
| `claude-code`         | Anthropic Claude Code CLI (native installer on each OS) | no           |
| `chezmoi`             | Apply a configured dotfiles repo                        | no           |
| `git-base`            | Identity-agnostic git config + ssh-agent service        | no           |
| `git-identity`        | user.name/email/signing-key (with `includeIf` for non-defaults) | yes  |
| `ssh-key`             | Restore-from-BW or generate-and-store SSH keypair       | yes          |
| `credential-helpers`  | HTTPS helpers per identity (`gcm`, `bitwarden`, `ssh`)  | yes          |
| `bw-unlock-shell`     | Per-session `bw-unlock` function in shell rc / PS profile | no         |
| `wsl-interop`         | Re-register WSLInterop binfmt (WSL only)                | no           |
| `wsl-bootstrap`       | From Windows host: invoke bootstrap.sh inside WSL       | no           |
| `dev-utilities`       | Clone/reset an arbitrary git repo at a configured path  | no           |
| `bitbucket-mcp`       | `npm install && npm run build` in a configured dir      | no           |

Add your own component as a directory under `components/<name>/` with a
`manifest.toml`. If a component has no script for the current OS the runner
just skips it (so a Linux-only component is safe to list in a profile that
also runs on Windows).

## How identities work

A profile names one or more identities (e.g. `["personal", "work"]`).
Components flagged `per_identity = true` run once per identity, with
`IDENT_NAME`, `IDENT_GIT_NAME`, `IDENT_GIT_EMAIL`, `IDENT_BW_SSH_ITEM`,
`IDENT_DEFAULT`, and `IDENT_APPLIES_TO_JSON` set in the environment.

Exactly one identity per profile is the **default** (`default = true` in
the identity file). Its name/email/signing-key go into global git config.
Non-default identities get `includeIf` rules that activate them when the
working repo's remote URL matches one of their `git_url_patterns` —
classic per-host, per-identity git setup, but driven by config instead of
hardcoded.

The big payoff: a personal-only profile literally does not name any
work-related Bitwarden item, SSH key, repo URL, or email address
anywhere in its execution path. You can't accidentally install a work
key on a personal machine because there's nowhere for that intent to
hide.

## Adding a new identity

### Option 1: directly in the Bitwarden web UI

1. Create a Secure Note named `Machine Identity: <yourname>`.
2. Add custom fields (text, except `private_key` which is hidden):
   `git_name`, `git_email`, `default` (`"true"` or `"false"`),
   `applies_to_json` (see below), `public_key`, `private_key`.
3. Save. Bootstrap will pick it up on next run via the identity picker.

`applies_to_json` example for a personal GitHub identity that uses SSH:

```json
[
  {
    "host": "github.com",
    "git_url_patterns": ["git@github.com:*/*", "https://github.com/*/*"],
    "credential_helper": "ssh"
  }
]
```

### Option 2: from the CLI

```sh
export BW_SESSION="$(bw unlock --raw)"

# Interactive — prompts for name/email/host/helper, generates SSH key,
# stores in BW with all fields:
./tools/seed-bw-identity.sh new personal

# Or migrate an existing identities/<name>.toml + an existing SSH key item:
./tools/seed-bw-identity.sh from-toml local/identities/work.toml \
    --ssh-from "Machine SSH Key Work"
```

Both forms upsert idempotently — re-running updates fields in place.

### Option 3: TOML fallback (no Bitwarden)

Create `local/identities/<name>.toml` with the same shape as the
identity registry. The bootstrap loads it if no BW item matches. This
works for the SSH key fields too — point `bw_ssh_item` at any existing
BW SSH-key item to keep using one.

## Private keys never on disk

On Linux/WSL the `ssh-key` component pipes the private key directly
from BW into `ssh-add -` — it never touches disk. On Windows the private
key is written to a temp file with restricted ACL, loaded into the
ssh-agent service (which persists keys across reboots in DPAPI-encrypted
storage), and the temp file is immediately deleted.

The `ssh-key` component also auto-generates a fresh ed25519 key the
first time it can't find a BW item for an identity, then stores it back
in BW — same flow as before.

## Bitwarden credential helper (HTTPS auth)

For hosts that auth via username/api-token (corporate Bitbucket etc.),
declare on the identity's `applies_to` entry:

```toml
credential_helper  = "bitwarden"
bw_credential_item = "Some BW Item"
bw_username_field  = "username"
bw_password_field  = "api_token"
```

Currently Linux/WSL only.

## Auth scheme conventions

GitHub supports both SSH and HTTPS-with-GCM. Pick per identity:

| Identity kind | Recommended `credential_helper` | Why                                                          |
| ------------- | -------------------------------- | ------------------------------------------------------------ |
| Personal      | `ssh`                            | Simpler — your SSH key is already in agent for signing       |
| Work          | `gcm`                            | Many corporate GitHub orgs require SSO via the OAuth flow    |

Bitbucket only supports SSH for git auth (corporate Bitbucket dropped app
passwords); use `credential_helper = "ssh"` and make sure the identity's
SSH key is registered at `https://bitbucket.org/account/settings/ssh-keys/`.

The `credential-helpers` component reads `applies_to[].credential_helper`
per host, so one identity can use SSH for github.com and `bitwarden` for a
private host that takes username/api-token. See
[`components/credential-helpers/manifest.toml`](components/credential-helpers/manifest.toml)
for all options.

## Adding work / private overlay

See [`local/README.md`](local/README.md). TL;DR:

1. `local/identities/work.toml` — work git identity + BW SSH item name + applies_to.
2. `local/profiles/work-desktop.toml` — bundles personal + work + work-only components.
3. `bash bootstrap.sh` (or `.\bootstrap.ps1`) — pick the new profile.

Nothing in the public repo carries employer-specific data.
