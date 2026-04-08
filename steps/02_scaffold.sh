#!/usr/bin/env bash
set -euo pipefail

# ─── Step 2: Scaffold Project ───────────────────────────────────────────────
#
# Usage: ./steps/02_scaffold.sh <project-name>
#
# Runs `npx create-eth@latest` to create an SE2 project with the correct
# solidity framework, then installs dependencies.
#
# Inputs:
#   <project-name>  From params.json (e.g. clawd-burn-board)
#   Reads: builds/<project-name>/params.json for framework
#
# Outputs:
#   builds/<project-name>/<project-name>/  — full SE2 project
#   packages/foundry/ or packages/hardhat/ exists
#   packages/nextjs/ exists
#   yarn install completed
#
# Success: builds/<project-name>/<project-name>/packages/nextjs/scaffold.config.ts exists
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

PROJECT_NAME="${1:?Usage: ./steps/02_scaffold.sh <project-name>}"
load_params "$PROJECT_NAME"

echo ">>> Step 2: Scaffolding SE2 project..."
echo "    Project:   $PROJECT_NAME"
echo "    Framework: $FRAMEWORK"
echo "    Target:    $BUILDS_DIR/$PROJECT_NAME/$PROJECT_NAME"
echo ""

BUILD_DIR="$BUILDS_DIR/$PROJECT_NAME"

# Check if already scaffolded
if [[ -f "$PROJECT_DIR/packages/nextjs/scaffold.config.ts" ]]; then
  echo "  Project already scaffolded. Skipping."
  echo ">>> Step 2 complete (skipped)."
  exit 0
fi

# Scaffold — pipe project name to the interactive prompt
cd "$BUILD_DIR"
echo "$PROJECT_NAME" | npx create-eth@latest -s "$FRAMEWORK" --skip-install 2>&1

# Install dependencies
echo ""
echo "  Installing dependencies..."
cd "$PROJECT_DIR"
yarn install 2>&1

# ─── Verify ──────────────────────────────────────────────────────────────────
echo ""
if [[ -f "$PROJECT_DIR/packages/nextjs/scaffold.config.ts" ]]; then
  echo "  ✓ scaffold.config.ts exists"
else
  echo "  ERROR: scaffold.config.ts not found"
  exit 1
fi

if [[ -d "$PROJECT_DIR/packages/$FRAMEWORK" ]]; then
  echo "  ✓ packages/$FRAMEWORK/ exists"
else
  echo "  ERROR: packages/$FRAMEWORK/ not found"
  exit 1
fi

if [[ -d "$PROJECT_DIR/packages/nextjs" ]]; then
  echo "  ✓ packages/nextjs/ exists"
else
  echo "  ERROR: packages/nextjs/ not found"
  exit 1
fi

echo ""
echo ">>> Step 2 complete."
