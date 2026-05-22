#!/usr/bin/env bash
# Per-session helper:  claude-sync {pull|push|status}  → sync ~/.claude/
# to/from a Bitwarden attachment.
#
# Mirrors bw-unlock-shell: a tiny shell function in bashrc/zshrc ensures
# BW_SESSION is exported in the parent shell, then calls the engine
# at ~/.local/bin/claude-sync. The engine itself is just a symlink to
# tools/claude-sync.sh in this repo, so editing the script and running
# `git pull` updates the installed command in place.

ensure_path

_engine_src="$MACHINE_SETUP_DIR/tools/claude-sync.sh"
_engine_dst="$HOME/.local/bin/claude-sync"

if [ ! -x "$_engine_src" ]; then
  warn "claude-sync: engine '$_engine_src' missing or not executable"
  return 1
fi

# Symlink → engine in PATH. If a previous run left a copy or stale link, replace.
if [ -L "$_engine_dst" ] || [ -e "$_engine_dst" ]; then
  rm -f "$_engine_dst"
fi
ln -s "$_engine_src" "$_engine_dst"
log "Linked $_engine_dst → $_engine_src"

# Shell rc snippet: claude-sync function. Same shape as bw-unlock — the
# function ensures BW_SESSION is exported in the parent shell so the user
# isn't re-prompted on each invocation.
_snippet='
# machine-setup: sync ~/.claude/ to/from Bitwarden.
claude-sync() {
  if [ -z "${BW_SESSION:-}" ] || ! bw status 2>/dev/null | grep -q "\"status\":\"unlocked\""; then
    export BW_SESSION="$(bw unlock --raw)"
  fi
  command claude-sync "$@"
}
'
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  if grep -q '# machine-setup: sync ~/.claude/' "$rc"; then
    # Replace any prior block (lets us evolve the snippet without dupes)
    python3 - "$rc" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
new = re.sub(r"\n*# machine-setup: sync ~/\.claude/.*?\nclaude-sync\(\) \{.*?\n\}\n", "\n", text, flags=re.S)
p.write_text(new)
PY
  fi
  printf '%s\n' "$_snippet" >> "$rc"
done
log "Installed claude-sync function in shell rc files"
