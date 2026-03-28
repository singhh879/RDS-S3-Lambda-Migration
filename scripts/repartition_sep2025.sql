-- ============================================================
-- Re-partition nifty50_table Sep 2025: monthly → 30 daily
-- Run in pgAdmin AFTER market close (3:30 PM IST)
-- Estimated time: 30–60 minutes
-- ============================================================


-- ── STEP 0: Run this first (separately) to confirm partition name ──────────
-- Just run this SELECT, check the result, then proceed to Step 1.

SELECT
    c.relname        AS partition_name,
    pg_get_expr(c.relpartbound, c.oid) AS partition_range,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_inherits i  ON i.inhrelid = c.oid
JOIN pg_class p     ON p.oid = i.inhparent
JOIN pg_namespace pn ON pn.oid = p.relnamespace
WHERE pn.nspname = 'datafeedschema'
  AND p.relname  = 'nifty50_table'
  AND pg_get_expr(c.relpartbound, c.oid) LIKE '%2025-09%'
ORDER BY c.relname;

-- Expected result: one row, something like:
--   partition_name            | nifty50_table_2025_09
--   partition_range           | FOR VALUES FROM ('2025-09-01') TO ('2025-10-01')
--   size                      | ~50–200 GB
--
-- If the name differs from nifty50_table_2025_09, update MONTHLY_PARTITION
-- in Step 1 below before running.


-- ============================================================
-- MAIN SCRIPT — run everything below as one transaction
-- ============================================================

BEGIN;

-- ── STEP 1: Record row count before touching anything ─────────────────────
-- Save this number. At the end we verify daily partitions match it.

DO $$
DECLARE
    monthly_count  BIGINT;
    partition_name TEXT := 'nifty50_table_2025_09';   -- ← update if Step 0 shows a different name
BEGIN
    -- Verify the monthly partition exists
    IF NOT EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'datafeedschema' AND c.relname = partition_name
    ) THEN
        RAISE EXCEPTION 'Partition datafeedschema.% not found. Check name from Step 0.', partition_name;
    END IF;

    EXECUTE format('SELECT COUNT(*) FROM datafeedschema.%I', partition_name)
        INTO monthly_count;

    RAISE NOTICE '================================================';
    RAISE NOTICE 'Monthly partition: datafeedschema.%', partition_name;
    RAISE NOTICE 'Row count before repartition: %', monthly_count;
    RAISE NOTICE 'Expected after: same count spread across 30 daily partitions';
    RAISE NOTICE '================================================';
END $$;


-- ── STEP 2: Detach the monthly partition ──────────────────────────────────
-- This removes it from the parent table but keeps all data intact.
-- The table datafeedschema.nifty50_table_2025_09 still exists as a standalone table.

ALTER TABLE datafeedschema.nifty50_table
    DETACH PARTITION datafeedschema.nifty50_table_2025_09;


-- ── STEP 3: Create 30 daily partitions (Sep 1–30 2025) ───────────────────
-- Sep 2025 has 30 days. Each partition covers one calendar day.
-- Rows in the parent table will auto-route here based on tickd value.

