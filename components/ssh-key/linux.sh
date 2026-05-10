#!/usr/bin/env bash
# Per-identity SSH key. Skipped if the identity has no bw_ssh_item.
#
# - If BW item exists: load private into agent (no disk write), drop public key.
# - If BW item doesn't exist: generate ed25519, store in BW, leave public on disk.
# - Then update ~/.ssh/config: route each `applies_to[].host` to this key's
#   public path. OpenSSH 7.2+ reads <path>.pub for the public key and asks
#   ssh-agent for the matching private key, so the private file never
#   has to exist on disk.

if [ -z "${IDENT_BW_SSH_ITEM:-}" ]; then
  log "ssh-key ($IDENT_NAME): no bw_ssh_item declared — skipping"
  return 0
fi

if ! check_bw_session 2>/dev/null; then
  warn "ssh-key ($IDENT_NAME): Bitwarden session not active — skipping"
  return 1
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

_basename="$IDENT_SSH_KEY_BASENAME"
_pub="$HOME/.ssh/${_basename}.pub"
_priv_phantom="$HOME/.ssh/${_basename}"  # never actually written; just the path ssh-config points at

# Ensure ssh-agent. Only spawn a new one when the existing socket is truly
# unreachable (ssh-add -l rc=2). rc=1 just means "agent has no identities" —
# loading into that agent (e.g. systemd's /run/user/$UID/ssh-agent.socket)
# is exactly what we want, since those keys then persist across every shell
# in the user session instead of dying with this subprocess.
ssh-add -l >/dev/null 2>&1; _agent_rc=$?
if [ -z "${SSH_AUTH_SOCK:-}" ] || [ "$_agent_rc" -eq 2 ]; then
  eval "$(ssh-agent -s)" >/dev/null
fi
unset _agent_rc

_load_from_bw() {
  log "Loading SSH key from BW: $IDENT_BW_SSH_ITEM"
  bw_item_json_exact "$IDENT_BW_SSH_ITEM" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(next(f['value'] for f in d['fields'] if f['name'] == 'private_key'), end='')
" | ssh-add - 2>/dev/null \
    && log "  Loaded $IDENT_BW_SSH_ITEM into agent" \
    || warn "  ssh-add failed for $IDENT_BW_SSH_ITEM"

  if [ ! -f "$_pub" ]; then
    bw_item_json_exact "$IDENT_BW_SSH_ITEM" \
      | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(next(f['value'] for f in d['fields'] if f['name'] == 'public_key'), end='')
" > "$_pub"
    log "  Wrote $(basename "$_pub")"
  fi
  chmod 644 "$_pub"
}

_generate_and_store() {
  log "BW item '$IDENT_BW_SSH_ITEM' not found — generating new ed25519 key..."
  local tmp_dir tmp_key
  tmp_dir=$(mktemp -d)
  tmp_key="$tmp_dir/id_ed25519"
  ssh-keygen -t ed25519 -C "$IDENT_GIT_EMAIL" -f "$tmp_key" -N "" </dev/null \
    || { warn "ssh-keygen failed"; rm -rf "$tmp_dir"; return 1; }

  log "Storing in Bitwarden as '$IDENT_BW_SSH_ITEM'..."
  local py
  py=$(mktemp --suffix=.py)
  cat > "$py" <<'PYEOF'
import sys, json
_, item_name, key_file = sys.argv
item = json.load(sys.stdin)
with open(key_file)        as f: priv = f.read()
with open(key_file+'.pub') as f: pub  = f.read()
item.update({
  'type': 2, 'name': item_name,
  'secureNote': {'type': 0},
  'fields': [
    {'name': 'private_key', 'value': priv, 'type': 1},
    {'name': 'public_key',  'value': pub,  'type': 0},
  ],
})
print(json.dumps(item))
PYEOF
  bw get template item \
    | python3 "$py" "$IDENT_BW_SSH_ITEM" "$tmp_key" \
    | bw encode \
    | bw create item >/dev/null \
    || { rm -f "$py"; rm -rf "$tmp_dir"; warn "BW store failed"; return 1; }
  rm -f "$py"

  ssh-add "$tmp_key" 2>/dev/null && log "  Loaded into agent"
  cp "${tmp_key}.pub" "$_pub"
  chmod 644 "$_pub"
  rm -rf "$tmp_dir"

  # Print register URLs from applies_to (e.g. github.com/settings/ssh/new)
  printf '%s' "$IDENT_APPLIES_TO_JSON" | python3 -c "
import sys, json
for app in json.load(sys.stdin):
    if app.get('register_url'):
        print(app.get('register_label','SSH'), '->', app['register_url'])
" | while IFS= read -r line; do
        [ -n "$line" ] && warn "ACTION REQUIRED — register $(basename "$_pub") at: $line"
      done
  echo ""
  cat "$_pub"
  echo ""
  # Pause for the user to register the new key on the relevant service —
  # except under the TUI, where /dev/tty is owned by Textual and a read
  # would deadlock. The component log shows the pubkey + URL; user can
  # register it later (subsequent components retry on next bootstrap).
  if [ "${MACHINE_SETUP_NONINTERACTIVE:-0}" != "1" ] && [ -t 0 ]; then
    read -r -p "Press ENTER once the key is added (or Ctrl-C to do later): " _ < /dev/tty || true
  else
    warn "Bootstrap is non-interactive — register the key above before re-running components that need it."
  fi
}

if bw_item_json_exact "$IDENT_BW_SSH_ITEM" >/dev/null 2>&1; then
  _load_from_bw
else
  _generate_and_store || return 1
fi

# Update ~/.ssh/config — one Host block per applies_to entry that has `host`.
# We mark each block with `# machine-setup:<identity>` so re-runs replace
# only this identity's blocks, not other identities'.
_config="$HOME/.ssh/config"
_marker_begin="# BEGIN machine-setup:$IDENT_NAME"
_marker_end="# END machine-setup:$IDENT_NAME"

_block=$(printf '%s' "$IDENT_APPLIES_TO_JSON" | python3 -c "
import sys, json, os
home = os.environ['HOME']
basename = os.environ['IDENT_SSH_KEY_BASENAME']
out = []
for app in json.load(sys.stdin):
    host = app.get('host')
    if not host:
        continue
    out.append(f'Host {host}')
    out.append(f'    IdentityFile {home}/.ssh/{basename}')
    out.append('    IdentitiesOnly yes')
    out.append('')
print('\n'.join(out).rstrip() + '\n' if out else '')
")

if [ -n "$_block" ]; then
  python3 - "$_config" "$_marker_begin" "$_marker_end" "$_block" <<'PYEOF'
import sys, os, re
config_path, begin, end, block = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
content = open(config_path).read() if os.path.exists(config_path) else ""
pattern = re.escape(begin) + r'.*?' + re.escape(end) + r'\r?\n?'
content = re.sub(pattern, '', content, flags=re.DOTALL)
content = content.rstrip('\n')
new_block = f"{begin}\n{block.rstrip()}\n{end}\n"
new = (content + '\n\n' if content else '') + new_block
with open(config_path, 'w') as f:
    f.write(new)
PYEOF
  chmod 600 "$_config"
  log "Updated ~/.ssh/config for $IDENT_NAME hosts"
fi
