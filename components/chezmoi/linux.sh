#!/usr/bin/env bash
# chezmoi: install the binary, then init/apply a configured dotfiles repo.
#
# Profile config (TOML):
#   [component_config.chezmoi]
#   repo = "https://github.com/USER/dotfiles.git"   # required
#   reset_entry_key = "/home/x/register-mcp-servers.sh"  # optional: clears
#       chezmoi entryState so a run_onchange_ script re-runs even if its
#       rendered SHA hasn't changed (useful when the script depends on
#       tools installed AFTER its first run cached "done").

ensure_path

if ! command -v chezmoi >/dev/null 2>&1; then
  log "Installing chezmoi..."
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" \
    || { warn "chezmoi installation failed"; return 1; }
fi

# The chezmoi source lives inside this repo at $MACHINE_SETUP_DIR/chezmoi-source.
# Override via [component_config.chezmoi].source = "/path/to/dir" if you want
# to point at a different source (e.g. a local/chezmoi-source overlay).
_source=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('source',''))")
[ -z "$_source" ] && _source="$MACHINE_SETUP_DIR/chezmoi-source"
_reset_key=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('reset_entry_key',''))")

if [ ! -d "$_source" ]; then
  warn "chezmoi: source dir '$_source' does not exist — skipping"
  return 0
fi

# Expose MCP-component selection to chezmoi templates as env vars.
# claude-config's run_onchange_register-mcp-servers.sh.tmpl reads these to
# decide which `claude mcp add` calls to emit, and pulls the secrets from
# Bitwarden via chezmoi's bitwardenFields template functions (no shell-side
# secret handling here — that was the old, fragile path).
_has_component() {
  printf '%s' "$PLAN_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('1' if any(c.get('name')=='$1' for c in d.get('components', [])) else '0')
"
}
export MS_MCP_CONTEXT7=$(_has_component mcp-context7)
export MS_MCP_BITBUCKET=$(_has_component mcp-bitbucket)
export MS_MCP_JIRA=$(_has_component mcp-jira)
log "MCP flags for chezmoi: context7=$MS_MCP_CONTEXT7 bitbucket=$MS_MCP_BITBUCKET jira=$MS_MCP_JIRA"

log "Applying chezmoi from local source: $_source"
if [ -n "$_reset_key" ]; then
  chezmoi state delete --source "$_source" --bucket=entryState --key="$_reset_key" >/dev/null 2>&1 || true
fi
chezmoi apply --source "$_source" --force \
  || warn "chezmoi apply had errors — config may be partially applied"

# Legacy: pull ~/.claude/CLAUDE.md from the BW item "Claude Code Global
# Config" (notes field). Superseded by the claude-sync-shell component,
# which packs the whole ~/.claude/ subset (including CLAUDE.md) into a
# single BW attachment ("Claude Code Config Bundle"). If that bundle item
# exists in the vault, skip this fetch so the two paths don't compete.
# Otherwise fall back to the legacy item for backwards compat.
if command -v bw >/dev/null 2>&1 && [ -n "${BW_SESSION:-}" ]; then
  _bundle_exists=$(bw list items --search "Claude Code Config Bundle" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    items = json.load(sys.stdin)
except Exception:
    items = []
print('1' if any(i.get('name') == 'Claude Code Config Bundle' for i in items) else '0')
")
  if [ "$_bundle_exists" = "1" ]; then
    log "Found 'Claude Code Config Bundle' — leaving CLAUDE.md to claude-sync"
  else
    _notes=$(bw get notes "Claude Code Global Config" 2>/dev/null || true)
    if [ -n "$_notes" ]; then
      mkdir -p "$HOME/.claude"
      printf '%s\n' "$_notes" > "$HOME/.claude/CLAUDE.md"
      log "Wrote ~/.claude/CLAUDE.md from Bitwarden (Claude Code Global Config, legacy)"
    fi
  fi
fi
