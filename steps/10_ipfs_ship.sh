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

# Check for cid-tool (CIDv0 → CIDv1 conversion)
if ! command -v npx &> /dev/null; then
  echo "ERROR: npx not found. Install Node.js."
  exit 1
fi

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
echo "  Uploading to IPFS via bgipfs API..."

# Build curl command with all files from out/
cd "$NEXTJS_DIR/out"
CURL_ARGS=(-s -X POST "https://upload.bgipfs.com/api/v0/add?wrap-with-directory=true&pin=true" -H "X-API-Key: $BGIPFS_API_KEY")

FILE_UPLOAD_COUNT=0
while IFS= read -r -d '' f; do
  REL_PATH="${f#./}"
  CURL_ARGS+=(-F "file=@$f;filename=$REL_PATH")
  FILE_UPLOAD_COUNT=$((FILE_UPLOAD_COUNT + 1))
done < <(find . -type f -print0 | sort -z)

echo "  Uploading $FILE_UPLOAD_COUNT files..."
UPLOAD_OUTPUT=$(curl "${CURL_ARGS[@]}" 2>&1)

# The root directory hash is the last line (empty Name field)
ROOT_HASH=$(echo "$UPLOAD_OUTPUT" | tail -1 | jq -r '.Hash // empty' 2>/dev/null)

if [[ -z "$ROOT_HASH" ]]; then
  echo "  ✗ Upload failed — no root hash returned"
  echo "$UPLOAD_OUTPUT" | tail -5
  exit 1
fi

echo "  ✓ Uploaded to IPFS (CIDv0: $ROOT_HASH)"

# Convert CIDv0 (Qm...) to CIDv1 (bafy...) for subdomain gateway
CID=$(npx -y cid-tool base32 "$ROOT_HASH" 2>/dev/null)
if [[ -z "$CID" ]]; then
  CID="$ROOT_HASH"
fi

IPFS_URL="https://${CID}.ipfs.community.bgipfs.com/"

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
