#!/usr/bin/env bash
set -euo pipefail

# ─── Step 8: Build Frontend ─────────────────────────────────────────────────
#
# Usage: ./steps/08_frontend.sh <model> <project-name>
#
# Updates scaffold.config.ts for the target chain, then sends the job spec,
# design brief, contract ABIs, and SE2 conventions to an LLM to generate
# all frontend files (theme, components, pages).
#
# Inputs:
#   <model>         LLM model ID
#   <project-name>  From params.json
#   Reads: job.md, params.json, deployed contract ABI, existing SE2 scaffold
#
# Outputs:
#   Updated scaffold.config.ts (target network)
#   Updated styles/globals.css (custom theme)
#   Updated components/Header.tsx
#   Updated components/Footer.tsx
#   New components in components/
#   Updated app/page.tsx
#
# Success: yarn next:build completes without errors
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

MODEL="${1:?Usage: ./steps/08_frontend.sh <model> <project-name>}"
PROJECT="${2:?Usage: ./steps/08_frontend.sh <model> <project-name>}"

load_params "$PROJECT"

NEXTJS_DIR="$PROJECT_DIR/packages/nextjs"
JOB_CONTENT=$(cat "$BUILDS_DIR/$PROJECT/job.md")

echo ">>> Step 8: Building frontend..."
echo "    Model:   $MODEL"
echo "    Project: $PROJECT"
echo ""

# ─── Step 8a: Update scaffold.config.ts (deterministic) ─────────────────────
echo "  Updating scaffold.config.ts for $CHAIN..."

# Map chain name to viem chain import
case "$CHAIN" in
  base)       CHAIN_IMPORT="base" ;;
  mainnet)    CHAIN_IMPORT="mainnet" ;;
  arbitrum)   CHAIN_IMPORT="arbitrum" ;;
  optimism)   CHAIN_IMPORT="optimism" ;;
  sepolia)    CHAIN_IMPORT="sepolia" ;;
  *)          CHAIN_IMPORT="$CHAIN" ;;
esac

# Replace the targetNetworks line
sed -i.bak "s/chains\.foundry/chains.$CHAIN_IMPORT/" "$NEXTJS_DIR/scaffold.config.ts"
rm -f "$NEXTJS_DIR/scaffold.config.ts.bak"
echo "  ✓ Set targetNetworks to chains.$CHAIN_IMPORT"

# ─── Step 8b: Gather context for LLM ────────────────────────────────────────

