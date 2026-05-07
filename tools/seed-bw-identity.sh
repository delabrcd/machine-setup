#!/usr/bin/env bash
# Seed (or update) a Bitwarden item named "Machine Identity: <name>" so the
# bootstrap can discover it as an identity at runtime.
#
# Usage:
#   tools/seed-bw-identity.sh from-toml <path-to-identity.toml> [--ssh-from <existing-bw-item>]
#       Read identity fields from a local/identities/<name>.toml file. SSH key
#       fields are optionally copied from an existing BW item (e.g. an old
#       "Machine SSH Key Work") and written to the new identity item alongside
#       the metadata.
#
#   tools/seed-bw-identity.sh new <name>
#       Interactively prompt for git_name + git_email + applies_to host config,
#       generate a fresh ed25519 SSH key, and create the BW item from scratch.
#
# Requirements:
#   - bw CLI installed and unlocked: export BW_SESSION="$(bw unlock --raw)"
#   - python3 (for TOML parsing + JSON building)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '2,/^$/p' "$0"; exit 1; }

[ $# -ge 1 ] || usage
mode="$1"; shift

check_bw_session 2>/dev/null || die "BW_SESSION not set / vault locked. Run: export BW_SESSION=\"\$(bw unlock --raw)\""

# Build an "items.create" payload from field name=value pairs, then upsert it.
# If an item with the target name already exists, edits in place.
_bw_upsert_identity() {
  local item_name="$1" git_name="$2" git_email="$3" ssh_basename="$4" \
        is_default="$5" applies_to_json="$6" priv_key="$7" pub_key="$8"

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
    log "Updating existing item: $item_name"
    bw get item "$existing_id" \
      | python3 - "$git_name" "$git_email" "$ssh_basename" "$is_default" "$applies_to_json" "$priv_key" "$pub_key" <<'PY' \
      | bw encode | bw edit item "$existing_id" >/dev/null
import sys, json
item = json.load(sys.stdin)
gn, ge, sb, df, atj, priv, pub = sys.argv[1:8]
desired = {
    "git_name":          gn,
    "git_email":         ge,
    "ssh_key_basename":  sb,
    "default":           df,
    "applies_to_json":   atj,
    "private_key":       priv,
    "public_key":        pub,
}
fields = item.get("fields") or []
existing_names = {f.get("name"): f for f in fields}
HIDDEN = {"private_key"}
for k, v in desired.items():
    if not v and k in ("private_key", "public_key"):
        continue
    f_type = 1 if k in HIDDEN else 0
    if k in existing_names:
        existing_names[k]["value"] = v
        existing_names[k]["type"] = f_type
    else:
        fields.append({"name": k, "value": v, "type": f_type})
item["fields"] = fields
print(json.dumps(item))
PY
  else
    log "Creating new item: $item_name"
    bw get template item \
      | python3 - "$item_name" "$git_name" "$git_email" "$ssh_basename" "$is_default" "$applies_to_json" "$priv_key" "$pub_key" <<'PY' \
      | bw encode | bw create item >/dev/null
import sys, json
item = json.load(sys.stdin)
name, gn, ge, sb, df, atj, priv, pub = sys.argv[1:9]
item.update({
    "type": 2,
    "name": name,
    "secureNote": {"type": 0},
    "fields": [
        {"name": "git_name",         "value": gn,   "type": 0},
        {"name": "git_email",        "value": ge,   "type": 0},
        {"name": "ssh_key_basename", "value": sb,   "type": 0},
        {"name": "default",          "value": df,   "type": 0},
        {"name": "applies_to_json",  "value": atj,  "type": 0},
        {"name": "public_key",       "value": pub,  "type": 0},
        {"name": "private_key",      "value": priv, "type": 1},
    ],
})
print(json.dumps(item))
PY
  fi
  log "Done: $item_name"
}

# Read an SSH key pair (private + public) from an existing BW item by name.
# Echoes "PRIV<NUL>PUB" — reader splits on the NUL byte.
_read_ssh_from_bw() {
  local from_item="$1"
  bw_item_json_exact "$from_item" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
priv = next((f['value'] for f in (d.get('fields') or []) if f.get('name') == 'private_key'), '')
pub  = next((f['value'] for f in (d.get('fields') or []) if f.get('name') == 'public_key'),  '')
sys.stdout.write(priv + '\x00' + pub)
"
}

cmd_from_toml() {
  local toml="${1:?usage: from-toml <path> [--ssh-from <bw-item>]}"
  local ssh_from=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --ssh-from) ssh_from="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -f "$toml" ] || die "no such file: $toml"

  # Parse the TOML once and emit shell-evaluable assignments.
  eval "$(python3 - "$toml" <<'PY'
import sys, json, tomllib, shlex
with open(sys.argv[1], 'rb') as f:
    d = tomllib.load(f)
name      = d.get('name')   or sys.argv[1].split('/')[-1].removesuffix('.toml')
git_name  = d.get('git_name', '')
git_email = d.get('git_email', '')
sb        = d.get('ssh_key_basename') or f"id_ed25519_{name}"
default   = 'true' if d.get('default') else 'false'
applies_to = json.dumps(d.get('applies_to', []))
print(f"NAME={shlex.quote(name)}")
print(f"GIT_NAME={shlex.quote(git_name)}")
print(f"GIT_EMAIL={shlex.quote(git_email)}")
print(f"SSH_BASENAME={shlex.quote(sb)}")
print(f"IS_DEFAULT={shlex.quote(default)}")
print(f"APPLIES_TO={shlex.quote(applies_to)}")
PY
)"

  local priv="" pub=""
  if [ -n "$ssh_from" ]; then
    log "Pulling SSH key from existing BW item: $ssh_from"
    local both
    both=$(_read_ssh_from_bw "$ssh_from")
    priv="${both%%$'\x00'*}"
    pub="${both#*$'\x00'}"
    [ -n "$priv" ] || warn "  no private_key field on '$ssh_from' — identity will have no SSH key"
  else
    warn "No --ssh-from given. Identity item will be created without SSH key fields."
    warn "Either re-run with --ssh-from <item>, or 'ssh-key' component will generate one on first bootstrap."
  fi

  _bw_upsert_identity "Machine Identity: $NAME" "$GIT_NAME" "$GIT_EMAIL" \
                      "$SSH_BASENAME" "$IS_DEFAULT" "$APPLIES_TO" "$priv" "$pub"
}

