#!/usr/bin/env bash
set -euo pipefail

# ─── Step 10: Build and Ship to IPFS ────────────────────────────────────────
#
# Usage: ./steps/10_ipfs_ship.sh <project-name>
#
# Builds the Next.js frontend for static export and uploads to IPFS via bgipfs.
#
# Inputs:
#   <project-name>  From params.json
#   Requires: BGIPFS_API_KEY in .env
#
# Outputs:
#   Static build in packages/nextjs/out/
#   IPFS CID
#   Live URL: https://<CID>.ipfs.community.bgipfs.com/
#
# Success: curl of the IPFS URL returns HTML
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

PROJECT="${1:?Usage: ./steps/10_ipfs_ship.sh <project-name>}"

load_params "$PROJECT"

NEXTJS_DIR="$PROJECT_DIR/packages/nextjs"

echo ">>> Step 10: Building and shipping to IPFS..."
echo "    Project: $PROJECT"
echo ""

# ─── Check prerequisites ────────────────────────────────────────────────────
if [[ -z "${BGIPFS_API_KEY:-}" ]]; then
  echo "ERROR: BGIPFS_API_KEY not set. Add it to .env."
  exit 1
fi

# Check bgipfs is installed
if ! command -v bgipfs &> /dev/null; then
  echo "  Installing bgipfs..."
  npm install -g bgipfs 2>&1 | tail -3
fi

# ─── Configure bgipfs credentials ───────────────────────────────────────────
BGIPFS_CONFIG_DIR="$HOME/.bgipfs"
BGIPFS_CREDS="$BGIPFS_CONFIG_DIR/credentials.json"

mkdir -p "$BGIPFS_CONFIG_DIR"
cat > "$BGIPFS_CREDS" << EOF
{
  "url": "https://upload.bgipfs.com",
  "headers": {
    "X-API-Key": "$BGIPFS_API_KEY"
  }
}
EOF
echo "  ✓ bgipfs credentials configured"

# ─── Create polyfill for Node 25+ localStorage issue ────────────────────────
POLYFILL_FILE="$NEXTJS_DIR/polyfill-localstorage.cjs"
cat > "$POLYFILL_FILE" << 'POLYFILL'
if (typeof globalThis.localStorage !== "undefined" &&
    typeof globalThis.localStorage.getItem !== "function") {
  const store = new Map();
  globalThis.localStorage = {
    getItem: (key) => store.get(key) ?? null,
    setItem: (key, value) => store.set(key, String(value)),
    removeItem: (key) => store.delete(key),
    clear: () => store.clear(),
    key: (index) => [...store.keys()][index] ?? null,
    get length() { return store.size; },
  };
}
POLYFILL
echo "  ✓ localStorage polyfill created"

# ─── Build for IPFS ─────────────────────────────────────────────────────────
echo ""
echo "  Building for IPFS (static export)..."
cd "$NEXTJS_DIR"

# Clean previous builds
rm -rf .next out

# Build with IPFS flag and polyfill
BUILD_OUTPUT=$(NEXT_PUBLIC_IPFS_BUILD=true \
  NODE_OPTIONS="--require ./polyfill-localstorage.cjs" \
  npm run build 2>&1) || true

if [[ ! -d "$NEXTJS_DIR/out" ]]; then
  echo "  ✗ Build failed — out/ directory not created"
  echo "$BUILD_OUTPUT" | tail -20
  exit 1
fi

FILE_COUNT=$(find "$NEXTJS_DIR/out" -type f | wc -l | tr -d ' ')
echo "  ✓ Build succeeded ($FILE_COUNT files in out/)"

# ─── Upload to IPFS ─────────────────────────────────────────────────────────
echo ""
echo "  Uploading to IPFS via bgipfs..."
UPLOAD_OUTPUT=$(bgipfs upload "$NEXTJS_DIR/out" --config "$BGIPFS_CREDS" 2>&1)

# Extract CID from output
CID=$(echo "$UPLOAD_OUTPUT" | grep -oE 'bafy[a-zA-Z0-9]+' | head -1)

if [[ -z "$CID" ]]; then
  echo "  ✗ Upload failed — no CID returned"
  echo "$UPLOAD_OUTPUT"
  exit 1
fi

IPFS_URL="https://${CID}.ipfs.community.bgipfs.com/"

echo "  ✓ Uploaded to IPFS"
echo ""
echo "  CID:  $CID"
echo "  URL:  $IPFS_URL"

# ─── Verify deployment ──────────────────────────────────────────────────────
echo ""
echo "  Verifying deployment..."
sleep 3  # Give IPFS gateway a moment

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$IPFS_URL" 2>/dev/null || echo "000")

if [[ "$HTTP_STATUS" == "200" ]]; then
  echo "  ✓ Site is live! HTTP $HTTP_STATUS"
else
  echo "  ⚠ HTTP $HTTP_STATUS — may take a moment to propagate"
fi

# ─── Save deployment info ───────────────────────────────────────────────────
DEPLOY_INFO="$BUILDS_DIR/$PROJECT/deployment.json"
jq -n \
  --arg cid "$CID" \
  --arg url "$IPFS_URL" \
  --arg chain "$CHAIN" \
  --arg chain_id "$CHAIN_ID" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    cid: $cid,
    url: $url,
    chain: $chain,
    chain_id: $chain_id,
    deployed_at: $timestamp
  }' > "$DEPLOY_INFO"

echo ""
echo "  Saved: $DEPLOY_INFO"

echo ""
echo "========================================="
echo " DEPLOYED"
echo " $IPFS_URL"
echo "========================================="
echo ""
echo ">>> Step 10 complete."
