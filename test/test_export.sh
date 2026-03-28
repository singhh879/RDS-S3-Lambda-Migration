#!/bin/bash
# ──────────────────────────────────────────────
# test_export.sh — Docker export image tests
# ──────────────────────────────────────────────
# Tests the ECS container (export.sh) against the local test Postgres.
# Runs in DRY_RUN mode — no real S3 writes.
#
# Prerequisites:
#   docker compose up -d   (marsquant-test-postgres must be running)
#
# Run standalone:
#   bash test/test_export.sh
#
# Or via full chain:
#   bash test/test_full_chain.sh
# ──────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[export-test]${NC} $1"; }
warn() { echo -e "${YELLOW}[export-test]${NC} WARNING: $1"; }
fail() { echo -e "${RED}[export-test]${NC} FAIL: $1"; exit 1; }
pass() { echo -e "${GREEN}[export-test]${NC} PASS: $1"; }

IMAGE_NAME="marsquant-export-test"

# Container name and network created by docker compose
POSTGRES_CONTAINER="marsquant-test-postgres"
DOCKER_NETWORK="marsquant-test-net"

# ─── Pre-flight checks ───
if ! docker network inspect "$DOCKER_NETWORK" > /dev/null 2>&1; then
    fail "Network '$DOCKER_NETWORK' not found. Run: docker compose up -d"
fi

if ! docker container inspect "$POSTGRES_CONTAINER" > /dev/null 2>&1; then
    fail "Container '$POSTGRES_CONTAINER' not running. Run: docker compose up -d"
fi

log "Pre-flight checks passed ✓"

# ─── Step 1: Build Docker image ───
log "Building Docker image '$IMAGE_NAME' from docker/Dockerfile..."
docker build -t "$IMAGE_NAME" -f docker/Dockerfile docker/ --quiet
pass "Image built: $IMAGE_NAME"

# ─── Helper: run the export container ───
run_export() {
    local year="$1" month="$2" day="$3"
    local extra_env="${4:-}"     # optional extra -e flags (space-separated, pre-quoted)
    local dry_run="${5:-true}"

    # shellcheck disable=SC2086
    docker run --rm \
        --network "$DOCKER_NETWORK" \
        -e PGHOST="$POSTGRES_CONTAINER" \
        -e PGPORT="5432" \
        -e PGDATABASE="datafeeddatabase" \
        -e PGUSER="marsquantMasterUser" \
        -e PGPASSWORD="testpassword" \
        -e TARGET_YEAR="$year" \
        -e TARGET_MONTH="$month" \
        -e TARGET_DAY="$day" \
        -e TABLE_NAME="nifty50_table" \
        -e SCHEMA_NAME="datafeedschema" \
        -e S3_BUCKET="marsquant-test-bucket" \
        -e DRY_RUN="$dry_run" \
        $extra_env \
        "$IMAGE_NAME"
}

# ─── Test 1: DRY_RUN happy path ───
log "TEST 1 — DRY_RUN export for 2025-09-01 (existing partition)..."
run_export "2025" "09" "01"
pass "TEST 1 — DRY_RUN export succeeded"

# ─── Test 2: Non-existent partition → clean failure ───
log "TEST 2 — Export for 2025-09-15 (no partition → should fail cleanly)..."
set +e
run_export "2025" "09" "15"
EXIT_CODE=$?
set -e
if [ "$EXIT_CODE" -ne 0 ]; then
    pass "TEST 2 — Non-existent partition failed with exit code $EXIT_CODE (expected)"
else
    fail "TEST 2 — Expected failure for non-existent partition but got exit code 0"
fi

# ─── Test 3: Invalid TARGET_MONTH → validation failure ───
log "TEST 3 — Invalid TARGET_MONTH=13 (validation should reject)..."
set +e
docker run --rm \
    --network "$DOCKER_NETWORK" \
    -e PGHOST="$POSTGRES_CONTAINER" -e PGPORT="5432" \
    -e PGDATABASE="datafeeddatabase" -e PGUSER="marsquantMasterUser" \
    -e PGPASSWORD="testpassword" \
    -e TARGET_YEAR="2025" -e TARGET_MONTH="13" -e TARGET_DAY="01" \
    -e TABLE_NAME="nifty50_table" -e SCHEMA_NAME="datafeedschema" \
    -e S3_BUCKET="marsquant-test-bucket" -e DRY_RUN="true" \
    "$IMAGE_NAME"
EXIT_CODE=$?
set -e
if [ "$EXIT_CODE" -ne 0 ]; then
    pass "TEST 3 — Invalid month validation correctly rejected"
else
    fail "TEST 3 — Expected validation failure for month=13 but got exit code 0"
fi

# ─── Test 4: Missing required env var → clean failure ───
log "TEST 4 — Missing S3_BUCKET env var (should fail at validation)..."
set +e
docker run --rm \
    --network "$DOCKER_NETWORK" \
    -e PGHOST="$POSTGRES_CONTAINER" -e PGPORT="5432" \
    -e PGDATABASE="datafeeddatabase" -e PGUSER="marsquantMasterUser" \
    -e PGPASSWORD="testpassword" \
    -e TARGET_YEAR="2025" -e TARGET_MONTH="09" -e TARGET_DAY="01" \
    -e TABLE_NAME="nifty50_table" -e SCHEMA_NAME="datafeedschema" \
    "$IMAGE_NAME"
EXIT_CODE=$?
set -e
if [ "$EXIT_CODE" -ne 0 ]; then
    pass "TEST 4 — Missing S3_BUCKET correctly rejected at validation"
else
    fail "TEST 4 — Expected validation failure for missing S3_BUCKET but got exit code 0"
fi

# ─── Test 5: Wrong DB password → connection failure ───
log "TEST 5 — Wrong PGPASSWORD (connection should fail cleanly)..."
set +e
docker run --rm \
    --network "$DOCKER_NETWORK" \
    -e PGHOST="$POSTGRES_CONTAINER" -e PGPORT="5432" \
    -e PGDATABASE="datafeeddatabase" -e PGUSER="marsquantMasterUser" \
    -e PGPASSWORD="wrongpassword" \
    -e TARGET_YEAR="2025" -e TARGET_MONTH="09" -e TARGET_DAY="01" \
    -e TABLE_NAME="nifty50_table" -e SCHEMA_NAME="datafeedschema" \
    -e S3_BUCKET="marsquant-test-bucket" -e DRY_RUN="true" \
    "$IMAGE_NAME"
EXIT_CODE=$?
set -e
if [ "$EXIT_CODE" -ne 0 ]; then
    pass "TEST 5 — Wrong password correctly rejected"
else
    fail "TEST 5 — Expected connection failure but got exit code 0"
fi

echo ""
log "════════════════════════════════════════════"
log "  ALL EXPORT TESTS PASSED (5/5) ✓"
log "════════════════════════════════════════════"
