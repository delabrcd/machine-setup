#!/usr/bin/env bash
# Install uv via the Astral installer. Writes to ~/.local/bin.

if command -v uv >/dev/null 2>&1; then
  log "uv already installed: $(uv --version 2>/dev/null)"
  return 0
fi

log "Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh \
  || { warn "uv installation failed"; return 1; }
ensure_path
