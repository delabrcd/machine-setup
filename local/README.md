# `local/` — per-host private overlay

Everything here (except this README and `.gitkeep`) is **gitignored**. At
bootstrap time the loader checks `local/` first, then falls back to the
in-repo defaults.

In the current architecture, almost everything that used to live in
`local/` has moved:

- **Identities** → Bitwarden (`Machine Identity: <name>` items, managed
  via the in-TUI BW config wizard or the seed-bw-identity tools)
- **Profiles** → gone, replaced by per-machine `~/.config/machine-setup/machine.toml`
- **chezmoi source** → ships in-repo at `<repo>/chezmoi-source/`

So `local/` is mostly empty by default. It still serves as the escape
hatch for two things:

## When you'd actually use `local/`

### 1. TOML-fallback identity (instead of Bitwarden)

If for some reason you don't want a particular identity in Bitwarden:

```toml
# local/identities/scratch.toml
name = "scratch"
git_name = "Scratch User"
git_email = "scratch@example.com"
ssh_key_basename = "id_ed25519_scratch"
default = false

[[applies_to]]
host = "github.com"
git_url_patterns = ["git@github.com:*/*", "https://github.com/*/*"]
credential_helper = "ssh"
```

The picker shows it with a `[local-toml]` source tag.

### 2. chezmoi source override

Want to point chezmoi at your *own* dotfiles repo or a custom local copy
instead of the bundled `chezmoi-source/`? Edit `~/.config/machine-setup/machine.toml`:

```toml
[component_config.chezmoi]
source = "/path/to/your/chezmoi/source/dir"
```

Or symlink `local/chezmoi-source/` into place and reference it via the
same key.

### 3. Custom components

Drop in `local/components/<name>/manifest.toml` + `linux.sh` /
`windows.ps1` to add a per-machine component the public repo doesn't have.

## Setting up Bitwarden for the first time

You don't need to author files in `local/` for this anymore — the
bootstrap's BW config manager handles it. On a fresh vault:

1. Run the bootstrap (`curl|bash` one-liner from the top README).
2. Enter your BW master password at the unlock screen.
3. The vault is empty → BW manager auto-launches.
4. Click "Create new identity" — fill in name, email, host, helper,
   then choose Generate / Import-from-files / Paste for the SSH key.
5. Click "Manage MCP secrets" — fill in API keys + URLs.
6. Click "Edit Claude Code global instructions" — paste/edit the
   contents of `~/.claude/CLAUDE.md` (stored in BW notes field).
7. Click "Done".
7. Bootstrap continues with the picker, MCPs, plan execution.

Re-run any time and pick `[~] Manage Bitwarden config...` on the
identity picker to edit anything later.
