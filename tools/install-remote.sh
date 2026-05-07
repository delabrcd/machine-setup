#!/usr/bin/env bash
# Bootstrap a remote Linux/WSL machine over SSH, including any per-host overlay.
#
# Usage:  tools/install-remote.sh <ssh-host> <profile> [bootstrap-args...]
#
# What it does:
#   1. Installs git on the remote if missing (apt/dnf/pacman)
#   2. Clones the public machine-setup repo to ~/.local/share/machine-setup
#   3. Streams your *local checkout's* local/ overlay (tar-piped over ssh)
#      into the remote's local/ — so private profiles/identities follow you
#      to any box without ever hitting the public repo
#   4. Runs bootstrap.sh on the remote with MACHINE_SETUP_PROFILE pre-set
#      (interactive — ssh -t for password prompts and key-registration pauses)
#
# The remote needs:
#   - ssh access (key or otherwise) — `ssh <host> echo ok` should already work
#   - sudo for the package install step (only if git isn't present)
#   - your Bitwarden master password if the profile uses BW

set -euo pipefail

HOST="${1:?usage: $0 <ssh-host> <profile> [bootstrap-args...]}"
PROFILE="${2:?usage: $0 <ssh-host> <profile> [bootstrap-args...]}"
shift 2

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_DEST_LITERAL='$HOME/.local/share/machine-setup'   # expanded on the remote
REPO_URL="${MACHINE_SETUP_REPO:-https://github.com/delabrcd/machine-setup.git}"

# Sanity: make sure the local profile actually exists. Catches typos before
# we go through the whole remote dance.
if ! python3 "$REPO_ROOT/lib/config.py" list-profiles \
     | python3 -c "import sys,json; ns=[json.loads(l)['name'] for l in sys.stdin if l.strip()]; sys.exit(0 if '$PROFILE' in ns else 1)"
then
  echo "ERROR: profile '$PROFILE' not found in profiles/ or local/profiles/." >&2
  echo "       Available:" >&2
  python3 "$REPO_ROOT/lib/config.py" list-profiles \
    | python3 -c "import sys,json
for l in sys.stdin:
    if l.strip():
        d=json.loads(l); print(f'         - {d[\"name\"]}  [{d[\"source\"]}]')"
  exit 1
fi

echo "==> [$HOST] Installing git + cloning machine-setup..."
ssh "$HOST" "REPO_URL=$REPO_URL bash -s" <<'REMOTE'
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y git
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y git
  elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm git
  else echo "ERROR: no apt/dnf/pacman; install git manually first." >&2; exit 1
  fi
fi

DEST="$HOME/.local/share/machine-setup"
mkdir -p "$(dirname "$DEST")"
if [ -d "$DEST/.git" ]; then
  echo "    Updating $DEST"
  # Force origin to the public HTTPS URL — handles older checkouts whose
  # origin was the (now archived) private SSH URL and would fail to fetch
  # without an SSH key loaded into agent.
  git -C "$DEST" remote set-url origin "$REPO_URL"
  git -C "$DEST" fetch origin
  git -C "$DEST" reset --hard origin/HEAD
else
  echo "    Cloning $REPO_URL -> $DEST"
  git clone "$REPO_URL" "$DEST"
fi
mkdir -p "$DEST/local/identities" "$DEST/local/profiles" "$DEST/local/components"
REMOTE

echo "==> [$HOST] Copying local/ overlay..."
# Stream the contents of local/ into the remote (skipping the public README and
# .gitkeep). Anything already on the remote in local/ that isn't in our local/
# is preserved — tar -x doesn't delete files.
if [ -d "$REPO_ROOT/local" ]; then
  tar -C "$REPO_ROOT" -cf - \
      --exclude='local/README.md' \
      --exclude='local/.gitkeep' \
      local | \
    ssh "$HOST" "tar -xf - -C $REMOTE_DEST_LITERAL && echo '    overlay applied'"
else
  echo "    (no local/ on this machine — skipping overlay sync)"
fi

echo "==> [$HOST] Running bootstrap with profile=$PROFILE"
# -t allocates a TTY so the BW master-password prompt + the SSH key-registration
# "press ENTER" pause both work. Pass any extra bootstrap args through.
exec ssh -t "$HOST" "MACHINE_SETUP_PROFILE=$PROFILE bash $REMOTE_DEST_LITERAL/bootstrap.sh $*"