CREATE TABLE datafeedschema.nifty50_table_2025_09_01 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-01') TO ('2025-09-02');
CREATE TABLE datafeedschema.nifty50_table_2025_09_02 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-02') TO ('2025-09-03');
CREATE TABLE datafeedschema.nifty50_table_2025_09_03 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-03') TO ('2025-09-04');
CREATE TABLE datafeedschema.nifty50_table_2025_09_04 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-04') TO ('2025-09-05');
CREATE TABLE datafeedschema.nifty50_table_2025_09_05 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-05') TO ('2025-09-06');
CREATE TABLE datafeedschema.nifty50_table_2025_09_06 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-06') TO ('2025-09-07');
CREATE TABLE datafeedschema.nifty50_table_2025_09_07 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-07') TO ('2025-09-08');
CREATE TABLE datafeedschema.nifty50_table_2025_09_08 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-08') TO ('2025-09-09');
CREATE TABLE datafeedschema.nifty50_table_2025_09_09 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-09') TO ('2025-09-10');
CREATE TABLE datafeedschema.nifty50_table_2025_09_10 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-10') TO ('2025-09-11');
CREATE TABLE datafeedschema.nifty50_table_2025_09_11 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-11') TO ('2025-09-12');
CREATE TABLE datafeedschema.nifty50_table_2025_09_12 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-12') TO ('2025-09-13');
CREATE TABLE datafeedschema.nifty50_table_2025_09_13 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-13') TO ('2025-09-14');
CREATE TABLE datafeedschema.nifty50_table_2025_09_14 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-14') TO ('2025-09-15');
CREATE TABLE datafeedschema.nifty50_table_2025_09_15 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-15') TO ('2025-09-16');
CREATE TABLE datafeedschema.nifty50_table_2025_09_16 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-16') TO ('2025-09-17');
CREATE TABLE datafeedschema.nifty50_table_2025_09_17 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-17') TO ('2025-09-18');
CREATE TABLE datafeedschema.nifty50_table_2025_09_18 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-18') TO ('2025-09-19');
CREATE TABLE datafeedschema.nifty50_table_2025_09_19 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-19') TO ('2025-09-20');
CREATE TABLE datafeedschema.nifty50_table_2025_09_20 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-20') TO ('2025-09-21');
CREATE TABLE datafeedschema.nifty50_table_2025_09_21 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-21') TO ('2025-09-22');
CREATE TABLE datafeedschema.nifty50_table_2025_09_22 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-22') TO ('2025-09-23');
CREATE TABLE datafeedschema.nifty50_table_2025_09_23 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-23') TO ('2025-09-24');
CREATE TABLE datafeedschema.nifty50_table_2025_09_24 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-24') TO ('2025-09-25');
CREATE TABLE datafeedschema.nifty50_table_2025_09_25 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-25') TO ('2025-09-26');
CREATE TABLE datafeedschema.nifty50_table_2025_09_26 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-26') TO ('2025-09-27');
CREATE TABLE datafeedschema.nifty50_table_2025_09_27 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-27') TO ('2025-09-28');
CREATE TABLE datafeedschema.nifty50_table_2025_09_28 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-28') TO ('2025-09-29');
CREATE TABLE datafeedschema.nifty50_table_2025_09_29 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-29') TO ('2025-09-30');
CREATE TABLE datafeedschema.nifty50_table_2025_09_30 PARTITION OF datafeedschema.nifty50_table FOR VALUES FROM ('2025-09-30') TO ('2025-10-01');


-- ── STEP 4: Re-insert data ────────────────────────────────────────────────
-- PostgreSQL automatically routes each row to the correct daily partition
-- based on the tickd value. This is the slow step (30–60 min).
-- You will see nothing in pgAdmin until it completes — that is normal.

INSERT INTO datafeedschema.nifty50_table
    SELECT * FROM datafeedschema.nifty50_table_2025_09;


-- ── STEP 5: Verify row counts match before committing ─────────────────────
-- This runs inside the transaction. If counts don't match, we ROLLBACK.

DO $$
DECLARE
    original_count BIGINT;
    daily_count    BIGINT;
BEGIN
    SELECT COUNT(*) INTO original_count
        FROM datafeedschema.nifty50_table_2025_09;

    SELECT COUNT(*) INTO daily_count
        FROM datafeedschema.nifty50_table
        WHERE tickd >= '2025-09-01' AND tickd < '2025-10-01';

    RAISE NOTICE 'Original monthly count : %', original_count;
    RAISE NOTICE 'Daily partitions count : %', daily_count;

    IF original_count <> daily_count THEN
        RAISE EXCEPTION 'Row count mismatch! % vs %. Rolling back.', original_count, daily_count;
    END IF;

    RAISE NOTICE '✓ Counts match. Safe to commit.';
END $$;


-- ── STEP 6: Drop the old monthly partition ───────────────────────────────
-- Only reached if Step 5 passed. Data is now in the 30 daily partitions.

DROP TABLE datafeedschema.nifty50_table_2025_09;


COMMIT;

-- ── STEP 7: Post-commit verification (run separately after COMMIT) ────────
-- Confirm 30 daily partitions exist and each has data.

SELECT
    c.relname                                          AS partition,
    pg_size_pretty(pg_total_relation_size(c.oid))      AS size,
    (SELECT COUNT(*) FROM datafeedschema.nifty50_table
     WHERE tickd >= (SELECT lo FROM
         (SELECT split_part(pg_get_expr(c.relpartbound, c.oid), '''', 2) AS lo) t)
       AND tickd <  (SELECT hi FROM
         (SELECT split_part(pg_get_expr(c.relpartbound, c.oid), '''', 4) AS hi) t)
    )                                                  AS row_count
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_inherits i  ON i.inhrelid = c.oid
JOIN pg_class p     ON p.oid = i.inhparent
WHERE n.nspname = 'datafeedschema'
  AND p.relname = 'nifty50_table'
  AND c.relname LIKE 'nifty50_table_2025_09_%'
ORDER BY c.relname;
