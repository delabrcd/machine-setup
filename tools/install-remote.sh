#!/usr/bin/env bash
# Bootstrap a remote Linux/WSL machine over SSH, including any per-host overlay.
#
# Usage:  tools/install-remote.sh <ssh-host> [bootstrap-args...]
#
# What it does:
#   1. Installs git on the remote if missing (apt/dnf/pacman)
#   2. Clones the public machine-setup repo to ~/.local/share/machine-setup
#   3. Streams your *local checkout's* local/ overlay (tar-piped over ssh)
#      into the remote's local/ — so private identities/components follow you
#      to any box without ever hitting the public repo
#   4. Runs bootstrap.sh on the remote (interactive — ssh -t for prompts)
#
# The remote needs:
#   - ssh access (`ssh <host> echo ok` works)
#   - sudo for the package install step (only if git isn't present)
#   - your Bitwarden master password (or BW_PASSWORD in env)
set -euo pipefail

HOST="${1:?usage: $0 <ssh-host> [bootstrap-args...]}"
shift

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_DEST_LITERAL='$HOME/.local/share/machine-setup'
REPO_URL="${MACHINE_SETUP_REPO:-https://github.com/delabrcd/machine-setup.git}"

echo "==> [$HOST] Installing git + cloning machine-setup..."
ssh "$HOST" "REPO_URL=$REPO_URL bash -s" <<'REMOTE'
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y git
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y git
  elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm git
  else echo "ERROR: no apt/dnf/pacman; install git manually first." >&2; exit 1
  fi
fi

DEST="$HOME/.local/share/machine-setup"
mkdir -p "$(dirname "$DEST")"
if [ -d "$DEST/.git" ]; then
  echo "    Updating $DEST"
  git -C "$DEST" remote set-url origin "$REPO_URL"
  git -C "$DEST" fetch origin
  git -C "$DEST" reset --hard origin/HEAD
else
  echo "    Cloning $REPO_URL -> $DEST"
  git clone "$REPO_URL" "$DEST"
fi
mkdir -p "$DEST/local/identities" "$DEST/local/components"
REMOTE

echo "==> [$HOST] Copying local/ overlay..."
if [ -d "$REPO_ROOT/local" ]; then
  tar -C "$REPO_ROOT" -cf - \
      --exclude='local/README.md' \
      --exclude='local/.gitkeep' \
      local | \
    ssh "$HOST" "tar -xf - -C $REMOTE_DEST_LITERAL && echo '    overlay applied'"
else
  echo "    (no local/ on this machine — skipping overlay sync)"
fi

echo "==> [$HOST] Running bootstrap..."
# -t allocates a TTY so the BW prompt + key-registration pause both work.
exec ssh -t "$HOST" "bash $REMOTE_DEST_LITERAL/bootstrap.sh $*"
