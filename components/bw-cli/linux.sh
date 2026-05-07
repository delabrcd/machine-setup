#!/usr/bin/env bash
# Install Bitwarden CLI. Tries distro packages first (AUR on Arch), falls back
# to npm. After this component, downstream components can rely on `bw`.

if command -v bw >/dev/null 2>&1; then
  log "bw already installed: $(bw --version 2>/dev/null)"
  return 0
fi

# Source nvm so npm is available
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && set +u && . "$NVM_DIR/nvm.sh" && set -u

if command -v yay >/dev/null 2>&1; then
  log "Installing bw via yay (AUR)..."
  yay -S --noconfirm bitwarden-cli-bin && return 0 || true
elif command -v paru >/dev/null 2>&1; then
  log "Installing bw via paru (AUR)..."
  paru -S --noconfirm bitwarden-cli-bin && return 0 || true
fi

if command -v npm >/dev/null 2>&1; then
  log "Installing bw via npm..."
  npm install -g @bitwarden/cli || warn "Bitwarden CLI installation failed"
else
  warn "npm not available — skipping Bitwarden CLI install"
  return 1
fi
