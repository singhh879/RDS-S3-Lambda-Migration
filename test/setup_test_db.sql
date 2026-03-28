-- ──────────────────────────────────────────────
-- Test Database Setup
-- ──────────────────────────────────────────────
-- Mirrors the production nifty50_table structure:
--   42 columns, PARTITION BY RANGE (tickd), datafeedschema schema
--
-- Creates 3 daily partitions (2025-09-01, 02, 03) with 5,000 rows each.
-- Partition naming: nifty50_table_YYYY_MM_DD  (matches pipeline convention)
--
-- This file auto-runs on first container boot via docker-entrypoint-initdb.d.
-- To reset: docker compose down -v && docker compose up -d
-- ──────────────────────────────────────────────

\echo '=== Setting up datafeedschema ==='
CREATE SCHEMA IF NOT EXISTS datafeedschema;

-- ──────────────────────────────────────────────
-- Parent partitioned table  (42 columns, tickd as partition key)
-- ──────────────────────────────────────────────
\echo '=== Creating nifty50_table (partitioned parent) ==='
CREATE TABLE datafeedschema.nifty50_table (
    id              BIGSERIAL,                             -- 1
    tickd           DATE          NOT NULL,                -- 2  ← partition key
    ticktime        TIME          NOT NULL,                -- 3
    exchange        VARCHAR(10),                           -- 4
    instrument      VARCHAR(50),                           -- 5
    expiry          DATE,                                  -- 6
    strike          NUMERIC(10,2),                         -- 7
    option_type     CHAR(2),                               -- 8
    open            NUMERIC(12,4),                         -- 9
    high            NUMERIC(12,4),                         -- 10
    low             NUMERIC(12,4),                         -- 11
    close           NUMERIC(12,4),                         -- 12
    last_price      NUMERIC(12,4),                         -- 13
    prev_close      NUMERIC(12,4),                         -- 14
    net_change      NUMERIC(12,4),                         -- 15
    pct_change      NUMERIC(8,4),                          -- 16
    volume          BIGINT,                                -- 17
    traded_value    NUMERIC(20,4),                         -- 18
    open_interest   BIGINT,                                -- 19
    oi_change       BIGINT,                                -- 20
    bid_price       NUMERIC(12,4),                         -- 21
    bid_qty         BIGINT,                                -- 22
    ask_price       NUMERIC(12,4),                         -- 23
    ask_qty         BIGINT,                                -- 24
    implied_vol     NUMERIC(8,4),                          -- 25
    delta           NUMERIC(8,6),                          -- 26
    gamma           NUMERIC(8,6),                          -- 27
    theta           NUMERIC(8,6),                          -- 28
    vega            NUMERIC(8,6),                          -- 29
    rho             NUMERIC(8,6),                          -- 30
    underlying_px   NUMERIC(12,4),                         -- 31
    spot_price      NUMERIC(12,4),                         -- 32
    time_to_expiry  NUMERIC(8,4),                          -- 33
    days_to_expiry  INTEGER,                               -- 34
    pcr             NUMERIC(8,4),                          -- 35
    vwap            NUMERIC(12,4),                         -- 36
    atm_strike      NUMERIC(10,2),                         -- 37
    spread          NUMERIC(12,4),                         -- 38
    depth_ratio     NUMERIC(8,4),                          -- 39
    total_sell_qty  BIGINT,                                -- 40
    total_buy_qty   BIGINT,                                -- 41
    created_at      TIMESTAMP     DEFAULT NOW()            -- 42
) PARTITION BY RANGE (tickd);

-- ──────────────────────────────────────────────
-- Daily partitions
-- ──────────────────────────────────────────────
\echo '=== Creating daily partitions ==='

CREATE TABLE datafeedschema.nifty50_table_2025_09_01
    PARTITION OF datafeedschema.nifty50_table
    FOR VALUES FROM ('2025-09-01') TO ('2025-09-02');

CREATE TABLE datafeedschema.nifty50_table_2025_09_02
    PARTITION OF datafeedschema.nifty50_table
    FOR VALUES FROM ('2025-09-02') TO ('2025-09-03');

CREATE TABLE datafeedschema.nifty50_table_2025_09_03
    PARTITION OF datafeedschema.nifty50_table
    FOR VALUES FROM ('2025-09-03') TO ('2025-09-04');

-- ──────────────────────────────────────────────
-- Test data — 5,000 rows per partition
-- ──────────────────────────────────────────────
-- generate_series n=1..5000, 5-second tick intervals starting 09:15:00
-- instrument cycles: NIFTY / BANKNIFTY / FINNIFTY  (realistic NFO mix)
-- strikes: 24000 + (n % 50) * 100  →  24000..28900
-- option_type: CE for even n, PE for odd n
-- All numeric columns use random() within realistic market ranges
-- ──────────────────────────────────────────────

