#!/bin/bash
# ──────────────────────────────────────────────
# export.sh — RDS pg_dump → S3 Upload
# ──────────────────────────────────────────────
# This script is the core of the migration pipeline.
# It runs inside the ECS Fargate container.
#
# WHAT IT DOES:
#   1. Validates all required environment variables
#   2. Connects to RDS and runs pg_dump for the target daily partition
#   3. Compresses the output with gzip
#   4. Uploads to S3 at: s3://bucket/backups/YYYY/MM/DD/dump_YYYYMMDD.sql.gz
#   5. Writes a metadata manifest (row count, file size, checksum)
#   6. Exits 0 on success, 1 on failure
#
# REQUIRED ENV VARS (set by ECS task definition):
#   PGHOST       — RDS endpoint
#   PGPORT       — RDS port (usually 5432)
#   PGDATABASE   — database name
#   PGUSER       — database user
#   PGPASSWORD   — database password (from Secrets Manager)
#   TARGET_YEAR  — e.g., "2025"
#   TARGET_MONTH — e.g., "09"
#   TARGET_DAY   — e.g., "01"
#   TABLE_NAME   — e.g., "nifty50_table"  (partition parent name)
#   SCHEMA_NAME  — e.g., "datafeedschema"
#   S3_BUCKET    — S3 bucket name
#
# OPTIONAL:
#   DRY_RUN      — if "true", runs everything except the actual upload
# ──────────────────────────────────────────────

set -euo pipefail

# ─── Colors for logging ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2; }

# ─── Step 1: Validate environment variables ───
log "Starting RDS to S3 export..."

REQUIRED_VARS=("PGHOST" "PGPORT" "PGDATABASE" "PGUSER" "PGPASSWORD" "TARGET_YEAR" "TARGET_MONTH" "TARGET_DAY" "TABLE_NAME" "SCHEMA_NAME" "S3_BUCKET")
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    error "Required environment variable $var is not set"
    exit 1
  fi
done

# Validate year format (4 digits)
if ! [[ "$TARGET_YEAR" =~ ^[0-9]{4}$ ]]; then
  error "TARGET_YEAR must be 4 digits, got: $TARGET_YEAR"
  exit 1
fi

# Validate month format (01-12)
if ! [[ "$TARGET_MONTH" =~ ^(0[1-9]|1[0-2])$ ]]; then
  error "TARGET_MONTH must be 01-12, got: $TARGET_MONTH"
  exit 1
fi

# Validate day format (01-31)
if ! [[ "$TARGET_DAY" =~ ^(0[1-9]|[12][0-9]|3[01])$ ]]; then
  error "TARGET_DAY must be 01-31, got: $TARGET_DAY"
  exit 1
fi

DRY_RUN="${DRY_RUN:-false}"

# ─── Derived names ───
PARTITION_NAME="${TABLE_NAME}_${TARGET_YEAR}_${TARGET_MONTH}_${TARGET_DAY}"
DUMP_FILE="/tmp/dump_${TARGET_YEAR}${TARGET_MONTH}${TARGET_DAY}.sql.gz"
S3_KEY="backups/${TARGET_YEAR}/${TARGET_MONTH}/${TARGET_DAY}/dump_${TARGET_YEAR}${TARGET_MONTH}${TARGET_DAY}.sql.gz"
METADATA_KEY="metadata/${TARGET_YEAR}/${TARGET_MONTH}/${TARGET_DAY}/manifest.json"

log "Table:     ${SCHEMA_NAME}.${TABLE_NAME}"
log "Partition: ${PARTITION_NAME}"
log "Target:    ${TARGET_YEAR}-${TARGET_MONTH}-${TARGET_DAY}"
log "S3 destination: s3://${S3_BUCKET}/${S3_KEY}"

# ─── Step 2: Test RDS connectivity ───
log "Testing RDS connectivity..."
if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT 1;" > /dev/null 2>&1; then
  error "Cannot connect to RDS at ${PGHOST}:${PGPORT}"
  exit 1
fi
log "RDS connection successful"

# ─── Step 3: Verify partition exists ───
log "Checking partition ${PARTITION_NAME} exists..."
PARTITION_EXISTS=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
  -t -A -c "
    SELECT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = '${SCHEMA_NAME}'
        AND table_name   = '${PARTITION_NAME}'
    );
  " 2>&1)

if [ "$PARTITION_EXISTS" != "t" ]; then
  error "Partition ${SCHEMA_NAME}.${PARTITION_NAME} does not exist. Aborting."
  exit 1
fi
log "Partition confirmed"

# ─── Step 4: Get row count BEFORE dump (for manifest + verification) ───
# Counts directly from the daily partition — fast, no full table scan.
log "Counting rows in ${PARTITION_NAME}..."

ROW_COUNT=""
if ! ROW_COUNT=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
  -t -A -c "SELECT COUNT(*) FROM ${SCHEMA_NAME}.\"${PARTITION_NAME}\";" 2>&1); then
  error "Failed to get row count: $ROW_COUNT"
  exit 1
fi

log "Row count: ${ROW_COUNT}"

