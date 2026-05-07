#!/usr/bin/env bash
# Stage-0 installer for machine-setup.
# Usage:  curl -fsSL https://raw.githubusercontent.com/delabrcd/machine-setup/main/install.sh | bash
# Env:
#   MACHINE_SETUP_DIR     install location (default: ~/.local/share/machine-setup)
#   MACHINE_SETUP_REPO    repo URL         (default: https://github.com/delabrcd/machine-setup.git)
#   MACHINE_SETUP_PROFILE pre-pick a profile so the bootstrap doesn't prompt
set -euo pipefail

DEST="${MACHINE_SETUP_DIR:-$HOME/.local/share/machine-setup}"
REPO="${MACHINE_SETUP_REPO:-https://github.com/delabrcd/machine-setup.git}"

# Install git if missing — every distro has it in its base package set.
if ! command -v git >/dev/null 2>&1; then
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y git
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y git
  elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm git
  else
    echo "ERROR: git not installed and no recognized package manager (apt/dnf/pacman)." >&2
    exit 1
  fi
fi

if [ -d "$DEST/.git" ]; then
  echo "==> Updating $DEST"
  git -C "$DEST" fetch origin
  git -C "$DEST" reset --hard origin/HEAD
else
  echo "==> Cloning $REPO → $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone "$REPO" "$DEST"
fi

exec bash "$DEST/bootstrap.sh" "$@"
