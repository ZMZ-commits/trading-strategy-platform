#!/usr/bin/env bash
# Rebuild and redeploy all environments on the Hetzner server from source.
# Each environment builds from its own branch:
#   prod → main, stg → staging, dev → deployment
# The shared data pipeline image is built from the deployment branch.
#
# Usage on the VM:
#   bash /opt/trading-platform/deploy/redeploy.sh           # all environments
#   bash /opt/trading-platform/deploy/redeploy.sh prod      # one environment
#   bash /opt/trading-platform/deploy/redeploy.sh pipeline  # just the pipeline

set -euo pipefail

ONLY="${1:-all}"
BE_REPO="https://github.com/zmz-commits/trading-strategy-backend.git"
FE_REPO="https://github.com/zmz-commits/trading-strategy-ui.git"
PIPE_REPO="https://github.com/zmz-commits/trading-strategy-data-pipeline.git"

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

build_pipeline() {
  # Single shared pipeline (Alpaca free tier allows one data stream).
  echo "==> building data pipeline from branch 'deployment'"
  rm -rf /tmp/pipeline
  git clone --depth 1 -b deployment "$PIPE_REPO" /tmp/pipeline
  docker build -t "ghcr.io/zmz-commits/trading-strategy-data-pipeline:latest" /tmp/pipeline
}

case "$ONLY" in
  all)      build_pipeline; for env in prod stg dev; do build_env "$env"; done ;;
  pipeline) build_pipeline ;;
  *)        build_env "$ONLY" ;;
esac

echo "==> Restarting stack"
cd /opt/trading-platform/deploy
docker compose up -d
docker image prune -f
echo "==> Redeploy complete."
