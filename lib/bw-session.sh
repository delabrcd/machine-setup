#!/usr/bin/env bash
# Unlock the Bitwarden vault so downstream components have BW_SESSION available.
# Called by bootstrap.sh after the bw-cli component runs (if any identity in
# the active profile uses Bitwarden — checked via bw_session_required).
#
# BW_SESSION may already be set in the environment (e.g. forwarded via WSLENV
# from the Windows bootstrap). In that case we just verify the session is
# unlocked and don't prompt.

bw_session_required() {
  # Returns 0 if any identity in the plan declares a bw_ssh_item OR uses the
  # bitwarden credential helper. Caller must have PLAN_JSON in the env.
  printf '%s\n' "$PLAN_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ident in data.get('identities', []):
    if ident.get('bw_ssh_item'):
        sys.exit(0)
    for app in ident.get('applies_to', []):
        if app.get('credential_helper') == 'bitwarden':
            sys.exit(0)
sys.exit(1)
"
}

bw_session_unlock() {
  command -v bw >/dev/null 2>&1 || { warn "bw CLI not installed; skipping vault unlock"; return 1; }

  if check_bw_session 2>/dev/null; then
    log "Bitwarden session already active."
    bw sync >/dev/null 2>&1 || warn "BW sync failed — using local cache"
    return 0
  fi

  local status
  status=$(bw status 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unauthenticated'))" \
    2>/dev/null || echo unauthenticated)

  if [ "$status" = "unauthenticated" ]; then
    log "Logging in to Bitwarden..."
    bw login || { warn "Bitwarden login failed — BW-dependent components will be skipped"; return 1; }
  fi

  if [ -n "${BW_PASSWORD:-}" ]; then
    log "Unlocking Bitwarden vault (BW_PASSWORD from environment)..."
    BW_SESSION=$(bw unlock --passwordenv BW_PASSWORD --raw) || \
      { warn "Bitwarden unlock failed"; return 1; }
  else
    log "Unlocking Bitwarden vault (enter master password)..."
    BW_SESSION=$(bw unlock --raw) || \
      { warn "Bitwarden unlock failed"; return 1; }
  fi
  export BW_SESSION

  log "Syncing Bitwarden vault..."
  bw sync >/dev/null 2>&1 || warn "BW sync failed — using local cache"
}
