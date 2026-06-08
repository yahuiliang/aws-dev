#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

cd "$TF_DIR"

terraform output

echo ""
echo "--- Cursor Remote SSH ---"
echo "运行 make cursor，然后在 Cursor 里连接 Host aws-vibe-dev"
