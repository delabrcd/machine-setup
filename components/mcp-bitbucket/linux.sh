#!/usr/bin/env bash
# Register aashari/mcp-server-atlassian-bitbucket as the Bitbucket MCP.

bw_item=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_item','Claude Code MCP Secrets'))")
user_field=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_username_field','bitbucket_username'))")
token_field=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_token_field','bitbucket_api_token'))")
scope=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('scope','user'))")

command -v claude >/dev/null 2>&1 || { warn "claude CLI not on PATH"; return 1; }

if ! check_bw_session 2>/dev/null; then
  warn "Bitwarden not unlocked — skipping bitbucket MCP registration"
  return 1
fi

# Pull both fields from the same BW item
fields=$(bw_item_json_exact "$bw_item" 2>/dev/null \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
fs = {f.get('name'): f.get('value') for f in (d.get('fields') or [])}
print(fs.get('$user_field','') + '\\t' + fs.get('$token_field',''))
")
username="${fields%%$'\t'*}"
token="${fields#*$'\t'}"

if [ -z "$username" ] || [ -z "$token" ]; then
  warn "BW item '$bw_item' missing '$user_field' or '$token_field' — skipping"
  return 1
fi

claude mcp remove --scope "$scope" bitbucket 2>/dev/null || true

# Aashari reads ATLASSIAN_BITBUCKET_USERNAME + ATLASSIAN_BITBUCKET_APP_PASSWORD.
# (The "APP_PASSWORD" env var name is kept by the project for backwards compat;
# you can put a scoped API token in there once your org's transition completes.)
claude mcp add --scope "$scope" bitbucket \
  --env "ATLASSIAN_BITBUCKET_USERNAME=$username" \
  --env "ATLASSIAN_BITBUCKET_APP_PASSWORD=$token" \
  -- npx -y @aashari/mcp-server-atlassian-bitbucket \
  || { warn "claude mcp add bitbucket failed"; return 1; }

log "Registered bitbucket MCP (scope=$scope)"