cmd_new() {
  local name="${1:?usage: new <identity-name>}"
  [ -r /dev/tty ] || die "no /dev/tty for interactive prompts"

  printf 'git user.name : ' > /dev/tty;  read -r git_name  < /dev/tty
  printf 'git user.email: ' > /dev/tty;  read -r git_email < /dev/tty
  printf 'default identity for global git config? (y/N): ' > /dev/tty
  read -r yn < /dev/tty
  local is_default="false"
  [ "$yn" = "y" ] || [ "$yn" = "Y" ] && is_default="true"

  local applies_to_json='[]'
  printf 'Add a host (e.g. github.com) for this identity? (leave blank to skip): ' > /dev/tty
  read -r host < /dev/tty
  if [ -n "$host" ]; then
    printf 'credential_helper for %s [ssh|gcm|bitwarden|none] (default: ssh): ' "$host" > /dev/tty
    read -r helper < /dev/tty
    helper="${helper:-ssh}"
    applies_to_json=$(python3 -c "
import json, sys
host, helper = sys.argv[1], sys.argv[2]
patterns = [f'git@{host}:*/*', f'https://{host}/*/*']
print(json.dumps([{'host': host, 'git_url_patterns': patterns, 'credential_helper': helper}]))
" "$host" "$helper")
  fi

  log "Generating ed25519 SSH key..."
  local tmp_dir tmp_key
  tmp_dir=$(mktemp -d)
  tmp_key="$tmp_dir/id_ed25519"
  ssh-keygen -t ed25519 -C "$git_email" -f "$tmp_key" -N "" </dev/null >/dev/null
  local priv pub
  priv=$(cat "$tmp_key")
  pub=$(cat "${tmp_key}.pub")
  rm -rf "$tmp_dir"

  _bw_upsert_identity "Machine Identity: $name" "$git_name" "$git_email" \
                      "id_ed25519_$name" "$is_default" "$applies_to_json" "$priv" "$pub"

  echo "" > /dev/tty
  echo "Public key (register on the relevant service):" > /dev/tty
  echo "" > /dev/tty
  echo "$pub" > /dev/tty
  echo "" > /dev/tty
  if [ -r /dev/tty ]; then
    printf "Press ENTER once the key is registered (or Ctrl+C to abort): " > /dev/tty
    read -r _ < /dev/tty || true
  fi
}

case "$mode" in
  from-toml) cmd_from_toml "$@" ;;
  new)       cmd_new "$@" ;;
  *) usage ;;
esac
