#!/usr/bin/env bash
# junto-update — pull the latest junto tooling from GitHub.
#
# Usage:
#   ~/.junto/junto-update.sh
#
# Tip: add an alias in your shell profile:
#   alias junto-update="~/.junto/junto-update.sh"

set -euo pipefail

JUNTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "junto-update: pulling latest tooling from GitHub..." >&2
git -C "$JUNTO_DIR" pull --ff-only
echo "junto-update: done. Relaunch junto for changes to take effect." >&2