if [ "$ROW_COUNT" -eq 0 ]; then
  error "Row count is 0 — no data found in ${PARTITION_NAME}. Aborting."
  exit 1
fi

# ─── Step 5: Run pg_dump ───
# Targets only the specific daily partition in the correct schema.
# --no-owner and --no-privileges make the dump portable across environments.
log "Running pg_dump for ${SCHEMA_NAME}.${PARTITION_NAME}..."
DUMP_START=$(date +%s)

pg_dump \
  -h "$PGHOST" \
  -p "$PGPORT" \
  -U "$PGUSER" \
  -d "$PGDATABASE" \
  -t "${SCHEMA_NAME}.${PARTITION_NAME}" \
  --no-owner \
  --no-privileges \
  --verbose \
  -Z 6 \
  -f "$DUMP_FILE" \
  2>&1 | while IFS= read -r line; do log "  pg_dump: $line"; done

# Check if dump file was created and is non-empty
if [ ! -f "$DUMP_FILE" ]; then
  error "Dump file was not created"
  exit 1
fi

DUMP_END=$(date +%s)
DUMP_DURATION=$((DUMP_END - DUMP_START))
FILE_SIZE=$(stat -c%s "$DUMP_FILE" 2>/dev/null || stat -f%z "$DUMP_FILE")
FILE_SIZE_MB=$((FILE_SIZE / 1024 / 1024))
CHECKSUM=$(md5sum "$DUMP_FILE" | awk '{print $1}')

log "pg_dump complete in ${DUMP_DURATION}s"
log "File size: ${FILE_SIZE_MB} MB"
log "MD5 checksum: ${CHECKSUM}"

if [ "$FILE_SIZE" -lt 1024 ]; then
  error "Dump file is suspiciously small (${FILE_SIZE} bytes). Aborting."
  exit 1
fi

# ─── Step 6: Upload to S3 ───
if [ "$DRY_RUN" = "true" ]; then
  warn "DRY_RUN=true — skipping S3 upload"
else
  log "Uploading to s3://${S3_BUCKET}/${S3_KEY}..."
  UPLOAD_START=$(date +%s)

  aws s3 cp "$DUMP_FILE" "s3://${S3_BUCKET}/${S3_KEY}" \
    --sse AES256 \
    --only-show-errors

  if [ $? -ne 0 ]; then
    error "S3 upload failed"
    exit 1
  fi

  UPLOAD_END=$(date +%s)
  UPLOAD_DURATION=$((UPLOAD_END - UPLOAD_START))
  log "Upload complete in ${UPLOAD_DURATION}s"

  # Verify upload by checking S3 object exists and size matches
  S3_SIZE=$(aws s3api head-object \
    --bucket "$S3_BUCKET" \
    --key "$S3_KEY" \
    --query 'ContentLength' \
    --output text 2>&1)

  if [ "$S3_SIZE" != "$FILE_SIZE" ]; then
    error "S3 file size ($S3_SIZE) does not match local file size ($FILE_SIZE)"
    exit 1
  fi
  log "S3 upload verified — sizes match"
fi

# ─── Step 7: Write metadata manifest ───
# This JSON file is what the verification Lambda reads.
MANIFEST=$(cat <<EOF
{
  "year": "${TARGET_YEAR}",
  "month": "${TARGET_MONTH}",
  "day": "${TARGET_DAY}",
  "table_name": "${TABLE_NAME}",
  "schema_name": "${SCHEMA_NAME}",
  "partition_name": "${PARTITION_NAME}",
  "s3_bucket": "${S3_BUCKET}",
  "s3_key": "${S3_KEY}",
  "file_size_bytes": ${FILE_SIZE},
  "md5_checksum": "${CHECKSUM}",
  "row_count": ${ROW_COUNT},
  "dump_duration_seconds": ${DUMP_DURATION},
  "pg_dump_version": "$(pg_dump --version | head -1)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

if [ "$DRY_RUN" = "true" ]; then
  warn "DRY_RUN=true — skipping metadata upload"
  log "Manifest would be:"
  echo "$MANIFEST"
else
  echo "$MANIFEST" | aws s3 cp - "s3://${S3_BUCKET}/${METADATA_KEY}" \
    --sse AES256 \
    --content-type "application/json" \
    --only-show-errors

  log "Metadata manifest uploaded to s3://${S3_BUCKET}/${METADATA_KEY}"
fi

# ─── Step 8: Cleanup ───
rm -f "$DUMP_FILE"
log "Local dump file cleaned up"

# ─── Done ───
log "════════════════════════════════════════════"
log "  EXPORT COMPLETE"
log "  Partition: ${PARTITION_NAME}"
log "  Date:      ${TARGET_YEAR}-${TARGET_MONTH}-${TARGET_DAY}"
log "  Rows:      ${ROW_COUNT}"
log "  Size:      ${FILE_SIZE_MB} MB"
log "  Checksum:  ${CHECKSUM}"
log "  Duration:  ${DUMP_DURATION}s (dump) + ${UPLOAD_DURATION:-0}s (upload)"
log "════════════════════════════════════════════"

exit 0
