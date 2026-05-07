#!/usr/bin/env bash
# One-shot migration: push everything currently in local/ to Bitwarden.
#
#   - local/profiles/<name>.toml    -> "Machine Profile: <name>"  (Secure Note,
#                                       body = file content)
#   - local/identities/<name>.toml  -> "Machine Identity: <name>" (Secure Note,
#                                       fields populated from TOML; SSH key
#                                       fields copied from the existing BW
#                                       item named in the TOML's `bw_ssh_item`)
#
# Idempotent: re-running updates fields in place. Existing BW items are
# updated, never duplicated.
#
# Usage:
#   export BW_SESSION="$(bw unlock --raw)"
#   tools/migrate-to-bw.sh                    # push all of local/
#   tools/migrate-to-bw.sh --dry-run          # show what would be pushed
#   tools/migrate-to-bw.sh --skip-profiles    # only identities
#   tools/migrate-to-bw.sh --skip-identities  # only profiles
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=0
DO_PROFILES=1
DO_IDENTITIES=1
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n)       DRY_RUN=1 ;;
    --skip-profiles)    DO_PROFILES=0 ;;
    --skip-identities)  DO_IDENTITIES=0 ;;
    --help|-h)          sed -n '2,/^$/p' "$0"; exit 0 ;;
    *) die "unknown arg: $arg" ;;
  esac
done

check_bw_session 2>/dev/null \
  || die "BW_SESSION not set / vault locked. Run: export BW_SESSION=\"\$(bw unlock --raw)\""

_run() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

# ── Profiles ─────────────────────────────────────────────────────────────────
if [ "$DO_PROFILES" = "1" ]; then
  step "Profiles"
  shopt -s nullglob
  for f in "$SCRIPT_DIR"/local/profiles/*.toml; do
    name=$(basename "$f" .toml)
    log "  $f -> Machine Profile: $name"
    _run "$SCRIPT_DIR/tools/seed-bw-profile.sh" push "$f"
  done
  shopt -u nullglob
fi

# ── Identities ──────────────────────────────────────────────────────────────
if [ "$DO_IDENTITIES" = "1" ]; then
  step "Identities"
  shopt -s nullglob
  for f in "$SCRIPT_DIR"/local/identities/*.toml; do
    name=$(basename "$f" .toml)

    # Auto-detect the existing SSH-key BW item from the TOML's bw_ssh_item field.
    ssh_from=$(python3 -c "
import sys, tomllib
with open(sys.argv[1], 'rb') as fp:
    d = tomllib.load(fp)
print(d.get('bw_ssh_item', '') or '')
" "$f")

    if [ -n "$ssh_from" ]; then
      # The TOML bw_ssh_item might already BE the destination "Machine Identity: <name>"
      # (e.g. if you re-ran migration after the first push). Detect that and skip
      # --ssh-from to avoid the no-op SSH copy from the same item.
      target_name="Machine Identity: $name"
      if [ "$ssh_from" = "$target_name" ]; then
        log "  $f -> $target_name  (SSH already in place)"
        _run "$SCRIPT_DIR/tools/seed-bw-identity.sh" from-toml "$f"
      else
        log "  $f -> $target_name  (SSH from '$ssh_from')"
        _run "$SCRIPT_DIR/tools/seed-bw-identity.sh" from-toml "$f" --ssh-from "$ssh_from"
      fi
    else
      warn "  $f has no bw_ssh_item field — pushing without SSH key"
      _run "$SCRIPT_DIR/tools/seed-bw-identity.sh" from-toml "$f"
    fi
  done
  shopt -u nullglob
fi

if [ "$DRY_RUN" = "1" ]; then
  log "Dry run complete. Re-run without --dry-run to apply."
else
  log "Migration complete. Verify with: bw list items | jq '.[] | select(.name | startswith(\"Machine \")) | .name'"
  log "Once verified, you can delete local/profiles/* and local/identities/* — the bootstrap will discover them from BW."
fi
