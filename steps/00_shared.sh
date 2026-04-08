# Shared helpers for dApp builder steps.
# Source this file, don't execute it: source "$(dirname "$0")/00_shared.sh"

# ─── Load .env ───────────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDS_DIR="$ROOT_DIR/builds"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

# ─── Bankr LLM Gateway ──────────────────────────────────────────────────────
BANKR_URL="https://llm.bankr.bot/v1/chat/completions"

# llm_call <model> <system_prompt> <user_prompt> [max_tokens]
# Returns: cleaned text content (thinking tags and markdown fencing stripped)
llm_call() {
  local model="$1"
  local system_prompt="$2"
  local user_prompt="$3"
  local max_tokens="${4:-4096}"

  if [[ -z "${BANKR_API_KEY:-}" ]]; then
    echo "ERROR: BANKR_API_KEY not set." >&2
    return 1
  fi

  local payload
  payload=$(jq -n \
    --arg model "$model" \
    --arg system "$system_prompt" \
    --arg user "$user_prompt" \
    --argjson max_tokens "$max_tokens" \
    '{
      model: $model,
      max_tokens: $max_tokens,
      messages: [
        { role: "system", content: $system },
        { role: "user", content: $user }
      ],
      temperature: 0
    }')

  local raw
  raw=$(curl -s "$BANKR_URL" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $BANKR_API_KEY" \
    -d "$payload")

  # Check for API errors
  local error
  error=$(echo "$raw" | jq -r '.error.message // empty' 2>/dev/null)
  if [[ -n "$error" ]]; then
    echo "ERROR: API returned: $error" >&2
    return 1
  fi

  # Extract content, strip <think>...</think> tags some models emit (multiline)
  local content
  content=$(echo "$raw" | jq -r '.choices[0].message.content // empty')
  content=$(echo "$content" | perl -0777 -pe 's/<think>.*?<\/think>\s*//gs')

  # Strip markdown code fencing (```json ... ``` or ```solidity ... ```)
  content=$(echo "$content" | perl -0777 -pe 's/^```\w*\n//; s/\n```\s*$//s')

  echo "$content"
}

# require_param <param_name> <value>
require_param() {
  if [[ -z "${2:-}" ]]; then
    echo "ERROR: Missing required parameter: $1" >&2
    return 1
  fi
}

# ─── Extract JSON from LLM output (may be wrapped in text) ──────────────────
extract_json() {
  local raw="$1"
  # Try raw first
  if echo "$raw" | jq . > /dev/null 2>&1; then
    echo "$raw"
    return
  fi
  # Try to extract JSON object from surrounding text
  local extracted
  extracted=$(echo "$raw" | perl -0777 -ne 'print $1 if /(\{.*\})/s')
  if [[ -n "$extracted" ]] && echo "$extracted" | jq . > /dev/null 2>&1; then
    echo "$extracted"
    return
  fi
  echo ""
}

# ─── Verify + Fix Loop ──────────────────────────────────────────────────────
# verify_fix_loop <model> <verify_cmd> <work_dir> <max_retries> <source_dirs...>
#
# Runs verify_cmd in work_dir. If it fails, gathers .sol/.ts/.tsx/.css files
# from source_dirs, sends errors + sources to an LLM for fix, writes fixed
# files back, and retries up to max_retries times.
#
# The LLM returns JSON: { "relative/path/file.ext": "content", ... }
# Files are written relative to work_dir.
#
# Returns 0 on success, 1 if retries exhausted.
verify_fix_loop() {
  local model="$1"
  local verify_cmd="$2"
  local work_dir="$3"
  local max_retries="$4"
  shift 4
  local source_dirs=("$@")

  local attempt=0

  while [[ $attempt -le $max_retries ]]; do
    attempt=$((attempt + 1))

    if [[ $attempt -gt 1 ]]; then
      echo ""
      echo "  --- Fix attempt $((attempt - 1)) of $max_retries ---"
    fi

    # Run verify command
    local output
    output=$(cd "$work_dir" && eval "$verify_cmd" 2>&1) || true

    # Check for errors (non-zero exit or error keywords)
    if echo "$output" | grep -qiE "^Error|error:|failed|FAIL"; then
      local pass_count fail_count
      pass_count=$(echo "$output" | grep -oE '[0-9]+ (tests )?passed' | tail -1 | grep -oE '[0-9]+' || echo "")
      fail_count=$(echo "$output" | grep -oE '[0-9]+ failed' | tail -1 | grep -oE '[0-9]+' || echo "")

      if [[ -n "$pass_count" && -n "$fail_count" ]]; then
        echo "  ✗ Verify: $pass_count passed, $fail_count failed"
      else
        echo "  ✗ Verify failed"
      fi

      if [[ $attempt -gt $max_retries ]]; then
        echo ""
        echo "  ERROR: Still failing after $max_retries fix attempts."
        echo "$output" | grep -iE "error|FAIL" | head -20
        return 1
      fi

      # Gather source files
      local sources=""
      for dir in "${source_dirs[@]}"; do
        for f in $(find "$dir" -maxdepth 2 -type f \( -name "*.sol" -o -name "*.ts" -o -name "*.tsx" -o -name "*.css" \) ! -path "*/node_modules/*" ! -name "DeployHelpers.s.sol" ! -name "VerifyAll.s.sol" 2>/dev/null | sort); do
          local relpath="${f#$work_dir/}"
          sources="$sources
--- $relpath ---
$(cat "$f")
"
        done
      done

      # Filter errors to just the key lines (not verbose candidates/notes)
      local filtered_errors
      filtered_errors=$(echo "$output" | grep -E "Error|error:|FAIL|failed" | head -30)

      echo "  Asking LLM to fix..."

      local fix_system='You are a code debugger. You will be given build/test errors and source files. Fix the errors.

IMPORTANT OUTPUT FORMAT:
Return a JSON object where each key is a file path (relative to the project) and each value is the COMPLETE fixed file content. Only include files you changed. Return ONLY the JSON. No markdown. No explanation.

RULES:
- Read errors carefully. Fix the root cause.
- If a test assertion fails, the test expectation is probably wrong — fix the test, not the contract.
- For Solidity unicode strings, use unicode"..." prefix.
- For TypeScript/ESLint unused import errors, remove the unused import.
- For TypeScript type errors, fix the types.
- Preserve all passing code. Only modify what is broken.
- Return COMPLETE file contents for changed files.'

      local fix_user="## Errors
$filtered_errors

## Source Files
$sources

Fix the errors. Return ONLY the JSON object with changed files."

      local fix_raw
      fix_raw=$(llm_call "$model" "$fix_system" "$fix_user" 16384)
      local fix_json
      fix_json=$(extract_json "$fix_raw")

      if [[ -n "$fix_json" ]]; then
        for raw_key in $(echo "$fix_json" | jq -r 'keys[]'); do
          local content
          content=$(echo "$fix_json" | jq -r --arg f "$raw_key" '.[$f]')
          local target="$work_dir/$raw_key"
          # If key has no directory, try to infer from extension
          if [[ "$raw_key" != */* ]]; then
            local base_name
            base_name=$(basename "$raw_key")
            # Search for existing file with that name
            local found
            found=$(find "$work_dir" -name "$base_name" ! -path "*/node_modules/*" | head -1)
            if [[ -n "$found" ]]; then
              target="$found"
            fi
          fi
          mkdir -p "$(dirname "$target")"
          echo "$content" > "$target"
          echo "    Fixed: ${target#$work_dir/}"
        done
      else
        echo "  Could not extract JSON from LLM fix. Retrying..."
      fi
      continue
    fi

    # Success
    echo "  ✓ Verify passed"
    return 0
  done

  return 1
}

# load_params <project-name>
# Sets PARAMS variable and exports individual fields
load_params() {
  local project="$1"
  local params_file="$BUILDS_DIR/$project/params.json"

  if [[ ! -f "$params_file" ]]; then
    echo "ERROR: params.json not found at $params_file" >&2
    echo "       Run Step 1 first: ./steps/01_parse_job.sh <model>" >&2
    return 1
  fi

  PARAMS=$(cat "$params_file")
  PROJECT_NAME=$(echo "$PARAMS" | jq -r '.project_name')
  CHAIN=$(echo "$PARAMS" | jq -r '.chain')
  CHAIN_ID=$(echo "$PARAMS" | jq -r '.chain_id')
  FRAMEWORK=$(echo "$PARAMS" | jq -r '.framework')
  PROJECT_DIR="$BUILDS_DIR/$PROJECT_NAME/$PROJECT_NAME"
}
