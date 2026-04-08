#!/usr/bin/env bash
set -euo pipefail

# ─── Step 3: Write Contracts ────────────────────────────────────────────────
#
# Usage: ./steps/03_write_contracts.sh <model> <project-name>
#
# Sends the job spec to an LLM to generate Solidity contracts.
# Removes the default YourContract.sol and writes the new contracts.
#
# Inputs:
#   <model>         LLM model ID
#   <project-name>  From params.json
#   Reads: builds/<project-name>/params.json, builds/<project-name>/job.md
#
# Outputs:
#   .sol files in builds/<project-name>/<project-name>/packages/foundry/contracts/
#   Default YourContract.sol removed
#
# Success: All files in contract_names exist as .sol files in the contracts dir
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

MODEL="${1:?Usage: ./steps/03_write_contracts.sh <model> <project-name>}"
PROJECT="${2:?Usage: ./steps/03_write_contracts.sh <model> <project-name>}"

load_params "$PROJECT"

CONTRACTS_DIR="$PROJECT_DIR/packages/foundry/contracts"
JOB_CONTENT=$(cat "$BUILDS_DIR/$PROJECT/job.md")
CONTRACT_NAMES=$(echo "$PARAMS" | jq -r '.contract_names[]')

echo ">>> Step 3: Writing Solidity contracts..."
echo "    Model:     $MODEL"
echo "    Project:   $PROJECT"
echo "    Contracts: $CONTRACT_NAMES"
echo ""

# Build the list of contracts for the prompt
CONTRACT_LIST=$(echo "$PARAMS" | jq -r '.contract_names | join(", ")')
EXTERNAL_INFO=$(echo "$PARAMS" | jq -r '.external_contracts[] | "- \(.name) at \(.address): \(.description)"')

SYSTEM_PROMPT='You are a Solidity smart contract developer. You write clean, secure, production-ready contracts.

You will be given a dApp build plan. Write the Solidity contracts specified.

IMPORTANT OUTPUT FORMAT:
Return a JSON object where each key is the filename (e.g. "BurnBoard.sol") and each value is the complete Solidity source code as a string. Return ONLY this JSON. No markdown fencing. No explanation.

Example output format:
{"BurnBoard.sol": "// SPDX-License-Identifier...\npragma solidity..."}

ENVIRONMENT:
- Foundry project with forge-std available
- OpenZeppelin available via: import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
- Solidity version: pragma solidity ^0.8.19;
- The contracts will be placed in packages/foundry/contracts/

SECURITY RULES (from ethskills.com/security):
- Follow Checks-Effects-Interactions pattern
- Use SafeERC20 for all token operations (safeTransferFrom, not transferFrom)
- Validate bytes(text).length for string length checks, not text.length
- Emit events for every state change
- Cap pagination limits to prevent gas DoS on view functions
- No infinite approvals
- If the spec says "no admin, no owner" — do not add any access control

QUALITY RULES:
- No console.log imports (that is for debugging only)
- No unnecessary comments or boilerplate
- Keep contracts focused — one contract per file
- Use descriptive error messages or custom errors
- Use immutable/constant where appropriate'

USER_PROMPT="## Build Plan

$JOB_CONTENT

## Contracts to Write
$CONTRACT_LIST

## External Contracts Available
$EXTERNAL_INFO

## Chain
$CHAIN (chain ID: $CHAIN_ID)

Write the Solidity contracts now. Return ONLY the JSON object mapping filename to source code."

LLM_OUTPUT=$(llm_call "$MODEL" "$SYSTEM_PROMPT" "$USER_PROMPT")

if [[ -z "$LLM_OUTPUT" ]]; then
  echo "ERROR: LLM returned no content."
  exit 1
fi

# Strip markdown fencing if present
CLEAN_OUTPUT=$(echo "$LLM_OUTPUT" | sed 's/^```json//; s/^```//; s/```$//')

# Validate JSON
if ! echo "$CLEAN_OUTPUT" | jq . > /dev/null 2>&1; then
  echo "ERROR: LLM output is not valid JSON."
  echo "Raw output:"
  echo "$LLM_OUTPUT"
  exit 1
fi

# Remove default YourContract.sol
if [[ -f "$CONTRACTS_DIR/YourContract.sol" ]]; then
  rm "$CONTRACTS_DIR/YourContract.sol"
  echo "  Removed default YourContract.sol"
fi

# Write each contract file
FILE_COUNT=0
for FILENAME in $(echo "$CLEAN_OUTPUT" | jq -r 'keys[]'); do
  CONTENT=$(echo "$CLEAN_OUTPUT" | jq -r --arg f "$FILENAME" '.[$f]')
  echo "$CONTENT" > "$CONTRACTS_DIR/$FILENAME"
  echo "  Wrote: $CONTRACTS_DIR/$FILENAME"
  FILE_COUNT=$((FILE_COUNT + 1))
done

echo ""
echo "  Wrote $FILE_COUNT contract(s)"

# ─── Verify ──────────────────────────────────────────────────────────────────
echo ""
MISSING=0
for NAME in $CONTRACT_NAMES; do
  # Normalize: add .sol if not present
  SOLFILE="$NAME"
  [[ "$SOLFILE" != *.sol ]] && SOLFILE="${SOLFILE}.sol"

  if [[ -f "$CONTRACTS_DIR/$SOLFILE" ]]; then
    echo "  ✓ $SOLFILE exists"
  else
    echo "  ✗ $SOLFILE MISSING"
    MISSING=$((MISSING + 1))
  fi
done

if [[ $MISSING -gt 0 ]]; then
  echo ""
  echo "ERROR: $MISSING contract(s) missing. Check LLM output."
  exit 1
fi

# ─── Build-fix loop: compile contracts ───────────────────────────────────────
echo ""
echo "  Verifying contracts compile..."
FOUNDRY_DIR="$PROJECT_DIR/packages/foundry"
verify_fix_loop "$MODEL" "forge build --skip test --skip script" "$FOUNDRY_DIR" 3 "$CONTRACTS_DIR"

echo ""
echo ">>> Step 3 complete."
