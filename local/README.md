# `local/` — per-host private overlay

Everything here (except this README and `.gitkeep`) is **gitignored**. At
bootstrap time the loader checks `local/` first, then falls back to the
in-repo defaults — so you can override any profile, identity, or component
without leaking anything into public history.

## Directory layout

```
local/
├── profiles/<name>.toml      # private profile bindings (chezmoi.repo, dev-utilities.repo, etc.)
├── identities/<name>.toml    # OPTIONAL — TOML fallback for identities not in Bitwarden
└── components/<name>/        # per-component overrides (manifest + scripts)
    ├── manifest.toml
    └── linux.sh
```

## Recommended: identities live in Bitwarden, not here

The bootstrap discovers identities at runtime from BW items named
`Machine Identity: <name>`. See the top-level README for the field
schema. The TOML fallback below is only useful if you genuinely don't
want to use Bitwarden for an identity (rare).

## Typical usage: adding a work overlay

### 1. Create a work identity in Bitwarden

Easiest way: use the helper.

```sh
export BW_SESSION="$(bw unlock --raw)"
~/.local/share/machine-setup/tools/seed-bw-identity.sh new work
```

It prompts for `git_name`, `git_email`, host (e.g. `bitbucket.org`), and
credential helper (e.g. `ssh`); generates a fresh ed25519 key; stores
everything in a BW item called `Machine Identity: work`. Then register
the printed public key on the relevant service.

If you already have a TOML identity + an existing BW SSH-key item:

```sh
~/.local/share/machine-setup/tools/seed-bw-identity.sh from-toml local/identities/work.toml \
    --ssh-from "Machine SSH Key Work"
```

### 2. Drop a work profile in `local/profiles/`

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

# Empty list means "show the picker over BW-discovered identities".
# Pre-pin specific names here if you want to skip the picker.
identities = []

[component_config.chezmoi]
repo = "https://github.com/yourname/dotfiles.git"

[component_config.dev-utilities]
repo = "git@bitbucket.org:workspace-name/dev-utilities.git"
dest = "~/.local/share/dev-utilities"

[component_config.bitbucket-mcp]
path = "~/.local/share/dev-utilities/bitbucket-mcp"

# On work machines, override the personal identity's github.com helper from
# its default (ssh) to gcm — corporate networks often gate GitHub behind SSO
# which only works through the OAuth flow. The override is merged onto the
# identity's applies_to entry that matches `host = "github.com"`.
[[identity_overrides.personal.applies_to]]
host = "github.com"
credential_helper = "gcm"
```

That's it — `bash bootstrap.sh` will offer the new profile in the
profile picker, then offer your `personal` and `work` BW identities in
the identity picker.

## Per-profile identity tweaks

The `[[identity_overrides.<name>.applies_to]]` block above is the
escape hatch when one identity needs different behavior on different
profiles. Common case: `credential_helper` (ssh on personal machines,
gcm on work machines). It also works for any other applies_to field
(`bw_credential_item`, `register_url`, etc.) and for top-level identity
fields too:

```toml
[identity_overrides.personal]
ssh_key_basename = "id_ed25519_personal_alt"   # override top-level field

[[identity_overrides.personal.applies_to]]
host = "github.com"
credential_helper = "gcm"
```

Override matching is by `host`. If no existing applies_to entry has
that host, the override is appended as a new entry.

## Keeping `local/` synced across machines

Since this directory is gitignored, you have to bring it onto each new
machine yourself. Identities don't need this — they sync via Bitwarden
automatically. The remaining file (`local/profiles/work-desktop.toml`
or similar) is small and easy to move:

- **Bitwarden secure note** — paste the TOML into one BW note, recreate the file on each machine
- **Private gist / repo** — clone into `local/` after the first bootstrap
- **rsync / scp** — fastest one-off (`tools/install-remote.sh` does this automatically when bootstrapping over SSH)
