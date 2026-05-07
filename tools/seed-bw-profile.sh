#!/usr/bin/env bash
# Push a profile TOML to Bitwarden as "Machine Profile: <name>" so any other
# machine can pick it up via the bootstrap's BW profile discovery.
#
# Usage:
#   tools/seed-bw-profile.sh push <path/to/profile.toml> [--name <override>]
#       Read the file, create or update a BW Secure Note named
#       "Machine Profile: <name>" with the file content as the note body.
#       <name> defaults to the file's basename without the .toml extension.
#
#   tools/seed-bw-profile.sh list
#       List all "Machine Profile: *" items currently in your vault.
#
#   tools/seed-bw-profile.sh pull <name> [> path]
#       Dump a BW profile's TOML body to stdout (handy for editing locally
#       and pushing back).
#
# Requirements:
#   - bw CLI installed and unlocked: export BW_SESSION="$(bw unlock --raw)"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '2,/^$/p' "$0"; exit 1; }
[ $# -ge 1 ] || usage
mode="$1"; shift

check_bw_session 2>/dev/null \
  || die "BW_SESSION not set / vault locked. Run: export BW_SESSION=\"\$(bw unlock --raw)\""

cmd_push() {
  local path="${1:?usage: push <file> [--name <override>]}"
  shift
  local name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -f "$path" ] || die "no such file: $path"
  if [ -z "$name" ]; then
    name=$(basename "$path"); name="${name%.toml}"
  fi

  local item_name="Machine Profile: $name"
  local body; body=$(cat "$path")

  local existing_id
  existing_id=$(bw list items --search "$item_name" 2>/dev/null \
    | python3 -c "
import sys, json
items = json.load(sys.stdin)
for i in items:
    if i.get('name') == '$item_name':
        print(i['id']); break
")

  if [ -n "$existing_id" ]; then
    log "Updating $item_name (id $existing_id)"
    bw get item "$existing_id" \
      | python3 -c "
import sys, json
item = json.load(sys.stdin)
item['notes'] = sys.argv[1]
print(json.dumps(item))
" "$body" \
      | bw encode | bw edit item "$existing_id" >/dev/null
  else
    log "Creating $item_name"
    bw get template item \
      | python3 -c "
import sys, json
item = json.load(sys.stdin)
item.update({
  'type': 2,
  'name': '$item_name',
  'secureNote': {'type': 0},
  'notes': sys.argv[1],
})
print(json.dumps(item))
" "$body" \
      | bw encode | bw create item >/dev/null
  fi
  log "Done: $item_name"
}

cmd_list() {
  bw list items 2>/dev/null \
    | python3 -c "
import sys, json
prefix = 'Machine Profile: '
for i in json.load(sys.stdin):
    name = i.get('name','')
    if name.startswith(prefix):
        body = (i.get('notes') or '').strip()
        first_line = body.split('\n', 1)[0] if body else '(empty)'
        print(f'{name[len(prefix):]:<25}  {first_line[:60]}')
"
}

cmd_pull() {
  local name="${1:?usage: pull <profile-name>}"
  local item_name="Machine Profile: $name"
  bw list items --search "$item_name" 2>/dev/null \
    | python3 -c "
import sys, json
prefix = 'Machine Profile: '
for i in json.load(sys.stdin):
    if i.get('name') == sys.argv[1]:
        sys.stdout.write((i.get('notes') or '').rstrip() + '\n')
        sys.exit(0)
sys.exit(2)
" "$item_name" \
    || die "profile '$name' not found in BW"
}

case "$mode" in
  push) cmd_push "$@" ;;
  list) cmd_list "$@" ;;
  pull) cmd_pull "$@" ;;
  *)    usage ;;
esac
