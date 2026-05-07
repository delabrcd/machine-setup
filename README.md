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
profiles/<name>.toml             # what gets installed (components + identities)
identities/<name>.toml           # name/email/SSH key per git identity
components/<name>/
    manifest.toml                # name, supported OSes, deps, per_identity flag
    linux.sh                     # Linux/WSL implementation (optional)
    windows.ps1                  # Windows implementation (optional)
local/                           # gitignored overlay — mirrors the layout above
    profiles/, identities/, components/
```

`local/` always wins. Drop work-only profiles, employer email, private repo
URLs, or any other private config there and the public repo stays clean.
See [`local/README.md`](local/README.md) for a worked example.

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
bash ~/.local/share/machine-setup/bootstrap.sh                # uses saved profile
bash ~/.local/share/machine-setup/bootstrap.sh --reconfigure  # re-pick
MACHINE_SETUP_PROFILE=personal-server bash bootstrap.sh        # scripted override
```

```powershell
& "$env:USERPROFILE\.local\share\machine-setup\bootstrap.ps1"             # uses saved profile
& "$env:USERPROFILE\.local\share\machine-setup\bootstrap.ps1" -Reconfigure
$env:MACHINE_SETUP_PROFILE = "windows-desktop"
& "$env:USERPROFILE\.local\share\machine-setup\bootstrap.ps1"
```

The first interactive run saves the chosen profile to
`~/.config/machine-setup/machine.toml` (or `%USERPROFILE%\.config\...` on
Windows), so subsequent runs are non-interactive.

## Built-in profiles

| Profile           | OS targets        | Identities  | Notes                                            |
| ----------------- | ----------------- | ----------- | ------------------------------------------------ |
| `minimal`         | Linux/WSL         | none        | Just packages + Claude Code                      |
| `personal-server` | Linux/WSL         | personal    | Adds BW SSH key, git config, GCM for github.com  |
| `personal-desktop`| Linux/WSL         | personal    | Adds uv + chezmoi-managed Claude Code config     |
| `windows-desktop` | Windows + WSL     | personal    | Windows-side identity, then runs personal-* in WSL |

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

## Bitwarden items

Components that touch Bitwarden look up items by name. Each identity's
SSH item must have:

| Field         | Type           |
| ------------- | -------------- |
| `private_key` | hidden / secure |
| `public_key`  | text            |

The `ssh-key` component will *generate and store* a fresh ed25519 key
the first time it can't find the named item. Private keys are never
written to disk on Linux/WSL (loaded straight from BW into `ssh-add`).
On Windows they're written to a temp file with restricted ACL, loaded
into `ssh-agent`, and immediately deleted.

For the `bitwarden` credential helper (currently Linux-only), declare:

```toml
bw_credential_item  = "Some BW Item"
bw_username_field   = "username"
bw_password_field   = "api_token"
```

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
