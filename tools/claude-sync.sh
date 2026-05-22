#!/usr/bin/env bash
# claude-sync — pack/unpack ~/.claude/ as a Bitwarden attachment.
#
# Sync model: a single BW item ("Claude Code Config Bundle") holds one
# attachment, claude-config.tar.gz, containing a whitelisted subset of
# ~/.claude/. Run `claude-sync push` on the machine you've been editing
# from, then `claude-sync pull` on the others.
#
# Volatile state (sessions, history, caches, per-project state) is excluded
# so the bundle stays small and machine-portable.
#
# Designed to be runnable two ways:
#   1. Directly from the repo:  bash tools/claude-sync.sh push
#   2. Via the shell wrapper:   claude-sync push   (installed by the
#      claude-sync-shell component, which also auto-unlocks BW).

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
BUNDLE_ITEM="${CLAUDE_SYNC_BW_ITEM:-Claude Code Config Bundle}"
ATTACHMENT_NAME="claude-config.tar.gz"

# Paths under $CLAUDE_DIR that get packed into the bundle. Everything else
# is excluded (sessions, caches, history, per-project state).
INCLUDE_PATHS=(
  "settings.json"
  "CLAUDE.md"
  "agents"
  "commands"
  "skills"
  "hooks"
  "plugins/installed_plugins.json"
  "plugins/known_marketplaces.json"
)

# Per-project auto-memory dirs: ~/.claude/projects/<slug>/memory/
# These are path-keyed by project location, so they only line up across
# machines if the same project lives at the same absolute path on each.
PROJECT_MEMORY_GLOB="projects/*/memory"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} ${BOLD}$*${NC}"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

require_bw() {
  command -v bw >/dev/null 2>&1 || die "'bw' (Bitwarden CLI) not on PATH"
  [ -n "${BW_SESSION:-}" ] || die "BW_SESSION not set — run: export BW_SESSION=\"\$(bw unlock --raw)\" (or use the 'claude-sync' shell function which unlocks for you)"
  bw status 2>/dev/null | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s.get('status') == 'unlocked'
" 2>/dev/null || die "Bitwarden vault is locked"
}

# Print the BW item id for the bundle item, or empty string if not found.
bundle_item_id() {
  bw list items --search "$BUNDLE_ITEM" 2>/dev/null \
    | python3 -c '
import sys, json
items = json.load(sys.stdin)
m = next((i for i in items if i.get("name") == sys.argv[1]), None)
print(m["id"] if m else "")
' "$BUNDLE_ITEM"
}

# Print attachment id on the given item that matches $ATTACHMENT_NAME, or empty.
bundle_attachment_id() {
  local item_id="$1"
  bw get item "$item_id" 2>/dev/null \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
a = next((a for a in (d.get("attachments") or []) if a.get("fileName") == sys.argv[1]), None)
print(a["id"] if a else "")
' "$ATTACHMENT_NAME"
}

# Ensure the bundle item exists. Creates it (as a Secure Note) if missing.
# Prints the item id on stdout.
ensure_bundle_item() {
  local id; id=$(bundle_item_id)
  if [ -n "$id" ]; then
    printf '%s' "$id"; return
  fi
  log "Creating BW item: $BUNDLE_ITEM" >&2
  local payload
  payload=$(python3 -c '
import sys, json
print(json.dumps({
    "type": 2,
    "name": sys.argv[1],
    "notes": "Created by claude-sync. Holds claude-config.tar.gz as an attachment.",
    "secureNote": {"type": 0},
}))
' "$BUNDLE_ITEM")
  printf '%s' "$payload" | bw encode | bw create item 2>/dev/null \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])'
}

# Build the list of paths (relative to $CLAUDE_DIR) that currently exist
# and should be packed. Writes one path per line.
existing_include_paths() {
  cd "$CLAUDE_DIR"
  local p
  for p in "${INCLUDE_PATHS[@]}"; do
    [ -e "$p" ] && printf '%s\n' "$p"
  done
  # Per-project memory dirs
  # shellcheck disable=SC2086
  find . -mindepth 3 -maxdepth 3 -type d -path "./$PROJECT_MEMORY_GLOB" 2>/dev/null \
    | sed 's|^\./||'
}

