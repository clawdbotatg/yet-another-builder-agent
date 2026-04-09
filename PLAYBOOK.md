# DAPP BUILDER PLAYBOOK

You are an orchestrator. Follow these steps IN ORDER to build and ship a dApp from a job.md file. Each step has a script you run. Check the output of each step before proceeding to the next.

## Prerequisites

- `.env` file with: `BANKR_API_KEY`, `BGIPFS_API_KEY`, `BASE_RPC_URL`, `ETH_PRIVATE_KEY`
- Node.js, yarn, foundry (forge/anvil), jq, curl, perl installed
- A `job.md` file describing the dApp to build

## Directory Structure

```
.
├── .env                  # API keys (never commit)
├── job.md                # The dApp spec you're building
├── PLAYBOOK.md           # This file (you follow it)
├── steps/                # Individual step scripts
│   ├── 00_shared.sh      # Shared helpers (LLM call, env loading)
│   ├── 01_parse_job.sh   # Step 1
│   ├── 02_scaffold.sh    # Step 2
│   └── ...               # Steps 3-10
└── builds/
    └── <project-name>/   # Created by Step 1
        ├── params.json   # Extracted build parameters
        ├── job.md         # Copy of the job spec
        └── <project>/    # SE2 project (created by Step 2)
```

---

## Step 1: Parse Job

**What:** Sends job.md to an LLM to extract structured build parameters.
**Type:** LLM call
**Script:** `./steps/01_parse_job.sh <model> [job-file]`

**Inputs:**
- `<model>` — LLM model ID (e.g. `minimax-m2.7`, `claude-sonnet-4-20250514`)
- `[job-file]` — path to job spec (default: `./job.md`)

**Outputs:**
- `builds/<project-name>/params.json` — structured JSON with:
  - `project_name` (kebab-case)
  - `chain` (e.g. "base")
  - `chain_id` (e.g. 8453)
  - `framework` ("foundry" or "hardhat")
  - `external_contracts` (array of {name, address, description})
  - `contract_names` (array of contract names to write)
  - `description` (one sentence summary)
- `builds/<project-name>/job.md` — copy of the job spec

**Success check:** `jq .project_name builds/<project-name>/params.json` returns a non-empty string.

**Example:**
```bash
./steps/01_parse_job.sh minimax-m2.7
# Output: builds/clawd-burn-board/params.json
```

---

## Step 2: Scaffold Project

**What:** Runs `npx create-eth@latest` to create the SE2 project with the correct framework.
**Type:** Deterministic (shell commands only)
**Script:** `./steps/02_scaffold.sh <project-name>`

**Inputs:**
- `<project-name>` — from `params.json` (e.g. `clawd-burn-board`)
- Reads `builds/<project-name>/params.json` for framework choice

**Outputs:**
- `builds/<project-name>/<project-name>/` — full SE2 project directory
- `packages/foundry/` or `packages/hardhat/` exists
- `packages/nextjs/` exists
- `yarn install` completed

**Success check:** `ls builds/<project-name>/<project-name>/packages/nextjs/scaffold.config.ts` exists.

**Example:**
```bash
./steps/02_scaffold.sh clawd-burn-board
```

---

## Step 3: Write Contracts

**What:** Sends the job spec + contract names to an LLM, which writes Solidity contracts.
**Type:** LLM call
**Script:** `./steps/03_write_contracts.sh <model> <project-name>`

**Inputs:**
- `<model>` — LLM model ID
- `<project-name>` — project directory name
- Reads `params.json` for contract names and job spec for requirements

**Outputs:**
- Solidity files written to `builds/<project-name>/<project-name>/packages/foundry/contracts/`
- One `.sol` file per entry in `contract_names`

**Success check:** `forge build` compiles without errors (checked in Step 7).

---

## Step 4: Write Deploy Scripts

