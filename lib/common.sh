#!/usr/bin/env bash
# Shared logging, OS detection, and small utilities.
# No identity/personal/work knowledge — that all lives in identities/*.toml now.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} ${BOLD}$*${NC}"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}--- $* ---${NC}"; }

is_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }

ensure_path() {
  mkdir -p "$HOME/.local/bin"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
  esac
}

# WSL: ensure Windows .exe interop works (needed for the GCM bridge).
# Same logic as before — moved here so anyone can call it.
ensure_wsl_interop() {
  is_wsl || return 0
  [ -f /proc/sys/fs/binfmt_misc/WSLInterop ] && return 0

  log "Restoring WSLInterop binfmt registration..."

  if [ ! -f /usr/lib/binfmt.d/WSLInterop.conf ]; then
    echo ':WSLInterop:M::MZ::/init:PF' | sudo tee /usr/lib/binfmt.d/WSLInterop.conf >/dev/null
  fi

  sudo mkdir -p /etc/systemd/system/systemd-binfmt.service.d
  if [ ! -f /etc/systemd/system/systemd-binfmt.service.d/override.conf ]; then
    sudo tee /etc/systemd/system/systemd-binfmt.service.d/override.conf >/dev/null <<'EOF'
[Unit]
ConditionVirtualization=
EOF
    sudo systemctl daemon-reload
  fi

  sudo systemctl restart systemd-binfmt 2>/dev/null || true
  sudo systemctl enable  systemd-binfmt 2>/dev/null || true

  if [ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
    echo ':WSLInterop:M::MZ::/init:PF' | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null || true
  fi

  if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then log "WSLInterop registered."
  else                                                warn "WSLInterop registration failed — .exe interop won't work. Try: wsl --shutdown && wsl"
  fi
}

# Bitwarden helpers — only call if your component opts into BW.
check_bw_session() {
  command -v bw >/dev/null 2>&1 || { warn "'bw' not found — Bitwarden steps will be skipped"; return 1; }
  [ -n "${BW_SESSION:-}" ] || { warn "BW_SESSION not set — run: export BW_SESSION=\"\$(bw unlock --raw)\""; return 1; }
  bw status 2>/dev/null | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s.get('status') == 'unlocked', 'vault not unlocked'
" 2>/dev/null || { warn "Bitwarden vault is locked"; return 1; }
}

# Look up a BW item by *exact* name (bw list filtering — `bw get item` matches
# substrings, so 'Machine SSH Key' also returns 'Machine SSH Key Work'). Prefers
# items that already have a private_key field, since that's the canonical SSH
# key item shape.
bw_item_json_exact() {
  local name="$1"
  bw list items --search "$name" 2>/dev/null \
    | python3 -c "
import sys, json
items = json.load(sys.stdin)
exact = [i for i in items if i.get('name') == sys.argv[1]]
if not exact:
    sys.exit(1)
for item in exact:
    if any(f.get('name') == 'private_key' for f in item.get('fields', [])):
        print(json.dumps(item)); sys.exit(0)
print(json.dumps(exact[0]))
" "$name"
}

# Read a named field from a BW item JSON blob on stdin.
bw_field_from_json() {
  local field="$1"
  python3 -c "
import sys, json
d = json.load(sys.stdin)
print(next((f['value'] for f in d.get('fields', []) if f.get('name') == '$field'), ''))
"
}
