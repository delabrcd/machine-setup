#!/usr/bin/env bash
# Thin Linux/WSL stub. All flow logic lives in lib/main.py — this file just
# ensures python3 is available, performs the self-update + re-exec dance,
# then dispatches.
set -euo pipefail

trap 'echo ""; echo "Aborted by user." >&2; exit 130' INT

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Self-update + re-exec.
#
# Only safe to hard-reset when the working tree is clean AND we're on the
# branch that tracks origin's default head (typically main). Otherwise the
# user is doing local development on this repo and a reset would eat their
# work — skip the update and let bootstrap proceed against the local tree.
# Set MACHINE_SETUP_SKIP_UPDATE=1 to bypass the update entirely.
if [ -d "$DIR/.git" ] && [ -z "${_BOOTSTRAP_UPDATED:-}" ] && [ -z "${MACHINE_SETUP_SKIP_UPDATE:-}" ]; then
  _dirty=$(git -C "$DIR" status --porcelain 2>/dev/null || true)
  _branch=$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")
  _default=$(git -C "$DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  if [ -z "$_dirty" ] && [ -n "$_branch" ] && [ -n "$_default" ] && [ "$_branch" = "$_default" ]; then
    echo "==> Updating machine-setup..."
    git -C "$DIR" fetch origin 2>/dev/null || true
    git -C "$DIR" reset --hard "origin/$_default" 2>/dev/null || true
    export _BOOTSTRAP_UPDATED=1
    exec bash "$DIR/bootstrap.sh" "$@"
  else
    if [ -n "$_dirty" ]; then
      echo "==> Skipping self-update: working tree has local changes"
    elif [ -z "$_branch" ]; then
      echo "==> Skipping self-update: HEAD is detached"
    elif [ "$_branch" != "$_default" ]; then
      echo "==> Skipping self-update: on branch '$_branch' (default is '${_default:-unknown}')"
    fi
    export _BOOTSTRAP_UPDATED=1
  fi
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
