#!/usr/bin/env bash
set -euo pipefail

# ─── Step 6: Write Tests ────────────────────────────────────────────────────
#
# Usage: ./steps/06_write_tests.sh <model> <project-name>
#
# Sends contracts to an LLM to generate Foundry test files.
#
# Inputs:
#   <model>         LLM model ID
#   <project-name>  From params.json
#   Reads: contract .sol files from Step 3, job.md for requirements
#
# Outputs:
#   Test files in packages/foundry/test/
#
# Success: forge test passes (checked in Step 7)
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

MODEL="${1:?Usage: ./steps/06_write_tests.sh <model> <project-name>}"
PROJECT="${2:?Usage: ./steps/06_write_tests.sh <model> <project-name>}"

load_params "$PROJECT"

CONTRACTS_DIR="$PROJECT_DIR/packages/foundry/contracts"
TEST_DIR="$PROJECT_DIR/packages/foundry/test"

echo ">>> Step 6: Writing tests..."
echo "    Model:   $MODEL"
echo "    Project: $PROJECT"
echo ""

# Gather all contract sources
CONTRACT_SOURCES=""
for SOL_FILE in "$CONTRACTS_DIR"/*.sol; do
  [[ -f "$SOL_FILE" ]] || continue
  FILENAME=$(basename "$SOL_FILE")
  CONTENT=$(cat "$SOL_FILE")
  CONTRACT_SOURCES="$CONTRACT_SOURCES
--- $FILENAME ---
$CONTENT
"
done

JOB_CONTENT=$(cat "$BUILDS_DIR/$PROJECT/job.md")
EXTERNAL_INFO=$(echo "$PARAMS" | jq -r '.external_contracts[] | "- \(.name) at \(.address): \(.description)"')

SYSTEM_PROMPT='You are a Solidity test engineer writing Foundry tests for Scaffold-ETH 2 projects.

You will be given contract source code and a build plan. Write comprehensive Foundry tests.

IMPORTANT OUTPUT FORMAT:
Return a JSON object where each key is a test filename (e.g. "BurnBoard.t.sol") and each value is the complete Solidity test source code. Return ONLY this JSON. No markdown. No explanation.

TESTING FRAMEWORK:
- Use forge-std/Test.sol (import { Test, console } from "forge-std/Test.sol")
- Import contracts via relative path: import "../contracts/ContractName.sol"
- Use vm.prank(), vm.deal(), vm.expectRevert(), vm.warp() etc.
- For ERC20 interactions: deploy a mock ERC20 or use forge-std mock capabilities

WHAT TO TEST:
- All public/external functions
- Constructor setup and initial state
- Happy path for each function
- Revert cases (bad inputs, insufficient balance, unauthorized access)
- Edge cases (zero values, max values, boundary conditions)
- String length validation (if applicable)
- Pagination logic (if applicable)

MOCK ERC20 PATTERN (use when contracts interact with external ERC20s):
```
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
```

RULES:
- One test file per contract
- Use setUp() function for common setup (deploy contracts, mint tokens, etc.)
- Test names should be descriptive: test_post_succeeds, test_post_reverts_when_message_too_long
- Use assertEq, assertTrue, assertFalse for assertions
- Use vm.expectRevert() BEFORE the call that should revert
- Do NOT import console.sol in tests unless debugging
- Make sure mock tokens are properly approved before testing transferFrom flows'

USER_PROMPT="## Contract Sources
$CONTRACT_SOURCES

## External Contracts
$EXTERNAL_INFO

## Build Plan (for context on expected behavior)
$JOB_CONTENT

Write comprehensive Foundry tests now. Return ONLY the JSON object."

# Tests are verbose — use 16k tokens
LLM_OUTPUT=$(llm_call "$MODEL" "$SYSTEM_PROMPT" "$USER_PROMPT" 16384)

if [[ -z "$LLM_OUTPUT" ]]; then
  echo "ERROR: LLM returned no content."
  exit 1
fi

CLEAN_OUTPUT="$LLM_OUTPUT"

if ! echo "$CLEAN_OUTPUT" | jq . > /dev/null 2>&1; then
  echo "ERROR: LLM output is not valid JSON."
  echo "Raw output:"
  echo "$LLM_OUTPUT"
  exit 1
fi

# Write each test file
FILE_COUNT=0
for FILENAME in $(echo "$CLEAN_OUTPUT" | jq -r 'keys[]'); do
  CONTENT=$(echo "$CLEAN_OUTPUT" | jq -r --arg f "$FILENAME" '.[$f]')
  echo "$CONTENT" > "$TEST_DIR/$FILENAME"
  echo "  Wrote: $TEST_DIR/$FILENAME"
  FILE_COUNT=$((FILE_COUNT + 1))
done

echo ""
echo "  Wrote $FILE_COUNT test file(s)"
echo ""
echo ">>> Step 6 complete. Run Step 7 (compile & test) to verify."