# Read contract source for ABI context
CONTRACT_SOURCES=""
for SOL_FILE in "$PROJECT_DIR/packages/foundry/contracts"/*.sol; do
  [[ -f "$SOL_FILE" ]] || continue
  CONTRACT_SOURCES="$CONTRACT_SOURCES
--- $(basename "$SOL_FILE") ---
$(cat "$SOL_FILE")
"
done

# Read existing files the LLM needs to understand
EXISTING_HEADER=$(cat "$NEXTJS_DIR/components/Header.tsx")
EXISTING_FOOTER=$(cat "$NEXTJS_DIR/components/Footer.tsx")
EXISTING_PAGE=$(cat "$NEXTJS_DIR/app/page.tsx")
EXISTING_LAYOUT=$(cat "$NEXTJS_DIR/app/layout.tsx")
EXISTING_CSS=$(cat "$NEXTJS_DIR/styles/globals.css")
EXTERNAL_CONTRACTS=$(cat "$NEXTJS_DIR/contracts/externalContracts.ts")

EXTERNAL_INFO=$(echo "$PARAMS" | jq -r '.external_contracts[] | "- \(.name) at \(.address): \(.description)"')

# ─── Step 8c: LLM call to generate all frontend files ───────────────────────
echo ""
echo "  Generating frontend files with LLM..."

SYSTEM_PROMPT='You are a frontend developer building a Scaffold-ETH 2 dApp.

You will be given a build plan with a design brief, contract source code, and existing SE2 scaffold files. Generate the complete frontend.

IMPORTANT OUTPUT FORMAT:
Return a JSON object where each key is a file path relative to packages/nextjs/ and each value is the complete file content. Return ONLY this JSON. No markdown. No explanation.

FILES TO GENERATE:
1. "styles/globals.css" — Custom DaisyUI theme matching the design brief. Keep the @import, @plugin structure.
2. "components/Header.tsx" — Custom header per the design brief. MUST keep RainbowKitCustomConnectButton.
3. "components/Footer.tsx" — Minimal or custom footer. Remove SE2 branding.
4. "app/page.tsx" — Main page composing all components for the dApp.
5. Any additional component files needed in "components/" (e.g. "components/MessageFeed.tsx", "components/PostForm.tsx")
6. "app/layout.tsx" — Update metadata (title, description). Keep the structure identical.

SE2 HOOK PATTERNS (use these exactly):
```typescript
// Read contract data
const { data } = useScaffoldReadContract({
  contractName: "ContractName",
  functionName: "functionName",
  args: [arg1, arg2],
});

// Write to contract
const { writeContractAsync, isPending } = useScaffoldWriteContract("ContractName");
await writeContractAsync({ functionName: "fn", args: [a, b] });

// Read external contract (like ERC20 token)
const { data } = useScaffoldReadContract({
  contractName: "CLAWD",  // must match key in externalContracts.ts
  functionName: "balanceOf",
  args: [address],
});

// Write to external contract
const { writeContractAsync } = useScaffoldWriteContract("CLAWD");
await writeContractAsync({ functionName: "approve", args: [spender, amount] });
```

IMPORT PATTERNS:
```typescript
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { useAccount } from "wagmi";
import { Address } from "@scaffold-ui/components";
import { formatEther, parseEther } from "viem";
import type { NextPage } from "next";
```

CRITICAL RULES:
- "use client" directive at top of any file using hooks or interactivity
- Use DaisyUI semantic classes (btn, card, bg-base-100, text-base-content) not raw hex colors in components
- Custom colors go in globals.css theme, not inline
- Button state machine: Connect → Switch Network → Approve → Execute (never show approve + execute at same time)
- Show loading spinners during pending transactions: <span className="loading loading-spinner loading-sm" />
- Format token amounts with formatEther/formatUnits, never show raw wei
- Use the Address component from @scaffold-ui/components for displaying addresses
- Keep all existing imports from the SE2 scaffold that are needed (RainbowKit, ThemeProvider, etc.)
- Do NOT modify ScaffoldEthAppWithProviders.tsx or any scaffold-eth/ internal components
- Approve exact amounts or 3-5x, NEVER infinite approvals'

USER_PROMPT="## Build Plan & Design Brief
$JOB_CONTENT

## Smart Contracts (for ABI reference)
$CONTRACT_SOURCES

## External Contracts
$EXTERNAL_INFO

## External Contracts TypeScript (already configured)
$EXTERNAL_CONTRACTS

## Chain: $CHAIN (ID: $CHAIN_ID)

## Existing Files (for reference — modify these, keep working patterns):

--- components/Header.tsx ---
$EXISTING_HEADER

--- components/Footer.tsx ---
$EXISTING_FOOTER

--- app/page.tsx ---
$EXISTING_PAGE

--- app/layout.tsx ---
$EXISTING_LAYOUT

--- styles/globals.css ---
$EXISTING_CSS

Generate all frontend files now. Return ONLY the JSON object."

LLM_OUTPUT=$(llm_call "$MODEL" "$SYSTEM_PROMPT" "$USER_PROMPT" 16384)

if [[ -z "$LLM_OUTPUT" ]]; then
  echo "ERROR: LLM returned no content."
  exit 1
fi

# Validate JSON
if ! echo "$LLM_OUTPUT" | jq . > /dev/null 2>&1; then
  # Try to extract JSON from surrounding text
  EXTRACTED=$(echo "$LLM_OUTPUT" | perl -0777 -ne 'print $1 if /(\{.*\})/s')
  if [[ -n "$EXTRACTED" ]] && echo "$EXTRACTED" | jq . > /dev/null 2>&1; then
    LLM_OUTPUT="$EXTRACTED"
  else
    echo "ERROR: LLM output is not valid JSON."
    echo "Raw output (first 500 chars):"
    echo "$LLM_OUTPUT" | head -c 500
    exit 1
  fi
fi

# ─── Write files ─────────────────────────────────────────────────────────────
FILE_COUNT=0
for FILEPATH in $(echo "$LLM_OUTPUT" | jq -r 'keys[]'); do
  CONTENT=$(echo "$LLM_OUTPUT" | jq -r --arg f "$FILEPATH" '.[$f]')

  # Ensure directory exists
  TARGET="$NEXTJS_DIR/$FILEPATH"
  mkdir -p "$(dirname "$TARGET")"

  echo "$CONTENT" > "$TARGET"
  echo "  Wrote: $FILEPATH"
  FILE_COUNT=$((FILE_COUNT + 1))
done

echo ""
echo "  Wrote $FILE_COUNT file(s)"

# ─── Build-fix loop: yarn next:build ─────────────────────────────────────────
echo ""
echo "  Verifying frontend build..."
verify_fix_loop "$MODEL" "yarn next:build" "$PROJECT_DIR" 3 \
  "$NEXTJS_DIR/app" \
  "$NEXTJS_DIR/components" \
  "$NEXTJS_DIR/styles" \
  "$NEXTJS_DIR/contracts"

echo ""
echo ">>> Step 8 complete."