**What:** Sends the written contracts to an LLM to generate Foundry deploy scripts.
**Type:** LLM call
**Script:** `./steps/04_deploy_scripts.sh <model> <project-name>`

**Inputs:**
- `<model>` — LLM model ID
- `<project-name>` — project directory name
- Reads the contracts written in Step 3

**Outputs:**
- Deploy scripts in `builds/<project-name>/<project-name>/packages/foundry/script/`

**Success check:** Deploy script files exist and reference the correct contract names.

---

## Step 5: Add External Contracts

**What:** Sends external contract info to an LLM to populate `externalContracts.ts` with ABIs.
**Type:** LLM call + chain RPC calls (to fetch ABIs from block explorer)
**Script:** `./steps/05_external_contracts.sh <model> <project-name>`

**Inputs:**
- `<model>` — LLM model ID
- `<project-name>` — project directory name
- Reads `params.json` for external contract addresses and chain

**Outputs:**
- Updated `packages/nextjs/contracts/externalContracts.ts`

**Success check:** File contains all addresses from `params.json`.

---

## Step 6: Write Tests

**What:** Sends contracts to an LLM to generate Foundry test files.
**Type:** LLM call
**Script:** `./steps/06_write_tests.sh <model> <project-name>`

**Inputs:**
- `<model>` — LLM model ID
- `<project-name>` — project directory name
- Reads the contracts from Step 3

**Outputs:**
- Test files in `builds/<project-name>/<project-name>/packages/foundry/test/`

**Success check:** `forge test` passes (checked in Step 7).

---

## Step 7: Compile and Test

**What:** Runs `forge build` and `forge test`. On failure, sends errors + source to LLM for auto-fix, then retries. Loops up to max-retries times.
**Type:** Deterministic + LLM (for auto-fix loop)
**Script:** `./steps/07_compile_test.sh <model> <project-name> [max-retries]`

**Inputs:**
- `<model>` — LLM model ID (used for fix attempts)
- `<project-name>` — project directory name
- `[max-retries]` — number of fix attempts (default: 3)

**Outputs:**
- Fixed .sol files (contracts, tests, deploy scripts) if corrections were needed
- Compilation artifacts
- Test results (pass/fail)

**Success check:** Exit code 0. All tests pass.

**On failure:** Exhausts retries and exits with error. Try a smarter model or increase retries.

**Example:**
```bash
./steps/07_compile_test.sh minimax-m2.7 clawd-burn-board 3
./steps/07_compile_test.sh claude-opus-4-6 clawd-burn-board 5  # smarter model, more retries
```

---

## Step 8: Build Frontend

**What:** Sends the job spec, design brief, contract ABIs, and SE2 conventions to an LLM to create/modify frontend components and pages.
**Type:** LLM call (largest step — multiple files)
**Script:** `./steps/08_frontend.sh <model> <project-name>`

**Inputs:**
- `<model>` — LLM model ID
- `<project-name>` — project directory name
- Reads: job.md (design brief), deployed contract ABIs, SE2 AGENTS.md conventions

**Outputs:**
- Modified/new files in `packages/nextjs/app/`
- Modified/new files in `packages/nextjs/components/`
- Updated `tailwind.config.ts` (custom theme)
- Updated `scaffold.config.ts` (target network)

**Success check:** `yarn next:build` completes without errors.

---

## Step 9: Deploy Contracts to Chain

**What:** Deploys contracts to the target chain and verifies them on the block explorer.
**Type:** Deterministic (interactive — prompts for keystore password via TTY)
**Script:** `./steps/09_deploy_chain.sh <project-name>`

**Two-pass flow:**
1. **First run (no keystore):** Generates a new deployer wallet, imports into a foundry keystore (prompts for password via TTY), shows the address, exits. Fund the address before proceeding.
2. **Second run (funded keystore):** Deploys contracts (prompts for keystore password via TTY), generates ABIs, verifies on block explorer.