cmd_push() {
  require_bw
  [ -d "$CLAUDE_DIR" ] || die "$CLAUDE_DIR does not exist"

  local includes_file; includes_file=$(mktemp)
  existing_include_paths > "$includes_file"
  if [ ! -s "$includes_file" ]; then
    rm -f "$includes_file"
    die "No syncable paths found under $CLAUDE_DIR"
  fi
  local count; count=$(wc -l < "$includes_file")
  log "Packing $count paths from $CLAUDE_DIR ..."
  sed 's|^|  |' "$includes_file" >&2

  local tmpdir; tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir' '$includes_file'" EXIT
  local archive="$tmpdir/$ATTACHMENT_NAME"
  tar -czf "$archive" -C "$CLAUDE_DIR" -T "$includes_file"

  local item_id; item_id=$(ensure_bundle_item)
  [ -n "$item_id" ] || die "Failed to resolve/create bundle item"

  local att_id; att_id=$(bundle_attachment_id "$item_id")
  if [ -n "$att_id" ]; then
    log "Replacing previous attachment ($att_id) ..."
    bw delete attachment "$att_id" --itemid "$item_id" >/dev/null \
      || die "Failed to delete previous attachment"
  fi
  log "Uploading $(du -h "$archive" | cut -f1) ..."
  bw create attachment --file "$archive" --itemid "$item_id" >/dev/null \
    || die "Attachment upload failed"

  # Stamp the item's notes field with push metadata for `status` to read.
  local meta
  meta=$(python3 -c '
import sys, json, datetime
print(json.dumps({
    "pushed_at": datetime.datetime.now().astimezone().isoformat(),
    "host": sys.argv[1],
    "paths": int(sys.argv[2]),
    "size_bytes": int(sys.argv[3]),
}, indent=2))
' "$(hostname)" "$count" "$(stat -c%s "$archive" 2>/dev/null || stat -f%z "$archive")")
  bw get item "$item_id" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['notes'] = sys.argv[1]
print(json.dumps(d))
" "$meta" | bw encode | bw edit item "$item_id" >/dev/null || true

  log "Push complete."
}

cmd_pull() {
  require_bw
  local item_id; item_id=$(bundle_item_id)
  if [ -z "$item_id" ]; then
    warn "No '$BUNDLE_ITEM' item in vault — nothing to pull. (Run 'claude-sync push' from a configured machine first.)"
    return 0
  fi
  local att_id; att_id=$(bundle_attachment_id "$item_id")
  if [ -z "$att_id" ]; then
    warn "Bundle item exists but has no attachment — nothing to pull."
    return 0
  fi

  local tmpdir; tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" EXIT
  local archive="$tmpdir/$ATTACHMENT_NAME"
  log "Downloading attachment ..."
  bw get attachment "$att_id" --itemid "$item_id" --output "$archive" >/dev/null \
    || die "Attachment download failed"

  mkdir -p "$CLAUDE_DIR"
  log "Extracting into $CLAUDE_DIR ..."
  tar -xzf "$archive" -C "$CLAUDE_DIR"
  log "Pull complete."
}

cmd_status() {
  require_bw
  local item_id; item_id=$(bundle_item_id)
  if [ -z "$item_id" ]; then
    echo "No '$BUNDLE_ITEM' item in vault."
    return 0
  fi
  bw get item "$item_id" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("Item:    ", d.get("name"))
print("Revision:", d.get("revisionDate"))
print("Notes:")
notes = d.get("notes") or "(empty)"
for line in notes.splitlines():
    print("  " + line)
print("Attachments:")
for a in (d.get("attachments") or []):
    size = a.get("size") or "?"
    print(f"  {a.get(\"fileName\")} ({size} bytes)  id={a.get(\"id\")}")
'

  echo
  echo "Local include candidates:"
  existing_include_paths | sed 's|^|  |'
}

cmd_list() {
  echo "$CLAUDE_DIR include paths:"
  existing_include_paths | sed 's|^|  |' || true
}

usage() {
  cat <<USAGE
Usage: claude-sync <command>

Commands:
  pull     Download Claude config bundle from Bitwarden and extract to ~/.claude/
  push     Pack ~/.claude/ (whitelisted paths) and upload to Bitwarden
  status   Show bundle metadata stored on the BW item
  list     Print the local paths that would be packed on push

Environment:
  BW_SESSION              Required. Bitwarden session token.
  CLAUDE_DIR              Override the Claude config dir (default ~/.claude).
  CLAUDE_SYNC_BW_ITEM     Override BW item name (default "Claude Code Config Bundle").

Bundle contents (relative to \$CLAUDE_DIR):
$(printf '  %s\n' "${INCLUDE_PATHS[@]}")
  projects/*/memory       (per-project auto-memory dirs)
USAGE
}

case "${1:-}" in
  pull)    shift; cmd_pull   "$@" ;;
  push)    shift; cmd_push   "$@" ;;
  status)  shift; cmd_status "$@" ;;
  list)    shift; cmd_list   "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
