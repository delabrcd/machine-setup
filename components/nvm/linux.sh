#!/usr/bin/env bash
# Install nvm and the latest Node LTS.

export NVM_DIR="$HOME/.nvm"

if [ ! -d "$NVM_DIR" ]; then
  log "Installing nvm..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh | bash \
    || { warn "nvm installation failed"; return 1; }
else
  log "nvm already installed; updating..."
  (cd "$NVM_DIR" && git pull --ff-only 2>/dev/null) || true
fi

# nvm.sh references unset vars in some code paths; relax -u for the duration.
set +u
# shellcheck source=/dev/null
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
else
  set -u; warn "nvm.sh not found after install"; return 1
fi

nvm install --lts || { set -u; warn "Failed to install Node LTS"; return 1; }
nvm use --lts >/dev/null
nvm alias default 'lts/*' >/dev/null
set -u

log "node $(node --version)  npm $(npm --version)"

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  grep -q 'NVM_DIR' "$rc" && continue
  cat >> "$rc" <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
EOF
done
