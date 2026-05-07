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
for arg in "$@"; do
  case "$arg" in
    --reconfigure|-r) RECONFIGURE=1 ;;
    --help|-h)
      cat <<USAGE
Usage: bash bootstrap.sh [--reconfigure]
  --reconfigure   Re-run the profile picker (otherwise saved choice is used)
Env:
  MACHINE_SETUP_PROFILE  Profile name to use (skips TUI)
  BW_SESSION             Pre-unlocked Bitwarden session (e.g. from WSLENV)
  BW_PASSWORD            Master password (used for non-interactive unlock)
USAGE
      exit 0
      ;;
  esac
done

step "OS detection"
OS_TAG=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" os-tag)
log "OS tag: $OS_TAG"

# WSL needs interop early so the GCM bridge works. Components can also run
# this via the wsl-interop component, but doing it here means it's available
# to any subsequent step regardless of profile composition.
if [ "$OS_TAG" = "wsl" ]; then
  ensure_wsl_interop || warn "WSL interop fix failed — Windows .exe interop disabled"
fi

step "Profile selection"
if [ "$RECONFIGURE" = "1" ]; then
  ui_pick_profile_force
else
  ui_pick_profile
fi
log "Profile: $PROFILE"

step "Resolve plan"
driver_load_plan "$PROFILE"
log "Components: $(driver_components | paste -sd ' ' -)"
log "Identities: $(driver_identities | paste -sd ' ' -)"

step "Bitwarden session"
if bw_session_required; then
  bw_session_unlock || warn "BW unlock failed — components requiring it will be skipped"
else
  log "No component in this profile needs Bitwarden — skipping unlock."
fi

# Run all components in topo order ───────────────────────────────────────────
driver_run_all
driver_summary
