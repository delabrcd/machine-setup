#!/usr/bin/env bash
# Signal-only component. Inclusion in the plan is the signal; chezmoi reads
# it (via the MS_MCP_* env vars its run script sets) and handles the actual
# `claude mcp add` plus secret extraction (via chezmoi's bitwardenFields
# template functions). No BW reads or claude invocations here.
log "context7 MCP enabled — registration handled by chezmoi"
