# yubikey-linux-setup

One-shot setup script to configure a **Fedora 44** system for Yubikey-backed
GPG with SSH agent and Git commit signing.

## Usage

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/yubikey-linux-setup/main/setup.sh)
```

The script will:
1. Ask for your Git name, email, and GPG key ID
2. Install required packages (`gnupg2`, `pcsc-lite`, `ykpers`, etc.)
3. Enable `pcscd` service
4. Configure `gpg-agent` with SSH support
5. Wire `SSH_AUTH_SOCK` to the GPG agent socket
6. Set up Yubikey udev rules
7. Configure Git for commit signing

## What it does

| Area | Change |
|------|--------|
| **Packages** | `gnupg2`, `pcsc-lite`, `pcsc-lite-ccid`, `ccid`, `opensc`, `ykpers`, `yubikey-manager`, `pinentry-gnome3` |
| **Services** | `pcscd` enabled |
| **GPG agent** | `~/.gnupg/gpg-agent.conf` — SSH support + pinentry |
| **SSH** | `~/.config/yubikey-linux-setup/env` sourced from `.bashrc`, `AddKeysToAgent yes` in `~/.ssh/config` |
| **Git** | `user.name`, `user.email`, `user.signingkey`, `commit.gpgsign true`, `gpg.program gpg2` |
| **udev** | `/etc/udev/rules.d/70-yubikey.rules` — `uaccess` tag for Yubikey HID devices |

## Prerequisites

- Fedora 44
- A Yubikey with GPG keys (optional — the script will warn if signing fails)

## After setup

```bash
# Source the environment (or log out and back in)
source ~/.bashrc

# Verify the card is detected
gpg --card-status

# Check SSH keys are available
ssh-add -l

# Test Git signing
git commit --allow-empty -m "test signing"
```

## License

MIT
