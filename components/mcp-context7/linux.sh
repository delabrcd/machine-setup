#!/usr/bin/env bash
# Register the context7 MCP server with Claude Code.
#
# Reads the API key from a Bitwarden item (default: "Claude Code MCP Secrets",
# field "context7_api_key") and runs `claude mcp add --user` so it shows up in
# `claude mcp list` regardless of cwd.
#
# Override item name / field via [component_config.mcp-context7] in machine.toml:
#   bw_item   = "Claude Code MCP Secrets"
#   bw_field  = "context7_api_key"
#   scope     = "user"   # or "local" / "project"

bw_item=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_item','Claude Code MCP Secrets'))")
bw_field=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_field','context7_api_key'))")
scope=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('scope','user'))")

command -v claude >/dev/null 2>&1 || { warn "claude CLI not on PATH"; return 1; }

if ! check_bw_session 2>/dev/null; then
  warn "Bitwarden not unlocked — skipping context7 MCP registration"
  return 1
fi

bw sync >/dev/null 2>&1 || warn "bw sync failed; reading possibly-stale cache"

api_key=$(bw_item_json_exact "$bw_item" 2>/dev/null \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(next((f['value'] for f in (d.get('fields') or []) if f.get('name')=='$bw_field'), ''))
")

if [ -z "$api_key" ]; then
  warn "BW item '$bw_item' has no '$bw_field' field — skipping"
  return 1
fi

# claude mcp add is idempotent only if the entry doesn't already exist; remove first.
claude mcp remove --scope "$scope" context7 2>/dev/null || true

claude mcp add --scope "$scope" context7 \
  --env "CONTEXT7_API_KEY=$api_key" \
  -- npx -y @upstash/context7-mcp \
  || { warn "claude mcp add context7 failed"; return 1; }

log "Registered context7 MCP (scope=$scope)"
