#!/usr/bin/env bash
# Identity-agnostic git config.

git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global gpg.format ssh
git config --global gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
git config --global commit.gpgsign true
git config --global tag.gpgsign true

# Make sure ~/.ssh exists for downstream identity components.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/allowed_signers"

log "Wrote base git config (defaultBranch=main, signing format=ssh)."
