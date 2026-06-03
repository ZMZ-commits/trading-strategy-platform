#!/usr/bin/env bash
# One-shot setup for a fresh Ubuntu 22.04 VM (Hetzner CAX11 / any ARM or x86 VPS).
# Installs Docker + docker-compose, configures UFW firewall, creates data dirs,
# clones this repo to /opt/trading-platform.
#
# Usage on the VM (as root or via sudo):
#   curl -fsSL https://raw.githubusercontent.com/zmz-commits/trading-strategy-platform/main/deploy/bootstrap.sh | bash

set -euo pipefail

echo "==> Updating apt and installing prerequisites"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release git ufw

echo "==> Installing Docker (official repo)"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Adding deploy user to docker group"
TARGET_USER="${SUDO_USER:-$USER}"
if [ "$TARGET_USER" != "root" ] && id "$TARGET_USER" &>/dev/null; then
  sudo usermod -aG docker "$TARGET_USER"
else
  # Hetzner default is root. Create a non-root 'deploy' user for SSH deploys.
  if ! id "deploy" &>/dev/null; then
    sudo useradd -m -s /bin/bash deploy
    sudo usermod -aG sudo,docker deploy
    sudo mkdir -p /home/deploy/.ssh
    sudo cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
    sudo chown -R deploy:deploy /home/deploy/.ssh
    sudo chmod 700 /home/deploy/.ssh
    sudo chmod 600 /home/deploy/.ssh/authorized_keys
    echo "deploy ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/deploy
  fi
  TARGET_USER="deploy"
fi

echo "==> Configuring UFW firewall (allow SSH/HTTP/HTTPS)"
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

echo "==> Creating data directories"
sudo mkdir -p /data/prod /data/stg /data/dev /opt/trading-platform
sudo chown -R "$TARGET_USER:$TARGET_USER" /data /opt/trading-platform

echo "==> Cloning trading-strategy-platform"
if [ ! -d /opt/trading-platform/.git ]; then
  sudo -u "$TARGET_USER" git clone https://github.com/zmz-commits/trading-strategy-platform.git /opt/trading-platform
fi

echo ""
echo "==> Bootstrap complete."
echo ""
echo "Next steps:"
echo "  1. SSH back in as the '$TARGET_USER' user (if you bootstrapped as root):"
echo "       ssh $TARGET_USER@<vm-ip>"
echo "  2. The container image is public — no docker login needed."
echo "  3. Start the stack:"
echo "       cd /opt/trading-platform/deploy && docker compose up -d"
echo "  4. Verify:"
echo "       docker compose ps"
