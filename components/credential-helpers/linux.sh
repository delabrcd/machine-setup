#!/usr/bin/env bash
# Per-identity HTTPS credential helpers. Iterates IDENT_APPLIES_TO_JSON and
# configures git's `credential.https://<host>.helper` for each applies_to entry
# according to its credential_helper field.
#
# Supported schemes:
#   gcm        - Git Credential Manager. WSL bridges to Windows GCM (so you
#                login once on Windows). Native Linux installs GCM to
#                ~/.local/bin and uses libsecret if available else cache.
#   bitwarden  - reads username/password from a BW item the identity declares
#                (bw_credential_item, bw_username_field, bw_password_field).
#                Installs ~/.local/bin/git-credential-bitwarden once.
#   ssh        - no HTTPS helper; SSH-only (we still clear stale rules).
#   none       - same as ssh: ensure no helper is configured for this host.

ensure_path

_install_gcm_linux() {
  command -v git-credential-manager >/dev/null 2>&1 && return 0
  local arch
  case "$(uname -m)" in
    x86_64)  arch="x64"   ;;
    aarch64) arch="arm64" ;;
    *)       warn "GCM: unsupported arch $(uname -m)"; return 1 ;;
  esac
  log "Installing Git Credential Manager (Linux $arch)..."
  local version
  version=$(curl -fsSL "https://api.github.com/repos/git-ecosystem/git-credential-manager/releases/latest" \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null)
  [ -n "$version" ] || { warn "GCM: could not determine latest version"; return 1; }

  local tarball="gcm-linux-${arch}-${version}.tar.gz"
  local url="https://github.com/git-ecosystem/git-credential-manager/releases/download/v${version}/${tarball}"
  local tmp; tmp=$(mktemp -d); trap "rm -rf $tmp" RETURN
  curl -fsSL "$url" -o "$tmp/gcm.tar.gz" \
    || { warn "GCM: download failed"; return 1; }
  tar -xzf "$tmp/gcm.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/git-credential-manager" "$HOME/.local/bin/git-credential-manager"
  log "GCM installed: $($HOME/.local/bin/git-credential-manager --version 2>/dev/null | head -n1)"
}

_install_bw_helper() {
  cat > "$HOME/.local/bin/git-credential-bitwarden" <<'EOF'
#!/usr/bin/env bash
# git credential helper backed by Bitwarden. Per-host config picks the BW
# item + field names. Reads:
#   credential.<scope>.bwItem
#   credential.<scope>.bwUsernameField
#   credential.<scope>.bwPasswordField
case "$1" in
  get)
    [ -z "${BW_SESSION:-}" ] && exit 1
    # Re-shell git to read host-scoped config. The protocol passes
    # `protocol=https\nhost=...\n\n` on stdin; we use it to scope the lookup.
    proto=""; host=""
    while IFS='=' read -r k v; do
      case "$k" in protocol) proto="$v" ;; host) host="$v" ;; esac
    done
    scope="${proto}://${host}"
    item=$(git config --get "credential.${scope}.bwItem")
    user_field=$(git config --get "credential.${scope}.bwUsernameField" || echo username)
    pass_field=$(git config --get "credential.${scope}.bwPasswordField" || echo password)
    [ -z "$item" ] && exit 1
    payload=$(bw get item "$item" 2>/dev/null) || exit 1
    echo "username=$(printf '%s' "$payload" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(next((f['value'] for f in d.get('fields', []) if f.get('name') == '$user_field'), ''))
")"
    echo "password=$(printf '%s' "$payload" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(next((f['value'] for f in d.get('fields', []) if f.get('name') == '$pass_field'), ''))
")"
    ;;
  store|erase) ;;
esac
EOF
  chmod +x "$HOME/.local/bin/git-credential-bitwarden"
}

_configure_gcm() {
  local host="$1" username="$2"
  local windows_gcm="/mnt/c/Program Files/Git/mingw64/bin/git-credential-manager.exe"
  git config --global --unset-all "credential.https://${host}.helper" 2>/dev/null || true
  [ -n "$username" ] && git config --global "credential.https://${host}.username" "$username"

  if is_wsl && [ -x "$windows_gcm" ]; then
    git config --global "credential.https://${host}.helper" "${windows_gcm// /\\ }"
    log "  $host: GCM (bridged to Windows)"
    return 0
  fi
  _install_gcm_linux \
    && git config --global "credential.https://${host}.helper" "$(command -v git-credential-manager)" \
    || { git config --global "credential.https://${host}.helper" '!gh auth git-credential'
         warn "  $host: GCM unavailable — falling back to gh CLI helper (run 'gh auth login' once)"
         return 0; }

  if [ -z "$(git config --global credential.credentialStore || true)" ]; then
    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}${XDG_RUNTIME_DIR:-}" ] \
       && command -v secret-tool >/dev/null 2>&1; then
      git config --global credential.credentialStore secretservice
    else
      git config --global credential.credentialStore cache
    fi
  fi
  log "  $host: GCM ($(git config --global credential.credentialStore))"
}

_configure_bw() {
  local host="$1" item="$2" user_field="$3" pass_field="$4"
  [ -f "$HOME/.local/bin/git-credential-bitwarden" ] || _install_bw_helper
  git config --global --unset-all "credential.https://${host}.helper" 2>/dev/null || true
  git config --global "credential.https://${host}.helper" bitwarden
  git config --global "credential.https://${host}.bwItem" "$item"
  git config --global "credential.https://${host}.bwUsernameField" "${user_field:-username}"
  git config --global "credential.https://${host}.bwPasswordField" "${pass_field:-password}"
  log "  $host: Bitwarden helper ($item)"
}

_clear_helper() {
  local host="$1"
  git config --global --unset-all "credential.https://${host}.helper" 2>/dev/null || true
  log "  $host: no helper (SSH-only)"
}

# Iterate applies_to entries and dispatch on credential_helper
[ -n "${IDENT_APPLIES_TO_JSON:-}" ] || { warn "credential-helpers ($IDENT_NAME): no applies_to"; return 0; }

while IFS=$'\t' read -r host helper item user_field pass_field; do
  [ -z "$host" ] && continue
  case "$helper" in
    gcm)       _configure_gcm "$host" "$IDENT_GIT_NAME" ;;
    bitwarden) _configure_bw  "$host" "$item" "$user_field" "$pass_field" ;;
    ssh|none|"") _clear_helper "$host" ;;
    *) warn "  $host: unknown credential_helper '$helper' — skipping" ;;
  esac
done < <(printf '%s' "$IDENT_APPLIES_TO_JSON" | python3 -c "
import sys, json
for app in json.load(sys.stdin):
    host = app.get('host','')
    helper = app.get('credential_helper','')
    item = app.get('bw_credential_item','')
    uf = app.get('bw_username_field','')
    pf = app.get('bw_password_field','')
    print(f'{host}\t{helper}\t{item}\t{uf}\t{pf}')
")