\echo '=== Inserting 5,000 rows into 2025-09-01 ==='
INSERT INTO datafeedschema.nifty50_table (
    tickd, ticktime, exchange, instrument, expiry, strike, option_type,
    open, high, low, close, last_price, prev_close, net_change, pct_change,
    volume, traded_value, open_interest, oi_change,
    bid_price, bid_qty, ask_price, ask_qty,
    implied_vol, delta, gamma, theta, vega, rho,
    underlying_px, spot_price, time_to_expiry, days_to_expiry,
    pcr, vwap, atm_strike, spread, depth_ratio,
    total_sell_qty, total_buy_qty
)
SELECT
    '2025-09-01'::date,
    (TIME '09:15:00' + (n * INTERVAL '5 second'))::time,
    'NFO',
    CASE (n % 3) WHEN 0 THEN 'NIFTY' WHEN 1 THEN 'BANKNIFTY' ELSE 'FINNIFTY' END,
    '2025-09-25'::date,
    (24000 + (n % 50) * 100)::numeric,
    CASE WHEN n % 2 = 0 THEN 'CE' ELSE 'PE' END,
    ROUND((50  + random() * 200)::numeric, 4),
    ROUND((60  + random() * 200)::numeric, 4),
    ROUND((40  + random() * 200)::numeric, 4),
    ROUND((55  + random() * 200)::numeric, 4),
    ROUND((55  + random() * 200)::numeric, 4),
    ROUND((50  + random() * 200)::numeric, 4),
    ROUND(((random() * 20) - 10)::numeric, 4),
    ROUND(((random() * 10) -  5)::numeric, 4),
    (500  + (random() * 9500)::int)::bigint,
    ROUND((10000 + random() * 990000)::numeric, 4),
    (1000 + (random() * 49000)::int)::bigint,
    ((-500) + (random() * 1000)::int)::bigint,
    ROUND((55 + random() * 200)::numeric, 4),
    (100 + (random() * 900)::int)::bigint,
    ROUND((56 + random() * 200)::numeric, 4),
    (100 + (random() * 900)::int)::bigint,
    ROUND((15 + random() * 35)::numeric, 4),
    ROUND((random() * 0.8)::numeric, 6),
    ROUND((random() * 0.01)::numeric, 6),
    ROUND(((random() * -10))::numeric, 6),
    ROUND((random() * 20)::numeric, 6),
    ROUND((random() * 5)::numeric, 6),
    ROUND((25000 + random() * 500)::numeric, 4),
    ROUND((25000 + random() * 500)::numeric, 4),
    ROUND((random() * 0.1)::numeric, 4),
    (1 + (random() * 29)::int)::int,
    ROUND((random() * 2)::numeric, 4),
    ROUND((55 + random() * 200)::numeric, 4),
    (24000 + (n % 50) * 100)::numeric,
    ROUND((random() * 5)::numeric, 4),
    ROUND((random() * 2)::numeric, 4),
    (100 + (random() * 4900)::int)::bigint,
    (100 + (random() * 4900)::int)::bigint
FROM generate_series(1, 5000) AS n;

\echo '=== Inserting 5,000 rows into 2025-09-02 ==='
INSERT INTO datafeedschema.nifty50_table (
    tickd, ticktime, exchange, instrument, expiry, strike, option_type,
    open, high, low, close, last_price, prev_close, net_change, pct_change,
    volume, traded_value, open_interest, oi_change,
    bid_price, bid_qty, ask_price, ask_qty,
    implied_vol, delta, gamma, theta, vega, rho,
    underlying_px, spot_price, time_to_expiry, days_to_expiry,
    pcr, vwap, atm_strike, spread, depth_ratio,
    total_sell_qty, total_buy_qty
)
SELECT
    '2025-09-02'::date,
    (TIME '09:15:00' + (n * INTERVAL '5 second'))::time,
    'NFO',
    CASE (n % 3) WHEN 0 THEN 'NIFTY' WHEN 1 THEN 'BANKNIFTY' ELSE 'FINNIFTY' END,
    '2025-09-25'::date,
    (24000 + (n % 50) * 100)::numeric,
    CASE WHEN n % 2 = 0 THEN 'CE' ELSE 'PE' END,
    ROUND((50  + random() * 200)::numeric, 4),
    ROUND((60  + random() * 200)::numeric, 4),
    ROUND((40  + random() * 200)::numeric, 4),
    ROUND((55  + random() * 200)::numeric, 4),
    ROUND((55  + random() * 200)::numeric, 4),
    ROUND((50  + random() * 200)::numeric, 4),
    ROUND(((random() * 20) - 10)::numeric, 4),
    ROUND(((random() * 10) -  5)::numeric, 4),
    (500  + (random() * 9500)::int)::bigint,
    ROUND((10000 + random() * 990000)::numeric, 4),
    (1000 + (random() * 49000)::int)::bigint,
    ((-500) + (random() * 1000)::int)::bigint,
    ROUND((55 + random() * 200)::numeric, 4),
    (100 + (random() * 900)::int)::bigint,
    ROUND((56 + random() * 200)::numeric, 4),
    (100 + (random() * 900)::int)::bigint,
    ROUND((15 + random() * 35)::numeric, 4),
    ROUND((random() * 0.8)::numeric, 6),
    ROUND((random() * 0.01)::numeric, 6),
    ROUND(((random() * -10))::numeric, 6),
    ROUND((random() * 20)::numeric, 6),
    ROUND((random() * 5)::numeric, 6),
    ROUND((25000 + random() * 500)::numeric, 4),
    ROUND((25000 + random() * 500)::numeric, 4),
    ROUND((random() * 0.1)::numeric, 4),
    (1 + (random() * 29)::int)::int,
    ROUND((random() * 2)::numeric, 4),
    ROUND((55 + random() * 200)::numeric, 4),
    (24000 + (n % 50) * 100)::numeric,
    ROUND((random() * 5)::numeric, 4),
    ROUND((random() * 2)::numeric, 4),
    (100 + (random() * 4900)::int)::bigint,
    (100 + (random() * 4900)::int)::bigint
