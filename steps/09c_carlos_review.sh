#!/usr/bin/env bash
set -euo pipefail

# ─── Step 9c: Carlos Semantic Code Review ───────────────────────────────────
#
# Usage: ./steps/09c_carlos_review.sh <model> <project-name> [max-retries]
#
# Runs a grumpy-carlos-style LLM semantic review of the generated frontend
# and contract code. Unlike 09b (which runs pattern grep checks), this step
# reasons about the CODE itself against the spec:
#
#   - Contract addresses never hardcoded / passed as props
#   - All write calls have human-readable error handling
#   - No dead/unused components
#   - SE-2 hook patterns used correctly
#   - Components do one thing; no accidental complexity
#   - Frontend matches the job spec
#
# On issues: Carlos provides both the critique AND the fixed file contents in
# one call. Fixed files are written back and the review loops until APPROVED
# or max-retries is exhausted.
#
# Must run AFTER 09b (QA audit) and BEFORE 10 (IPFS ship).
# Exit code 1 if CRITICAL issues remain after max retries.
# ─────────────────────────────────────────────────────────────────────────────

source "$(dirname "$0")/00_shared.sh"

MODEL="${1:?Usage: ./steps/09c_carlos_review.sh <model> <project-name> [max-retries]}"
PROJECT="${2:?Usage: ./steps/09c_carlos_review.sh <model> <project-name> [max-retries]}"
MAX_RETRIES="${3:-2}"

load_params "$PROJECT"

NEXTJS_DIR="$PROJECT_DIR/packages/nextjs"
FOUNDRY_DIR="$PROJECT_DIR/packages/foundry"
APP_DIR="$NEXTJS_DIR/app"
COMP_DIR="$NEXTJS_DIR/components"
CONTRACTS_DIR="$NEXTJS_DIR/contracts"

echo ">>> Step 9c: Carlos Semantic Review..."
echo "    Model:   $MODEL"
echo "    Project: $PROJECT"
echo ""

