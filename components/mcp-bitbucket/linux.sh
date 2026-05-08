#!/usr/bin/env bash
# Register aashari/mcp-server-atlassian-bitbucket as the Bitbucket MCP.
#
# Two auth modes supported (auto-detected from your BW item's fields):
#
#   1. API token (recommended; works with the new Scoped API Tokens)
#        env: ATLASSIAN_USER_EMAIL + ATLASSIAN_API_TOKEN
#        BW fields: bitbucket_email (or fallback) + bitbucket_api_token
#
#   2. App password (legacy; deprecated by Atlassian on 2026-06)
#        env: ATLASSIAN_BITBUCKET_USERNAME + ATLASSIAN_BITBUCKET_APP_PASSWORD
#        BW fields: bitbucket_username + bitbucket_app_password
#
# Override via [component_config.mcp-bitbucket] in machine.toml:
#   bw_item             = "Claude Code MCP Secrets"
#   bw_email_field      = "bitbucket_email"
#   bw_username_field   = "bitbucket_username"
#   bw_token_field      = "bitbucket_api_token"
#   bw_password_field   = "bitbucket_app_password"
#   workspace           = "your-workspace"     # sets BITBUCKET_DEFAULT_WORKSPACE
#   bw_workspace_field  = "bitbucket_workspace"
#   debug               = false                # sets DEBUG=true on the MCP for troubleshooting
#   scope               = "user"

bw_item=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_item','Claude Code MCP Secrets'))")
email_field=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_email_field','bitbucket_email'))")
user_field=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_username_field','bitbucket_username'))")
token_field=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_token_field','bitbucket_api_token'))")
password_field=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_password_field','bitbucket_app_password'))")
workspace_cfg=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('workspace','') or '')")
ws_field=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_workspace_field','bitbucket_workspace'))")
debug_flag=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print('1' if json.load(sys.stdin).get('debug') else '0')")
scope=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('scope','user'))")

command -v claude >/dev/null 2>&1 || { warn "claude CLI not on PATH"; return 1; }

if ! check_bw_session 2>/dev/null; then
  warn "Bitwarden not unlocked — skipping bitbucket MCP registration"
  return 1
fi

# Re-sync so any BW field changes since unlock are visible.
bw sync >/dev/null 2>&1 || warn "bw sync failed; reading possibly-stale cache"

# Pull all candidate fields from the BW item in one go
fields_blob=$(bw_item_json_exact "$bw_item" 2>/dev/null \
  | python3 - "$email_field" "$user_field" "$token_field" "$password_field" "$ws_field" <<'PY'
import sys, json
d = json.load(sys.stdin)
fs = {f.get('name'): f.get('value') for f in (d.get('fields') or [])}
e_f, u_f, t_f, p_f, w_f = sys.argv[1:6]
out = [
    fs.get(e_f, '') or '',  # email
    fs.get(u_f, '') or '',  # username
    fs.get(t_f, '') or '',  # api token
    fs.get(p_f, '') or '',  # app password
    fs.get(w_f, '') or '',  # workspace
]
print('\t'.join(out))
PY
)
IFS=$'\t' read -r email username token app_pw workspace_bw <<< "$fields_blob"
workspace="${workspace_cfg:-$workspace_bw}"

# Decide auth mode. Prefer API-token (email+token) when both are set, else
# fall back to legacy app-password. If username field happens to contain an
# email (has '@'), treat it as the email for the new flow.
if [ -z "$email" ] && [[ "$username" == *"@"* ]]; then
  email="$username"
fi

claude_args=()
if [ -n "$email" ] && [ -n "$token" ]; then
  log "Using API-token auth (ATLASSIAN_USER_EMAIL + ATLASSIAN_API_TOKEN)"
  claude_args+=(--env "ATLASSIAN_USER_EMAIL=$email" --env "ATLASSIAN_API_TOKEN=$token")
elif [ -n "$username" ] && [ -n "$app_pw" ]; then
  log "Using legacy app-password auth (ATLASSIAN_BITBUCKET_USERNAME + ATLASSIAN_BITBUCKET_APP_PASSWORD)"
  claude_args+=(--env "ATLASSIAN_BITBUCKET_USERNAME=$username" --env "ATLASSIAN_BITBUCKET_APP_PASSWORD=$app_pw")
else
  warn "BW item '$bw_item' has neither (email + api_token) nor (username + app_password) — skipping"
  warn "  expected fields: '$email_field'+'$token_field' OR '$user_field'+'$password_field'"
  return 1
fi

if [ -n "$workspace" ]; then
  claude_args+=(--env "BITBUCKET_DEFAULT_WORKSPACE=$workspace")
fi
if [ "$debug_flag" = "1" ]; then
  claude_args+=(--env "DEBUG=true")
fi

claude mcp remove --scope "$scope" bitbucket 2>/dev/null || true

claude mcp add --scope "$scope" bitbucket \
  "${claude_args[@]}" \
  -- npx -y @aashari/mcp-server-atlassian-bitbucket \
  || { warn "claude mcp add bitbucket failed"; return 1; }

log "Registered bitbucket MCP (scope=$scope)"
[ "$debug_flag" = "1" ] && log "  DEBUG=true — server logs at ~/.mcp/data/@aashari-mcp-server-atlassian-bitbucket"