FROM generate_series(1, 5000) AS n;

\echo '=== Inserting 5,000 rows into 2025-09-03 ==='
INSERT INTO datafeedschema.nifty50_table (
    tickd, ticktime, exchange, instrument, expiry, strike, option_type,
    open, high, low, close, last_price, prev_close, net_change, pct_change,
    volume, traded_value, open_interest, oi_change,
    bid_price, bid_qty, ask_price, ask_qty,
    implied_vol, delta, gamma, theta, vega, rho,
    underlying_px, spot_price, time_to_expiry, days_to_expiry,
    pcr, vwap, atm_strike, spread, depth_ratio,
    total_sell_qty, total_buy_qty
)
SELECT
    '2025-09-03'::date,
    (TIME '09:15:00' + (n * INTERVAL '5 second'))::time,
    'NFO',
    CASE (n % 3) WHEN 0 THEN 'NIFTY' WHEN 1 THEN 'BANKNIFTY' ELSE 'FINNIFTY' END,
    '2025-09-25'::date,
    (24000 + (n % 50) * 100)::numeric,
    CASE WHEN n % 2 = 0 THEN 'CE' ELSE 'PE' END,
    ROUND((50  + random() * 200)::numeric, 4),
    ROUND((60  + random() * 200)::numeric, 4),
    ROUND((40  + random() * 200)::numeric, 4),
    ROUND((55  + random() * 200)::numeric, 4),
    ROUND((55  + random() * 200)::numeric, 4),
    ROUND((50  + random() * 200)::numeric, 4),
    ROUND(((random() * 20) - 10)::numeric, 4),
    ROUND(((random() * 10) -  5)::numeric, 4),
    (500  + (random() * 9500)::int)::bigint,
    ROUND((10000 + random() * 990000)::numeric, 4),
    (1000 + (random() * 49000)::int)::bigint,
    ((-500) + (random() * 1000)::int)::bigint,
    ROUND((55 + random() * 200)::numeric, 4),
    (100 + (random() * 900)::int)::bigint,
    ROUND((56 + random() * 200)::numeric, 4),
    (100 + (random() * 900)::int)::bigint,
    ROUND((15 + random() * 35)::numeric, 4),
    ROUND((random() * 0.8)::numeric, 6),
    ROUND((random() * 0.01)::numeric, 6),
    ROUND(((random() * -10))::numeric, 6),
    ROUND((random() * 20)::numeric, 6),
    ROUND((random() * 5)::numeric, 6),
    ROUND((25000 + random() * 500)::numeric, 4),
    ROUND((25000 + random() * 500)::numeric, 4),
    ROUND((random() * 0.1)::numeric, 4),
    (1 + (random() * 29)::int)::int,
    ROUND((random() * 2)::numeric, 4),
    ROUND((55 + random() * 200)::numeric, 4),
    (24000 + (n % 50) * 100)::numeric,
    ROUND((random() * 5)::numeric, 4),
    ROUND((random() * 2)::numeric, 4),
    (100 + (random() * 4900)::int)::bigint,
    (100 + (random() * 4900)::int)::bigint
FROM generate_series(1, 5000) AS n;

-- ──────────────────────────────────────────────
-- Sanity check
-- ──────────────────────────────────────────────
\echo '=== Row counts per partition ==='
SELECT
    tableoid::regclass AS partition,
    COUNT(*)           AS row_count
FROM datafeedschema.nifty50_table
GROUP BY tableoid
ORDER BY partition;

\echo '=== Setup complete: 3 partitions × 5,000 rows each ==='
