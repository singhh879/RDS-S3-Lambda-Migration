-- ============================================================
-- Restore a daily nifty50 partition from S3 dump
-- Run in pgAdmin after downloading the dump file from S3
-- ============================================================
-- BEFORE RUNNING THIS SCRIPT:
--
--   1. Download the dump from S3 (run in terminal):
--      aws s3 cp s3://marsquant-market-data-archive/backups/2025/09/01/dump_20250901.sql.gz . --profile harshit-singh
--      gunzip dump_20250901.sql.gz
--
--   2. Restore the table (run in terminal, not pgAdmin):
--      psql -h mq-datafeed-postgres-instance-prod-v1.cbiike0eiqk9.ap-south-1.rds.amazonaws.com \
--           -U marsquantMasterUser \
--           -d datafeeddatabase \
--           -f dump_20250901.sql
--
--   3. Then run the SQL below in pgAdmin to verify + attach.
--
-- NOTE: The dump restores the partition as a standalone table.
-- The SQL below re-attaches it to the parent and verifies data.
-- ============================================================


-- ── STEP 1: Confirm the restored table exists and has data ────────────────
-- Run this first before attaching anything.

SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(
        quote_ident(schemaname) || '.' || quote_ident(tablename)
    )) AS size
FROM pg_tables
WHERE schemaname = 'datafeedschema'
  AND tablename  = 'nifty50_table_2025_09_01';  -- ← change date as needed

-- Expected: one row with a non-zero size.
-- If empty or missing, the psql restore step above did not complete.


-- ── STEP 2: Check row count of restored table ─────────────────────────────
-- Compare this against the manifest.json row_count field in S3.

SELECT COUNT(*) AS restored_row_count
FROM datafeedschema.nifty50_table_2025_09_01;  -- ← change date as needed

-- Open S3 → marsquant-market-data-archive → metadata/2025/09/01/manifest.json
-- and compare the row_count field. They must match before proceeding.


-- ── STEP 3: Spot-check a few rows ────────────────────────────────────────
-- Sanity check: confirm data looks like real tick data (not nulls, not zeros).

SELECT *
FROM datafeedschema.nifty50_table_2025_09_01  -- ← change date as needed
ORDER BY tickd
LIMIT 10;

-- Check:
--   tickd     → should be timestamps within 2025-09-01
--   open/high/low/close → should be non-zero decimal values (Nifty50 range: ~24000–26000)
--   volume    → should be non-zero integers


-- ── STEP 4: Check if that daily slot already exists in the parent ─────────
-- Safety check: if the partition was never dropped, attaching will fail.

SELECT COUNT(*) AS existing_partition_count
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_inherits i  ON i.inhrelid = c.oid
JOIN pg_class p     ON p.oid = i.inhparent
WHERE n.nspname = 'datafeedschema'
  AND p.relname  = 'nifty50_table'
  AND c.relname  = 'nifty50_table_2025_09_01';  -- ← change date as needed

-- Expected: 0 (slot is empty, safe to attach)
-- If 1: the partition already exists — do NOT run Step 5, data is already there.


-- ── STEP 5: Attach the restored table as a partition ─────────────────────
-- Only run if Step 4 returned 0.
-- This makes the data queryable through the parent nifty50_table again.

ALTER TABLE datafeedschema.nifty50_table
    ATTACH PARTITION datafeedschema.nifty50_table_2025_09_01  -- ← change date as needed
    FOR VALUES FROM ('2025-09-01') TO ('2025-09-02');          -- ← change dates as needed


-- ── STEP 6: Final verification — query through the parent ─────────────────
-- Confirm data is accessible through the parent table (not just the child).

SELECT
    COUNT(*)                      AS row_count,
    MIN(tickd)                    AS first_tick,
    MAX(tickd)                    AS last_tick,
    ROUND(AVG(close)::numeric, 2) AS avg_close
FROM datafeedschema.nifty50_table
WHERE tickd >= '2025-09-01'
  AND tickd <  '2025-09-02';

-- Expected:
--   row_count  → matches manifest.json and Step 2
--   first_tick → 2025-09-01 (market open time)
--   last_tick  → 2025-09-01 (before midnight)
--   avg_close  → sensible Nifty50 value (~24000–26000)
