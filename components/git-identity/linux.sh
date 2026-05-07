#!/usr/bin/env bash
# Apply git config for the identity in IDENT_* env vars.
#
# Default identity (IDENT_DEFAULT=1):
#   sets global user.name / user.email / user.signingKey directly
#
# Non-default identity:
#   writes ~/.gitconfig-<name> and registers includeIf rules — one per
#   git_url_pattern in IDENT_APPLIES_TO_JSON. This means git uses this
#   identity automatically when working in a repo with a matching remote.
#
# Pattern note: git's hasconfig pattern engine treats `**` as `*` (single
# component, no slashes) unless adjacent to `/`. So `git@bitbucket.org:**`
# does NOT match `git@bitbucket.org:workspace/repo`. Use `*/*`.

[ -n "${IDENT_NAME:-}" ] || { warn "git-identity: IDENT_NAME not set"; return 1; }
[ -n "${IDENT_GIT_NAME:-}" ] || { warn "git-identity ($IDENT_NAME): no git_name set in identity file"; return 1; }
[ -n "${IDENT_GIT_EMAIL:-}" ] || { warn "git-identity ($IDENT_NAME): no git_email set in identity file"; return 1; }

_pub="$HOME/.ssh/${IDENT_SSH_KEY_BASENAME}.pub"

if [ "${IDENT_DEFAULT:-0}" = "1" ]; then
  log "Default identity: $IDENT_NAME ($IDENT_GIT_EMAIL)"
  git config --global user.name  "$IDENT_GIT_NAME"
  git config --global user.email "$IDENT_GIT_EMAIL"
  if [ -f "$_pub" ]; then
    git config --global user.signingKey "$_pub"
  fi
else
  log "Non-default identity: $IDENT_NAME — writing ~/.gitconfig-$IDENT_NAME"
  _conf="$HOME/.gitconfig-$IDENT_NAME"
  {
    echo "[user]"
    echo "    name = $IDENT_GIT_NAME"
    echo "    email = $IDENT_GIT_EMAIL"
    [ -f "$_pub" ] && echo "    signingKey = $_pub"
  } > "$_conf"

  # Clear prior includeIf rules for this identity, then set fresh ones.
  git config --global --get-regexp "^includeIf\." | awk '{print $1}' \
    | while read -r key; do
        # Only remove rules that point to OUR config file
        if [ "$(git config --global "$key" 2>/dev/null)" = "$_conf" ]; then
          git config --global --unset-all "$key" 2>/dev/null || true
        fi
      done

  # Register one rule per git_url_pattern listed in this identity's applies_to
  printf '%s' "$IDENT_APPLIES_TO_JSON" | python3 -c "
import sys, json
for app in json.load(sys.stdin):
    for pat in app.get('git_url_patterns', []):
        print(pat)
" | while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        git config --global "includeIf.hasconfig:remote.*.url:${pat}.path" "$_conf"
        log "  includeIf: $pat → ~/.gitconfig-$IDENT_NAME"
      done
fi

# Add this identity's signing key to allowed_signers (for `git log --show-signature`)
if [ -f "$_pub" ]; then
  _signers="$HOME/.ssh/allowed_signers"
  _key=$(cat "$_pub")
  if ! grep -qF "$_key" "$_signers" 2>/dev/null; then
    echo "$IDENT_GIT_EMAIL $_key" >> "$_signers"
    log "Added $IDENT_NAME to allowed_signers"
  fi
fi
