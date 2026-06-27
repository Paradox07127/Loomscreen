#!/usr/bin/env bash
#
# Backwards-compatible wrapper: packages the Loomscreen (Lite) SKU.
#
# The real engine is scripts/release-app.sh, which packages either SKU.
# This wrapper exists so the GitHub Actions release workflow can keep
# calling `scripts/release-loomscreen.sh --version X.Y.Z` unchanged.
#
# Usage:
#   scripts/release-loomscreen.sh --version 0.2.0
#   scripts/release-loomscreen.sh --version 0.2.0 --dry-run
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/release-app.sh" --sku lite "$@"
