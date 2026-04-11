#!/usr/bin/env bash
set -euo pipefail

# ─── Step 9b: QA Audit ─────────────────────────────────────────────────────
#
# Usage: ./steps/09b_qa_audit.sh <model> <project-name> [max-retries]
#
# Runs automated QA checks against the built frontend following the
# dApp QA Pre-Ship Audit skill (ethskills.com/qa/SKILL.md).
#
# Reports PASS/FAIL for each item. On critical failures, sends the
# failing code to the LLM for auto-fix, then re-checks. Loops up
# to max-retries times.
#
# Must run AFTER Step 8 (frontend) and Step 9 (deploy).
# Must run BEFORE Step 10 (IPFS ship).
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

MODEL="${1:?Usage: ./steps/09b_qa_audit.sh <model> <project-name> [max-retries]}"
PROJECT="${2:?Usage: ./steps/09b_qa_audit.sh <model> <project-name> [max-retries]}"
MAX_RETRIES="${3:-3}"

load_params "$PROJECT"

NEXTJS_DIR="$PROJECT_DIR/packages/nextjs"
FOUNDRY_DIR="$PROJECT_DIR/packages/foundry"
APP_DIR="$NEXTJS_DIR/app"
COMP_DIR="$NEXTJS_DIR/components"
STYLES_DIR="$NEXTJS_DIR/styles"
CONTRACTS_DIR="$NEXTJS_DIR/contracts"

echo ">>> Step 9b: QA Audit..."
echo "    Model:   $MODEL"
echo "    Project: $PROJECT"
echo ""

# ─── Checklist manifest ─────────────────────────────────────────────────────
# Every line item from the QA skill summary (ethskills.com/qa/SKILL.md).
# The script MUST run exactly this many checks. If EXPECTED != actual,
# something was skipped.
EXPECTED_CHECKS=21
# Ship-blocking:
#  1. Wallet connection shows a BUTTON, not text
#  2. Wrong network shows a Switch button (covered by RainbowKitCustomConnectButton)
#  3. One button at a time (Connect → Network → Approve → Action)
#     — checks 2+3 collapsed into check 2 (useScaffoldWriteContract) + check 3 (approve disabled)
#  4. Approve button disabled with spinner through block confirmation
#  5. Contracts verified on block explorer
#  6. SE2 footer branding removed
#  7. SE2 tab title removed
#  8. SE2 README replaced
# Important:
#  9.  Contract address displayed with <Address/>
#  10. Every address input uses <AddressInput/>
#  11. USD values next to token amounts (hard to automate — heuristic)
#  12. OG image is absolute production URL
#  13. pollingInterval is 3000
#  14. Favicon updated from SE2 default
#  15. --radius-field changed from 9999rem
#  16. Error messages human-readable — no silent catches, no raw hex selectors
#  17. No hardcoded dark backgrounds
#  18. Button loaders use inline spinner
#  19. Phantom wallet in RainbowKit
#  20. Mobile deep linking for wallet
#  21. Approve cooldown (prevents button flicker)
# Note: some skill items are collapsed (wrong network + one-button-at-a-time
# are structurally guaranteed by RainbowKitCustomConnectButton + useScaffoldWriteContract).
# Net unique automated checks: 19

# ─── Check functions ────────────────────────────────────────────────────────
CRITICAL_FAILS=0
IMPORTANT_FAILS=0
PASSES=0
REPORT=""
CHECK_COUNT=0

check() {
  local severity="$1"
  local name="$2"
  local result="$3"
  local detail="${4:-}"

  CHECK_COUNT=$((CHECK_COUNT + 1))
  if [[ "$result" == "PASS" ]]; then
    echo "  ✓ PASS: $name"
    REPORT="$REPORT\n  ✓ PASS: $name"
    PASSES=$((PASSES + 1))
  else
    if [[ "$severity" == "CRITICAL" ]]; then
      echo "  ✗ FAIL [CRITICAL]: $name"
      REPORT="$REPORT\n  ✗ FAIL [CRITICAL]: $name"
      CRITICAL_FAILS=$((CRITICAL_FAILS + 1))
    else
      echo "  ✗ FAIL [IMPORTANT]: $name"
      REPORT="$REPORT\n  ✗ FAIL [IMPORTANT]: $name"
      IMPORTANT_FAILS=$((IMPORTANT_FAILS + 1))
    fi
    if [[ -n "$detail" ]]; then
      echo "         $detail"
      REPORT="$REPORT\n         $detail"
    fi
  fi
}

