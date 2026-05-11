#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# Yubikey Linux Setup — Fedora 44
# GPG agent for SSH + Git commit signing
# ──────────────────────────────────────────────

REQUIRED_FEDORA_VERSION="44"
GPG_AGENT_CONF="${HOME}/.gnupg/gpg-agent.conf"
SSH_CONFIG="${HOME}/.ssh/config"
GPG_KEY_ID=""

# ── Utils ─────────────────────────────────────

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$*"; }
warn()  { printf '\033[0;33m%s\033[0m\n' "$*"; }

info()  { blue  ":: $*"; }
ok()    { green "=> $*"; }
err()   { red   "!! $*"; }

confirm() {
  printf "%s [y/N] " "$*" >&2
  read -r resp
  [[ "$resp" =~ ^[Yy] ]]
}

run_as_user() {
  if [[ $EUID -eq 0 ]]; then
    sudo -u "$SUDO_USER" "$@"
  else
    "$@"
  fi
}

real_home() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    getent passwd "$SUDO_USER" | cut -d: -f6
  else
    echo "$HOME"
  fi
}

user_shell() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    getent passwd "$SUDO_USER" | cut -d: -f7
  else
    echo "$SHELL"
  fi
}

shell_rc_files() {
  local home
  home=$(real_home)
  local shell
  shell=$(user_shell)
  local shell_name
  shell_name=$(basename "$shell")

  case "$shell_name" in
    zsh)
      printf "%s/.zshrc\n" "$home"
      ;;
  esac
  # Always include .bashrc as a fallback
  printf "%s/.bashrc\n" "$home"
}

add_env_to_rc() {
  local rc_file="$1"
  local source_line="$2"
  if [[ ! -f "$rc_file" ]]; then
    return
  fi
  if grep -qF "yubikey-linux-setup/env" "$rc_file" 2>/dev/null; then
    return
  fi
  echo "" >> "$rc_file"
  echo "# Added by yubikey-linux-setup" >> "$rc_file"
  echo "$source_line" >> "$rc_file"
}

# ── Pre-flight ────────────────────────────────

preflight() {
  echo
  blue "╔══════════════════════════════════════════╗"
  blue "║  Yubikey Linux Setup — Fedora 44         ║"
  blue "║  GPG agent · SSH · Git signing           ║"
  blue "╚══════════════════════════════════════════╝"
  echo

  # OS check
  if [[ ! -f /etc/fedora-release ]]; then
    err "This script is designed for Fedora Linux only."
    exit 1
  fi

  local version
  version=$(rpm -E %fedora)
  if [[ "$version" != "$REQUIRED_FEDORA_VERSION" ]]; then
    warn "Detected Fedora ${version} (expected ${REQUIRED_FEDORA_VERSION})"
    if ! confirm "Continue anyway?"; then
      exit 1
    fi
  fi

  info "Detected Fedora ${version}"

  # Sudo check — re-exec if needed
  if [[ $EUID -ne 0 ]]; then
    info "Escalating privileges (package installs need sudo)..."
    exec sudo bash "$0" "$@"
  fi

  info "Running with sufficient privileges"
}

# ── Collect Info ──────────────────────────────

detect_yubikey_gpg_key() {
  gpg2 --card-status 2>/dev/null | \
    awk -F': ' '/^Signature key/ {gsub(/ /, "", $2); print $2}'
}

collect_info() {
  echo
  blue "── Configuration ──"
  echo

  local default_name default_email
  default_name=$(run_as_user git config --global user.name 2>/dev/null || true)
  default_email=$(run_as_user git config --global user.email 2>/dev/null || true)

  read_with_default() {
    local prompt="$1" default="$2" var_name="$3"
    local val
    if [[ -n "$default" ]]; then
      printf "  %s [%s]: " "$prompt" "$default" >&2
    else
      printf "  %s: " "$prompt" >&2
    fi
    read -r val
    if [[ -z "$val" && -n "$default" ]]; then
      printf -v "$var_name" "%s" "$default"
    else
      printf -v "$var_name" "%s" "$val"
    fi
  }

  read_with_default "Full name for Git" "$default_name" GIT_NAME
  read_with_default "Email for Git" "$default_email" GIT_EMAIL

  local detected_key
  detected_key=$(detect_yubikey_gpg_key) || true
  if [[ -n "$detected_key" ]]; then
    info "Detected GPG key on Yubikey: ${detected_key:0:4}...${detected_key: -8}"
    if confirm "Use this key for Git signing?"; then
      GPG_KEY_ID="$detected_key"
    fi
  fi

  if [[ -z "${GPG_KEY_ID:-}" ]]; then
    printf "  GPG key ID to use for signing (leave blank to skip): " >&2
    read -r GPG_KEY_ID
  fi

  if confirm "Enable SSH support via gpg-agent?"; then
    ENABLE_SSH=true
  else
    ENABLE_SSH=false
  fi

  echo
}

