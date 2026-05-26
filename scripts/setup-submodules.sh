#!/usr/bin/env bash
# Run once after cloning to wire up all sub-repos as git submodules.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"
cd "$ROOT"

BRANCH="claude/serene-euler-Gq1ma"

declare -A REPOS=(
  ["packages/trading-strategy-ui"]="https://github.com/zmz-commits/trading-strategy-ui.git"
  ["packages/trading-strategy-backend"]="https://github.com/zmz-commits/trading-strategy-backend.git"
  ["packages/trading-strategy-engine"]="https://github.com/zmz-commits/trading-strategy-engine.git"
  ["packages/trading-strategy-data-pipeline"]="https://github.com/zmz-commits/trading-strategy-data-pipeline.git"
)

mkdir -p packages

for path in "${!REPOS[@]}"; do
  url="${REPOS[$path]}"
  if [ -f "$path/.git" ] || [ -d "$path/.git" ]; then
    echo "  already initialised: $path"
  else
    echo "  adding submodule: $path"
    git submodule add -b "$BRANCH" "$url" "$path"
  fi
done

git submodule update --init --recursive

echo ""
echo "Done. All submodules are live under packages/."
echo "To update all submodules to their latest commits:"
echo "  git submodule update --remote --merge"
