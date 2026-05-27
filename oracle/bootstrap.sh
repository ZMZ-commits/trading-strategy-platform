#!/usr/bin/env bash
# Run this ONCE on a fresh Oracle Cloud Ubuntu 22.04 VM.
# It installs Docker + docker-compose, opens firewall ports, and prepares
# data directories for the 3 backend environments.
#
# Usage (on the VM, as user "ubuntu"):
#   curl -fsSL https://raw.githubusercontent.com/zmz-commits/trading-strategy-platform/main/oracle/bootstrap.sh | bash

set -euo pipefail

echo "==> Updating apt and installing prerequisites"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release git

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

echo "==> Adding 'ubuntu' user to docker group"
sudo usermod -aG docker ubuntu

echo "==> Opening firewall ports 80 and 443 (Oracle iptables)"
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80  -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save || sudo bash -c 'apt-get install -y iptables-persistent && netfilter-persistent save'

echo "==> Creating data directories"
sudo mkdir -p /data/prod /data/stg /data/dev /opt/trading-platform
sudo chown -R ubuntu:ubuntu /data /opt/trading-platform

echo "==> Cloning trading-strategy-platform"
if [ ! -d /opt/trading-platform/.git ]; then
  git clone https://github.com/zmz-commits/trading-strategy-platform.git /opt/trading-platform
fi

echo ""
echo "==> Bootstrap complete."
echo ""
echo "Next steps:"
echo "  1. Log out and back in so the docker group membership takes effect"
echo "  2. Authenticate Docker with GitHub Container Registry:"
echo "       echo <YOUR_GITHUB_PAT> | docker login ghcr.io -u <YOUR_GITHUB_USERNAME> --password-stdin"
echo "  3. Start the stack:"
echo "       cd /opt/trading-platform/oracle && docker compose up -d"
echo "  4. Verify:"
echo "       docker compose ps"
