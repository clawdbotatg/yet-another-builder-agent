#!/usr/bin/env bash
set -euo pipefail

# ─── Step 9: Deploy Contracts to Chain ──────────────────────────────────────
#
# Usage: ./steps/09_deploy_chain.sh <project-name>
#
# Deploys contracts using SE2's yarn deploy flow with foundry keystores.
#
# First run (no keystore):  Uses yarn generate (via expect) to create a
#                           deployer keystore. Saves password + keystore name
#                           to .env. Shows address to fund. Exits.
# Second run (funded):      Pipes password to yarn deploy for non-interactive
#                           deployment through SE2's full flow.
#
# .env vars used:
#   DEPLOYER_PASSWORD  — keystore password (auto-generated on first run)
#   DEPLOYER_KEYSTORE  — keystore name (auto-saved on first run)
#   BASE_RPC_URL       — optional RPC override for Base
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

PROJECT="${1:?Usage: ./steps/09_deploy_chain.sh <project-name>}"

load_params "$PROJECT"

FOUNDRY_DIR="$PROJECT_DIR/packages/foundry"
FOUNDRY_TOML="$FOUNDRY_DIR/foundry.toml"
KEYSTORE_NAME="${DEPLOYER_KEYSTORE:-dapp-builder-deployer}"

echo ">>> Step 9: Deploying contracts to $CHAIN..."
echo "    Project: $PROJECT"
echo "    Chain:   $CHAIN (id: $CHAIN_ID)"
echo ""

cd "$PROJECT_DIR"

# ─── Ensure deployer keystore exists (uses yarn generate) ───────────────────
if [[ ! -f "$HOME/.foundry/keystores/$KEYSTORE_NAME" ]]; then
  echo "  No deployer keystore found. Running yarn generate..."
  echo ""

  # Generate a random password
  DEPLOYER_PASSWORD=$(openssl rand -hex 16)

  # Use expect to drive yarn generate non-interactively:
  #   1. Enters keystore name when prompted
  #   2. Enters password when prompted
  GENERATE_OUTPUT=$(cd "$PROJECT_DIR" && expect -c "
    set timeout 30
    spawn yarn generate
    expect \"Enter name for new keystore:\"
    send \"${KEYSTORE_NAME}\r\"
    expect \"Enter password:\"
    send \"${DEPLOYER_PASSWORD}\r\"
    expect eof
  " 2>&1)

  # Verify keystore was created
  if [[ ! -f "$HOME/.foundry/keystores/$KEYSTORE_NAME" ]]; then
    echo "  ERROR: yarn generate failed to create keystore"
    echo "$GENERATE_OUTPUT"
    exit 1
  fi

  # Extract the address from yarn generate output
  DEPLOYER_ADDR=$(echo "$GENERATE_OUTPUT" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)

  # Save password and keystore name to .env
  if grep -q "^DEPLOYER_PASSWORD=" "$ROOT_DIR/.env" 2>/dev/null; then
    sed -i.bak "s|^DEPLOYER_PASSWORD=.*|DEPLOYER_PASSWORD=$DEPLOYER_PASSWORD|" "$ROOT_DIR/.env"
    rm -f "$ROOT_DIR/.env.bak"
  else
    echo "DEPLOYER_PASSWORD=$DEPLOYER_PASSWORD" >> "$ROOT_DIR/.env"
  fi

  if grep -q "^DEPLOYER_KEYSTORE=" "$ROOT_DIR/.env" 2>/dev/null; then
    sed -i.bak "s|^DEPLOYER_KEYSTORE=.*|DEPLOYER_KEYSTORE=$KEYSTORE_NAME|" "$ROOT_DIR/.env"
    rm -f "$ROOT_DIR/.env.bak"
  else
    echo "DEPLOYER_KEYSTORE=$KEYSTORE_NAME" >> "$ROOT_DIR/.env"
  fi

  echo "  ✓ Keystore created: $KEYSTORE_NAME"
  echo "  ✓ Password saved to .env as DEPLOYER_PASSWORD"
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║  Fund this address on $CHAIN before running this step again:"
  printf "  ║  %-60s║\n" "$DEPLOYER_ADDR"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  After funding, re-run: ./steps/09_deploy_chain.sh $PROJECT"
  exit 0
fi

# ─── Verify we have the password ────────────────────────────────────────────
if [[ -z "${DEPLOYER_PASSWORD:-}" ]]; then
  echo "  ERROR: DEPLOYER_PASSWORD not found in .env"
  echo "  The keystore '$KEYSTORE_NAME' exists but the password is missing."
  echo "  Add DEPLOYER_PASSWORD=<your-password> to .env"
  exit 1
fi

# Show deployer info (like yarn account but non-interactive)
DEPLOYER_ADDR=$(cast wallet address --account "$KEYSTORE_NAME" 2>/dev/null || echo "unknown")
echo "  Keystore: $KEYSTORE_NAME"
echo "  Deployer: $DEPLOYER_ADDR"

# ─── Configure RPC in foundry.toml if needed ────────────────────────────────
case "$CHAIN" in
  base)
    if [[ -n "${BASE_RPC_URL:-}" ]]; then
      if ! grep -q "$BASE_RPC_URL" "$FOUNDRY_TOML" 2>/dev/null; then
        sed -i.bak "s|^base = .*|base = \"$BASE_RPC_URL\"|" "$FOUNDRY_TOML"
        rm -f "$FOUNDRY_TOML.bak"
        echo "  ✓ Updated base RPC in foundry.toml"
      fi
    fi
    ;;
