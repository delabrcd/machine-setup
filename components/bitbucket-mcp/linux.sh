#!/usr/bin/env bash
# Build the MCP server inside a configured directory.

_path=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('path','') or '')")
[ -n "$_path" ] || _path="${XDG_DATA_HOME:-$HOME/.local/share}/dev-utilities/bitbucket-mcp"

case "$_path" in '~'*) _path="$HOME${_path#\~}" ;; esac

[ -d "$_path" ] || { warn "bitbucket-mcp: $_path does not exist — skipping"; return 1; }

# Source nvm so npm is available
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && set +u && . "$NVM_DIR/nvm.sh" && set -u

command -v npm >/dev/null 2>&1 || { warn "npm not available — skipping"; return 1; }

(cd "$_path" && npm install && npm run build) \
  || { warn "build failed"; return 1; }
log "Built MCP server: $_path/dist"
