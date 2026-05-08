#!/usr/bin/env bash
# Register the Jira MCP (sooperset/mcp-atlassian via `uvx`) with Claude Code.

bw_item=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_item','Claude Code MCP Secrets'))")
url_field=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_url_field','jira_url'))")
pat_field=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('bw_pat_field','jira_personal_token'))")
scope=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('scope','user'))")

command -v claude >/dev/null 2>&1 || { warn "claude CLI not on PATH"; return 1; }
command -v uvx    >/dev/null 2>&1 || { warn "uvx not on PATH (uv component should have installed it)"; return 1; }

if ! check_bw_session 2>/dev/null; then
  warn "Bitwarden not unlocked — skipping jira MCP registration"
  return 1
fi

fields=$(bw_item_json_exact "$bw_item" 2>/dev/null \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
fs = {f.get('name'): f.get('value') for f in (d.get('fields') or [])}
print(fs.get('$url_field','') + '\\t' + fs.get('$pat_field',''))
")
jira_url="${fields%%$'\t'*}"
jira_pat="${fields#*$'\t'}"

if [ -z "$jira_url" ] || [ -z "$jira_pat" ]; then
  warn "BW item '$bw_item' missing '$url_field' or '$pat_field' — skipping"
  return 1
fi

claude mcp remove --scope "$scope" jira 2>/dev/null || true

# mcp-atlassian reads JIRA_URL + JIRA_PERSONAL_TOKEN (PAT) for token auth.
claude mcp add --scope "$scope" jira \
  --env "JIRA_URL=$jira_url" \
  --env "JIRA_PERSONAL_TOKEN=$jira_pat" \
  -- uvx mcp-atlassian \
  || { warn "claude mcp add jira failed"; return 1; }

log "Registered jira MCP (scope=$scope)"
