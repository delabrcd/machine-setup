#!/usr/bin/env bash
# Identity-first Linux/WSL bootstrap.
#
# Flow:
#   1. Self-update + load lib/
#   2. OS detect; WSL: ensure interop
#   3. Bitwarden unlock + identity discovery
#   4. Identity selection (with [+] create-new wizard)
#   5. Per-identity auth picker (credential helper per host)
#   6. Component picker (required derived; optional toggleable)
#   7. Component-config prompts (chezmoi.repo, dev-utilities.repo, ...)
#   8. Resolve plan, run components in dep order
#
# All decisions persist to ~/.config/machine-setup/machine.toml.
# --reconfigure  re-runs every picker
# --quiet        skips pickers; uses saved selections
# Env: MACHINE_SETUP_IDENTITIES, MACHINE_SETUP_COMPONENTS,
#      BW_SESSION, BW_PASSWORD

set -euo pipefail
trap 'echo ""; echo "Aborted by user." >&2; exit 130' INT

MACHINE_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MACHINE_SETUP_DIR

# Self-update + re-exec ──────────────────────────────────────────────────────
if [ -d "$MACHINE_SETUP_DIR/.git" ] && [ -z "${_BOOTSTRAP_UPDATED:-}" ]; then
  echo "==> Updating machine-setup..."
  git -C "$MACHINE_SETUP_DIR" fetch origin 2>/dev/null || true
  git -C "$MACHINE_SETUP_DIR" reset --hard origin/HEAD 2>/dev/null || true
  export _BOOTSTRAP_UPDATED=1
  exec bash "$MACHINE_SETUP_DIR/bootstrap.sh" "$@"
fi

# shellcheck source=lib/common.sh
. "$MACHINE_SETUP_DIR/lib/common.sh"
# shellcheck source=lib/ui.sh
. "$MACHINE_SETUP_DIR/lib/ui.sh"
# shellcheck source=lib/driver.sh
. "$MACHINE_SETUP_DIR/lib/driver.sh"
# shellcheck source=lib/bw-session.sh
. "$MACHINE_SETUP_DIR/lib/bw-session.sh"

# Args ────────────────────────────────────────────────────────────────────────
RECONFIGURE=0
QUIET_MODE=0
for arg in "$@"; do
  case "$arg" in
    --reconfigure|-r) RECONFIGURE=1 ;;
    --quiet|-q)       QUIET_MODE=1 ;;
    --help|-h)
      cat <<USAGE
Usage: bash bootstrap.sh [--reconfigure] [--quiet]

  --reconfigure   Re-run every picker (default: use saved selections)
  --quiet         Skip pickers; use saved/env-supplied selections

Env:
  MACHINE_SETUP_IDENTITIES   Comma-separated identity names (skips picker)
  MACHINE_SETUP_COMPONENTS   Comma-separated optional components (skips picker)
  BW_SESSION                 Pre-unlocked Bitwarden session
  BW_PASSWORD                Master password (for non-interactive unlock)
USAGE
      exit 0
      ;;
  esac
done
export RECONFIGURE QUIET_MODE

# OS detection ───────────────────────────────────────────────────────────────
step "OS detection"
OS_TAG=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" os-tag)
log "OS tag: $OS_TAG"
if [ "$OS_TAG" = "wsl" ]; then
  ensure_wsl_interop || warn "WSL interop fix failed -- Windows .exe interop disabled"
fi

# Load saved state ───────────────────────────────────────────────────────────
step "Load saved state"
if [ "$RECONFIGURE" = "1" ]; then
  log "--reconfigure: clearing saved selections"
  _machine_state_reset
else
  _machine_state_load
fi
_machine_state_migrate_legacy

# Bitwarden unlock + discovery ──────────────────────────────────────────────
step "Bitwarden session"
if command -v bw >/dev/null 2>&1; then
  bw_session_unlock || warn "BW unlock failed -- identity discovery + BW components will be skipped"
else
  log "bw CLI not installed yet -- a fresh-install pass will install it; re-run after for BW-stored identities"
fi

step "BW discovery"
BW_CACHE_DIR="${TMPDIR:-/tmp}/machine-setup-bw-$$"
trap 'rm -rf "$BW_CACHE_DIR"' EXIT
mkdir -p "$BW_CACHE_DIR/profiles"
IDENTITY_REGISTRY_FILE="$BW_CACHE_DIR/identities.json"
echo '{}' > "$IDENTITY_REGISTRY_FILE"
if check_bw_session 2>/dev/null; then
  bw_discover_identities "$IDENTITY_REGISTRY_FILE" || true
fi
export MACHINE_SETUP_IDENTITY_REGISTRY="$IDENTITY_REGISTRY_FILE"

# Pickers ───────────────────────────────────────────────────────────────────
step "Identity selection"
ui_pick_identities

step "Per-identity auth"
ui_pick_auth

step "Component selection"
ui_pick_components

step "Component configuration"
ui_prompt_component_config

# Persist all decisions to machine.toml ─────────────────────────────────────
_machine_state_save
log "Saved selections to $MACHINE_CONFIG_FILE"

# Resolve + run ─────────────────────────────────────────────────────────────
step "Resolve plan"
driver_load_plan
log "Components: $(driver_components | paste -sd ' ' -)"
log "Identities: $(driver_identities | paste -sd ' ' -)"

driver_run_all
driver_summary
