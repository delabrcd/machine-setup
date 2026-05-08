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

# Pull config out of $COMPONENT_CONFIG_JSON
_repo=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('repo',''))")
_reset_key=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('reset_entry_key',''))")

if [ -z "$_repo" ]; then
  warn "chezmoi: no repo configured in [component_config.chezmoi].repo — skipping"
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

if [ -d "${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi/.git" ]; then
  log "chezmoi source present; applying ($_repo)..."
  if [ -n "$_reset_key" ]; then
    chezmoi state delete --bucket=entryState --key="$_reset_key" >/dev/null 2>&1 || true
  fi
  chezmoi apply --force || warn "chezmoi apply had errors — config may be partially applied"
else
  log "Initialising chezmoi from $_repo..."
  chezmoi init --apply --force "$_repo" \
    || warn "chezmoi init failed — dotfiles not applied"
fi
