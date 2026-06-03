#!/usr/bin/env bash
# Rebuild and redeploy all environments on the Hetzner server from source.
# Each environment builds from its own branch:
#   prod → main, stg → staging, dev → deployment
#
# Usage on the VM:
#   bash /opt/trading-platform/deploy/redeploy.sh           # all environments
#   bash /opt/trading-platform/deploy/redeploy.sh prod      # one environment

set -euo pipefail

ONLY="${1:-all}"
BE_REPO="https://github.com/zmz-commits/trading-strategy-backend.git"
FE_REPO="https://github.com/zmz-commits/trading-strategy-ui.git"

declare -A BRANCH=( [prod]=main [stg]=staging [dev]=deployment )
declare -A API_URL=(
  [prod]=https://api.zemingzhang.com
  [stg]=https://api-stg.zemingzhang.com
  [dev]=https://api-dev.zemingzhang.com
)

git config --global --add safe.directory /opt/trading-platform 2>/dev/null || true
echo "==> Updating platform repo (compose + Caddyfile)"
cd /opt/trading-platform && git pull --ff-only

build_env() {
  local env="$1"
  local branch="${BRANCH[$env]}"
  echo "==> [$env] building backend from branch '$branch'"
  rm -rf "/tmp/be-$env"
  git clone --depth 1 -b "$branch" "$BE_REPO" "/tmp/be-$env"
  docker build -t "ghcr.io/zmz-commits/trading-strategy-backend:$env" "/tmp/be-$env"

  echo "==> [$env] building frontend (API ${API_URL[$env]})"
  rm -rf "/tmp/fe-$env"
  git clone --depth 1 -b "$branch" "$FE_REPO" "/tmp/fe-$env"
  docker build --build-arg "VITE_API_BASE_URL=${API_URL[$env]}" \
    -t "ghcr.io/zmz-commits/trading-strategy-ui:$env" "/tmp/fe-$env"
}

if [ "$ONLY" = "all" ]; then
  for env in prod stg dev; do build_env "$env"; done
else
  build_env "$ONLY"
fi

echo "==> Restarting stack"
cd /opt/trading-platform/deploy
docker compose up -d
docker image prune -f
echo "==> Redeploy complete."
