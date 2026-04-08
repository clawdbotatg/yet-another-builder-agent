#!/usr/bin/env bash
set -euo pipefail

# ─── Step 7: Compile and Test ───────────────────────────────────────────────
#
# Usage: ./steps/07_compile_test.sh <model> <project-name> [max-retries]
#
# Runs forge build then forge test. On failure, uses the shared verify_fix_loop
# to auto-fix errors via LLM. Two phases: compile first, then test.
#
# Inputs:
#   <model>         LLM model ID (used for fix attempts)
#   <project-name>  From params.json
#   [max-retries]   Number of fix attempts per phase (default: 3)
#
# Outputs:
#   Fixed .sol files if corrections were needed
#   Compilation artifacts + test results
#
# Success: Exit code 0. All tests pass.
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

MODEL="${1:?Usage: ./steps/07_compile_test.sh <model> <project-name> [max-retries]}"
PROJECT="${2:?Usage: ./steps/07_compile_test.sh <model> <project-name> [max-retries]}"
MAX_RETRIES="${3:-3}"

load_params "$PROJECT"

FOUNDRY_DIR="$PROJECT_DIR/packages/foundry"
CONTRACTS_DIR="$FOUNDRY_DIR/contracts"
TEST_DIR="$FOUNDRY_DIR/test"
SCRIPT_DIR_SOL="$FOUNDRY_DIR/script"

echo ">>> Step 7: Compile and test..."
echo "    Model:       $MODEL"
echo "    Project:     $PROJECT"
echo "    Max retries: $MAX_RETRIES"
echo ""

# Phase 1: Compile everything
echo "  Phase 1: Compile..."
verify_fix_loop "$MODEL" "forge build" "$FOUNDRY_DIR" "$MAX_RETRIES" \
  "$CONTRACTS_DIR" "$TEST_DIR" "$SCRIPT_DIR_SOL"

# Phase 2: Run tests
echo ""
echo "  Phase 2: Test..."
verify_fix_loop "$MODEL" "forge test -vv" "$FOUNDRY_DIR" "$MAX_RETRIES" \
  "$CONTRACTS_DIR" "$TEST_DIR"

echo ""
echo ">>> Step 7 complete."
