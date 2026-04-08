#!/usr/bin/env bash
set -euo pipefail

# ─── Step 1: Parse Job ──────────────────────────────────────────────────────
#
# Usage: ./steps/01_parse_job.sh <model> [job-file]
#
# Sends job.md to an LLM to extract structured build parameters.
#
# Inputs:
#   <model>     LLM model ID (e.g. minimax-m2.7, claude-sonnet-4-20250514)
#   [job-file]  Path to job spec (default: ./job.md)
#
# Outputs:
#   builds/<project-name>/params.json  — structured build parameters
#   builds/<project-name>/job.md       — copy of the job spec
#
# Success: jq .project_name builds/<project-name>/params.json returns a value
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

MODEL="${1:?Usage: ./steps/01_parse_job.sh <model> [job-file]}"
JOB_FILE="${2:-$ROOT_DIR/job.md}"

if [[ ! -f "$JOB_FILE" ]]; then
  echo "ERROR: Job file not found: $JOB_FILE"
  exit 1
fi

echo ">>> Step 1: Parsing job.md to extract build parameters..."
echo "    Model: $MODEL"
echo "    Job:   $JOB_FILE"
echo ""

JOB_CONTENT=$(cat "$JOB_FILE")

SYSTEM_PROMPT='You are a build parameter extractor for Ethereum dApp projects.

Given a dApp build plan, extract EXACTLY these fields and return ONLY valid JSON with no markdown fencing, no explanation, no extra text:

{
  "project_name": "kebab-case name derived from the project title",
  "chain": "the target chain (e.g. base, mainnet, arbitrum, optimism, sepolia)",
  "chain_id": the numeric chain ID (e.g. 8453 for base, 1 for mainnet),
  "framework": "foundry or hardhat (default foundry)",
  "external_contracts": [
    {
      "name": "human readable name",
      "address": "0x...",
      "description": "what this contract is"
    }
  ],
  "contract_names": ["list of new contracts to write"],
  "description": "one sentence summary of what this dapp does"
}

Rules:
- project_name must be kebab-case, short, no special chars
- If the plan mentions Foundry or Forge, framework is "foundry". If Hardhat, use "hardhat". Default to "foundry".
- Extract ALL external contract addresses mentioned (tokens, protocols, etc.)
- contract_names should list the new Solidity contracts that need to be written
- Return ONLY the JSON object. No markdown. No backticks. No explanation.'

LLM_OUTPUT=$(llm_call "$MODEL" "$SYSTEM_PROMPT" "$JOB_CONTENT")

if [[ -z "$LLM_OUTPUT" ]]; then
  echo "ERROR: LLM returned no content."
  exit 1
fi

# Strip any markdown fencing the LLM might add despite instructions
PARAMS=$(echo "$LLM_OUTPUT" | sed 's/^```json//; s/^```//; s/```$//' | jq . 2>/dev/null)

if [[ -z "$PARAMS" ]]; then
  echo "ERROR: LLM output is not valid JSON."
  echo "Raw output:"
  echo "$LLM_OUTPUT"
  exit 1
fi

# Display
PROJECT_NAME=$(echo "$PARAMS" | jq -r '.project_name')
CHAIN=$(echo "$PARAMS" | jq -r '.chain')
CHAIN_ID=$(echo "$PARAMS" | jq -r '.chain_id')
FRAMEWORK=$(echo "$PARAMS" | jq -r '.framework')
DESCRIPTION=$(echo "$PARAMS" | jq -r '.description')
CONTRACT_COUNT=$(echo "$PARAMS" | jq '.contract_names | length')
EXTERNAL_COUNT=$(echo "$PARAMS" | jq '.external_contracts | length')

echo "  Project:    $PROJECT_NAME"
echo "  Chain:      $CHAIN (id: $CHAIN_ID)"
echo "  Framework:  $FRAMEWORK"
echo "  Contracts:  $CONTRACT_COUNT to write"
echo "  External:   $EXTERNAL_COUNT referenced"
echo "  Summary:    $DESCRIPTION"
echo ""

# Save
BUILD_DIR="$BUILDS_DIR/$PROJECT_NAME"
mkdir -p "$BUILD_DIR"
echo "$PARAMS" > "$BUILD_DIR/params.json"
cp "$JOB_FILE" "$BUILD_DIR/job.md"

echo "  Saved: $BUILD_DIR/params.json"
echo "  Saved: $BUILD_DIR/job.md"
echo ""
echo ">>> Step 1 complete."