esac

# ─── Deploy via yarn deploy (SE2's full flow) ───────────────────────────────
# yarn deploy --network <chain> --keystore <name> goes through:
#   parseArgs.js → make deploy-and-generate-abis → forge script + generateTsAbis.js
# Pipe password so forge reads it from stdin when it prompts.
echo ""
echo "  Deploying to $CHAIN via yarn deploy..."

echo "$DEPLOYER_PASSWORD" | yarn deploy --network "$CHAIN" --keystore "$KEYSTORE_NAME"
DEPLOY_EXIT=$?

if [[ $DEPLOY_EXIT -ne 0 ]]; then
  echo ""
  echo "  ✗ Deployment failed (exit $DEPLOY_EXIT)"
  exit 1
fi

echo ""
echo "  ✓ Contracts deployed + ABIs generated"

# ─── Verify contracts on block explorer ──────────────────────────────────────
echo ""
echo "  Verifying contracts..."
echo "$DEPLOYER_PASSWORD" | yarn verify --network "$CHAIN" 2>&1 || true

# Show deployed addresses
BROADCAST_DIR="$FOUNDRY_DIR/broadcast/Deploy.s.sol/$CHAIN_ID"
if [[ -d "$BROADCAST_DIR" ]]; then
  for SOL_FILE in "$FOUNDRY_DIR/contracts"/*.sol; do
    [[ -f "$SOL_FILE" ]] || continue
    CONTRACT_NAME=$(basename "$SOL_FILE" .sol)
    DEPLOYED_ADDR=$(jq -r --arg name "$CONTRACT_NAME" \
      '.transactions[] | select(.contractName == $name) | .contractAddress' \
      "$BROADCAST_DIR/run-latest.json" 2>/dev/null | head -1)

    if [[ -n "$DEPLOYED_ADDR" && "$DEPLOYED_ADDR" != "null" ]]; then
      echo "  $CONTRACT_NAME deployed at $DEPLOYED_ADDR"
    fi
  done
fi

# ─── Check deployedContracts.ts was updated ──────────────────────────────────
DEPLOYED_TS="$PROJECT_DIR/packages/nextjs/contracts/deployedContracts.ts"
if [[ -f "$DEPLOYED_TS" ]] && grep -q "$CHAIN_ID" "$DEPLOYED_TS"; then
  echo "  ✓ deployedContracts.ts updated with chain $CHAIN_ID"
else
  echo "  ⚠ deployedContracts.ts may not have been updated"
fi

echo ""
echo ">>> Step 9 complete."