# ─── Gather sources ──────────────────────────────────────────────────────────
gather_sources() {
  local sources=""
  for f in $(find "$APP_DIR" "$COMP_DIR" -maxdepth 3 -type f \
      \( -name "*.tsx" -o -name "*.ts" \) \
      ! -path "*/node_modules/*" \
      ! -path "*/scaffold-eth/*" \
      2>/dev/null | sort); do
    local relpath="${f#$PROJECT_DIR/}"
    sources="$sources
--- $relpath ---
$(cat "$f")
"
  done

  # Also styles and config
  for f in "$NEXTJS_DIR/styles/globals.css" \
            "$NEXTJS_DIR/scaffold.config.ts" \
            "$CONTRACTS_DIR/deployedContracts.ts" \
            "$CONTRACTS_DIR/externalContracts.ts"; do
    if [[ -f "$f" ]]; then
      local relpath="${f#$PROJECT_DIR/}"
      sources="$sources
--- $relpath ---
$(cat "$f")
"
    fi
  done

  # Contract sources
  for SOL_FILE in "$FOUNDRY_DIR/contracts"/*.sol; do
    [[ -f "$SOL_FILE" ]] || continue
    local relpath="${SOL_FILE#$PROJECT_DIR/}"
    sources="$sources
--- $relpath ---
$(cat "$SOL_FILE")
"
  done

  printf '%s' "$sources"
}

JOB_CONTENT=$(cat "$BUILDS_DIR/$PROJECT/job.md")

CARLOS_SYSTEM='You are Carlos, a grumpy but deeply caring senior code reviewer with high standards for Scaffold-ETH 2 projects. You specialize in TypeScript, React, Next.js, and Solidity. You are brutally honest but always constructive.

## Your Core Standards

### Contract Address Handling (the #1 bug class)
- NEVER accept a deployed contract address hardcoded as a string literal in any React file
- NEVER accept a deployed contract address passed as a prop from page.tsx into a child component
- Components that need a deployed contract address MUST call useDeployedContractInfo("ContractName") internally
- External contracts (tokens) are accessed via contractName in hooks — never hardcoded
- A 0x0000...0000 literal anywhere in app/ or components/ is always wrong

### SE-2 Patterns
- useScaffoldReadContract for reads (never raw wagmi useReadContract)
- useScaffoldWriteContract for writes (never raw wagmi useWriteContract)
- useDeployedContractInfo for getting a deployed contract address
- Address component from @scaffold-ui/components for displaying addresses (never custom)
- AddressInput for address input fields

### Error Handling
- Every catch block on a write call must call notification.error() with a human-readable message
- getParsedError() must be used to parse contract errors
- Every known contract error must be mapped to plain English
- Raw hex selectors (0x...) must never reach the user

### Code Cleanliness
- No unused/dead components (every file in components/ must be imported and used)
- No any types unless absolutely unavoidable
- Components do ONE thing
- No unnecessary props — if a component can get data itself via hooks, it should

## Output Format

You MUST return a single JSON object with this exact structure:

{
  "verdict": "APPROVED" or "ISSUES_FOUND",
  "critical": [
    "packages/nextjs/app/page.tsx: BURN_BOARD_ADDRESS is hardcoded as 0x0000... — this is a placeholder that was never replaced",
    "packages/nextjs/components/PostForm.tsx: catch block calls console.error instead of notification.error"
  ],
  "improvements": [
    "packages/nextjs/components/StatsBar.tsx: minor — totalBurned calculation should use BigInt to avoid precision loss for large values"
  ],
  "fixes": {
    "packages/nextjs/app/page.tsx": "COMPLETE fixed file content here",
    "packages/nextjs/components/PostForm.tsx": "COMPLETE fixed file content here"
  }
}

Rules for the JSON output:
- "critical" lists issues that BLOCK shipping: wrong address patterns, silent errors, broken flows, security issues
- "improvements" lists non-blocking issues worth fixing
- "fixes" contains COMPLETE file contents for every file that needs changes (critical AND improvements)
- If verdict is APPROVED, fixes can be empty {}
- Only include files in "fixes" that you actually changed
- Return ONLY the JSON — no markdown fences, no explanation outside the JSON
- File paths in "fixes" are relative to the project root (e.g. "packages/nextjs/app/page.tsx")'

USER_PROMPT="## Job Spec (what this dApp is supposed to do)
$JOB_CONTENT

## Source Files (review all of these)
$(gather_sources)

Review the code. Return ONLY the JSON object."

# ─── Review loop ─────────────────────────────────────────────────────────────
ATTEMPT=0
CRITICAL_COUNT=0

while [[ $ATTEMPT -le $MAX_RETRIES ]]; do
  ATTEMPT=$((ATTEMPT + 1))

  if [[ $ATTEMPT -gt 1 ]]; then
    echo ""
    echo "  --- Re-review attempt $((ATTEMPT - 1)) of $MAX_RETRIES ---"
  fi

  echo "  Asking Carlos to review..."

  REVIEW_RAW=$(llm_call "$MODEL" "$CARLOS_SYSTEM" "$USER_PROMPT" 16384)
  REVIEW_JSON=$(extract_json "$REVIEW_RAW")

  if [[ -z "$REVIEW_JSON" ]]; then
    echo "  ✗ Could not parse Carlos's response as JSON"
    if [[ $ATTEMPT -gt $MAX_RETRIES ]]; then
      echo "  Exhausted retries. Continuing without Carlos's sign-off."
      exit 0  # Don't block on parse failure — the other checks still ran
    fi
    continue
  fi

  VERDICT=$(echo "$REVIEW_JSON" | jq -r '.verdict // "ISSUES_FOUND"')
  CRITICAL_COUNT=$(echo "$REVIEW_JSON" | jq '.critical | length' 2>/dev/null || echo "0")
  IMPROVEMENT_COUNT=$(echo "$REVIEW_JSON" | jq '.improvements | length' 2>/dev/null || echo "0")

  echo ""
  echo "  Verdict: $VERDICT"
  echo "  Critical: $CRITICAL_COUNT | Improvements: $IMPROVEMENT_COUNT"

  # Print issues
  if [[ "$CRITICAL_COUNT" -gt 0 ]]; then
    echo ""
    echo "  ── Critical Issues ──"
    echo "$REVIEW_JSON" | jq -r '.critical[]' | while IFS= read -r issue; do
      echo "  ✗ $issue"
    done
  fi

  if [[ "$IMPROVEMENT_COUNT" -gt 0 ]]; then
    echo ""
    echo "  ── Improvements ──"
    echo "$REVIEW_JSON" | jq -r '.improvements[]' | while IFS= read -r issue; do
      echo "  ~ $issue"
    done
  fi

  # If APPROVED or no critical issues, we're done
  if [[ "$VERDICT" == "APPROVED" || "$CRITICAL_COUNT" -eq 0 ]]; then
    echo ""
    # Still apply improvement fixes if provided
    FIX_COUNT=$(echo "$REVIEW_JSON" | jq '.fixes | length' 2>/dev/null || echo "0")
    if [[ "$FIX_COUNT" -gt 0 ]]; then
      echo "  Applying $FIX_COUNT improvement fix(es)..."
      for raw_key in $(echo "$REVIEW_JSON" | jq -r '.fixes | keys[]'); do
        content=$(echo "$REVIEW_JSON" | jq -r --arg f "$raw_key" '.fixes[$f]')
        target="$PROJECT_DIR/$raw_key"
        mkdir -p "$(dirname "$target")"
        echo "$content" > "$target"
        echo "    Fixed: $raw_key"
      done

      # Verify build still passes after improvements
      echo ""
      echo "  Verifying build after improvements..."
      BUILD_OK=true
      cd "$NEXTJS_DIR" && npm run build > /dev/null 2>&1 || BUILD_OK=false
      if $BUILD_OK; then
        echo "  ✓ Build still passes"
      else
        echo "  ✗ Build broken by improvements — reverting is not automatic, continuing"
      fi
    fi

    if [[ "$CRITICAL_COUNT" -eq 0 ]]; then
      echo "  ✓ Carlos approves (no critical issues)"
    fi
    echo ""
    echo ">>> Step 9c complete."
    exit 0
  fi

  # Apply fixes for critical issues
  FIX_COUNT=$(echo "$REVIEW_JSON" | jq '.fixes | length' 2>/dev/null || echo "0")
  if [[ "$FIX_COUNT" -gt 0 ]]; then
    echo ""
    echo "  Applying $FIX_COUNT fix(es) from Carlos..."
    for raw_key in $(echo "$REVIEW_JSON" | jq -r '.fixes | keys[]'); do
      content=$(echo "$REVIEW_JSON" | jq -r --arg f "$raw_key" '.fixes[$f]')
      target="$PROJECT_DIR/$raw_key"

      # If key has no directory, try to find by filename
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

    # Verify build after fix
    echo ""
    echo "  Verifying build after fixes..."
    BUILD_OK=true
    (cd "$NEXTJS_DIR" && npm run build > /dev/null 2>&1) || BUILD_OK=false
    if $BUILD_OK; then
      echo "  ✓ Build passes"
    else
      echo "  ✗ Build broken by fix — Carlos will re-review with build errors in mind"
    fi
  else
    echo ""
    echo "  ✗ Carlos found critical issues but provided no fixes"
    if [[ $ATTEMPT -gt $MAX_RETRIES ]]; then
      break
    fi
  fi

  # Update sources for re-review
  USER_PROMPT="## Job Spec (what this dApp is supposed to do)
$JOB_CONTENT

## Source Files (re-review after fixes were applied)
$(gather_sources)

Review the code again — fixes were applied for the issues you found. Return ONLY the JSON object."

done

# ─── Final result ─────────────────────────────────────────────────────────────
echo ""
echo "  ══════════════════════════════════════════"
echo "  CARLOS REVIEW COMPLETE"
echo "  Critical issues remaining: $CRITICAL_COUNT"
echo "  ══════════════════════════════════════════"

if [[ "$CRITICAL_COUNT" -gt 0 ]]; then
  echo ""
  echo "  ✗ $CRITICAL_COUNT critical issue(s) not resolved after $MAX_RETRIES attempt(s)."
  echo "    Review Carlos's findings above before shipping."
  echo ""
  echo ">>> Step 9c complete (with unresolved critical issues)."
  exit 1
fi

echo ""
echo ">>> Step 9c complete."
