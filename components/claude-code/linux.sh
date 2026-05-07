#!/usr/bin/env bash
# Claude Code CLI via the native installer (writes to ~/.local/bin).

ensure_path

if command -v claude >/dev/null 2>&1; then
  log "Claude Code already installed: $(claude --version 2>/dev/null || echo unknown)"
  return 0
fi

log "Installing Claude Code (native installer)..."
curl -fsSL https://claude.ai/install.sh | bash \
  || { warn "Claude Code installer failed"; return 1; }

command -v claude >/dev/null 2>&1 \
  || { warn "Claude Code installed but 'claude' not on PATH"; return 1; }
log "Claude Code: $(claude --version 2>/dev/null || echo unknown)"
