# `local/` — per-host private overlay

Everything in this directory (except this README and `.gitkeep`) is **gitignored**.
At bootstrap time the loader looks for files here first, then falls back to the
repo defaults — so you can override any profile, identity, or component without
leaking anything into the public history.

## Directory layout

```
local/
├── profiles/<name>.toml      # extra or overriding profiles
├── identities/<name>.toml    # extra or overriding identities
└── components/<name>/        # per-component overrides (manifest, scripts)
    ├── manifest.toml
    └── linux.sh
```

## Typical usage: adding a work overlay

Two files. First, the work identity:

```toml
# local/identities/work.toml
name = "work"
git_name = "Your Name"
git_email = "you@employer.com"
bw_ssh_item = "Machine SSH Key Work"
ssh_key_basename = "id_ed25519_work"
default = false   # personal stays default; work is scoped via includeIf

# Bitbucket only supports SSH for git auth.
[[applies_to]]
host = "bitbucket.org"
git_url_patterns = [
    "git@bitbucket.org:*/*",
    "https://bitbucket.org/*/*",
]
credential_helper = "ssh"
register_url = "https://bitbucket.org/account/settings/ssh-keys/"
register_label = "Bitbucket (SSH key)"

# If your work GitHub access is gated by SSO/HTTPS, prefer GCM here. Otherwise
# drop this block entirely — the personal identity already covers github.com.
[[applies_to]]
host = "github.com"
git_url_patterns = [
    "git@github-work:*/*",                         # if you set up an SSH host alias
    "https://github.com/your-employer-org/*",      # tighter than `*/*`
]
credential_helper = "gcm"


Then a work profile that bundles personal + work:

```toml
# local/profiles/work-desktop.toml
name = "work-desktop"
description = "Work desktop — personal + work identities, dev-utilities, MCPs"

components = [
    "packages", "nvm", "bw-cli", "uv",
    "git-base", "git-identity", "ssh-key", "credential-helpers",
    "bw-unlock-shell",
    "claude-code", "chezmoi",
    "dev-utilities", "bitbucket-mcp",
]

identities = ["personal", "work"]

[component_config.chezmoi]
repo = "https://github.com/yourname/claude-config.git"
reset_entry_key = "register-mcp-servers.sh"

[component_config.dev-utilities]
repo = "git@bitbucket.org:workspace-name/dev-utilities.git"
dest = "~/.local/share/dev-utilities"

[component_config.bitbucket-mcp]
path = "~/.local/share/dev-utilities/bitbucket-mcp"
```

That's it — `bash bootstrap.sh` will pick up the new profile in the picker.

## Tip: keeping `local/` synced across machines

Since `local/` is gitignored, you have to bring it onto each new machine
yourself. A few options:

- **Bitwarden secure note** — paste the contents of each file into a single
  note, then recreate them on each machine.
- **Private gist or repo** — clone into `local/` after the first bootstrap.
- **rsync from another box** — fastest for one-off setups.