**Inputs:**
- `<project-name>` — project directory name
- Reads `params.json` for chain
- Keystore password entered via TTY (never stored in files or env vars)

**Outputs:**
- Deployed contract addresses
- Verified source on block explorer
- Updated `deployedContracts.ts` (via SE2's `generateTsAbis.js`)

**Success check:** `deployedContracts.ts` contains the chain ID. Contracts verified on block explorer.

---

## Step 10: Build and Ship to IPFS

**What:** Builds the Next.js frontend for static export and uploads to IPFS via bgipfs.
**Type:** Deterministic
**Script:** `./steps/10_ipfs_ship.sh <project-name>`

**Inputs:**
- `<project-name>` — project directory name
- Requires `BGIPFS_API_KEY` in `.env`

**Outputs:**
- Static build in `packages/nextjs/out/`
- IPFS CID
- Live URL: `https://<CID>.ipfs.community.bgipfs.com/`

**Success check:** `curl -s https://<CID>.ipfs.community.bgipfs.com/ | head` returns HTML.

---

## Build-Fix Loop

Every step that produces code includes a `verify_fix_loop` that:
1. Runs a verify command (forge build, forge test, yarn next:build)
2. If it fails, gathers source files and errors
3. Sends to the LLM for a fix
4. Writes the fixed files back
5. Retries (default 3 attempts)

This is defined in `steps/00_shared.sh` and used by steps 3, 4, 5, 7, and 8.

| Step | Verify Command |
|------|---------------|
| 3 | `forge build --skip test --skip script` |
| 4 | `forge build --skip test` |
| 5 | `yarn next:build` |
| 7 | `forge build` then `forge test -vv` |
| 8 | `yarn next:build` |

## Orchestration Flow

```
START
  │
  ▼
Step 1: Parse Job ──► params.json
  │
  ▼
Step 2: Scaffold ──► SE2 project dir
  │
  ▼
Step 3: Write Contracts ──► .sol files ──► verify_fix_loop(forge build)
  │
  ▼
Step 4: Deploy Scripts ──► Deploy.s.sol ──► verify_fix_loop(forge build)
  │
  ▼
Step 5: External Contracts ──► externalContracts.ts ──► verify_fix_loop(next:build)
  │
  ▼
Step 6: Write Tests ──► test files
  │
  ▼
Step 7: Compile & Test ──► verify_fix_loop(forge build) then verify_fix_loop(forge test)
  │
  ▼
Step 8: Build Frontend ──► UI components ──► verify_fix_loop(next:build)
  │
  ▼
Step 9: Deploy to Chain ──► live contracts + verified source
  │
  ▼
Step 10: Ship to IPFS ──► live URL + deployment.json
  │
  ▼
DONE ──► https://<CID>.ipfs.community.bgipfs.com/
```

## Running the Full Pipeline

To build everything end-to-end:
```bash
MODEL="minimax-m2.7"

./steps/01_parse_job.sh $MODEL
PROJECT=$(jq -r .project_name builds/*/params.json | head -1)

./steps/02_scaffold.sh $PROJECT
./steps/03_write_contracts.sh $MODEL $PROJECT
./steps/04_deploy_scripts.sh $MODEL $PROJECT
./steps/05_external_contracts.sh $MODEL $PROJECT
./steps/06_write_tests.sh $MODEL $PROJECT
./steps/07_compile_test.sh $MODEL $PROJECT
./steps/08_frontend.sh $MODEL $PROJECT
./steps/09_deploy_chain.sh $PROJECT
./steps/10_ipfs_ship.sh $PROJECT
```

You can use different models per step:
```bash
./steps/01_parse_job.sh minimax-m2.7                          # cheap for JSON
./steps/03_write_contracts.sh claude-opus-4-6 $PROJECT        # smart for Solidity
./steps/08_frontend.sh claude-sonnet-4-6 $PROJECT             # mid-range for frontend
```
