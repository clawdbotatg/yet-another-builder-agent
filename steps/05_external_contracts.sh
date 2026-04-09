#!/usr/bin/env bash
set -euo pipefail

# ─── Step 5: Add External Contracts ─────────────────────────────────────────
#
# Usage: ./steps/05_external_contracts.sh <model> <project-name>
#
# Generates externalContracts.ts with ABIs for all external contracts
# referenced in the job spec (e.g. tokens, protocols).
#
# Inputs:
#   <model>         LLM model ID
#   <project-name>  From params.json
#   Reads: params.json (external_contracts), job.md (for context on which functions are needed)
#
# Outputs:
#   Updated packages/nextjs/contracts/externalContracts.ts
#
# Success: File contains all addresses from params.json external_contracts
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

MODEL="${1:?Usage: ./steps/05_external_contracts.sh <model> <project-name>}"
PROJECT="${2:?Usage: ./steps/05_external_contracts.sh <model> <project-name>}"

load_params "$PROJECT"

EXTERNAL_FILE="$PROJECT_DIR/packages/nextjs/contracts/externalContracts.ts"
JOB_CONTENT=$(cat "$BUILDS_DIR/$PROJECT/job.md")
EXTERNAL_COUNT=$(echo "$PARAMS" | jq '.external_contracts | length')

echo ">>> Step 5: Adding external contracts..."
echo "    Model:    $MODEL"
echo "    Project:  $PROJECT"
echo "    External: $EXTERNAL_COUNT contract(s)"
echo ""

CONTRACT_COUNT=$(echo "$PARAMS" | jq '.contract_names | length')
if [[ "$EXTERNAL_COUNT" -eq 0 && "$CONTRACT_COUNT" -eq 0 ]]; then
  echo "  No external or project contracts to add. Skipping."
  echo ">>> Step 5 complete (skipped)."
  exit 0
fi

EXTERNAL_INFO=$(echo "$PARAMS" | jq -r '.external_contracts[] | "- \(.name) at \(.address): \(.description)"')
EXTERNAL_JSON=$(echo "$PARAMS" | jq '.external_contracts')

# Gather project contract sources (for ABI generation)
CONTRACT_SOURCES=""
for SOL_FILE in "$PROJECT_DIR/packages/foundry/contracts"/*.sol; do
  [[ -f "$SOL_FILE" ]] || continue
  CONTRACT_SOURCES="$CONTRACT_SOURCES
--- $(basename "$SOL_FILE") ---
$(cat "$SOL_FILE")
"
done

SYSTEM_PROMPT='You are a TypeScript developer working on a Scaffold-ETH 2 project.

You will be given external contract info, project contract source code, and a dApp build plan. Generate the complete externalContracts.ts file that includes BOTH external contracts AND project contracts (so the frontend can compile before deployment).

IMPORTANT: Return ONLY the TypeScript file content. No markdown fencing. No explanation. Just the raw TypeScript code.

FILE FORMAT (follow exactly):
```
import { GenericContractsDeclaration } from "~~/utils/scaffold-eth/contract";

const externalContracts = {
  CHAIN_ID: {
    ContractName: {
      address: "0x...",
      deployedOnBlock: 0,
      abi: [
        // ABI entries here
      ],
    },
  },
} as const;

export default externalContracts satisfies GenericContractsDeclaration;
```

RULES:
- Chain ID must be a number key (e.g. 8453 for Base), not a string
- EVERY contract MUST include `deployedOnBlock: 0` — this is required by SE2 type system
- For ERC20 tokens, include at minimum: name, symbol, decimals, totalSupply, balanceOf, transfer, transferFrom, approve, allowance, plus Transfer and Approval events
- Include ALL project contracts (from the Solidity source code provided) with address "0x0000000000000000000000000000000000000000" — these serve as ABI references until the contracts are deployed
- Read the Solidity source to build accurate ABIs for project contracts (include all public/external functions and events)
- Read the build plan to understand which functions the frontend will call
- ABI entries must be valid Ethereum ABI JSON format with type, name, inputs, outputs, stateMutability
- Include events in the ABI (type: "event") — these are needed by useScaffoldEventHistory
- Use the exact contract name from the params (e.g. "CLAWD" not "ClawdToken")
- The ABI must be a valid TypeScript array literal (not JSON.parse, not imported)'

USER_PROMPT="## External Contracts
$EXTERNAL_INFO

## Chain: $CHAIN (ID: $CHAIN_ID)

## External Contract Details (JSON)
$EXTERNAL_JSON

## Project Contract Source Code (generate ABIs from these)
$CONTRACT_SOURCES

## Build Plan (for context on which functions the frontend needs)
$JOB_CONTENT

Include ALL contracts (external + project) in the output. Every contract MUST have deployedOnBlock: 0.
Write the complete externalContracts.ts file now. Return ONLY the TypeScript code."

LLM_OUTPUT=$(llm_call "$MODEL" "$SYSTEM_PROMPT" "$USER_PROMPT")

if [[ -z "$LLM_OUTPUT" ]]; then
  echo "ERROR: LLM returned no content."
  exit 1
fi

# Strip markdown fencing if present
CLEAN_OUTPUT=$(echo "$LLM_OUTPUT" | sed 's/^```typescript//; s/^```ts//; s/^```//; s/```$//')

# Write the file
echo "$CLEAN_OUTPUT" > "$EXTERNAL_FILE"
echo "  Wrote: $EXTERNAL_FILE"

# ─── Verify ──────────────────────────────────────────────────────────────────
echo ""
MISSING=0
for ADDRESS in $(echo "$PARAMS" | jq -r '.external_contracts[].address'); do
  if grep -q "$ADDRESS" "$EXTERNAL_FILE"; then
    echo "  ✓ Found address $ADDRESS"
  else
    echo "  ✗ Missing address $ADDRESS"
    MISSING=$((MISSING + 1))
  fi
done

if [[ $MISSING -gt 0 ]]; then
  echo ""
  echo "ERROR: $MISSING address(es) missing from externalContracts.ts"
  exit 1
fi

# Check it has the import
if grep -q "GenericContractsDeclaration" "$EXTERNAL_FILE"; then
  echo "  ✓ Has correct import"
else
  echo "  ✗ Missing GenericContractsDeclaration import"
  exit 1
fi

# ─── Build-fix loop: type-check the file ─────────────────────────────────────
echo ""
echo "  Verifying TypeScript compiles..."
CONTRACTS_TS_DIR="$PROJECT_DIR/packages/nextjs/contracts"
verify_fix_loop "$MODEL" "yarn next:build" "$PROJECT_DIR" 3 "$CONTRACTS_TS_DIR"

echo ""
echo ">>> Step 5 complete."
