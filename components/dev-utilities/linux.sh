#!/usr/bin/env bash
# Clone or reset-to-origin a git repo at a configured path. Requires that any
# necessary SSH key was loaded by the ssh-key component already.

_repo=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('repo',''))")
_dest=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('dest','') or '')")

[ -n "$_repo" ] || { warn "dev-utilities: no repo set in [component_config.dev-utilities].repo — skipping"; return 0; }
[ -n "$_dest" ] || _dest="${XDG_DATA_HOME:-$HOME/.local/share}/dev-utilities"

# Tilde expansion (config files store ~/...)
case "$_dest" in
  '~'*) _dest="$HOME${_dest#\~}" ;;
esac

mkdir -p "$(dirname "$_dest")"
if [ -d "$_dest/.git" ]; then
  log "dev-utilities: $_dest exists; fetching + reset to origin/HEAD"
  git -C "$_dest" fetch origin || { warn "fetch failed"; return 1; }
  git -C "$_dest" reset --hard origin/HEAD
else
  log "dev-utilities: cloning $_repo → $_dest"
  git clone "$_repo" "$_dest" || { warn "clone failed"; return 1; }
fi
log "dev-utilities: $_dest"
