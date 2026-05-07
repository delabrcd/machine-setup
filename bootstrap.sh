#!/usr/bin/env bash
# Profile-driven Linux/WSL bootstrap.
#
# Usage:
#   bash bootstrap.sh                         # interactive on first run, then auto
#   MACHINE_SETUP_PROFILE=personal-server bash bootstrap.sh   # scripted
#   bash bootstrap.sh --reconfigure           # re-run the TUI
#
# Flow:
#   1. Self-update from origin
#   2. Detect OS tag (linux-ubuntu / linux-arch / wsl / ...)
#   3. Pick a profile (env var → saved config → TUI)
#   4. Resolve component dependency order
#   5. Optionally unlock Bitwarden (if any component needs it)
#   6. Run each component (per-identity if declared)
#   7. Summarize failures

set -euo pipefail

# Ctrl+C exits the bootstrap immediately. No fall-through, no half-applied
# state. Pickers + bw prompts that read /dev/tty all bubble SIGINT here.
trap 'echo ""; echo "Aborted by user." >&2; exit 130' INT

MACHINE_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MACHINE_SETUP_DIR

# Self-update + re-exec ──────────────────────────────────────────────────────
# The self-update has to happen before we source any lib/ scripts, since those
# are what get updated. Guard against infinite re-exec via _BOOTSTRAP_UPDATED.
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
    --quiet|-q) QUIET_MODE=1 ;;
    --help|-h)
      cat <<USAGE
Usage: bash bootstrap.sh [--reconfigure] [--quiet]
  --reconfigure   Re-run the profile + component pickers (otherwise saved choices are used)
  --quiet         Skip the component picker on first run; use the profile's component list as-is
Env:
  MACHINE_SETUP_PROFILE     Profile name to use (skips profile picker)
  MACHINE_SETUP_COMPONENTS  Comma-separated component override (skips component picker)
  BW_SESSION                Pre-unlocked Bitwarden session (e.g. from WSLENV)
  BW_PASSWORD               Master password (used for non-interactive unlock)
USAGE
      exit 0
      ;;
  esac
done
export QUIET_MODE

step "OS detection"
OS_TAG=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" os-tag)
log "OS tag: $OS_TAG"

if [ "$OS_TAG" = "wsl" ]; then
  ensure_wsl_interop || warn "WSL interop fix failed — Windows .exe interop disabled"
fi

# Bitwarden unlock — early, so BW-stored profiles + identities can populate
# the picker. If unlock fails or is skipped, fall back to public profiles
# only. BW_PASSWORD or BW_SESSION in env makes this non-interactive.
step "Bitwarden session (early)"
if command -v bw >/dev/null 2>&1; then
  bw_session_unlock || warn "BW unlock failed — continuing with public profiles only"
else
  log "bw CLI not installed yet — skipping early unlock (a profile that lists 'bw-cli' will install it on first run, then re-run for BW-stored profiles)."
fi

# Discover BW-stored profiles into a cache dir. config.py reads
# MACHINE_SETUP_BW_CACHE_DIR and treats it as a third overlay layer
# (between local/ and repo/) for profile lookups.
step "BW profile discovery"
BW_CACHE_DIR="${TMPDIR:-/tmp}/machine-setup-bw-$$"
trap 'rm -rf "$BW_CACHE_DIR" "${IDENTITY_REGISTRY_FILE:-}"' EXIT
mkdir -p "$BW_CACHE_DIR/profiles"
if check_bw_session 2>/dev/null; then
  bw_discover_profiles "$BW_CACHE_DIR" || true
fi
export MACHINE_SETUP_BW_CACHE_DIR="$BW_CACHE_DIR"

step "Profile selection"
if [ "$RECONFIGURE" = "1" ]; then
  ui_pick_profile_force
else
  ui_pick_profile
fi
log "Profile: $PROFILE"

step "Component selection"
if [ "$RECONFIGURE" = "1" ]; then
  ui_pick_components_force
else
  ui_pick_components
fi

# Pre-load plan with profile defaults
step "Resolve plan (initial)"
driver_load_plan "$PROFILE" "${COMPONENTS_OVERRIDE:-}"
log "Components: $(driver_components | paste -sd ' ' -)"

# Discover identities from BW into a registry file (BW already unlocked above)
step "Identity discovery"
IDENTITY_REGISTRY_FILE="$BW_CACHE_DIR/identities.json"
if check_bw_session 2>/dev/null; then
  bw_discover_identities "$IDENTITY_REGISTRY_FILE" || true
else
  echo '{}' > "$IDENTITY_REGISTRY_FILE"
fi
export MACHINE_SETUP_IDENTITY_REGISTRY="$IDENTITY_REGISTRY_FILE"

step "Identity selection"
if [ "$RECONFIGURE" = "1" ]; then
  ui_pick_identities_force
else
  ui_pick_identities
fi

# Re-resolve plan with the chosen identities folded in ───────────────────────
step "Resolve plan (final)"
driver_load_plan "$PROFILE" "${COMPONENTS_OVERRIDE:-}" "${IDENTITIES_OVERRIDE:-}"
log "Components: $(driver_components | paste -sd ' ' -)"
log "Identities: $(driver_identities | paste -sd ' ' -)"

# Run all components in topo order ───────────────────────────────────────────
driver_run_all
driver_summary
