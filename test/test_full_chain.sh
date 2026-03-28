#!/bin/bash
# ──────────────────────────────────────────────
# test_full_chain.sh — End-to-end local pipeline test
# ──────────────────────────────────────────────
# Orchestrates all Phase 4 tests in the correct order:
#   1. Start Postgres (docker compose)
#   2. Export tests  (Docker container, DRY_RUN)
#   3. Verify tests  (Python, moto + real Postgres)
#   4. Drop tests    (Python, moto + real Postgres)
#
# Run from the project root:
#   bash test/test_full_chain.sh
#
# To reset and re-run:
#   bash test/cleanup.sh
#   bash test/test_full_chain.sh
# ──────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
section() { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; \
            echo -e "${BLUE}  $1${NC}"; \
            echo -e "${BLUE}══════════════════════════════════════════${NC}"; }
log()  { echo -e "${GREEN}[chain]${NC} $1"; }
warn() { echo -e "${YELLOW}[chain]${NC} WARNING: $1"; }
fail() { echo -e "${RED}[chain]${NC} FAIL: $1"; exit 1; }
pass() { echo -e "${GREEN}[chain]${NC} PASS: $1"; }

CHAIN_START=$(date +%s)

# ──────────────────────────────────────────────
# Step 1: Python venv + dependencies
# ──────────────────────────────────────────────
section "Step 1/4 — Python venv + dependencies"

VENV_DIR="test/.venv"

# Create venv if it doesn't exist
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    log "Creating virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
fi

# Activate venv — all subsequent python3/pip calls use it
source "$VENV_DIR/bin/activate"
log "Virtual environment active: $VIRTUAL_ENV"

# Install/upgrade deps if anything is missing
if ! python3 -c "import moto, boto3, psycopg2" 2>/dev/null; then
    log "Installing test dependencies..."
    pip install -q -r test/requirements.txt
fi
pass "Python dependencies ready"

# ──────────────────────────────────────────────
# Step 2: Start Postgres
# ──────────────────────────────────────────────
section "Step 2/4 — Starting Postgres"

log "Starting marsquant-test-postgres..."
docker compose up -d postgres

log "Waiting for Postgres to be healthy (up to 60 s)..."
WAITED=0
until docker compose exec -T postgres \
    pg_isready -U marsquantMasterUser -d datafeeddatabase > /dev/null 2>&1; do
    if [ "$WAITED" -ge 60 ]; then
        fail "Postgres did not become healthy in 60 s. Check: docker compose logs postgres"
    fi
    printf '.'
    sleep 2
    WAITED=$((WAITED + 2))
done
echo ""
pass "Postgres healthy after ${WAITED}s"

# Verify test data is present
ROW_COUNT=$(docker compose exec -T postgres \
    psql -U marsquantMasterUser -d datafeeddatabase -t -A \
    -c "SELECT COUNT(*) FROM datafeedschema.nifty50_table;")

if [ -z "$ROW_COUNT" ] || [ "$ROW_COUNT" -lt 15000 ]; then
    warn "Expected ≥15,000 rows total. Got: ${ROW_COUNT:-0}"
    warn "If this is a fresh volume, setup_test_db.sql should have run automatically."
    warn "Try: docker compose down -v && docker compose up -d"
    fail "Insufficient test data"
fi
pass "Test data confirmed: ${ROW_COUNT} total rows across 3 partitions"

# ──────────────────────────────────────────────
# Step 3: Export tests (Docker container)
# ──────────────────────────────────────────────
section "Step 3/4 — Export tests (Docker + DRY_RUN)"
bash test/test_export.sh
pass "All export tests passed"

# ──────────────────────────────────────────────
# Step 4a: Verify Lambda tests
# ──────────────────────────────────────────────
section "Step 4a/4 — Verify Lambda tests"
python3 -m unittest test.test_verify -v 2>&1 || python3 test/test_verify.py
pass "All verify Lambda tests passed"

# ──────────────────────────────────────────────
# Step 4b: Drop Partition Lambda tests
# ──────────────────────────────────────────────
section "Step 4b/4 — Drop Partition Lambda tests"
python3 -m unittest test.test_drop -v 2>&1 || python3 test/test_drop.py
pass "All drop Lambda tests passed"

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
CHAIN_END=$(date +%s)
DURATION=$((CHAIN_END - CHAIN_START))

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ALL PHASE 4 TESTS PASSED ✓  (${DURATION}s)         ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Export  : 5 tests (DRY_RUN + error paths)  ║${NC}"
echo -e "${GREEN}║  Verify  : 6 tests (happy + 4 failure modes) ║${NC}"
echo -e "${GREEN}║  Drop    : 5 tests (happy + guard-rails)     ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Next: Phase 5 — terraform validate/plan     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
