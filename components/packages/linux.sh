#!/usr/bin/env bash
# Install base packages. Dispatches by distro family.

_pkg_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian|linuxmint) echo ubuntu ;;
      fedora|rhel|centos|rocky|almalinux) echo fedora ;;
      arch|manjaro|endeavouros) echo arch ;;
      *) echo "$ID" ;;
    esac
  fi
}

_pkg_install_ubuntu() {
  log "Updating apt..."
  sudo apt-get update -qq || warn "apt-get update failed"

  log "Installing base packages..."
  sudo apt-get install -y --no-install-recommends \
    git curl wget ca-certificates \
    python3 python3-pip \
    build-essential \
    whiptail \
    || warn "Some base packages failed to install"

  if ! command -v gh >/dev/null 2>&1; then
    log "Installing GitHub CLI..."
    {
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
      sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
      sudo apt-get update -qq
      sudo apt-get install -y gh
    } || warn "GitHub CLI installation failed"
  fi
}

_pkg_install_fedora() {
  log "Installing base packages..."
  sudo dnf install -y \
    git curl wget ca-certificates \
    python3 python3-pip \
    gcc gcc-c++ make \
    newt \
    gh \
    || warn "Some packages failed to install"
}

_pkg_install_arch() {
  log "Updating pacman..."
  sudo pacman -Syu --noconfirm || warn "pacman -Syu failed"

  log "Installing base packages..."
  sudo pacman -S --noconfirm --needed \
    git curl wget ca-certificates \
    python python-pip \
    base-devel \
    libnewt \
    github-cli \
    || warn "Some packages failed to install"
}

case "$(_pkg_distro)" in
  ubuntu) _pkg_install_ubuntu ;;
  fedora) _pkg_install_fedora ;;
  arch)   _pkg_install_arch ;;
  *) warn "Unsupported distro for packages component"; return 1 ;;
esac
