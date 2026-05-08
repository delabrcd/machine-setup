#!/usr/bin/env bash
# Signal-only component. Selection presence in the plan is the only signal;
# chezmoi handles the actual `claude mcp add` + BW secret extraction via its
# bitwardenFields template functions.
log "bitbucket MCP enabled — registration handled by chezmoi"