# ── Install Packages ──────────────────────────

install_packages() {
  echo
  blue "── Installing packages ──"
  echo

  local packages=(
    gnupg2
    gnupg2-scdaemon
    pcsc-lite
    pcsc-lite-ccid
    opensc
    ykpers
    yubikey-manager
    pinentry-gnome3
  )

  info "Installing: ${packages[*]}"
  dnf install -y "${packages[@]}"
  ok "Packages installed"
}

# ── Services ──────────────────────────────────

configure_services() {
  echo
  blue "── Enabling services ──"
  echo

  systemctl enable --now pcscd
  systemctl restart pcscd 2>/dev/null || true
  if systemctl is-active --quiet pcscd; then
    ok "pcscd enabled and running"
  else
    warn "pcscd service is not active — check systemctl status pcscd"
  fi
}

# ── GPG Agent ─────────────────────────────────

configure_gpg_agent() {
  echo
  blue "── Configuring GPG agent ──"
  echo

  local user_home
  user_home=$(real_home)
  local agent_conf="${user_home}/.gnupg/gpg-agent.conf"

  mkdir -p "${user_home}/.gnupg"
  chmod 700 "${user_home}/.gnupg"

  local pinentry="/usr/bin/pinentry-gnome3"
  if [[ ! -x "$pinentry" ]]; then
    for alt in /usr/bin/pinentry-qt /usr/bin/pinentry-curses /usr/bin/pinentry-tty; do
      if [[ -x "$alt" ]]; then
        pinentry="$alt"
        break
      fi
    done
  fi

  touch "$agent_conf"

  if ! grep -q "^enable-ssh-support" "$agent_conf" 2>/dev/null; then
    cat >> "$agent_conf" <<EOF
# Added by yubikey-linux-setup
enable-ssh-support
pinentry-program ${pinentry}
EOF
  else
    info "gpg-agent.conf already has enable-ssh-support"
  fi

  chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "${user_home}/.gnupg" 2>/dev/null || true

  ok "GPG agent configured"
}

# ── scdaemon ──────────────────────────────────

configure_scdaemon() {
  echo
  blue "── Configuring scdaemon ──"
  echo

  local user_home
  user_home=$(real_home)
  local scd_conf="${user_home}/.gnupg/scdaemon.conf"

  mkdir -p "${user_home}/.gnupg"
  chmod 700 "${user_home}/.gnupg"

  if [[ ! -f "$scd_conf" ]] || ! grep -q "^disable-ccid" "$scd_conf" 2>/dev/null; then
    cat >> "$scd_conf" <<'EOF'
# Added by yubikey-linux-setup
disable-ccid
EOF
    ok "scdaemon.conf created with disable-ccid"
  else
    info "scdaemon.conf already has disable-ccid"
  fi

  chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "${user_home}/.gnupg" 2>/dev/null || true

  ok "scdaemon configured"
}

# ── SSH ────────────────────────────────────────

configure_ssh() {
  if [[ "$ENABLE_SSH" != true ]]; then
    info "Skipping SSH configuration"
    return
  fi

  echo
  blue "── Configuring SSH for GPG agent ──"
  echo

  local user_home
  user_home=$(real_home)

  mkdir -p "${user_home}/.ssh"
  chmod 700 "${user_home}/.ssh"

  # Add GPG agent socket as an SSH key provider
  local sock_path="\${XDG_RUNTIME_DIR}/gnupg/S.gpg-agent.ssh"

  local env_file="${user_home}/.config/yubikey-linux-setup/env"
  mkdir -p "$(dirname "$env_file")"

  cat > "$env_file" <<EOF
# Added by yubikey-linux-setup
export SSH_AUTH_SOCK="\${XDG_RUNTIME_DIR}/gnupg/S.gpg-agent.ssh"
export GPG_TTY="\$(tty)"
EOF

  # Source env in the user's shell rc files
  local source_line=". \"\${HOME}/.config/yubikey-linux-setup/env\""
  local rc_file
  while IFS= read -r rc_file; do
    add_env_to_rc "$rc_file" "$source_line"
  done <<< "$(shell_rc_files | sort -u)"
  ok "Added env sourcing to shell rc files"

  # AddKeysToAgent in ssh config
  local ssh_config="${user_home}/.ssh/config"
  if [[ ! -f "$ssh_config" ]]; then
    echo "# Added by yubikey-linux-setup" > "$ssh_config"
    echo "AddKeysToAgent yes" >> "$ssh_config"
  else
    if ! grep -q "^AddKeysToAgent" "$ssh_config" 2>/dev/null; then
      echo "" >> "$ssh_config"
      echo "# Added by yubikey-linux-setup" >> "$ssh_config"
      echo "AddKeysToAgent yes" >> "$ssh_config"
    fi
  fi

  chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "${user_home}/.ssh" 2>/dev/null || true
  chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$(dirname "$env_file")" 2>/dev/null || true

  ok "SSH configured to use GPG agent"
}

