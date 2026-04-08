#!/usr/bin/env bash
set -euo pipefail

# ─── Step 4: Write Deploy Scripts ───────────────────────────────────────────
#
# Usage: ./steps/04_deploy_scripts.sh <model> <project-name>
#
# Sends the written contracts to an LLM to generate Foundry deploy scripts.
# Updates Deploy.s.sol orchestrator and replaces DeployYourContract.s.sol.
#
# Inputs:
#   <model>         LLM model ID
#   <project-name>  From params.json
#   Reads: contract .sol files from Step 3, params.json for external contract info
#
# Outputs:
#   Deploy<Name>.s.sol for each contract in packages/foundry/script/
#   Updated Deploy.s.sol orchestrator
#   Default DeployYourContract.s.sol removed
#   Default YourContract.t.sol test removed (references old contract)
#
# Success: Deploy.s.sol compiles (forge build --skip test)
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

MODEL="${1:?Usage: ./steps/04_deploy_scripts.sh <model> <project-name>}"
PROJECT="${2:?Usage: ./steps/04_deploy_scripts.sh <model> <project-name>}"

load_params "$PROJECT"

CONTRACTS_DIR="$PROJECT_DIR/packages/foundry/contracts"
SCRIPT_DIR_SOL="$PROJECT_DIR/packages/foundry/script"
TEST_DIR="$PROJECT_DIR/packages/foundry/test"

echo ">>> Step 4: Writing deploy scripts..."
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

# Read the existing DeployHelpers for context
DEPLOY_HELPERS=$(cat "$SCRIPT_DIR_SOL/DeployHelpers.s.sol")

EXTERNAL_INFO=$(echo "$PARAMS" | jq -r '.external_contracts[] | "- \(.name) at \(.address) on \(.description)"')

SYSTEM_PROMPT='You are a Foundry deploy script writer for Scaffold-ETH 2 projects.

You will be given Solidity contract source code and must write deploy scripts following the SE2 pattern EXACTLY.

IMPORTANT OUTPUT FORMAT:
Return a JSON object where each key is a filename and each value is the file content. Return ONLY this JSON. No markdown. No explanation.

You must return these files:
1. One "Deploy<ContractName>.s.sol" for each contract (replacing DeployYourContract.s.sol)
2. An updated "Deploy.s.sol" orchestrator that imports and calls all individual deploy scripts

DEPLOY SCRIPT PATTERN (follow exactly):
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import "../contracts/ContractName.sol";

contract DeployContractName is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        // Deploy with correct constructor args
        new ContractName(arg1, arg2);
    }
}
```

DEPLOY.S.SOL PATTERN (follow exactly):
```
//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { DeployContractName } from "./DeployContractName.s.sol";

contract DeployScript is ScaffoldETHDeploy {
  function run() external {
    DeployContractName deployContractName = new DeployContractName();
    deployContractName.run();
  }
}
```

RULES:
- Constructor args: read the contract constructors carefully. Use hardcoded addresses for known external contracts.
- The `deployer` variable is available from ScaffoldETHDeploy — use it when the contract needs an owner/admin address.
- Do NOT modify DeployHelpers.s.sol
- Do NOT include DeployHelpers.s.sol in your output'

USER_PROMPT="## Contract Sources
$CONTRACT_SOURCES

## External Contracts
$EXTERNAL_INFO

## Chain: $CHAIN (ID: $CHAIN_ID)

## Existing DeployHelpers.s.sol (DO NOT MODIFY, just for reference):
$DEPLOY_HELPERS

Write the deploy scripts now. Return ONLY the JSON object."

LLM_OUTPUT=$(llm_call "$MODEL" "$SYSTEM_PROMPT" "$USER_PROMPT")

if [[ -z "$LLM_OUTPUT" ]]; then
  echo "ERROR: LLM returned no content."
  exit 1
fi

# Strip markdown fencing
CLEAN_OUTPUT=$(echo "$LLM_OUTPUT" | sed 's/^```json//; s/^```//; s/```$//')

if ! echo "$CLEAN_OUTPUT" | jq . > /dev/null 2>&1; then
  echo "ERROR: LLM output is not valid JSON."
  echo "Raw output:"
  echo "$LLM_OUTPUT"
  exit 1
fi

# Remove defaults
if [[ -f "$SCRIPT_DIR_SOL/DeployYourContract.s.sol" ]]; then
  rm "$SCRIPT_DIR_SOL/DeployYourContract.s.sol"
  echo "  Removed default DeployYourContract.s.sol"
fi
if [[ -f "$TEST_DIR/YourContract.t.sol" ]]; then
  rm "$TEST_DIR/YourContract.t.sol"
  echo "  Removed default YourContract.t.sol"
fi

# Write each file
FILE_COUNT=0
for FILENAME in $(echo "$CLEAN_OUTPUT" | jq -r 'keys[]'); do
  CONTENT=$(echo "$CLEAN_OUTPUT" | jq -r --arg f "$FILENAME" '.[$f]')
  echo "$CONTENT" > "$SCRIPT_DIR_SOL/$FILENAME"
  echo "  Wrote: $SCRIPT_DIR_SOL/$FILENAME"
  FILE_COUNT=$((FILE_COUNT + 1))
done

echo ""
echo "  Wrote $FILE_COUNT deploy script(s)"

# ─── Build-fix loop: compile contracts + scripts ────────────────────────────
echo ""
echo "  Verifying compilation (skipping tests)..."
FOUNDRY_DIR="$PROJECT_DIR/packages/foundry"
verify_fix_loop "$MODEL" "forge build --skip test" "$FOUNDRY_DIR" 3 "$CONTRACTS_DIR" "$SCRIPT_DIR_SOL"

echo ""
echo ">>> Step 4 complete."
