#!/usr/bin/env bash
# Pull the latest commits for all submodules from their tracking branch.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"

git submodule update --remote --merge
git add packages/
git commit -m "chore: update submodule pointers" || echo "nothing to commit"

echo "Submodules updated."