# ── Git ────────────────────────────────────────

configure_git() {
  echo
  blue "── Configuring Git ──"
  echo

  local needs_signing=false

  if [[ -n "$GIT_NAME" ]]; then
    run_as_user git config --global user.name "$GIT_NAME"
    ok "Git user.name set to: $GIT_NAME"
  fi

  if [[ -n "$GIT_EMAIL" ]]; then
    run_as_user git config --global user.email "$GIT_EMAIL"
    ok "Git user.email set to: $GIT_EMAIL"
  fi

  if [[ -n "$GPG_KEY_ID" ]]; then
    run_as_user git config --global user.signingkey "$GPG_KEY_ID"
    run_as_user git config --global commit.gpgsign true
    info "Git signing key set to: $GPG_KEY_ID"
    needs_signing=true
  fi

  run_as_user git config --global gpg.program gpg2

  # If a key was specified, test the setup
  if [[ "$needs_signing" == true ]]; then
    echo
    info "Testing GPG signing..."
    run_as_user bash -c "echo test | gpg2 --clearsign > /dev/null 2>&1" && {
      ok "GPG signing works"
    } || {
      warn "GPG signing test failed. You may need to configure your Yubikey GPG keys."
      warn "See: https://docs.yubico.com/yesdk/users-manual/application-piv/generate-key.html"
    }
  fi

  ok "Git configured"
}

# ── Restart GPG stack ─────────────────────────

restart_gpg_stack() {
  echo
  blue "── Restarting PC/SC and GPG stack ──"
  echo

  # Restart pcscd to clear any stale card claims (e.g. from earlier
  # debugging tools). Without this, scdaemon can get a "sharing
  # violation" from PC/SC if another process has the card open.
  systemctl restart pcscd 2>/dev/null || true
  sleep 1

  # Kill both agent and scdaemon so they pick up the new config files
  # on next access. The agent will be auto-started by gpg on demand.
  run_as_user gpgconf --kill scdaemon 2>/dev/null || true
  run_as_user gpgconf --kill gpg-agent 2>/dev/null || true

  ok "PC/SC and GPG stack restarted"
}

# ── Yubikey udev ──────────────────────────────

configure_udev() {
  echo
  blue "── Checking udev rules ──"
  echo

  # Modern Fedora packages include Yubikey udev rules via libyubikey/ykpers
  # but we ensure the standard ones are in place
  local rules_file="/etc/udev/rules.d/70-yubikey.rules"

  if [[ ! -f "$rules_file" ]]; then
    cat > "$rules_file" <<'EOF'
# Yubikey U2F / CCID udev rules
ACTION!="add|change", GOTO="yubikey_end"

SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1050", ATTRS{idProduct}=="0113|0114|0115|0116|0120|0121|0200|0401|0402|0403|0404|0405|0406|0407|0410", TAG+="uaccess"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1050", ATTRS{idProduct}=="0010|0011|0030|0040", TAG+="uaccess"

LABEL="yubikey_end"
EOF
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    ok "Udev rules installed for Yubikey"
  else
    info "Yubikey udev rules already present"
  fi
}

# ── Summary ───────────────────────────────────

print_summary() {
  echo
  green "╔══════════════════════════════════════════╗"
  green "║  Setup complete!                         ║"
  green "╚══════════════════════════════════════════╝"
  echo

  if [[ -n "$GPG_KEY_ID" ]]; then
    info "Git signing key  : $GPG_KEY_ID"
  fi
  if [[ -n "$GIT_EMAIL" ]]; then
    info "Git email        : $GIT_EMAIL"
  fi
  if [[ -n "$GIT_NAME" ]]; then
    info "Git name         : $GIT_NAME"
  fi

  echo
  info "Next steps:"
  info "  1. Log out and back in (or run: source ~/.bashrc or source ~/.zshrc)"
  info "  2. Verify GPG keys: gpg --card-status"
  info "  3. List SSH keys  : ssh-add -l"
  if [[ -n "$GPG_KEY_ID" ]]; then
    info "  4. Test signing   : git commit --allow-empty -m test"
  fi
  echo
  info "If you don't have GPG keys on your Yubikey yet:"
  info "  ykman piv generate-key --pin-policy NEVER --touch-policy CACHE 9a pubkey.pem"
  info "  ykman piv generate-certificate --pin-policy NEVER --touch-policy CACHE -s 9a pubkey.pem"
  info "  gpg --edit-card"
  echo
}

# ── Main ──────────────────────────────────────

main() {
  preflight "$@"
  collect_info
  install_packages
  configure_services
  configure_gpg_agent
  configure_scdaemon
  configure_ssh
  configure_udev
  configure_git
  restart_gpg_stack
  print_summary
}

main "$@"
