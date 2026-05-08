#!/usr/bin/env bash
# Thin Linux/WSL stub. All flow logic lives in lib/main.py — this file just
# ensures python3 is available, performs the self-update + re-exec dance,
# then dispatches.
set -euo pipefail

trap 'echo ""; echo "Aborted by user." >&2; exit 130' INT

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Self-update + re-exec
if [ -d "$DIR/.git" ] && [ -z "${_BOOTSTRAP_UPDATED:-}" ]; then
  echo "==> Updating machine-setup..."
  git -C "$DIR" fetch origin 2>/dev/null || true
  git -C "$DIR" reset --hard origin/HEAD 2>/dev/null || true
  export _BOOTSTRAP_UPDATED=1
  exec bash "$DIR/bootstrap.sh" "$@"
fi

# Make sure python3 is available — main.py needs 3.11+ for tomllib.
if ! command -v python3 >/dev/null 2>&1; then
  echo "==> Installing python3..." >&2
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y python3
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y python3
  elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm python
  else echo "ERROR: install python3 manually." >&2; exit 1
  fi
fi

exec python3 "$DIR/lib/main.py" "$@"