# ─── Run all checks ────────────────────────────────────────────────────────

run_qa_checks() {
  CRITICAL_FAILS=0
  IMPORTANT_FAILS=0
  PASSES=0
  CHECK_COUNT=0
  REPORT=""

  echo "  ── Ship-Blocking Checks ──"
  echo ""

  # 1. CRITICAL: Wallet connection shows a BUTTON, not text
  # Look for "connect your wallet", "please connect", "connect to continue" as text
  WALLET_TEXT_MATCHES=$(grep -rnil "connect your wallet\|please connect\|connect to continue\|connect wallet to" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -v "node_modules" | grep -v "RainbowKit" || true)
  # Check if it's inside a <p>, <span>, <div> text (not a button)
  if [[ -n "$WALLET_TEXT_MATCHES" ]]; then
    # Look more specifically for text-only (not in a button)
    PLAIN_TEXT=$(grep -rnl ">\s*connect\|>\s*Connect\|>\s*Please connect" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
      | grep -v "node_modules" | grep -v "RainbowKit" || true)
    # Check if RainbowKitCustomConnectButton is also rendered for disconnected state
    HAS_CONNECT_BTN=$(grep -rn "RainbowKitCustomConnectButton" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
      | grep -v "node_modules" | grep -v "import" || true)
    if [[ -n "$PLAIN_TEXT" && -z "$HAS_CONNECT_BTN" ]]; then
      check "CRITICAL" "Wallet connection shows BUTTON not text" "FAIL" "Found text prompts without connect button: $PLAIN_TEXT"
    else
      check "CRITICAL" "Wallet connection shows BUTTON not text" "PASS"
    fi
  else
    check "CRITICAL" "Wallet connection shows BUTTON not text" "PASS"
  fi

  # 2. CRITICAL: No raw useWriteContract (should use useScaffoldWriteContract)
  RAW_WRITE=$(grep -rn "useWriteContract" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -v "node_modules" | grep -v "scaffold-eth" | grep -v "useScaffoldWriteContract" || true)
  if [[ -n "$RAW_WRITE" ]]; then
    check "CRITICAL" "Uses useScaffoldWriteContract (not raw wagmi)" "FAIL" "Found raw useWriteContract: $(echo "$RAW_WRITE" | head -3)"
  else
    check "CRITICAL" "Uses useScaffoldWriteContract (not raw wagmi)" "PASS"
  fi

  # 3. CRITICAL: Approve button has isPending/disabled state
  # Check that buttons in components use disabled={isPending} or similar
  APPROVE_NO_DISABLE=$(grep -rn "Approv" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -i "button\|btn" | grep -v "disabled" | grep -v "node_modules" | grep -v "import" || true)
  APPROVE_HAS_DISABLE=$(grep -rn "Approv" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -i "disabled" | grep -v "node_modules" || true)
  if [[ -n "$APPROVE_NO_DISABLE" && -z "$APPROVE_HAS_DISABLE" ]]; then
    check "CRITICAL" "Approve button disabled during pending" "FAIL" "Approve button without disabled prop"
  else
    check "CRITICAL" "Approve button disabled during pending" "PASS"
  fi

  # 4. CRITICAL: SE2 footer branding removed
  FOOTER_FILE=$(find "$COMP_DIR" -name "Footer.tsx" -not -path "*/node_modules/*" 2>/dev/null | head -1)
  if [[ -n "$FOOTER_FILE" ]]; then
    SE2_FOOTER=$(grep -i "buidlguidl\|scaffold-eth\|SE2\|Fork me" "$FOOTER_FILE" 2>/dev/null || true)
    if [[ -n "$SE2_FOOTER" ]]; then
      check "CRITICAL" "SE2 footer branding removed" "FAIL" "Found in Footer.tsx: $(echo "$SE2_FOOTER" | head -2)"
    else
      check "CRITICAL" "SE2 footer branding removed" "PASS"
    fi
  else
    check "CRITICAL" "SE2 footer branding removed" "PASS"
  fi

  # 5. CRITICAL: SE2 tab title removed
  LAYOUT_FILE="$APP_DIR/layout.tsx"
  if [[ -f "$LAYOUT_FILE" ]]; then
    SE2_TITLE=$(grep -i "Scaffold-ETH\|SE-2 App\|SE2" "$LAYOUT_FILE" 2>/dev/null | grep -v "import\|from\|scaffold-eth/" || true)
    if [[ -n "$SE2_TITLE" ]]; then
      check "CRITICAL" "SE2 tab title removed" "FAIL" "Found SE2 references in layout.tsx"
    else
      check "CRITICAL" "SE2 tab title removed" "PASS"
    fi
  else
    check "CRITICAL" "SE2 tab title removed" "PASS"
  fi

  # 6. CRITICAL: Contract verification on block explorer
  DEPLOYED_TS="$CONTRACTS_DIR/deployedContracts.ts"
  if [[ -f "$DEPLOYED_TS" ]] && grep -q "$CHAIN_ID" "$DEPLOYED_TS"; then
    VERIFIED_OK=true
    for SOL_FILE in "$FOUNDRY_DIR/contracts"/*.sol; do
      [[ -f "$SOL_FILE" ]] || continue
      CONTRACT_NAME=$(basename "$SOL_FILE" .sol)
      BROADCAST_DIR="$FOUNDRY_DIR/broadcast/Deploy.s.sol/$CHAIN_ID"
      DEPLOYED_ADDR=$(jq -r --arg name "$CONTRACT_NAME" \
        '.transactions[] | select(.contractName == $name) | .contractAddress' \
        "$BROADCAST_DIR/run-latest.json" 2>/dev/null | head -1)

      if [[ -n "$DEPLOYED_ADDR" && "$DEPLOYED_ADDR" != "null" ]]; then
        # Check verification by running yarn verify and checking output
        # The forge verify-check will say "already verified" if it's good
        VERIFY_CHECK=$(cd "$PROJECT_DIR" && KEYSTORE_PASSWORD="${DEPLOYER_PASSWORD:-}" yarn verify --network "$CHAIN" 2>&1 || true)
        if echo "$VERIFY_CHECK" | grep -qi "already verified\|successfully verified"; then
          true  # verified
        else
          VERIFIED_OK=false
          check "CRITICAL" "Contract verified: $CONTRACT_NAME ($DEPLOYED_ADDR)" "FAIL" "Not verified on block explorer"
        fi
      fi
    done
    if $VERIFIED_OK; then
      check "CRITICAL" "Contracts verified on block explorer" "PASS"
    fi
  else
    check "CRITICAL" "Contracts verified on block explorer" "FAIL" "deployedContracts.ts missing or no chain $CHAIN_ID"
  fi

  echo ""
  echo "  ── Important Checks ──"
  echo ""

  # 7. IMPORTANT: Contract address displayed with <Address/>
  ADDR_DISPLAY=$(grep -rn "<Address " "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -v "node_modules" | grep -v "scaffold-eth" | grep -v "AddressInput" || true)
  if [[ -z "$ADDR_DISPLAY" ]]; then
    check "IMPORTANT" "Contract address displayed with <Address/>" "FAIL" "No <Address/> component usage found in app/components"
  else
    check "IMPORTANT" "Contract address displayed with <Address/>" "PASS"
  fi

  # 8. IMPORTANT: AddressInput instead of raw input for addresses
  RAW_ADDR_INPUT=$(grep -rn 'type="text"' "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -iE "addr|owner|recip|0x" | grep -v "node_modules" || true)
  RAW_PLACEHOLDER=$(grep -rn 'placeholder="0x' "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -v "AddressInput" | grep -v "node_modules" || true)
  if [[ -n "$RAW_ADDR_INPUT" || -n "$RAW_PLACEHOLDER" ]]; then
    check "IMPORTANT" "Address inputs use <AddressInput/>" "FAIL" "Found raw text input for addresses"
  else
    check "IMPORTANT" "Address inputs use <AddressInput/>" "PASS"
  fi

  # 9. IMPORTANT: OG image is absolute URL
  if [[ -f "$LAYOUT_FILE" ]]; then
    OG_RELATIVE=$(grep -n "images:" "$LAYOUT_FILE" 2>/dev/null | grep -v "https://" || true)
    if [[ -n "$OG_RELATIVE" ]]; then
      check "IMPORTANT" "OG image is absolute URL" "FAIL" "Relative path in og:image"
    else
      check "IMPORTANT" "OG image is absolute URL" "PASS"
    fi
  else
    check "IMPORTANT" "OG image is absolute URL" "PASS"
  fi

  # 10. IMPORTANT: pollingInterval is 3000 (not 30000)
  SCAFFOLD_CONFIG="$NEXTJS_DIR/scaffold.config.ts"
  if [[ -f "$SCAFFOLD_CONFIG" ]]; then
    POLLING=$(grep "pollingInterval" "$SCAFFOLD_CONFIG" 2>/dev/null || true)
    if echo "$POLLING" | grep -q "30000"; then
      check "IMPORTANT" "pollingInterval is 3000" "FAIL" "Still using default 30000ms"
    else
      check "IMPORTANT" "pollingInterval is 3000" "PASS"
    fi
  fi

  # 11. IMPORTANT: Favicon updated from SE2 default
  # SE2's default favicon is at public/favicon.ico — check if it's the template one
  # We check if the file is exactly the SE2 default by size (SE2 default is ~15KB)
  FAVICON="$NEXTJS_DIR/public/favicon.ico"
  if [[ -f "$FAVICON" ]]; then
    # The SE2 default favicon has a specific size — flag if unchanged
    # (Heuristic: just note it for review since we can't easily compare)
    check "IMPORTANT" "Favicon updated from SE2 default" "FAIL" "favicon.ico exists but may be SE2 default — verify manually"
  else
    check "IMPORTANT" "Favicon updated from SE2 default" "PASS"
  fi

  # 12. IMPORTANT: --radius-field not 9999rem (pill-shaped inputs)
  GLOBALS_CSS="$STYLES_DIR/globals.css"
  if [[ -f "$GLOBALS_CSS" ]]; then
    PILL_RADIUS=$(grep "radius-field.*9999" "$GLOBALS_CSS" 2>/dev/null || true)
    if [[ -n "$PILL_RADIUS" ]]; then
      check "IMPORTANT" "No pill-shaped inputs (--radius-field)" "FAIL" "Found --radius-field: 9999rem in globals.css"
    else
      check "IMPORTANT" "No pill-shaped inputs (--radius-field)" "PASS"
    fi
  else
    check "IMPORTANT" "No pill-shaped inputs (--radius-field)" "PASS"
  fi

  # 13. IMPORTANT: No hardcoded dark backgrounds on root wrappers
  HARDCODED_DARK=$(grep -rn 'bg-\[#0\|bg-black\|bg-gray-9\|bg-zinc-9\|bg-neutral-9\|bg-slate-9' "$APP_DIR" 2>/dev/null \
    | grep -v "node_modules" || true)
  if [[ -n "$HARDCODED_DARK" ]]; then
    # Check if data-theme="dark" is forced AND SwitchTheme is removed (acceptable)
    FORCED_THEME=$(grep -r 'data-theme="dark"\|data-theme=.dark' "$APP_DIR/layout.tsx" 2>/dev/null || true)
    SWITCH_THEME=$(grep -rn "SwitchTheme" "$COMP_DIR/Header.tsx" 2>/dev/null || true)
    if [[ -n "$FORCED_THEME" && -z "$SWITCH_THEME" ]]; then
      check "IMPORTANT" "No hardcoded dark backgrounds (or theme forced)" "PASS"
    else
      check "IMPORTANT" "No hardcoded dark backgrounds" "FAIL" "Hardcoded dark bg in app/: $(echo "$HARDCODED_DARK" | head -3)"
    fi
  else
    check "IMPORTANT" "No hardcoded dark backgrounds" "PASS"
  fi

  # 14. IMPORTANT: Button loading uses inline spinner, not className="loading"
  BTN_LOADING_CLASS=$(grep -rn '"loading"' "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -i "btn\|button\|className" | grep -v "loading-spinner\|loading loading-spinner\|loading-sm\|loading-md" \
    | grep -v "node_modules" | grep -v "scaffold-eth" || true)
  # Also check for the pattern: className={`... ${isPending ? "loading" : ""}`}
  BTN_LOADING_TERNARY=$(grep -rn 'loading.*:.*""' "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -i "btn\|className" | grep -v "loading-spinner" | grep -v "node_modules" | grep -v "scaffold-eth" || true)
  if [[ -n "$BTN_LOADING_CLASS" || -n "$BTN_LOADING_TERNARY" ]]; then
    check "IMPORTANT" "Button loaders use inline spinner" "FAIL" "Found DaisyUI 'loading' class on button"
  else
    check "IMPORTANT" "Button loaders use inline spinner" "PASS"
  fi

  # 15. IMPORTANT: Phantom wallet in RainbowKit
  WAGMI_CONNECTORS="$NEXTJS_DIR/services/web3/wagmiConnectors.tsx"
  if [[ -f "$WAGMI_CONNECTORS" ]]; then
    PHANTOM=$(grep -i "phantom" "$WAGMI_CONNECTORS" 2>/dev/null || true)
    if [[ -z "$PHANTOM" ]]; then
      check "IMPORTANT" "Phantom wallet in RainbowKit" "FAIL" "phantomWallet not found in wagmiConnectors.tsx"
    else
      check "IMPORTANT" "Phantom wallet in RainbowKit" "PASS"
    fi
  else
    check "IMPORTANT" "Phantom wallet in RainbowKit" "FAIL" "wagmiConnectors.tsx not found"
  fi

  # 16. IMPORTANT: SE2 README replaced
  README="$PROJECT_DIR/README.md"
  if [[ -f "$README" ]]; then
    SE2_README=$(grep -i "Scaffold-ETH 2\|scaffold-eth-2\|create-eth" "$README" 2>/dev/null | head -3 || true)
    if [[ -n "$SE2_README" ]]; then
      check "IMPORTANT" "SE2 README replaced" "FAIL" "README still contains SE2 template content"
    else
      check "IMPORTANT" "SE2 README replaced" "PASS"
    fi
  else
    check "IMPORTANT" "SE2 README replaced" "PASS"
  fi

  # 17. IMPORTANT: Mobile deep linking for write calls
  DEEP_LINK=$(grep -rn "openWallet\|deep.link\|rainbow://\|metamask://\|cbwallet://" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -v "node_modules" || true)
  if [[ -z "$DEEP_LINK" ]]; then
    check "IMPORTANT" "Mobile deep linking for wallet" "FAIL" "No wallet deep linking found — mobile users must manually switch apps"
  else
    check "IMPORTANT" "Mobile deep linking for wallet" "PASS"
  fi

  # 18. IMPORTANT: Approve cooldown (post-submit allowance refresh gap)
  APPROVE_COOLDOWN=$(grep -rn "cooldown\|Cooldown\|setTimeout.*approv\|setTimeout.*refetch" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -v "node_modules" || true)
  if [[ -z "$APPROVE_COOLDOWN" ]]; then
    # Only flag if there IS an approve flow
    HAS_APPROVE=$(grep -rn "approve\|Approve" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
      | grep -v "node_modules" | grep -v "import" | head -1 || true)
    if [[ -n "$HAS_APPROVE" ]]; then
      check "IMPORTANT" "Approve cooldown (prevents button flicker)" "FAIL" "No cooldown after approve tx — button may flicker back"
    else
      check "IMPORTANT" "Approve cooldown (prevents button flicker)" "PASS"
    fi
  else
    check "IMPORTANT" "Approve cooldown (prevents button flicker)" "PASS"
  fi

  # 19. IMPORTANT: Error messages human-readable — no silent catches, no raw hex selectors
  # Check 1: catch blocks must use notification (not just console.error or empty)
  SILENT_CATCH=$(grep -rn "catch" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -v "node_modules" | grep -v "scaffold-eth" | grep -v "import" || true)
  HAS_NOTIFICATION=$(grep -rn "notification\.\|getParsedError" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -v "node_modules" | grep -v "scaffold-eth" | grep -v "import" || true)
  # Check 2: contract errors are mapped to human-readable strings
  # Look for error name mappings or getParsedError usage
  HAS_ERROR_MAP=$(grep -rn "getParsedError\|errorMessages\|errorMap\|error.*message\|error.*human\|error.*readable" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -v "node_modules" | grep -v "scaffold-eth" || true)

  if [[ -n "$SILENT_CATCH" && -z "$HAS_NOTIFICATION" ]]; then
    check "IMPORTANT" "Error messages human-readable (not raw hex)" "FAIL" "catch blocks found but no notification/getParsedError usage — errors are silent or show raw hex"
  elif [[ -n "$SILENT_CATCH" && -n "$HAS_NOTIFICATION" && -z "$HAS_ERROR_MAP" ]]; then
    # Has notifications but no explicit error mapping — might show raw errors
    # Check if there are console.error-only catch blocks alongside notification ones
    CONSOLE_ONLY_CATCH=$(grep -rn "console.error" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
      | grep -v "node_modules" | grep -v "scaffold-eth" || true)
    NOTIFICATION_COUNT=$(echo "$HAS_NOTIFICATION" | wc -l | tr -d ' ')
    CATCH_COUNT=$(echo "$SILENT_CATCH" | wc -l | tr -d ' ')
    if [[ "$NOTIFICATION_COUNT" -lt "$CATCH_COUNT" ]]; then
      check "IMPORTANT" "Error messages human-readable (not raw hex)" "FAIL" "Some catch blocks use notification but others only console.error — all user-facing errors must show readable messages"
    else
      check "IMPORTANT" "Error messages human-readable (not raw hex)" "PASS"
    fi
  elif [[ -z "$SILENT_CATCH" ]]; then
    # No catch blocks at all — pass (no error handling needed or everything uses .then)
    check "IMPORTANT" "Error messages human-readable (not raw hex)" "PASS"
  else
    check "IMPORTANT" "Error messages human-readable (not raw hex)" "PASS"
  fi

  # 20. CRITICAL: No zero-address placeholder in frontend code
  # 0x000...0 in components/app means a placeholder was never replaced with the real address.
  ZERO_ADDR=$(grep -rn "0x0000000000000000000000000000000000000000" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
    | grep -v "node_modules" \
    | grep -v "BURN_ADDRESS\|burnAddress\|deadAddr\|zeroAddress\|ZeroAddress\|address(0)" \
    | grep -v "//.*0x000\|#.*0x000" \
    || true)
  if [[ -n "$ZERO_ADDR" ]]; then
    check "CRITICAL" "No zero-address placeholder in frontend" "FAIL" "Found: $(echo "$ZERO_ADDR" | head -3)"
  else
    check "CRITICAL" "No zero-address placeholder in frontend" "PASS"
  fi

  # 21. CRITICAL: Deployed contract addresses not hardcoded as literals in components
  # Addresses should come from useDeployedContractInfo — never from string literals in component files.
  DEPLOYED_ADDRS=$(grep -oE '"0x[0-9a-fA-F]{40}"' "$CONTRACTS_DIR/deployedContracts.ts" 2>/dev/null \
    | tr -d '"' | sort -u || true)
  ADDR_HARDCODE_FAIL=false
  ADDR_HARDCODE_DETAIL=""
  for addr in $DEPLOYED_ADDRS; do
    ADDR_IN_COMPONENTS=$(grep -rn "$addr" "$APP_DIR" "$COMP_DIR" 2>/dev/null \
      | grep -v "node_modules" | grep -v "import" || true)
    if [[ -n "$ADDR_IN_COMPONENTS" ]]; then
      ADDR_HARDCODE_FAIL=true
      ADDR_HARDCODE_DETAIL="$addr hardcoded in: $(echo "$ADDR_IN_COMPONENTS" | head -2)"
      break
    fi
  done
  if $ADDR_HARDCODE_FAIL; then
    check "CRITICAL" "Deployed addresses not hardcoded in components" "FAIL" "$ADDR_HARDCODE_DETAIL"
  else
    check "CRITICAL" "Deployed addresses not hardcoded in components" "PASS"
  fi

  # ─── Count guard ──────────────────────────────────────────────────────────
  if [[ $CHECK_COUNT -ne $EXPECTED_CHECKS ]]; then
    echo ""
    echo "  ⚠ CHECK COUNT MISMATCH: ran $CHECK_COUNT checks but expected $EXPECTED_CHECKS"
    echo "    A check was added or removed without updating EXPECTED_CHECKS."
    echo "    This is a script bug — fix before trusting results."
  fi
}

# ─── Initial check run ─────────────────────────────────────────────────────
run_qa_checks

echo ""
echo "  ── Summary ──"
echo "  Passed: $PASSES | Critical fails: $CRITICAL_FAILS | Important fails: $IMPORTANT_FAILS"
echo ""

# ─── Auto-fix loop for failures ────────────────────────────────────────────
ATTEMPT=0
while [[ $((CRITICAL_FAILS + IMPORTANT_FAILS)) -gt 0 && $ATTEMPT -lt $MAX_RETRIES ]]; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "  ── Auto-fix attempt $ATTEMPT of $MAX_RETRIES ──"
  echo ""

  # Gather all frontend source files for context
  SOURCES=""
  for f in $(find "$APP_DIR" "$COMP_DIR" "$STYLES_DIR" "$NEXTJS_DIR/services" -maxdepth 3 -type f \( -name "*.tsx" -o -name "*.ts" -o -name "*.css" \) ! -path "*/node_modules/*" 2>/dev/null | sort); do
    relpath="${f#$PROJECT_DIR/}"
    SOURCES="$SOURCES
--- $relpath ---
$(cat "$f")
"
  done

  # Also include scaffold.config.ts and wagmiConnectors
  for f in "$NEXTJS_DIR/scaffold.config.ts" "$NEXTJS_DIR/services/web3/wagmiConnectors.tsx"; do
    if [[ -f "$f" ]]; then
      relpath="${f#$PROJECT_DIR/}"
      SOURCES="$SOURCES
--- $relpath ---
$(cat "$f")
"
    fi
  done

  FIX_SYSTEM='You are a QA engineer fixing a Scaffold-ETH 2 dApp frontend. You will be given a QA audit report showing PASS/FAIL results and the source files.

Fix ALL failures listed below. Follow these rules exactly:

CRITICAL FIXES (must fix):
- Wallet connection: disconnected users must see <RainbowKitCustomConnectButton /> as the primary UI, not text saying "connect wallet"
- Button flow: use useScaffoldWriteContract (not raw useWriteContract). Buttons must have disabled={isPending}.
- SE2 branding: remove any "Scaffold-ETH", "BuidlGuidl", "SE2" references from Footer, Header, layout metadata
- Contract verification: cannot fix via code — skip

IMPORTANT FIXES:
- Contract address: display deployed contract address using <Address address="0x..." /> from ~~/components/scaffold-eth
- AddressInput: replace any raw <input type="text"> for addresses with <AddressInput /> from ~~/components/scaffold-eth
- Dark mode: replace hardcoded bg colors (bg-[#0a0a0a], bg-black) with DaisyUI vars (bg-base-100, bg-base-200) OR force data-theme="dark" on <html> AND remove <SwitchTheme/>
- Button loading: never use className="loading" on buttons. Use <span className="loading loading-spinner loading-sm" /> INSIDE the button
- --radius-field: if 9999rem, change to 0.5rem in globals.css (BOTH theme blocks)
- Phantom wallet: add phantomWallet to wagmiConnectors.tsx wallet list (import from @rainbow-me/rainbowkit/wallets)
- SE2 README: replace with project-specific content
- pollingInterval: set to 3000 in scaffold.config.ts
- Approve cooldown: after approve tx resolves, set a 4s cooldown to prevent button flicker while allowance re-fetches
- Mobile deep linking: add writeAndOpen helper that fires TX then deep links to wallet after 2s delay. Check connector for wallet type. Skip if window.ethereum exists (in-app browser).
- Error messages: EVERY catch block that handles a contract write error must: (1) import getParsedError from ~~/utils/scaffold-eth, (2) import notification from ~~/utils/scaffold-eth, (3) call getParsedError(e) to parse the error, (4) call notification.error() with a human-readable message. Map known contract errors to plain English (e.g. "EmptyMessage" → "Message cannot be empty", "MessageTooLong" → "Message exceeds 280 bytes", "SafeERC20FailedOperation" → "Token transfer failed — check your CLAWD balance and approval"). Never show raw hex selectors or "Encoded error signature not found" to users.
- Zero-address placeholder: remove ALL occurrences of "0x0000000000000000000000000000000000000000" as a value in components/pages. Replace with useDeployedContractInfo("ContractName") to get the real address.
- Hardcoded deployed address: remove all deployed contract address literals from component/page files. Use useDeployedContractInfo("ContractName") inside the component that needs the address. Never pass an address as a prop from page.tsx — let the component resolve it from the registry.

IMPORTANT OUTPUT FORMAT:
Return a JSON object where each key is a file path (relative to the project root, e.g. "packages/nextjs/app/page.tsx") and each value is the COMPLETE fixed file content. Only include files you changed. Return ONLY the JSON. No markdown. No explanation.

RULES:
- Fix the root cause of each failure
- Preserve all existing functionality
- Do not remove features or components that are working
- Return COMPLETE file contents for changed files
- Do NOT wrap in markdown code fences'

  FIX_USER="## QA Audit Report
$(echo -e "$REPORT")

## Source Files
$SOURCES

Fix all FAIL items. Return ONLY the JSON object with changed files."

  echo "  Asking LLM to fix QA failures..."

  FIX_RAW=$(llm_call "$MODEL" "$FIX_SYSTEM" "$FIX_USER" 16384)
  FIX_JSON=$(extract_json "$FIX_RAW")

  if [[ -n "$FIX_JSON" ]]; then
    for raw_key in $(echo "$FIX_JSON" | jq -r 'keys[]'); do
      content=$(echo "$FIX_JSON" | jq -r --arg f "$raw_key" '.[$f]')
      target="$PROJECT_DIR/$raw_key"
      # If key has no directory, try to find it
      if [[ "$raw_key" != */* ]]; then
        found=$(find "$PROJECT_DIR" -name "$(basename "$raw_key")" ! -path "*/node_modules/*" | head -1)
        if [[ -n "$found" ]]; then
          target="$found"
        fi
      fi
      mkdir -p "$(dirname "$target")"
      echo "$content" > "$target"
      echo "    Fixed: ${target#$PROJECT_DIR/}"
    done
  else
    echo "  Could not extract JSON from LLM fix. Retrying..."
    continue
  fi

  # Verify frontend still builds after fixes
  echo ""
  echo "  Verifying build after fixes..."
  BUILD_OUTPUT=$(cd "$NEXTJS_DIR" && npm run build 2>&1) || true
  if echo "$BUILD_OUTPUT" | grep -q "Failed to compile"; then
    echo "  ✗ Build broken by fix — reverting not supported, continuing to next attempt"
  else
    echo "  ✓ Build still passes"
  fi

  # Re-run checks
  echo ""
  echo "  Re-running QA checks..."
  echo ""
  run_qa_checks

  echo ""
  echo "  ── Summary (attempt $ATTEMPT) ──"
  echo "  Passed: $PASSES | Critical fails: $CRITICAL_FAILS | Important fails: $IMPORTANT_FAILS"
  echo ""
done

# ─── Final report ──────────────────────────────────────────────────────────
echo ""
echo "  ══════════════════════════════════════════"
echo "  QA AUDIT COMPLETE"
echo "  Passed: $PASSES | Critical: $CRITICAL_FAILS | Important: $IMPORTANT_FAILS"
echo "  ══════════════════════════════════════════"

if [[ $CRITICAL_FAILS -gt 0 ]]; then
  echo ""
  echo "  ⚠ $CRITICAL_FAILS critical issue(s) remain. Review before shipping."
  echo ""
  echo ">>> Step 9b complete (with warnings)."
  exit 1
fi

if [[ $IMPORTANT_FAILS -gt 0 ]]; then
  echo ""
  echo "  ⚠ $IMPORTANT_FAILS non-critical issue(s) remain. Consider fixing before shipping."
fi

echo ""
echo ">>> Step 9b complete."
